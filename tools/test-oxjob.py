# -*- coding: utf-8 -*-
"""Which group ox_core calls your job, and what it is called on screen. Under real Lua.

    python tools/test-oxjob.py


ox has no "job": it has groups, so one has to be chosen. The first version took whichever group
`pairs` handed over first and stopped there, which for a character in two non-permission groups
is a job that changes between two opens of the same app with nothing having happened. It is also
invisible in testing, because a character in one group is stable and that is what anybody tests
with - so the test here is deliberately run over MANY shuffles of the same two groups, and
asserts one answer across all of them. A `break` on the first hit passes a single run.

The naming half: `ox_groups.label` and `ox_group_grades.label` are read by the Jobs catalogue
and were not read for the player's own card, so it said `police` and `2` where qb says
"Los Santos Police" and "Sergeant".
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'bridge', 'server', 'framework.lua'), encoding='utf-8').read()

# The pick, lifted out of the ox branch of Bridge.GetPlayer.
start = src.index("        local jobName, jobGrade = 'unemployed', 0")
end = src.index('\n        end\n', src.index('for group, grade in pairs(groups) do', start)) \
    + len('\n        end\n')
body = src[start:end]

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute("Config = { Compat = { ignoredGroups = { admin = true, mod = true } } }")
lua.execute('function pick(groups)\n' + body + '\n    return jobName, jobGrade\nend')

# The naming, lifted out of the same branch. `Bridge.OxGroupLabels` is stubbed with what the
# real query would answer, because the point here is that the answer is USED.
lua.execute("""
Bridge = { OxGroupLabels = function()
    return { police = { label = 'Los Santos Police', grades = { [2] = 'Sergeant' } },
             mechanic = { label = 'Hayes Autos', grades = {} } }
end }
function nameOf(jobName, jobGrade)
    local named = (Bridge.OxGroupLabels and Bridge.OxGroupLabels() or {})[jobName] or {}
    return named.label or jobName, (named.grades or {})[jobGrade] or tostring(jobGrade)
end
""")

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


def pick(d):
    t = lua.table_from(d)
    name, grade = g.pick(t)
    return name, grade


print('nothing to pick from')
check(pick({}) == ('unemployed', 0), 'no groups is unemployed')
check(pick({'admin': 5, 'mod': 3}) == ('unemployed', 0),
      'permission groups are not jobs', str(pick({'admin': 5, 'mod': 3})))

print('one group')
check(pick({'police': 2}) == ('police', 2), 'the only group is the job')
check(pick({'admin': 9, 'police': 1}) == ('police', 1), 'the permission group is stepped over')

print('two groups, over many shuffles of the same table')
# Lua's `pairs` order depends on the table's internal layout, so building the same two-key table
# repeatedly with extra keys added and removed is what actually varies it. A `break` on the
# first hit gives different answers across these; one answer for all of them is the assertion.
seen = set()
for i in range(60):
    t = lua.table()
    if i % 2:
        t['mechanic'] = 1
        t['police'] = 4
    else:
        t['police'] = 4
        t['mechanic'] = 1
    for k in range(i % 7):
        t['pad' + str(k)] = 0
        lua.execute('Config.Compat.ignoredGroups["pad%d"] = true' % k)
    name, grade = g.pick(t)
    seen.add((name, grade))
check(seen == {('police', 4)}, 'the higher grade wins, every time', str(sorted(seen)))

print('a tie is broken by name, not by luck')
tie = set()
for i in range(40):
    t = lua.table()
    if i % 2:
        t['zebra'] = 3
        t['alpha'] = 3
    else:
        t['alpha'] = 3
        t['zebra'] = 3
    tie.add(g.pick(t))
check(tie == {('alpha', 3)}, 'the same one every time', str(sorted(tie)))

print('a server with a group actually named unemployed')
# The sentinel trap: testing jobName against 'unemployed' rather than keeping a flag lets a
# later, LOWER group overwrite a real one that happens to carry that name.
un = set()
for i in range(40):
    t = lua.table()
    if i % 2:
        t['unemployed'] = 5
        t['mechanic'] = 1
    else:
        t['mechanic'] = 1
        t['unemployed'] = 5
    un.add(g.pick(t))
check(un == {('unemployed', 5)}, 'grade 5 beats grade 1 whatever it is called', str(sorted(un)))

print('what it is called on screen')
check(tuple(g.nameOf('police', 2)) == ('Los Santos Police', 'Sergeant'),
      'the group and grade labels ox already has',
      str(tuple(g.nameOf('police', 2))))
check(tuple(g.nameOf('mechanic', 3)) == ('Hayes Autos', '3'),
      'a grade with no row falls back to the number rather than blank',
      str(tuple(g.nameOf('mechanic', 3))))
check(tuple(g.nameOf('smuggler', 1)) == ('smuggler', '1'),
      'a group the tables do not know still shows',
      str(tuple(g.nameOf('smuggler', 1))))

print()
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all ox job cases pass')
