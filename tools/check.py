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
    """Remove comments, leaving strings alone.

    **This was `re.sub(r'/\\*.*?\\*/', ...)` and it was quietly deleting a tenth of app.js.**
    That file contains the string `'/*.lua are in fxmanifest.lua shared_scripts'` - advice
    printed to a server owner. The regex has no idea it is inside quotes, so the `/*` opened a
    block comment that ran to the next real `*/` three and a half thousand lines later, and
    every check downstream was reading a file with a hole in it. Nothing failed; the checks just
    passed, on less than they were shown.

    So the delimiters are found by walking the text and tracking whether we are inside a string.
    Quotes, escapes, and JavaScript template literals are all it needs to know about - this is
    not a parser, it is enough of one to tell a comment from a comment-shaped substring.
    """
    open_tok, close_tok = ('--[[', ']]') if lua else ('/*', '*/')
    out, i, n = [], 0, len(src)
    quote = None
    while i < n:
        c = src[i]
        if quote:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in '"\'' or (not lua and c == '`'):
            quote = c
            out.append(c)
            i += 1
            continue
        if src.startswith(open_tok, i):
            end = src.find(close_tok, i + len(open_tok))
            if end < 0:
                break                                  # unterminated: the rest is comment
            # Newlines are kept so every later line number still matches the real file.
            out.append('\n' * src.count('\n', i, end + len(close_tok)))
            i = end + len(close_tok)
            continue
        out.append(c)
        i += 1
    return '\n'.join(strip_line_comments(l, lua) for l in ''.join(out).split('\n'))


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


def check_social_ops(report):
    """Every `op` the page sends to the social layer, against the two gates it has to pass.

    The page does not talk to `v-phone:soc:<op>` directly. It posts to ONE `social` callback,
    which checks the name against an allowlist in client/main.lua and only then forwards it.
    So a new operation needs three things - the page asking, the allowlist letting it, and the
    server answering - and missing either of the last two is silent: the sheet spins, or comes
    back `forbidden`, and nothing in any log says which.

    `check_callbacks` cannot see this. It matches `post('social')` against
    `RegisterNUICallback('social')` and stops there, so every op inside is invisible to it.
    Both `likers` and `follows` shipped past it with no allowlist entry.
    """
    src = read(os.path.join(ROOT, 'html', 'app.js'))
    # `post('social', { op: 'x' ... })` - the op may sit anywhere in the object literal, so the
    # window is bounded rather than anchored to the first field.
    asked = set()
    for m in re.finditer(r"post\(\s*'social'\s*,\s*\{", src):
        window = src[m.end():m.end() + 260]
        found = re.search(r"\bop\s*:\s*'([A-Za-z0-9_]+)'", window)
        if found:
            asked.add(found.group(1))

    client = read(os.path.join(ROOT, 'client', 'main.lua'))
    block = re.search(r'SOCIAL_OPS\s*=\s*\{(.*?)\n\}', client, re.S)
    allowed = set(re.findall(r'(\w+)\s*=\s*true', block.group(1))) if block else set()

    server = read(os.path.join(ROOT, 'server', 'social.lua'))
    answered = set(re.findall(r"V\.Callback\(\s*'v-phone:soc:(\w+)'", server))

    problems = []
    for op in sorted(asked - allowed):
        problems.append("%s  (not in SOCIAL_OPS - the relay answers 'forbidden')" % op)
    for op in sorted(asked - answered):
        problems.append('%s  (no v-phone:soc:%s on the server)' % (op, op))
    for op in sorted(allowed - answered):
        problems.append('%s  (allowed through, but the server has no handler)' % op)

    report('social ops', '%d asked, %d allowed, %d answered'
           % (len(asked), len(allowed), len(answered)), problems)
    return not problems


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
    # Every quoted name inside a `ui(...)` call, not only one sitting immediately after the
    # bracket. `ui(ok ? 'toggleon' : 'toggleoff')` is two sounds, and the earlier pattern - which
    # demanded a quote as the first thing in the call - saw neither of them. A ui() call naming a
    # sound that does not exist is silent, so nothing else would ever have reported it.
    ui_calls = set()
    for args in re.findall(r"\bui\(([^()\n]*)\)", app):
        # The comparison in `ui(state === 'closed' ? 'received' : 'success')` names a state, not
        # a sound. Both sides of any equality operator are removed before the names are read,
        # so a condition cannot be mistaken for something to play.
        args = re.sub(r"[!=]==?\s*'[^']*'", '', args)
        args = re.sub(r"'[^']*'\s*[!=]==?", '', args)
        ui_calls.update(re.findall(r"'([A-Za-z0-9_]+)'", args))

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


