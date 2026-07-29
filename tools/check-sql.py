# -*- coding: utf-8 -*-
"""Send every query this resource can issue to a real database, and let it say no.

    set VPHONE_DB=mysql://user:password@127.0.0.1:3306/your_db
    python tools/check-sql.py

`tools/check.py` reads the source and counts placeholders against parameters. That catches a
whole class of mistake and cannot catch this one: a statement whose SYNTAX or whose COLUMN
NAMES the database refuses. Those do not fail until the line runs, and a line that only runs at
three in the morning during a cleanup pass is a line nobody watches.

So this asks the database. `PREPARE` runs the parser and the name resolver and then stops -
nothing is read, nothing is written, nothing is deleted. A statement that would have thrown in
production throws here, in a second, against your own schema.

**What it found the first time it was run**, none of which any static check had:

  * All six orphan-cleanup deletes were a parse error on every pass. They were written as
    `DELETE h FROM x h LEFT JOIN y ...`, and MySQL and MariaDB both refuse `LIMIT` on a
    multi-table DELETE - which the batched sweep appends to everything. The cleanup ran hourly,
    removed nothing, and printed an error nobody read.
  * The mail sweep filtered `vphone_mail_box` on `at`, a column that table does not have.

Nothing is checked that is not a complete literal. A query assembled at runtime with `..` or
`:format` is reported as skipped rather than silently counted as passing: a checker that
quietly covers two thirds of its subject is worse than none, because it reports a pass.

The connection is read from the environment and never written anywhere. It is not printed, not
logged, and not passed on the command line - the password goes through `MYSQL_PWD`, which is
what that variable is for.
"""

import io
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from check import ROOT, _split_args, read, rel                       # noqa: E402

BACKSLASH = chr(92)

# Tables that belong to somebody else. The bridge speaks to qb-core, ESX, ox and half a dozen
# scripts, and only one of them is installed on any given server - so a query naming a table
# this database has never heard of is the ordinary case, not a fault. Anything past that point
# (a column that is not there, syntax the parser will not take) means the table DOES exist and
# the query against it is wrong, which is worth stopping for.
UNKNOWN_TABLE = '1146'


def flatten(sql):
    """One line, with line comments removed first.

    Collapsing whitespace before stripping `--` folds the rest of the statement into the
    comment, and a perfectly good CREATE TABLE comes back as a syntax error. That is the
    checker inventing a bug, which is worse than missing one.
    """
    kept = []
    for line in sql.split(chr(10)):
        cut = line.find('--')
        kept.append(line[:cut] if cut >= 0 else line)
    return ' '.join(' '.join(kept).split())


# ══ Connection ═════════════════════════════════════════════════════════════

def connection():
    url = os.environ.get('VPHONE_DB') or ''
    for i, arg in enumerate(sys.argv):
        if arg == '--url' and i + 1 < len(sys.argv):
            url = sys.argv[i + 1]
    m = re.match(r'mysql://([^:@/]+)(?::([^@]*))?@([^:/]+):(\d+)/([^?\s]+)$', url.strip())
    if not m:
        sys.exit('set VPHONE_DB (or pass --url) to  mysql://user:password@host:port/database\n'
                 'A read-only copy of your schema is enough - nothing is executed.')
    return m.groups()


def client():
    for i, arg in enumerate(sys.argv):
        if arg == '--client' and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    found = shutil.which('mysql') or shutil.which('mariadb')
    if not found:
        sys.exit('no mysql/mariadb client on PATH. Pass --client "C:/path/to/mysql.exe".')
    return found


# ══ What to check ══════════════════════════════════════════════════════════

CALL = re.compile(r"MySQL\.(?:query|single|scalar|insert|update|prepare|transaction)"
                  r"(?:\.await)?\s*\(")

# A literal that carries one of these is a template, not a statement: it is finished at runtime
# and there is nothing complete here to hand to a parser.
ASSEMBLED = re.compile(r"%[sdq]|\.\.")


def unquote(lit):
    if lit.startswith('[['):
        return lit[2:-2] if lit.endswith(']]') else None
    if lit[:1] in ('"', "'") and lit[-1:] == lit[:1] and len(lit) >= 2:
        return lit[1:-1]
    return None


def literal_queries():
    """Every complete literal query in the Lua sources, and every one that is assembled."""
    complete, assembled = [], []
    paths = []
    for sub in ('server', 'client'):
        d = os.path.join(ROOT, sub)
        if os.path.isdir(d):
            paths += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith('.lua')]
    for base in ('bridge', 'apps'):
        for dirpath, _, files in os.walk(os.path.join(ROOT, base)):
            paths += [os.path.join(dirpath, f) for f in sorted(files) if f.endswith('.lua')]

    for path in paths:
        src = read(path)
        for m in CALL.finditer(src):
            args = _split_args(src[m.end():])
            if not args:
                continue
            lit = unquote(args[0].strip())
            line = src[:m.start()].count('\n') + 1
            where = '%s:%d' % (rel(path), line)
            if lit is None:
                continue
            if ASSEMBLED.search(lit):
                assembled.append(where)
                continue
            complete.append((where, flatten(lit)))
    return complete, assembled


