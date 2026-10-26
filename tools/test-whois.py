# -*- coding: utf-8 -*-
"""Who a script means by "this player", under real Lua.

    python tools/test-whois.py

`PhoneWhoIs` in server/main.lua turns whichever identifier a script happens to hold - a source,
a phone number, a citizen id - into the citizen id everything else is keyed on. Every export
that sends a message to a character goes through it.

**It read a citizen id as a source on ox_core.** A source is a small integer and a citizen id
was assumed not to be, so sources were recognised first. On qb and ESX that holds: a citizen id
looks like `ABC12345`. On ox a character id IS a small integer, so `PhoneWhoIs(3)` answered with
whoever was connected on slot 3, or with nothing. The social sign-up code is texted that way, so
on ox it went to a stranger or nowhere and the account could never be finished.

Pinned to Lua 5.4: a bare `import lupa` loads the newest bundled Lua, which FiveM does not run.
"""
import io
import os
import sys

import lupa.lua54 as lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

failures = []


def check(ok, label, detail=''):
    print(('  ok   ' if ok else '  FAIL ') + label + (('  (%s)' % detail) if not ok and detail else ''))
    if not ok:
        failures.append(label)


src = io.open(os.path.join(ROOT, 'server', 'main.lua'), encoding='utf-8').read()
start = src.index('function PhoneWhoIs(target)')
end = src.index('\nend\n', start) + len('\nend\n')
body = src[start:end]

PRELUDE = r'''
-- The phone's own character table: citizen id to the line it owns.
LINES = {}
-- Who is connected, by source.
PLAYERS = {}

function numberOfCid(cid) return LINES[tostring(cid)] end

function cidOfNumber(number)
    for cid, line in pairs(LINES) do
        if line == tostring(number) then return cid end
    end
    return nil
end

Core = { GetPlayer = function(src) return PLAYERS[src] end }

function asOx()
    -- ox_core: a character id is a small integer, and so is a source.
    LINES = { ['1'] = '555-0101', ['2'] = '555-0102', ['3'] = '555-0103' }
    PLAYERS = { [1] = { citizenid = '2' }, [2] = { citizenid = '1' } }
end

function asQb()
    LINES = { ['ABC12345'] = '555-0142' }
    PLAYERS = { [5] = { citizenid = 'ABC12345' } }
end
'''

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute(PRELUDE)
lua.execute(body)
who = lua.eval('PhoneWhoIs')
ex = lua.execute

print('who a script means by "this player"')
check(str(lua.eval('_VERSION')) == 'Lua 5.4', 'the Lua that FiveM runs', str(lua.eval('_VERSION')))

# 1. ox: a character id wins over the source that shares its digits.
ex('asOx()')
check(who('3') == '3', 'ox: a character id is that character', str(who('3')))
check(who(3) == '3', 'ox: the same, as a number rather than text', str(who(3)))
# Source 1 is held by character 2 in this fixture: reading "1" as a source would answer '2'.
check(who('1') == '1', 'ox: not the character connected on that slot', str(who('1')))
check(who('555-0103') == '3', 'ox: a phone number still finds its owner', str(who('555-0103')))
check(who('9') is None, 'ox: an id nobody owns is nobody', str(who('9')))

# 2. qb and ESX: the source still works, because no citizen id looks like one.
ex('asQb()')
check(who(5) == 'ABC12345', 'qb: a source is the character on it', str(who(5)))
check(who('ABC12345') == 'ABC12345', 'qb: a citizen id is itself', str(who('ABC12345')))
check(who('555-0142') == 'ABC12345', 'qb: a phone number finds its owner', str(who('555-0142')))
check(who(7) is None, 'qb: a source nobody is connected on is nobody', str(who(7)))
check(who(None) is None, 'nothing is nobody', str(who(None)))

print('')
if failures:
    print('%d failure(s)' % len(failures))
    sys.exit(1)
print('0 failure(s)')
