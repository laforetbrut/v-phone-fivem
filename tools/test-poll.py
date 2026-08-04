# -*- coding: utf-8 -*-
"""The balance sampler, and the double notification it would have caused. Under real Lua.

    python tools/test-poll.py


Two things are driven here. `pollEvery` resolves the config's `'auto'`, which is the whole
reason ox_core players were never told about money arriving: the shipped value was a flat 0 and
0 means off.

And the sampler's own arithmetic. Switching sampling on without the accounting below sends every
recipient of a phone transfer a second, unlabelled notification a few seconds after the real
one - the sampler noticing the phone. The event path recognises the phone's own movements by
their reason string and the sampler has only a number, so the phone's two money doors count
what they moved and the sampler subtracts it.

The last case is the one that is easy to skip: a movement landing WHILE a balance is being read
cannot be placed on either side of the number that comes back. Guessing there is how a player
gets told they received money they sent.
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'server', 'bank.lua'), encoding='utf-8').read()

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute('function num(v, d) return tonumber(v) or d or 0 end')
lua.execute('NOTIFY = {}')
lua.execute('Bridge = { framework = "qb" }')

# `pollEvery`, exactly as the file writes it.
start = src.index('local function pollEvery()')
end = src.index('\nend\n', start) + len('\nend\n')
lua.execute(src[start:end].replace('local function', 'function'))

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


print("the interval, resolving 'auto'")
for fw, want in [('qb', 0), ('esx', 0), ('ox', 30), ('standalone', 30)]:
    lua.execute('Bridge.framework = "%s"' % fw)
    lua.execute("NOTIFY.pollSeconds = 'auto'")
    got = g.pollEvery()
    check(got == want, "%s samples every %s" % (fw, want or 'never'), str(got))

lua.execute('Bridge.framework = "ox"')
lua.execute('NOTIFY.pollSeconds = 0')
check(g.pollEvery() == 0, 'an explicit 0 is still off, even on ox',
      'an operator who switched it off keeps it off')
lua.execute('NOTIFY.pollSeconds = 45')
check(g.pollEvery() == 45, 'a number is honoured exactly')
lua.execute('NOTIFY.pollSeconds = nil')
check(g.pollEvery() == 30, 'a missing value is auto, not zero',
      'nil reaching tonumber must not read as off')

# ── The sampler's arithmetic, lifted into a driveable shape ───────
#
# The loop body is rewritten here as a function of (balance, phone moves) because the real one
# is wrapped in `CreateThread` and `Wait`, neither of which exists outside FiveM. The DECISION
# is the code under test and is transcribed line for line.
lua.execute("""
lastSeen, ownMoved, announced = {}, {}, {}

function ownMove(src, delta)
    ownMoved[src] = (ownMoved[src] or 0) + math.floor(delta)
end

--- One pass over one player. `duringRead` is a phone movement that lands while the balance is
--- being fetched, which is the case that cannot be placed on either side of the answer.
function sample(src, bank, duringRead)
    local before = lastSeen[src]
    local mine = ownMoved[src] or 0
    if duringRead then ownMove(src, duringRead) end
    local now = math.floor(bank)
    if (ownMoved[src] or 0) ~= mine then
        lastSeen[src] = nil
    else
        if before then
            local unexplained = now - before - mine
            if unexplained ~= 0 then
                announced[#announced + 1] = unexplained
            end
        end
        lastSeen[src] = now
    end
    ownMoved[src] = 0
end
""")

announced = lambda: [g.announced[i] for i in range(1, len(g.announced) + 1)]


def reset():
    lua.execute('lastSeen, ownMoved, announced = {}, {}, {}')


print('the baseline')
reset()
g.sample(1, 5000, None)
check(announced() == [], 'the first sample announces nothing',
      'otherwise every player is greeted with their whole balance')

print('money from somewhere else')
g.sample(1, 5250, None)
check(announced() == [250], 'a salary paid by a job script is announced', str(announced()))
g.sample(1, 5250, None)
check(announced() == [250], 'a balance that did not move says nothing again')
g.sample(1, 5100, None)
check(announced() == [250, -150], 'money leaving is a movement too', str(announced()))

print('a transfer sent from the phone')
reset()
g.sample(2, 1000, None)
g.ownMove(2, 400)          # the phone credits this player, and notifies them itself
g.sample(2, 1400, None)
check(announced() == [],
      'the phone moving money is not announced a second time',
      'this is the bug that switching sampling on would have shipped')

print('the phone and something else in the same interval')
reset()
g.sample(3, 1000, None)
g.ownMove(3, 400)          # a phone transfer
g.sample(3, 1700, None)    # and a 300 paycheck from elsewhere
check(announced() == [300],
      'only the part the phone did not do is announced', str(announced()))

print('a phone movement while the balance is in flight')
reset()
g.sample(4, 1000, None)
g.sample(4, 1000, 250)     # the phone credits 250 mid-read
check(announced() == [],
      'nothing is announced from an ambiguous reading',
      'the number cannot be placed before or after the movement')
check(g.lastSeen[4] is None, 're-baselined instead of guessed')
g.sample(4, 1250, None)
check(announced() == [], 'the next pass only re-establishes the baseline', str(announced()))
g.sample(4, 1400, None)
check(announced() == [150], 'and the one after that works normally', str(announced()))

print()
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all sampler cases pass')
