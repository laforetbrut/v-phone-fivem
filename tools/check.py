#!/usr/bin/env python3
"""Everything that can be checked without a running server.

    python tools/check.py

Exit code 0 when every check passes. Run it before cutting a release.

There is no test runner in this repo and there is not going to be one: the phone is Lua and a
CEF page, and most of what breaks needs a game. These are the failures that DO NOT need a game
and that nothing else would notice, because none of them is an error - each one produces a phone
that is quietly, visibly wrong:

  1. a `post()` with no handler          the screen waits on its spinner for ever
  2. a locale key that does not exist    the key itself prints at the player
  3. a class with no rule                an element drawn with no styling at all
  4. a tone name that resolves nowhere   a notification answers with the call ringtone
  5. a query whose parameters do not     oxmysql binds the wrong value into the wrong column
     match its placeholders

Every check carries a `--selftest` that proves it can still fail. A checker nobody has watched
fail is a checker nobody knows the shape of, and one that cries wolf is worse than none: the
first version of check 3 reported nine classes and every one of them was a click handle.

    python tools/check.py --selftest

Needs `pip install lupa luaparser`.
"""

import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    return io.open(path, encoding='utf-8', errors='replace').read()


def rel(path):
    return os.path.relpath(path, ROOT).replace('\\', '/')


def strip_line_comments(line, lua):
    """One line without its comment. Quotes are respected, so a `--` inside a string survives."""
    out = []
    instr = None
    i = 0
    while i < len(line):
        ch = line[i]
        if instr:
            out.append(ch)
            if ch == '\\' and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if ch == instr:
                instr = None
        elif ch in '"\'':
            instr = ch
            out.append(ch)
        elif line.startswith('--' if lua else '//', i):
            break
        else:
            out.append(ch)
        i += 1
    return ''.join(out)


def strip_comments(src, lua):
    src = re.sub(r'--\[\[.*?\]\]' if lua else r'/\*.*?\*/', ' ', src, flags=re.S)
    return '\n'.join(strip_line_comments(l, lua) for l in src.split('\n'))


# ══ 1. Every post() the page makes has a handler ═══════════════════════════
# `post('x')` on the page is an HTTP call to the resource; FiveM delivers it to
# `RegisterNUICallback('x')` on the client. A name in one half and not the other is not an
# error - the page awaits a reply nobody will send. client/doctor.lua makes the same check
# in game; this one makes it before the server starts.

def check_callbacks(report):
    asked = set()
    for name in ('app.js', 'sdk.js'):
        asked |= set(re.findall(r"\bpost\(\s*'([A-Za-z0-9_:.-]+)'",
                                read(os.path.join(ROOT, 'html', name))))

    answered = set()
    for path in (glob.glob(os.path.join(ROOT, 'client', '*.lua')) +
                 glob.glob(os.path.join(ROOT, 'bridge', 'client', '*.lua')) +
                 glob.glob(os.path.join(ROOT, 'apps', '**', '*.lua'), recursive=True)):
        answered |= set(re.findall(r"RegisterNUICallback\(\s*'([A-Za-z0-9_:.-]+)'", read(path)))

    missing = sorted(asked - answered)
    report('callbacks', '%d asked, %d handled' % (len(asked), len(answered)),
           ['%s  (the screen would wait for ever)' % n for n in missing])
    return not missing


# ══ 2. Every locale key exists, in both languages ══════════════════════════
# `translate` returns the KEY when it has no translation, so a missing one prints `ph.whatever`
# at the player. Keys built by concatenation are collected as prefixes: a prefix matching no
# defined key means the whole family is missing.

def locale_tables():
    from lupa import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('Locales = { en = {}, fr = {} }')
    for name in ('en', 'fr'):
        lua.execute(read(os.path.join(ROOT, 'locales', '%s.lua' % name)))
    g = lua.globals()
    return {str(k) for k in list(g.Locales.en)}, {str(k) for k in list(g.Locales.fr)}


