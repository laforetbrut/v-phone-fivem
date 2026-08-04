# -*- coding: utf-8 -*-
"""The per-framework shapes the phone has to read, under real Lua.

    python tools/test-frameworks.py

Three schemas answer "is this car out of the garage" in three different ways, and only qb's was
being read. The other two were not merely unhandled - they were read as their OPPOSITE:

    qb    `state`  0 means out                          read correctly
    ESX   `stored` TINYINT, so oxmysql hands back the NUMBER 0 or 1. The app's last resort
          was `tostring(v.stored) == ''`, and tostring(0) is "0" - so a car that was OUT
          reported as parked.
    ox    `stored` VARCHAR naming the garage, NULL when the car is out. NULL arrives as nil,
          misses every branch, and lands on `else out = false` - the same wrong answer.

So on two of the four frameworks the one question the Garage app exists to answer was answered
backwards, always. This drives the normalisation and the app's own decision function together,
which is the only way to check that the two agree.
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute('Bridge = { framework = "qb" }')
lua.execute('function num(v, d) return tonumber(v) or d or 0 end')

# The normalisation, lifted out of Bridge.Vehicles.Owned.
src = io.open(os.path.join(ROOT, 'bridge', 'server', 'integrations.lua'), encoding='utf-8').read()
start = src.index("    if Bridge.framework == 'esx' then\n        for _, r in ipairs(rows) do\n            r.state = tonumber(r.stored) or 1")
end = src.index('\n    end\n', src.index("elseif Bridge.framework == 'ox' then", start)) + len('\n    end\n')
lua.execute('function normalise(rows)\n' + src[start:end] + '\nend')

# And the app's own decision, lifted out of vehicleRow.
app = io.open(os.path.join(ROOT, 'server', 'apps.lua'), encoding='utf-8').read()
astart = app.index('    local out\n    if v.state ~= nil')
aend = app.index('\n    end\n', astart) + len('\n    end\n')
lua.execute('function isOut(v)\n' + app[astart:aend] + '\n    return out\nend')

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


def one(framework, row):
    """Normalise a single row the way the bridge does, then ask the app about it."""
    lua.execute('Bridge.framework = "%s"' % framework)
    t = lua.table_from([lua.table_from(row)])
    g.normalise(t)
    return g.isOut(t[1]), t[1]


print('qb, which was always right')
lua.execute('Bridge.framework = "qb"')
out, _ = one('qb', {'plate': 'AAA', 'state': 0})
check(out is True, 'state 0 is out')
out, _ = one('qb', {'plate': 'AAA', 'state': 1})
check(out is False, 'state 1 is parked')

print('')
print('ESX, where stored is a number')
out, r = one('esx', {'plate': 'BBB', 'stored': 0, 'parking': 'legion'})
check(out is True, 'stored 0 is OUT', 'state=%s' % r.state)
check(r.garage == 'legion', 'and the garage name comes from `parking`', str(r.garage))
out, r = one('esx', {'plate': 'BBB', 'stored': 1, 'parking': 'legion'})
check(out is False, 'stored 1 is parked', 'state=%s' % r.state)

print('')
print('ox, where stored is the garage name and NULL means out')
out, r = one('ox', {'plate': 'CCC', 'stored': 'pillbox'})
check(out is False, 'a named garage is parked', 'state=%s' % r.state)
check(r.garage == 'pillbox', 'and that name is the garage', str(r.garage))
out, r = one('ox', {'plate': 'CCC'})
check(out is True, 'no garage at all is OUT', 'state=%s' % r.state)

print('')
print('the shapes that would have been read backwards before')
lua.execute('Bridge.framework = "esx"')
raw = lua.table_from({'plate': 'DDD', 'stored': 0})
check(g.isOut(raw) is False,
      'unnormalised, ESX stored=0 reads as PARKED - which is the bug this fixes')
lua.execute('Bridge.framework = "ox"')
raw = lua.table_from({'plate': 'EEE'})
check(g.isOut(raw) is False,
      'unnormalised, ox NULL reads as PARKED - the same bug from the other side')

print('')
print('%d failure(s)' % len(fails))
raise SystemExit(1 if fails else 0)
