# -*- coding: utf-8 -*-
"""The hourly "what's new" nudge, decided under real Lua.

    python tools/test-nudge.py


The nudge exists to give a quiet Bleeter or Snapmatic a reason to be opened, and it only earns
that by never lying. **A notification that fires on a feed the player has already read is the
notification that teaches them to ignore the next one**, so the decision is worth more than the
delivery: this drives it through every case that reaches it, including the four that are easy to
get wrong and impossible to see in game.

  never opened      somebody who has never opened Bleeter must not be handed the whole history
                    as a number. The mark is PLANTED where the feed stands and nothing is sent.
  already told      ignoring one nudge must not mean receiving it again every hour. The count is
                    measured from what they have READ; whether to speak at all is measured from
                    what they have already been TOLD, and those are two different numbers.
  silenced          do not disturb, an app they muted, an app they uninstalled, a flat battery
                    and a phone they are not carrying all stop it - and the silence spends the
                    turn, so turning do-not-disturb off cannot release an hour of held banners.
  a read in flight  the mark is re-read after the query, because a player who opens the app
                    while the count is being taken has read exactly the posts it counted.

`nudgeVerdict` is lifted out of server/social.lua as written. Everything around it is a database
read, a preference lookup or a clock, none of which run outside the game; the decision does, and
this is where it is held to account.
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'server', 'social.lua'), encoding='utf-8').read()

lua = lupa.LuaRuntime(unpack_returned_tuples=True)

# `num` is the file's own helper and lives above everything grabbed below. Re-declared rather
# than grabbed: it is one line, and grabbing a one-liner by the `\nend\n` rule would swallow the
# next function whole.
lua.execute('function num(v, d) return tonumber(v) or d or 0 end')

# What the operator asked for. `V.SettingBool` reads the convar first and falls back to the
# config, which is what this stands in for - CONVAR nil means "not set on this server".
lua.execute("""
SOC = { nudge = {
    enabled = true,
    bleeter = { enabled = true, minutes = 60 },
    snap    = { enabled = true, minutes = 60 },
} }
CONVAR = nil
V = { SettingBool = function(_, default)
    if CONVAR ~= nil then return CONVAR end
    return default and true or false
end }
""")

# The phone's per-character store and the one scalar the read mark needs, as fakes small enough
# to see through. STORE is what `vphone_kv` would hold; TOP is the newest post id in the app.
lua.execute("""
STORE = {}
TOP = { bleeter = 0, snap = 0 }
WRITES = 0

Bridge = {
    KvGet = function(cid, key) return STORE[cid .. '/' .. key] end,
    KvSet = function(cid, key, value)
        WRITES = WRITES + 1
        STORE[cid .. '/' .. key] = value
        return true
    end,
}

-- `nudgeMarkRead` asks for one scalar and nothing else. The fake answers from TOP, and records
-- that it was asked, so a mark that moves without a read would show up as a missing question.
ASKED = 0
MySQL = { scalar = { await = function(_, args)
    ASKED = ASKED + 1
    return TOP[args[1]] or 0
end } }

