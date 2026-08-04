# -*- coding: utf-8 -*-
"""Who a dispatch alert says called it in. Under real Lua.

    python tools/test-alert-caller.py


A dispatch script raising "Store robbery" passes the robber as `source`, because that is where
help has to go. `CreateAlert` used to read that as the caller, and three things followed:

  * the robber's phone buzzed "somebody took your alert", then "your alert was closed"
  * the police response appeared on the robber's own 911 screen, under their recent calls
  * every alert raised against them counted towards `maxOpen`, the cap on live calls one person
    may have - so somebody reported four times could no longer ring 911 themselves

Only the first was reported. The other two are why this is a test rather than a one-line patch:
the field that was wrong drives three separate behaviours, and each is checked here.

The resolution is lifted out of the export and driven with a fake `Core`, because the export
itself needs a running server. `tellCaller` and `openCount` are lifted whole.
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'server', 'emergency.lua'), encoding='utf-8').read()

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
-- Two characters. One robs the shop, one works the till.
PLAYERS = {
    [1] = { citizenid = 'ROBBER01', name = 'Kane Doyle' },
    [2] = { citizenid = 'CLERK002', name = 'Amina Diallo' },
}
Core = { GetPlayer = function(s) return PLAYERS[s] end }
GetCurrentResourceName = function() return 'v-phone' end
exports = setmetatable({}, { __index = function() return
    { GetNumber = function(_, cid) return '555-' .. tostring(cid):sub(1, 4) end } end })
GetPlayerPed = function() return 0 end
PhoneActingSource = function(s) return s end
function num(v, d) return tonumber(v) or d or 0 end
""")

# The caller resolution, exactly as the export writes it.
start = src.index('    local coords = o.coords\n    local callerName, callerNumber, callerCid')
end = src.index('\n    if coords and type(coords) == \'table\'', start)
lua.execute('function resolve(o)\n' + src[start:end] +
            '\n    return { cid = callerCid, name = callerName, number = callerNumber,'
            '\n             subject = subjectName, subjectNumber = subjectNumber }\nend')

# `openCount`, which is the per-caller limit.
ostart = src.index('local function openCount(cid)')
oend = src.index('\nend\n', ostart) + len('\nend\n')
lua.execute(src[ostart:oend].replace('local function', 'function'))
lua.execute("""
Alerts, Order = {}, {}
function isLive(a) return a.state ~= 'closed' end
function addAlert(id, cid) Alerts[id] = { state = 'open', callerCid = cid } Order[#Order+1] = id end
""")

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


def resolve(**o):
    return g.resolve(lua.table_from(o))


print('an alert ABOUT a player, raised by a dispatch script')
r = resolve(service='police', reason='Store robbery', source=1)
check(r['cid'] is None,
      'the suspect is not registered as the caller',
      'this is the bug: closing the alert notified the robber')
check(r['name'] is None,
      'and is not the name under "Caller" on the dispatch card either',
      'an officer opening a robbery was told the robber phoned it in')
check(r['subject'] == 'Kane Doyle',
      'their name reaches the card as the SUBJECT', str(r['subject']))
check(r['subjectNumber'] == '555-ROBB',
      'and the callback number, which is what API.md promises', str(r['subjectNumber']))

print('an alert with a real caller')
r = resolve(service='police', reason='Panic button', source=1, callerSource=2)
check(r['cid'] == 'CLERK002', 'the caller is the person who called', str(r['cid']))
check(r['name'] == 'Amina Diallo', 'and the card names the clerk as the caller', str(r['name']))
check(r['subject'] == 'Kane Doyle',
      'while the subject stays the person help is sent to', str(r['subject']))

print('a caller who is offline')
r = resolve(service='ems', reason='Collapse', callerCid='NEIGHB01')
check(r['cid'] == 'NEIGHB01', 'a citizen id is taken as given', str(r['cid']))
r = resolve(service='ems', reason='Collapse', callerCid='')
check(r['cid'] is None, 'an empty one is nobody, not a caller named ""')

print('a script that meant the old behaviour says so')
r = resolve(service='police', reason='Assault', source=2, callerSource=2)
check(r['cid'] == 'CLERK002', 'callerSource = source restores it exactly')
check(r['name'] == 'Amina Diallo' and r['subject'] == 'Amina Diallo',
      'and they are the caller AND the subject, which is what that script meant')

print('the open-alert limit counts only calls you made')
lua.execute('Alerts, Order = {}, {}')
for i in range(1, 5):
    g.addAlert(i, 'ROBBER01')          # four alerts raised AGAINST them
check(g.openCount('ROBBER01') == 4,
      'the counter itself works', 'so the next assertion means something')
lua.execute('Alerts, Order = {}, {}')
for i in range(1, 5):
    g.addAlert(i, None)                # the same four, with the fix: no caller
check(g.openCount('ROBBER01') == 0,
      'being reported four times does not use up your own 911 limit',
      'otherwise a wanted player cannot call for help')

print()
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all alert-caller cases pass')