# ══ 6. Every icon the page asks for exists ═════════════════════════════════
# An icon name that is not in the set draws NOTHING. No error, no console line, no gap in the
# layout worth noticing - just a button with no picture on it, which is exactly how `svg('x')`
# and `icon: 'flag'` both shipped. The names live in v-ui, outside this repository, so they are
# read out of the built preview, which inlines the whole set.

def check_icons(report):
    preview = os.path.join(ROOT, 'preview', 'index.html')
    if not os.path.exists(preview):
        report('icons', 'no preview built - run tools/make-preview.py', [])
        return True

    built = read(preview)
    m = re.search(r'(?:ICONS|icons)\s*=\s*\{', built)
    if not m:
        report('icons', 'no icon table in the built preview', [])
        return True
    i, depth, j = m.end(), 1, m.end()
    while j < len(built) and depth:
        if built[j] == '{':
            depth += 1
        elif built[j] == '}':
            depth -= 1
        j += 1
    known = set(re.findall(r"(?m)[\{,\s]([a-z][a-z0-9_]*)\s*:\s*['\"`]", built[i:j]))
    if not known:
        report('icons', 'the icon table read as empty', [])
        return True

    app = read(os.path.join(ROOT, 'html', 'app.js'))
    asked = {}
    for name in re.findall(r"svg\('([a-z0-9_]+)'\)", app):
        asked.setdefault(name, "svg('%s')" % name)
    for name in re.findall(r"icon: '([a-z0-9_]+)'", app):
        asked.setdefault(name, "icon: '%s'" % name)
    # `appIcon` takes an APP id, not an icon name, and those are drawn from a different table.
    for name in re.findall(r"UI\.appIcon\('([a-z0-9_]+)'\)", app):
        asked.pop(name, None)

    problems = ['%s draws nothing - no such icon' % asked[n]
                for n in sorted(set(asked) - known)]
    report('icons', '%d icons available, %d asked for' % (len(known), len(asked)), problems)
    return not problems


# ══ The runner ═════════════════════════════════════════════════════════════

def check_shot_backticks(report):
    """A backtick inside a shot script CLOSES the template literal that holds it.

    Every shot in tools/make-shots.js is written as script: followed by a template literal, and
    the natural way to write a comment about a function is to put its name in backticks - which
    ends the literal mid-script and turns the rest of the shot into JavaScript that happens to
    look like prose. It is always a syntax error, it is always found by running into it, and it
    cost six round trips in one session. node --check catches it too; this catches it a step
    earlier and says which line did it.
    """
    path = os.path.join(ROOT, 'tools', 'make-shots.js')
    if not os.path.exists(path):
        report('shot scripts', 'no make-shots.js', [])
        return True

    src = read(path)
    problems = []
    scripts = 0
    marker = 'script: ' + chr(96)
    closer = chr(96) + ',' + chr(10)
    i = 0
    while True:
        at = src.find(marker, i)
        if at < 0:
            break
        begin = at + len(marker)
        end = src.find(closer, begin)
        if end < 0:
            break
        scripts += 1
        body = src[begin:end]
        if chr(96) in body:
            line = src.count(chr(10), 0, begin + body.index(chr(96))) + 1
            problems.append('line %d: a backtick here closes the shot script it sits inside'
                            % line)
        i = end + 1

    report('shot scripts', '%d script(s)' % scripts, problems)
    return not problems