-- The three globals `nudgeQuiet` reaches for, out of server/main.lua.
INSTALLED = { bleeter = true, snap = true }
PREFS = nil
function PhoneHasApp(_, id) return INSTALLED[id] == true end
function PhonePrefs(_) return PREFS end
""")


def grab(name):
    """One `local function <name>` block, by the same brace-free rule the other suites use.

    `local` is dropped so each one lands as a GLOBAL: every `lua.execute` is its own chunk, and a
    local declared in one is gone by the time the next runs.
    """
    start = src.index('local function %s(' % name)
    end = src.index('\nend\n', start) + len('\nend\n')
    return src[start:end].replace('local function', 'function', 1)


# The key the record is filed under, read out of the file rather than repeated here: a test that
# invents the key would pass while the resource wrote somewhere else entirely.
lua.execute(src[src.index('local NUDGE_KEY ='):src.index('\n', src.index('local NUDGE_KEY ='))]
            .replace('local ', '', 1))

for fn in ('nudgeRecord', 'nudgeMark', 'nudgeCfg', 'nudgeVerdict', 'nudgeMarkRead', 'nudgeQuiet'):
    lua.execute(grab(fn))

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


def gate(due=True, phone=True, quiet=False):
    return lua.table_from({'due': due, 'phone': phone, 'quiet': quiet})


def mark(seen, told):
    return lua.table_from({'seen': seen, 'told': told})


def feed(**kw):
    return lua.table_from(kw)


def verdict(cfg, g8, mk, fd):
    """The verdict, plus the count and the post id when it answers with them."""
    res = g.nudgeVerdict(cfg, g8, mk, fd)
    if isinstance(res, tuple):
        return (tuple(res) + (None, None))[:3]
    return (res, None, None)


ON = g.nudgeCfg('bleeter')


print('what the operator asked for')
check(g.nudgeCfg('bleeter').on is True, 'on by default')
check(g.nudgeCfg('bleeter').minutes == 60, 'an hour by default', str(g.nudgeCfg('bleeter').minutes))
lua.execute('SOC.nudge.snap.enabled = false')
check(g.nudgeCfg('snap').on is False, 'one app off leaves the other alone')
check(g.nudgeCfg('bleeter').on is True, '...and Bleeter is still on')
lua.execute('SOC.nudge.snap.enabled = true')
lua.execute('SOC.nudge.bleeter.minutes = 0')
check(g.nudgeCfg('bleeter').minutes == 1, 'a ceiling under a minute is raised to one',
      'the pass ticks once a minute, so anything finer could not be honoured')
lua.execute('SOC.nudge.bleeter.minutes = 60')
lua.execute('CONVAR = false')
check(g.nudgeCfg('bleeter').on is False, 'phone_socialNudge false turns the whole thing off')
lua.execute('CONVAR = nil')
check(g.nudgeCfg('what').on is True, 'an app the config never named still reads as on')
check(g.nudgeCfg('what').minutes == 60, '...at the default interval')


print('')
print('nothing new, which is the case that must stay silent')
check(verdict(ON, gate(), mark(40, 40), feed(fresh=0, freshtop=0))[0] == 'none',
      'a feed with nothing above the read mark sends nothing')
check(verdict(ON, gate(), mark(40, 40), feed(fresh=0, freshtop=0))[1] is None,
      '...and answers no count with it')

print('')
print('something new')
v, count, top = verdict(ON, gate(), mark(40, 40), feed(fresh=3, freshtop=43))
check(v == 'send', 'three posts above the read mark are announced')
check(count == 3, 'the count is how many are new TO THEM', str(count))
check(top == 43, 'and the newest of them is what gets recorded as told', str(top))

v, count, _ = verdict(ON, gate(), mark(10, 50), feed(fresh=41, freshtop=51))
check(v == 'send', 'one new post above a long-unread feed still speaks')
check(count == 41, 'the count is measured from SEEN, not from told', str(count))

print('')
print('the same posts are never announced twice')
check(verdict(ON, gate(), mark(10, 50), feed(fresh=40, freshtop=50))[0] == 'none',
      'forty unread posts, all of them already announced, send nothing',
      'this is the difference between a nudge and a nag')
check(verdict(ON, gate(), mark(10, 50), feed(fresh=45, freshtop=49))[0] == 'none',
      'nor does a feed whose newest unread post is older than the last one announced')

print('')
print('the rate ceiling')
check(verdict(ON, gate(due=False), mark(40, 40), feed(fresh=9, freshtop=49))[0] == 'wait',
      'a player whose turn has not come is not asked anything')
check(verdict(ON, gate(due=False), None, None)[0] == 'wait',
      '...not even a player who has never been marked')

print('')
print('nothing is read until the gates have passed')
check(verdict(ON, gate(), mark(40, 40), None)[0] == 'ask',
      'a player who passes every gate is worth a query')
check(verdict(ON, gate(quiet=True), mark(40, 40), None)[0] == 'quiet',
      'a muted app never costs one')
check(verdict(g.nudgeCfg('snap'), gate(), mark(40, 40), None)[0] == 'ask',
      'both apps are on, so both are asked')

print('')
print('a silenced phone')
check(verdict(ON, gate(quiet=True), mark(40, 40), feed(fresh=9, freshtop=49))[0] == 'quiet',
      'do not disturb, or the app silenced, stops it')
check(verdict(ON, gate(phone=False), mark(40, 40), feed(fresh=9, freshtop=49))[0] == 'quiet',
      'a phone that is off, or not on them, stops it')
lua.execute('SOC.nudge.enabled = false')
check(verdict(g.nudgeCfg('bleeter'), gate(), mark(40, 40), feed(fresh=9, freshtop=49))[0] == 'off',
      'and the feature switched off stops it before anything else')
lua.execute('SOC.nudge.enabled = true')

print('')
print('...and the silence SPENDS the turn rather than banking it')
check(verdict(ON, gate(due=False, quiet=True), mark(40, 40), None)[0] == 'wait',
      'the ceiling is read before the silence',
      'the other order would release an hour of held banners the moment DND came off')

print('')
print('what silences it, as the phone itself answers')
lua.execute('PREFS = { dnd = false, notifMuted = {} }')
check(g.nudgeQuiet(1, None, 'bleeter') is False, 'an ordinary phone is not quiet')
lua.execute('PREFS = { dnd = true, notifMuted = {} }')
check(g.nudgeQuiet(1, None, 'bleeter') is True, 'do not disturb is')
lua.execute("PREFS = { dnd = false, notifMuted = { 'bleeter' } }")
check(g.nudgeQuiet(1, None, 'bleeter') is True, 'so is the app switched off in Settings')
check(g.nudgeQuiet(1, None, 'snap') is False, '...and only that app', 'Snapmatic is untouched')
lua.execute("PREFS = { dnd = false, notifMuted = {}, notifSilent = { 'bleeter' } }")
check(g.nudgeQuiet(1, None, 'bleeter') is False, 'silent is NOT quiet',
      'seen but not heard: the banner is still wanted, the sound is not')
lua.execute('INSTALLED.bleeter = nil')
check(g.nudgeQuiet(1, None, 'bleeter') is True, 'an app they uninstalled is quiet')
lua.execute('INSTALLED.bleeter = true')
lua.execute('PREFS = nil')
check(g.nudgeQuiet(1, None, 'bleeter') is False,
      'a character with no preferences yet is not quiet', 'absent means default, not off')


print('')
print('a player who has never opened the app')
lua.execute("STORE = {}; TOP = { bleeter = 1847, snap = 12 }; WRITES = 0")
check(g.nudgeMark(g.nudgeRecord('CID1'), 'bleeter') is None, 'has no mark at all')
v, count, top = verdict(ON, gate(), g.nudgeMark(g.nudgeRecord('CID1'), 'bleeter'),
                        feed(top=1847))
check(v == 'plant', 'is marked where the feed stands, and told nothing',
      '1847 posts of history is not a notification')
check(count == 0, '...with no count', str(count))
check(top == 1847, '...at the newest post there is', str(top))

print('')
print('and then, an hour later')
lua.execute("STORE['CID1/' .. NUDGE_KEY] = { bleeter = { seen = 1847, told = 1847 } }")
mk = g.nudgeMark(g.nudgeRecord('CID1'), 'bleeter')
check(mk is not None and mk.seen == 1847, 'the planted mark is read back')
check(verdict(ON, gate(), mk, feed(fresh=0, freshtop=0))[0] == 'none',
      'a quiet hour still sends nothing')
v, count, _ = verdict(ON, gate(), mk, feed(fresh=2, freshtop=1849))
check(v == 'send' and count == 2, 'two posts written since are two posts announced', str(count))


print('')
print('a player who opens the app constantly')
lua.execute("STORE = {}; TOP = { bleeter = 900, snap = 0 }; ASKED = 0; WRITES = 0")
g.nudgeMarkRead('CID2', 'bleeter')
mk = g.nudgeMark(g.nudgeRecord('CID2'), 'bleeter')
check(mk is not None and mk.seen == 900, 'opening the feed marks it read to the newest post',
      'the same rule the notifications tab states: opening it is reading it')
check(mk.told == 900, '...and told is carried up with it, never left behind')
check(verdict(ON, gate(), mk, feed(fresh=0, freshtop=0))[0] == 'none',
      'so there is never anything to tell them')

before = g.WRITES
g.nudgeMarkRead('CID2', 'bleeter')
g.nudgeMarkRead('CID2', 'bleeter')
check(g.WRITES == before, 'refreshing a feed that has not moved writes nothing',
      'a pull to refresh must not cost a row')
lua.execute('TOP.bleeter = 901')
g.nudgeMarkRead('CID2', 'bleeter')
check(g.WRITES == before + 1, 'and a feed that HAS moved writes once')
check(g.nudgeMark(g.nudgeRecord('CID2'), 'bleeter').seen == 901, 'to the new newest post')

print('')
print('reading it never moves the mark backwards')
lua.execute("STORE['CID2/' .. NUDGE_KEY] = { bleeter = { seen = 901, told = 5000 } }")
lua.execute('TOP.bleeter = 950')
g.nudgeMarkRead('CID2', 'bleeter')
mk = g.nudgeMark(g.nudgeRecord('CID2'), 'bleeter')
check(mk.told == 5000, 'told stays where it was when it is already ahead', str(mk.told))
check(mk.seen == 950, '...and seen still moves up', str(mk.seen))

print('')
print('the two apps keep their own marks')
lua.execute("STORE = {}; TOP = { bleeter = 900, snap = 40 }")
g.nudgeMarkRead('CID3', 'bleeter')
check(g.nudgeMark(g.nudgeRecord('CID3'), 'snap') is None,
      'reading Bleeter does not mark Snapmatic')
g.nudgeMarkRead('CID3', 'snap')
check(g.nudgeMark(g.nudgeRecord('CID3'), 'snap').seen == 40, '...and Snapmatic marks its own')
check(g.nudgeMark(g.nudgeRecord('CID3'), 'bleeter').seen == 900, '...without disturbing Bleeter')

print('')
print('a record written by hand, or by an older build')
lua.execute("STORE['CID4/' .. NUDGE_KEY] = { bleeter = 'nonsense' }")
check(g.nudgeMark(g.nudgeRecord('CID4'), 'bleeter') is None,
      'a value that is not a record reads as never marked')
lua.execute("STORE['CID4/' .. NUDGE_KEY] = { bleeter = {} }")
mk = g.nudgeMark(g.nudgeRecord('CID4'), 'bleeter')
check(mk is not None and mk.seen == 0 and mk.told == 0,
      'a record with neither number reads as zero, not as absent',
      'absent means plant; zero means the feed really is unread')
lua.execute("STORE['CID5/x'] = nil")
check(g.nudgeMark(g.nudgeRecord('CID5'), 'bleeter') is None, 'and a character with no row at all')

print()
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all nudge cases pass')
