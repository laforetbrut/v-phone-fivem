# -*- coding: utf-8 -*-
"""The block system, under real Lua 5.4.

    python tools/test-blocking.py

The functions that decide who gets through are lifted out of server/main.lua by name and run
against the cases that matter. One of them is the whole reason the design looks as it does:

**a block survives its target being renumbered, and does not follow the number.** An admin
running `/phoneadmin renumber` hands a number to somebody else. A blocklist that matched on the
number alone would then silently mute a player who has done nothing, with no way for either side
to work out why - so an entry stores the citizen id behind the number when the phone could
resolve one, and that is what is compared. Two assertions below are exactly that pair: the
blocked person stays blocked after their number changes, and the innocent person who is handed
the old number does not.

The rest: everything in `Config.RequiredContacts` is unblockable, a bare string from an older
stored list still reads, the cap holds, and the operator's switch means what it says.
"""
import io
import os

import lupa

ROOT = r'C:\Users\Jimmy\Documents\github\fivem-autres\v-phone'
src = io.open(os.path.join(ROOT, 'server', 'main.lua'), encoding='utf-8').read()


def grab(name):
    """One `local function <name>` block, by brace-free indentation matching."""
    start = src.index('local function %s(' % name)
    end = src.index('\nend\n', start) + len('\nend\n')
    # `local` is dropped so each one lands as a GLOBAL: every `lua.execute` is its own chunk,
    # and a local declared in one is gone by the time the next runs.
    return src[start:end].replace('local function', 'function', 1)


lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
Config = { Blocking = { enabled = true, max = 3 },
           RequiredContacts = { { name = '911', number = '911' },
                                { name = 'Taxi', number = '555-0100' } } }
Store = {}
Bridge = { KvGet = function(cid, key) return Store[cid] end }
""")

lua.execute(grab('blockList'))
lua.execute(grab('blockCap'))
lua.execute(grab('blockingOn'))
lua.execute(grab('blockable'))
lua.execute(grab('blocksOf'))
lua.execute(grab('isBlockedBy'))

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


print('the sanitiser')
out = g.blockList(lua.eval("{ { n = '555-0001', c = 'ABC1' }, '555-0002', { number = '555-0003' } }"), 10)
check(len(out) == 3, 'reads objects, bare strings and the number= alias', '%d entries' % len(out))
check(out[1].n == '555-0001' and out[1].c == 'ABC1', 'keeps both halves of a resolved entry')
check(out[2].n == '555-0002' and out[2].c is None, 'a bare string is number-only')

dupes = g.blockList(lua.eval("{ { n = '555-0001', c = 'ABC1' }, { n = '555-9999', c = 'ABC1' } }"), 10)
check(len(dupes) == 1, 'the same PERSON twice is one entry, whatever number was used')

capped = g.blockList(lua.eval("{ '1', '2', '3', '4', '5' }"), 3)
check(len(capped) == 3, 'the cap holds', '%d of 5' % len(capped))

ctrl = g.blockList(lua.eval("{ '555\\n0001' }"), 10)
check('\n' not in ctrl[1].n, 'control characters are stripped')

print('')
print('what may not be blocked')
check(g.blockable('911') is False, '911 is refused')
check(g.blockable('555-0100') is False, 'a required contact is refused')
check(g.blockable('555-0142') is True, 'an ordinary number is allowed')
check(g.blockable('') is False, 'an empty number is refused')

print('')
print('who is blocked, and who is not')
lua.execute("""
Store['VICTIM'] = { blocked = {
    { n = '555-0001', c = 'PEST' },     -- resolved when it was blocked
    { n = '555-0777' },                 -- nobody held it at the time
} }
""")
check(g.isBlockedBy('VICTIM', 'PEST', '555-0001') is True, 'the person who was blocked')
check(g.isBlockedBy('VICTIM', 'PEST', '555-4242') is True,
      'STILL blocked after an admin changed their number')
check(g.isBlockedBy('VICTIM', 'INNOCENT', '555-0001') is False,
      'NOT blocked: somebody else was handed that number')
check(g.isBlockedBy('VICTIM', 'STRANGER', '555-0777') is True,
      'a number-only entry still matches by number')
check(g.isBlockedBy('VICTIM', 'NOBODY', '555-9999') is False, 'anybody else gets through')
check(g.isBlockedBy('NOSUCHCID', 'PEST', '555-0001') is False, 'an unknown recipient blocks nobody')
check(g.isBlockedBy(None, 'PEST', '555-0001') is False, 'a nil recipient is not an error')

print('')
print('the operator switch')
lua.execute("Config.Blocking.enabled = false")
check(g.isBlockedBy('VICTIM', 'PEST', '555-0001') is False, 'off means nobody is blocked')
check(len(g.blocksOf('VICTIM')) == 0, 'and the list reads empty')
lua.execute("Config.Blocking.enabled = true")
check(g.isBlockedBy('VICTIM', 'PEST', '555-0001') is True, 'back on again')

lua.execute("Config.Blocking = nil")
check(g.blockingOn() is True, 'no Blocking table at all means ON, as the config documents')
check(g.blockCap() == 50, 'and the default cap', str(g.blockCap()))

print('')
print('%d failure(s)' % len(fails))
raise SystemExit(1 if fails else 0)