def check_cross_file_locals(report):
    """A file calling a name that is another file's TOP-LEVEL local.

    Lua has no module system here: every file in `server_scripts` shares one environment, so a
    name is reachable from another file only if it was written as a true global. A name declared
    `local X` at the top of a file and assigned later as `X = function(...)` reads like a global
    definition and is not - and calling it from elsewhere is nil at RUNTIME, inside whatever
    pcall happens to be around it. It compiles, it lints, and it fails silently on a live server.

    Three real bugs came out of this check the first time it ran:

      * `prefsOf` called from server/widgets.lua and server/bank.lua, which made every
        server-backed home-screen widget read "unavailable" with nothing on screen to say why
      * `requireItem` called from server/music.lua, guarded as `if not requireItem or ...` -
        always true, so music never checked that the player is carrying a phone
      * the same in server/reminders.lua, where a banner always claimed they were

    The last two are the shape to watch for: a name that is always nil, guarded with `or`, is a
    branch that is always taken, and the guard is what hides it.

    Only TOP-LEVEL locals count as owned; a caller with any binding of its own is not reported;
    comments and long-bracket strings are stripped; and client files are never compared against
    server files, because those are different Lua states.
    """
    import glob

    NAME = '[A-Za-z_][A-Za-z0-9_]*'
    LONG = re.compile(r'\[=*\[.*?\]=*\]', re.S)
    COMMENT = re.compile(r'(?m)--.*$')
    # `"ALTER TABLE ... PRIMARY KEY (...)"` is SQL, and reading it as Lua reported KEY() as a call.
    QUOTED = re.compile('"[^"]*"' + "|" + "'[^']*'")

    def realm(path):
        rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
        if rel.startswith('server/') or rel.startswith('bridge/server/'):
            return 'server'
        if rel.startswith('client/') or rel.startswith('bridge/client/'):
            return 'client'
        return 'shared'

    files = sorted(glob.glob(os.path.join(ROOT, 'server', '*.lua')) +
                   glob.glob(os.path.join(ROOT, 'client', '*.lua')) +
                   glob.glob(os.path.join(ROOT, 'bridge', '*', '*.lua')))

    owned, bound, code = {}, {}, {}
    real_globals = set()

    for path in files:
        src = read(path)
        # **Comments first.** An apostrophe in a comment - "don t" written properly - pairs
        # with the next real string quote and eats everything between them, which deleted whole
        # blocks of declarations and reported them as missing.
        clean = QUOTED.sub(chr(32), LONG.sub(chr(32), COMMENT.sub(chr(32), src)))
        code[path] = clean

        owned[path] = (set(re.findall('(?m)^local function (' + NAME + ')', clean))
                       | set(re.findall('(?m)^local (' + NAME + r')\s*$', clean))
                       | set(re.findall('(?m)^local (' + NAME + r')\s*=', clean)))

        mine = set()
        for group in re.findall(r'(?m)\blocal\s+([^=\n]+)', clean):
            mine |= set(re.findall(NAME, group))
        for group in re.findall(r'function\s*(?:' + NAME + r')?\s*\(([^)]*)\)', clean):
            mine |= set(re.findall(NAME, group))
        for group in re.findall(r'(?m)\bfor\s+([^=\n]+?)\s+(?:=|in)\b', clean):
            mine |= set(re.findall(NAME, group))
        bound[path] = mine

        real_globals |= set(re.findall('(?m)^function (' + NAME + r')\s*\(', clean))

    problems = []
    for path in files:
        here = realm(path)
        clean = code[path]
        called = set(re.findall(r'(?<![\w.:])(' + NAME + r')\s*\(', clean))
        for name in sorted(called - bound[path] - real_globals):
            owners = [p for p in files
                      if p != path and name in owned[p]
                      and realm(p) in (here, 'shared')]
            if not owners:
                continue
            hit = re.search(r'(?<![\w.:])' + re.escape(name) + r'\s*\(', clean)
            line = clean.count(chr(10), 0, hit.start()) + 1 if hit else 0
            problems.append('%s:~%d calls %s(), a top-level local in %s - nil from here'
                            % (os.path.relpath(path, ROOT).replace(os.sep, '/'), line, name,
                               os.path.relpath(owners[0], ROOT).replace(os.sep, '/')))

    report('cross-file locals', '%d lua file(s)' % len(files), problems)
    return not problems


CHECKS = [
    ('callbacks', check_callbacks),
    ('social ops', check_social_ops),
    ('locale keys', check_keys),
    ('css classes', check_css),
    ('icons', check_icons),
    ('sounds', check_sounds),
    ('sql parameters', check_sql),
    ('shot scripts', check_shot_backticks),
    ('cross-file locals', check_cross_file_locals),
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
