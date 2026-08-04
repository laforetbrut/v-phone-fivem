# -*- coding: utf-8 -*-
"""The step-day rollover keeps the finished day instead of deleting it. Under real Lua.

    python tools/test-steps.py


`rollStepDay` is lifted out of server/main.lua and driven through the sequence a real character
produces: walk, sleep, walk, come back a week later. What it replaced was one line -

    if rec.stepDay ~= day then rec.stepDay = day rec.steps = 0 end

- which lost the day at midnight, in an app whose store page promises trends. The same line
appeared again on the read path WITHOUT a write, so the rollover ran on every open until the
next step arrived.

The cases that matter and are easy to get wrong: a day with no steps must not be filed as a zero
row (a character who did not log in did not walk nought steps, they were not there); the history
must be capped without losing the newest end; and a second call on the same day must be a no-op,
because it is the answer to "does this need writing" that decides whether a metadata write goes
out on every single open.
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'server', 'main.lua'), encoding='utf-8').read()

lua = lupa.LuaRuntime(unpack_returned_tuples=True)

# The constant and the function, exactly as the file writes them.
start = src.index('local STEP_DAYS =')
end = src.index('\nend\n', src.index('local function rollStepDay')) + len('\nend\n')
lua.execute(src[start:end].replace('local STEP_DAYS', 'STEP_DAYS')
                          .replace('local function rollStepDay', 'function rollStepDay'))

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


def hist(rec):
    h = rec['stepHist']
    if h is None:
        return []
    return [(h[i]['d'], h[i]['s']) for i in range(1, len(h) + 1)]


print('a fresh record')
rec = lua.table()
changed = g.rollStepDay(rec, '2025-03-01')
check(changed is True, 'the first day is a change worth writing')
check(rec['stepDay'] == '2025-03-01', 'the day is stamped')
check(rec['steps'] == 0, 'the count starts at nought')
check(hist(rec) == [], 'nothing is filed for a day that never existed')

print('the same day again')
check(g.rollStepDay(rec, '2025-03-01') is False,
      'a second call on the same day writes nothing',
      'this is what stopped the read path rolling over on every open')

print('a day with steps in it rolls over')
rec['steps'] = 4820
check(g.rollStepDay(rec, '2025-03-02') is True, 'the new day is a change')
check(hist(rec) == [('2025-03-01', 4820)], 'yesterday was kept', str(hist(rec)))
check(rec['steps'] == 0, 'today starts at nought')

print('a day with no steps is not filed')
check(g.rollStepDay(rec, '2025-03-03') is True, 'the day still moves on')
check(hist(rec) == [('2025-03-01', 4820)],
      'a day nobody played is not a day of nought steps',
      str(hist(rec)))

print('the history is capped at a week, from the OLD end')
for i, day in enumerate(['2025-03-04', '2025-03-05', '2025-03-06', '2025-03-07',
                         '2025-03-08', '2025-03-09', '2025-03-10', '2025-03-11']):
    rec['steps'] = 100 + i
    g.rollStepDay(rec, day)
got = hist(rec)
check(len(got) == 7, 'seven days kept', str(len(got)))
check(got[-1] == ('2025-03-10', 107), 'the newest day survived the trim', str(got[-1]))
check(got[0][0] > '2025-03-01', 'the oldest day was the one dropped', str(got[0]))
check(all(a[0] < b[0] for a, b in zip(got, got[1:])), 'oldest first, in order', str(got))

print('a fractional or negative count cannot land in the history')
rec2 = lua.table()
g.rollStepDay(rec2, '2025-04-01')
rec2['steps'] = 12.7
g.rollStepDay(rec2, '2025-04-02')
check(hist(rec2) == [('2025-04-01', 12)], 'stored as a whole number', str(hist(rec2)))
rec2['steps'] = -50
g.rollStepDay(rec2, '2025-04-03')
check(hist(rec2) == [('2025-04-01', 12)],
      'a negative count is not filed as a day of walking', str(hist(rec2)))

print('a record whose stepHist is junk does not take the app down')
rec3 = lua.table()
rec3['stepDay'] = '2025-05-01'
rec3['steps'] = 900
rec3['stepHist'] = 'not a table'
g.rollStepDay(rec3, '2025-05-02')
check(hist(rec3) == [('2025-05-01', 900)], 'it is replaced rather than indexed', str(hist(rec3)))

print()
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all step-rollover cases pass')