def check_keys(report):
    en, fr = locale_tables()
    known = en | fr

    whole = re.compile(r"""['"]((?:ph|app)\.[a-z0-9_]+)['"]""")
    pre_lua = re.compile(r"""['"]((?:ph|app)\.[a-z0-9_]*_)['"]\s*\.\.""")
    pre_js = re.compile(r"""['"]((?:ph|app)\.[a-z0-9_]*_)['"]\s*\+""")

    sources = (glob.glob(os.path.join(ROOT, 'server', '*.lua')) +
               glob.glob(os.path.join(ROOT, 'client', '*.lua')) +
               glob.glob(os.path.join(ROOT, 'bridge', '**', '*.lua'), recursive=True) +
               glob.glob(os.path.join(ROOT, 'apps', '**', '*.lua'), recursive=True) +
               [os.path.join(ROOT, 'html', 'app.js'), os.path.join(ROOT, 'html', 'sdk.js'),
                os.path.join(ROOT, 'config.lua')])

    asked, prefixes = {}, {}
    for path in sources:
        lua = path.endswith('.lua')
        for i, line in enumerate(strip_comments(read(path), lua).split('\n'), start=1):
            for key in whole.findall(line):
                asked.setdefault(key, '%s:%d' % (rel(path), i))
            for pre in pre_lua.findall(line) + pre_js.findall(line):
                prefixes.setdefault(pre, '%s:%d' % (rel(path), i))

    missing = {k: w for k, w in asked.items() if k not in known and k not in prefixes}
    empty = {p: w for p, w in prefixes.items() if not any(k.startswith(p) for k in known)}
    drift = sorted((en - fr) | (fr - en))

    problems = (['%s  %s' % (k, missing[k]) for k in sorted(missing)] +
                ['%s*  %s  (nothing matches this prefix)' % (p, empty[p]) for p in sorted(empty)] +
                ['%s  (in one language only)' % k for k in drift])
    report('locale keys', '%d keys, %d asked for, %d built from a prefix'
           % (len(en), len(asked), len(prefixes)), problems)
    return not problems


# ══ 3. Every class the page writes has a rule ══════════════════════════════
# An unstyled class is an element drawn at its own size with no spacing and no background. It
# does not log and it is not an error; it just looks broken.
#
# Only a class that is the ONLY one on its element counts. This project uses a class as a click
# handle as often as a style hook - `class="row lead socfind"` is two looks and one listener -
# and reporting those is reporting nothing.

def styled_classes(css):
    css = re.sub(r'/\*.*?\*/', ' ', css, flags=re.S)
    out = set()
    for block in re.finditer(r'([^{}]+)\{', css):
        sel = re.sub(r'@[^{]*', ' ', block.group(1))
        out |= set(re.findall(r'\.(-?[A-Za-z_][A-Za-z0-9_-]*)', sel))
    return out


def page_classes(sources):
    attr = re.compile(r'class\s*=\s*"([^"]*)"')
    used = {}
    for path, src in sources:
        js = path.endswith('.js')
        src = strip_comments(src, False) if js else re.sub(r'<!--.*?-->', ' ', src, flags=re.S)
        for i, line in enumerate(src.split('\n'), start=1):
            for m in attr.findall(line):
                cleaned = re.sub(r'\$\{[^}]*\}|\'\s*\+[^+]*\+\s*\'', ' ', m)
                names = [n for n in cleaned.split()
                         if re.fullmatch(r'-?[A-Za-z_][A-Za-z0-9_-]*', n)]
                alone = len(names) == 1 and 'id=' not in line
                for n in names:
                    used.setdefault(n, ('%s:%d' % (rel(path), i), alone))
    return used


# A wrapper whose children carry every rule. Confirmed by hand; listed so a NEW one stands out.
STYLELESS_ON_PURPOSE = {'boothdial'}


