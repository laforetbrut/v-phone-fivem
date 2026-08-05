# -*- coding: utf-8 -*-
"""Every check this resource has, in one command.

    python tools/test-all.py
    python tools/test-all.py --fast     everything except the 71 screenshots

There were six ways to test this phone and no way to run them, so each one was run when
somebody remembered it existed. This is the list, in the order that fails cheapest first: a
syntax error should not cost five minutes of screenshots to discover.

    lua compile      every .lua file loaded by a real Lua 5.4
    js parse         every .js file through node --check
    check.py         fourteen static checks over the whole resource
    check selftest   each of those checks shown a fault it must catch
    test-blocking    the block list under real Lua, including the renumber trap
    test-money       which money movements the phone may announce, and which it may not
    test-migration   the character-id widening pass, against a fake information_schema
    test-frameworks  the per-framework vehicle shapes, qb against ESX against ox
    test-steps       the step-day rollover, which used to delete the day it rolled over
    test-oxjob       which ox group is your job, and what it is called on screen
    test-poll        the balance sampler, and the double notification it would have caused
    check-fr         no French word spelled two ways in the same locale file
    test-alert-caller who a dispatch alert says called it in, which is not its subject
    test-multiphoto  four photographs on one post, and the host gate on every one
    test-nudge       when the social apps may say what is new, and when they must stay quiet
    test-retention   how long a social row lives, and that both sweeps ask the one function
    test-mediaref    who still shows a photograph, before the sweep deletes it
    test-verify      who may buy the blue tick, and that the orange one never moves with it
    test-camera      what a photograph does when the upload host is slow or dead
    preview          the page built for a browser
    run-probe        can a cursor reach every control in all 37 apps
    probe-input      real mouse input through the compositor
    make-shots       71 screenshots, some of which are assertions

Exit code 1 if anything fails. Nothing here needs a database or a running server.
"""
import io
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAST = '--fast' in sys.argv

results = []


def run(name, argv, note=''):
    """One step. Prints a line, records the outcome, never raises."""
    started = time.time()
    # The "running" line is overwritten in place when there is a terminal to overwrite it in.
    # Piped into a file there is nothing to overwrite, so it would be noise on every other
    # line, and it is not printed at all.
    live = sys.stdout.isatty()
    if live:
        sys.stdout.write('%-16s %s' % (name, 'running...'))
        sys.stdout.flush()
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', shell=False)
        ok = p.returncode == 0
        out = (p.stdout or '') + (p.stderr or '')
    except Exception as e:                                    # noqa: BLE001 - reported, not raised
        ok, out = False, str(e)
    took = time.time() - started
    sys.stdout.write('%s%-16s %-4s %5.1fs  %s\n'
                     % ('\r' if live else '', name, 'ok' if ok else 'FAIL', took, note))
    if not ok:
        # The tail is where a test says what went wrong. The head is usually the banner.
        tail = [ln for ln in out.strip().split('\n') if ln.strip()][-12:]
        for ln in tail:
            print('                 ' + ln)
    results.append((name, ok))
    return ok


# ── The two that cost nothing and catch the most ──────────────────────────
LUA_CHECK = r'''
import glob, io, sys
try:
    import lupa
except ImportError:
    print('lupa is not installed: pip install lupa')
    sys.exit(1)
L = lupa.LuaRuntime()
load = L.eval('function(s, n) return load(s, n) end')
files = [f for f in sorted(glob.glob('**/*.lua', recursive=True))
         if 'preview' not in f and 'server-test' not in f]
bad = []
for f in files:
    # **`load` answers `nil, err` on failure, and lupa hands that back as a TUPLE.**
    #
    # The first version of this asked `if load(...) is None`, which a two-element tuple never
    # is - so this check has never once reported a broken file. It was green unconditionally,
    # and a real syntax error in server/media.lua walked past it and stopped the resource
    # loading on a live server. A gate that cannot fail is worse than no gate: it is a gate
    # everybody trusts.
    res = load(io.open(f, encoding='utf-8').read(), '@' + f)
    fn = res[0] if isinstance(res, tuple) else res
    if fn is None:
        bad.append((f, (res[1] if isinstance(res, tuple) else 'unknown error')))
for f, why in bad:
    print('does not compile:', f)
    print('                 ', why)
print('%d file(s)' % len(files))
sys.exit(1 if bad else 0)
'''

JS_CHECK = ['html/app.js', 'html/sdk.js', 'tools/probe.js', 'tools/probe-input.js',
            'tools/run-probe.js', 'tools/make-shots.js',
            # The S3 signer and uploader. A server script rather than a page script, and the
            # only one - which is exactly why it would have been left out of this list and
            # shipped unparsed.
            'server/s3.js']

print('')
run('lua compile', [sys.executable, '-c', LUA_CHECK])

js_ok = True
for f in JS_CHECK:
    if not os.path.exists(os.path.join(ROOT, f)):
        continue
    p = subprocess.run(['node', '--check', f], cwd=ROOT, capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    if p.returncode != 0:
        js_ok = False
        print('js parse         FAIL  ' + f)
        print('                 ' + (p.stderr or '').strip().split('\n')[0])
results.append(('js parse', js_ok))
if js_ok:
    print('%-16s %-4s        %d file(s)' % ('js parse', 'ok', len(JS_CHECK)))

run('check.py', [sys.executable, 'tools/check.py'])
run('check selftest', [sys.executable, 'tools/check.py', '--selftest'])
run('test-blocking', [sys.executable, 'tools/test-blocking.py'])
run('test-money', [sys.executable, 'tools/test-money-notify.py'])
run('test-migration', [sys.executable, 'tools/test-migration.py'])
run('test-frameworks', [sys.executable, 'tools/test-frameworks.py'])
run('test-steps', [sys.executable, 'tools/test-steps.py'])
run('test-oxjob', [sys.executable, 'tools/test-oxjob.py'])
run('test-poll', [sys.executable, 'tools/test-poll.py'])
run('test-alert-caller', [sys.executable, 'tools/test-alert-caller.py'])
run('test-multiphoto', [sys.executable, 'tools/test-multiphoto.py'])
run('test-nudge', [sys.executable, 'tools/test-nudge.py'])
run('test-retention', [sys.executable, 'tools/test-social-retention.py'])
run('test-mediaref', [sys.executable, 'tools/test-mediaref.py'])
run('test-verify', [sys.executable, 'tools/test-verify.py'])
run('test-camera', [sys.executable, 'tools/test-camera.py'])
run('check-fr', [sys.executable, 'tools/check-fr.py'])

# ── The ones that need a browser ──────────────────────────────────────────
run('preview', [sys.executable, 'tools/make-preview.py', '--lang', 'fr'])
run('run-probe', ['node', 'tools/run-probe.js'], 'every control reachable, 37 apps')
run('probe-input', ['node', 'tools/probe-input.js'], 'real mouse through the compositor')
if FAST:
    print('%-16s %-4s        skipped by --fast' % ('make-shots', '--'))
else:
    run('make-shots', ['node', 'tools/make-shots.js'], '71 screenshots and assertions')

print('')
failed = [n for n, ok in results if not ok]
if failed:
    print('%d of %d FAILED: %s' % (len(failed), len(results), ', '.join(failed)))
    sys.exit(1)
print('all %d passed' % len(results))