def retention_statements():
    """Every statement the retention sweep can issue, with the LIMIT the batcher appends.

    Reconstructed rather than read literally, because these are the ones that are BUILT - and
    they are also the ones that delete. The generic pass above skips exactly the statements
    that matter most here, which is why this exists alongside it.
    """
    path = os.path.join(ROOT, 'server', 'retention.lua')
    if not os.path.isfile(path):
        return []
    src = io.open(path, encoding='utf-8').read()

    def tables(block):
        """Split a Lua list of `{ ... }` entries at top level, counting depth.

        A regex with `[^{}]*?` silently skipped every entry containing a `{}` of its own -
        five of twelve - and still reported a pass.
        """
        out, depth, start = [], 0, None
        for i, ch in enumerate(block):
            if ch == '{':
                if depth == 0:
                    start = i + 1
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0 and start is not None:
                    out.append(block[start:i])
                    start = None
        return out

    out = []
    plan = src[src.index('local function plan()'):src.index('-- Rows that only point at')]
    plan = plan[plan.index('return {') + len('return {'):]
    for body in tables(plan):
        name = re.search(r"table\s*=\s*'(\w+)'", body)
        if not name:
            continue
        own = re.search(r"sql\s*=\s*\[\[(.*?)\]\]", body, re.S)
        if own:
            out.append(('retention ' + name.group(1), flatten(own.group(1)) + ' LIMIT ?'))
            continue
        col = re.search(r"column\s*=\s*'([^']+)'", body)
        extra = re.search(r"extra\s*=\s*'([^']*)'", body)
        out.append(('retention ' + name.group(1),
                    'DELETE FROM `%s` WHERE %s < DATE_SUB(NOW(), INTERVAL ? %s) %s LIMIT ?'
                    % (name.group(1), col.group(1) if col else '`at`',
                       'HOUR' if 'hours = true' in body else 'DAY',
                       extra.group(1) if extra else '')))

    orph = src[src.index('local ORPHANS = {'):]
    orph = orph[:orph.index('\n}\n')]
    for body in tables(orph[orph.index('{') + 1:]):
        own = re.search(r"sql\s*=\s*\[\[(.*?)\]\]", body, re.S)
        label = re.search(r"label\s*=\s*'([^']+)'", body)
        if own and label:
            # The orphan pass appends a number rather than a placeholder.
            out.append(('retention orphan: ' + label.group(1),
                        flatten(own.group(1)) + ' LIMIT 500'))
    return out


# ══ Ask the database ═══════════════════════════════════════════════════════

def prepare_all(rows):
    """One session, one line per statement, `--force` so the first error is not the last.

    The client reports `at line N` of the script it was given, and the script is written one
    statement per line, so N maps straight back to the query without any marker scheme.
    """
    user, password, host, port, db = connection()
    cmd = [client(), '-h', host, '-P', port, '-u', user, '-N', '-B', '--force', db]
    env = dict(os.environ)
    # Through the environment, never the command line: an argument is visible to every other
    # process on the machine, and this one is a password.
    if password:
        env['MYSQL_PWD'] = password
    else:
        env.pop('MYSQL_PWD', None)

    lines = []
    for _, sql in rows:
        body = sql.replace(BACKSLASH, BACKSLASH * 2).replace("'", "''")
        lines.append("PREPARE s FROM '%s'; DEALLOCATE PREPARE s;" % body)
    r = subprocess.run(cmd, input='\n'.join(lines) + '\n',
                       capture_output=True, text=True, env=env)

    failures = {}
    for line in (r.stderr or '').splitlines():
        m = re.search(r'ERROR\s+(\d+)\s+\([^)]*\)\s+at line (\d+):\s*(.*)', line)
        if m:
            # The FIRST error on a line, not the last. PREPARE and DEALLOCATE share a line, so
            # a failed PREPARE is always followed by "unknown prepared statement handler" -
            # and keeping the last one replaced every real message with that noise.
            n = int(m.group(2))
            if n not in failures:
                failures[n] = (m.group(1), m.group(3).strip())
        elif 'ERROR' in line and 'ssl-verify' not in line and not failures:
            failures[0] = ('', line.strip())
    return failures


def main():
    literal, assembled = literal_queries()
    rows = literal + retention_statements()
    if not rows:
        sys.exit('no queries found - is this the resource root?')

    failures = prepare_all(rows)
    if 0 in failures:
        sys.exit('could not reach the database\n  ' + failures[0][1])

    bad, foreign = [], []
    for i, (where, sql) in enumerate(rows, start=1):
        if i not in failures:
            continue
        code, msg = failures[i]
        (foreign if code == UNKNOWN_TABLE else bad).append((where, msg, sql))

    print('%d complete literal quer(ies) + %d retention statement(s) sent to the parser'
          % (len(literal), len(rows) - len(literal)))
    print('%d skipped: assembled at runtime, so there is nothing complete to check'
          % len(assembled))
    print("%d skipped: a table this database does not have, which is another framework's"
          % len(foreign))
    print('')
    for where, msg, sql in bad:
        print('  FAIL %s' % where)
        print('       %s' % msg[:160])
        print('       %s' % sql[:160])
    print('')
    print('%d statement(s) the database refuses' % len(bad) if bad
          else 'every statement this database owns parses')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