def check_css(report):
    styled = set()
    for name in ('style.css', 'theme.css', 'theme-vars.css'):
        styled |= styled_classes(read(os.path.join(ROOT, 'html', name)))

    used = page_classes([(p, read(p)) for p in
                         (os.path.join(ROOT, 'html', 'app.js'),
                          os.path.join(ROOT, 'html', 'sdk.js'),
                          os.path.join(ROOT, 'html', 'index.html'))])

    solo = {k: v for k, v in used.items()
            if k not in styled and v[1] and k not in STYLELESS_ON_PURPOSE}
    report('css classes', '%d styled, %d used by the page' % (len(styled), len(used)),
           ['%s  %s  (its only class, and it has no rule)' % (k, solo[k][0]) for k in sorted(solo)])
    return not solo


# ══ 4. Every tone name resolves to something playable ══════════════════════
# `synth` ends in `TONES[name] || TONES.classic`, so an unknown name plays the four-note CALL
# ringtone. A notification answering with the ring is a sound bug nothing reports.

def _object_body(src, name):
    m = re.search(r'const\s+' + name + r'\s*=\s*\{', src)
    if not m:
        return ''
    depth, i = 0, m.end() - 1
    for j in range(i, len(src)):
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
            if depth == 0:
                return re.sub(r'//[^\n]*', ' ', src[i + 1:j])
    return ''


def check_sounds(report):
    app = read(os.path.join(ROOT, 'html', 'app.js'))
    tones = set(re.findall(r'(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:', _object_body(app, 'TONES')))
    ui_tones = set(re.findall(r'(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:', _object_body(app, 'UI_TONES')))
    app_tones = set(re.findall(r":\s*'([A-Za-z0-9_]+)'", _object_body(app, 'APP_TONES')))

    files = {}
    for kind, inner in re.findall(r'(\w+)\s*:\s*\{([^}]*)\}', _object_body(app, 'SOUND_FILES')):
        files[kind] = set(re.findall(r'([A-Za-z0-9_]+)\s*:', inner))

    cfg = read(os.path.join(ROOT, 'config.lua'))
    m = re.search(r'ringtones\s*=\s*\{([^}]*)\}', cfg)
    cfg_rings = set(re.findall(r"'([A-Za-z0-9_]+)'", m.group(1))) if m else set()
    m = re.search(r'alerts\s*=\s*\{([^}]*)\}', cfg)
    cfg_alerts = set(re.findall(r"'([A-Za-z0-9_]+)'", m.group(1))) if m else set()
    ui_calls = set(re.findall(r"\bui\(\s*'([A-Za-z0-9_]+)'", app))

    problems = []
    for label, names, playable in (
            ('ringtone', cfg_rings, tones | files.get('ring', set())),
            ('alert', cfg_alerts, tones | files.get('alert', set())),
            ('app tone', app_tones, tones | files.get('alert', set())),
            ('ui sound', ui_calls, ui_tones | files.get('ui', set()))):
        for n in sorted(names - playable - {'none'}):
            problems.append('%s "%s" has no score and no file' % (label, n))

    report('sounds', '%d tone scores, %d interface scores' % (len(tones), len(ui_tones)), problems)
    return not problems


# ══ 5. Every query's parameters match its placeholders ═════════════════════
# A mismatch is not a syntax error. oxmysql either throws at runtime or binds the wrong value
# into the wrong column, and a query that reads somebody else's row looks like a working query.

def _split_args(s):
    depth, out, cur, instr, i = 0, [], '', None, 0
    while i < len(s):
        ch = s[i]
        if instr:
            if ch == instr and s[i - 1] != '\\':
                instr = None
            cur += ch
        elif ch in '"\'':
            instr = ch
            cur += ch
        elif s.startswith('[[', i):
            j = s.find(']]', i)
            if j < 0:
                return out + [cur]
            cur += s[i:j + 2]
            i = j + 1
        elif ch in '([{':
            depth += 1
            cur += ch
        elif ch in ')]}':
            if depth == 0:
                return out + [cur]
            depth -= 1
            cur += ch
        elif ch == ',' and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
        i += 1
    return out + [cur]


def check_sql(report):
    call = re.compile(r"MySQL\.(?:query|single|scalar|insert|update|prepare|transaction)"
                      r"(?:\.await)?\s*\(")
    problems, checked = [], 0
    for path in (glob.glob(os.path.join(ROOT, 'server', '*.lua')) +
                 glob.glob(os.path.join(ROOT, 'client', '*.lua')) +
                 glob.glob(os.path.join(ROOT, 'bridge', '**', '*.lua'), recursive=True) +
                 glob.glob(os.path.join(ROOT, 'apps', '**', '*.lua'), recursive=True)):
        src = read(path)
        for m in call.finditer(src):
            args = _split_args(src[m.end():])
            if len(args) < 2:
                continue
            q, p = args[0].strip(), args[1].strip()
            if not (q[:2] in ('[[',) or q[:1] in ('"', "'")):
                continue
            if not (p.startswith('{') and p.endswith('}')):
                continue
            checked += 1
            holes = re.sub(r'--[^\n]*', '', q).count('?')
            params = len([x for x in _split_args(p[1:-1] + ',') if x.strip()])
            if holes != params:
                problems.append('%s:%d  %d placeholders, %d parameters'
                                % (rel(path), src[:m.start()].count('\n') + 1, holes, params))
    report('sql parameters', '%d literal queries' % checked, problems)
    return not problems


# ══ The runner ═════════════════════════════════════════════════════════════

CHECKS = [
    ('callbacks', check_callbacks),
    ('locale keys', check_keys),
    ('css classes', check_css),
    ('sounds', check_sounds),
    ('sql parameters', check_sql),
]


def selftest():
    """Each check, shown a fault it must catch. Run this whenever one of them is edited."""
    ok = True

    probe = os.path.join(ROOT, '__check_selftest.lua')
    io.open(probe, 'w', encoding='utf-8').write(
        "local a = L('ph.this_key_cannot_exist')\n"
        "-- prose mentioning L('ph.only_in_a_comment') must be ignored\n"
        "local b = MySQL.query.await('SELECT 1 WHERE a = ? AND b = ?', { x })\n")
    try:
        en, _ = locale_tables()
        found = set()
        for i, line in enumerate(strip_comments(read(probe), True).split('\n'), start=1):
            found |= set(re.findall(r"""['"]((?:ph|app)\.[a-z0-9_]+)['"]""", line))
        hit = 'ph.this_key_cannot_exist' in found and 'ph.only_in_a_comment' not in found
        print('  keys      ' + ('finds a miss, ignores prose' if hit else 'FAILED'))
        ok = ok and hit

        args = _split_args("'SELECT 1 WHERE a = ? AND b = ?', { x })")
        holes = args[0].count('?')
        params = len([x for x in _split_args(args[1].strip()[1:-1] + ',') if x.strip()])
        hit = holes == 2 and params == 1
        print('  sql       ' + ('sees 2 placeholders against 1 parameter' if hit else 'FAILED'))
        ok = ok and hit
    finally:
        os.remove(probe)

    hit = 'missingclass' in {k for k, v in page_classes(
        [(os.path.join(ROOT, 'x.js'), 'h = \'<div class="missingclass"></div>\';')]).items()
        if v[1]}
    print('  css       ' + ('sees a lone class' if hit else 'FAILED'))
    ok = ok and hit

    hit = not _object_body('const OTHER = { a: 1 };', 'TONES')
    print('  sounds    ' + ('reads only the table it was asked for' if hit else 'FAILED'))
    ok = ok and hit

    print('')
    print('SELFTEST ' + ('PASSED' if ok else 'FAILED'))
    return 0 if ok else 1


def main():
    if '--selftest' in sys.argv:
        print('checking the checkers')
        print('')
        return selftest()

    failures = []

    def report(name, summary, problems):
        print('%-16s %s' % (name, summary))
        for line in problems:
            print('    ' + line)
            failures.append(name)
        print('')

    passed = True
    for _, fn in CHECKS:
        passed = fn(report) and passed

    if passed:
        print('all checks passed')
        return 0
    print('%d problem(s)' % len(failures))
    return 1


if __name__ == '__main__':
    sys.exit(main())
