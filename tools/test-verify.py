# -*- coding: utf-8 -*-
"""The two badges, and the desk that sells one of them, under real Lua.

    python tools/test-verify.py


There are two badges on a social account and they are two different things: the BLUE tick is
bought at a desk on the map, and the ORANGE mark is granted by staff and by nothing else. The
whole feature turns on decisions that are impossible to see in game - a refusal that happens one
line too late has already taken somebody's money, and a column written one character too wide
has quietly revoked a badge nobody asked about.

So this drives the real code:

  the verdict       every reason to say no, in the order they are answered. **The money is the
                    LAST thing that happens**, so each refusal is also checked to have charged
                    nothing at all - this resource has already shipped a path that took payment
                    for something which no longer existed
  the desk          where a player has to be standing, measured on the server from the ped. A
                    client that could name the desk it is at could name one it is nowhere near
  the two badges    that blue and orange never touch each other. Buying blue must not disturb an
                    orange mark staff granted, revoking orange must leave a paid tick alone, and
                    each app keeps its own pair
  grant and revoke  both directions, on both colours, through the exports the staff command uses

`verifyVerdict`, `verifySellOn`, `verifySells`, `verifyPrice`, `verifyDeskAt`, `verifyPoints`,
the two callbacks behind the desk and the two exports behind the staff command are all lifted
out of server/social.lua as written. Everything around them - the database, the framework's
money, the ped - is a fake small enough to see through.

Positions arrive here already normalised, because `normalisePlaces` in config.lua turns every
`coords = vector3(...)` into x/y/z at load. What is checked here is what happens to a row that
has neither, which is the shape a typo actually produces.
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'server', 'social.lua'), encoding='utf-8').read()

lua = lupa.LuaRuntime(unpack_returned_tuples=True)

# ── The world around the code ─────────────────────────────────────────────
# `num` is the file's own one-liner and is re-declared rather than grabbed: the `\nend\n` rule
# every suite here uses would swallow the next function whole.
lua.execute('function num(v, d) return tonumber(v) or d or 0 end')

# A vector3 with the two metamethods `#(a - b)` needs. The distance check is the anti-forgery
# gate of the whole feature, so it is run for real rather than stubbed to a number.
lua.execute("""
local mt = {}
mt.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, mt) end
mt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, mt) end
""")

lua.execute("""
Config = {
    Social = { enabled = true },
    SocialVerify = {
        enabled = true,
        price = { bleeter = 25000, snap = 10000 },
        apps = { 'bleeter', 'snap' },
        money = 'bank',
        account = '',
        distance = 2.0,
        points = { { label = 'Weazel News, reception', x = 100.0, y = 200.0, z = 30.0 } },
    },
}

-- `V.SettingBool` reads the convar first and falls back to the config. nil means "not set on
-- this server", which is every ordinary server.
CONVAR = {}
V = {
    SettingBool = function(name, default)
        if CONVAR[name] ~= nil then return CONVAR[name] end
        return default and true or false
    end,
    Log = function() end,
}

-- One account row per character per app, which is exactly the table's own key.
ROWS = {}
LOG = {}

local function key(cid, app) return tostring(cid) .. '/' .. tostring(app) end

function seed(cid, app, handle, verified, official)
    ROWS[key(cid, app)] = { handle = handle, verified = verified or false,
                            official = official or false }
end

function badgeOf(cid, app, which)
    local r = ROWS[key(cid, app)]
    if not r then return nil end
    return r[which]
end

MySQL = {
    single = { await = function(_, args)
        local r = ROWS[key(args[1], args[2])]
        if not r then return nil end
        -- oxmysql hands a TINYINT(1) back as a boolean, which is what `truthy` exists for.
        return { handle = r.handle, verified = r.verified, official = r.official }
    end },
    update = { await = function(sql, args)
        local col = sql:match('SET (%w+) =')
        local guarded = sql:find('AND verified = 0', 1, true) ~= nil
        local value, cid, app
        if sql:find('SET %w+ = %?') then
            value, cid, app = args[1], args[2], args[3]
        else
            value, cid, app = sql:match('SET %w+ = (%d+)'), args[1], args[2]
        end
        local r = ROWS[key(cid, app)]
        if not r then return 0 end
        -- A WHERE nothing matches changes no rows, which is what the guarded UPDATE relies on.
        if guarded and r.verified then return 0 end
        r[col] = (tonumber(value) or 0) ~= 0
        return 1
    end },
    query = { await = function() return {} end },
}

-- The framework's money, and a record of every time it was asked for some.
CHARGED = {}
SOCIETY = {}
BALANCE = { bank = 0, cash = 0 }
MONEY_OK = true

Bridge = {
    Banking = { Balances = function() return { bank = BALANCE.bank, cash = BALANCE.cash } end },
    RemoveMoney = function(src, amount, account, reason)
        CHARGED[#CHARGED + 1] = { src = src, amount = amount, account = account, reason = reason }
        if not MONEY_OK then return false end
        if num(BALANCE[account], 0) < amount then return false end
        BALANCE[account] = BALANCE[account] - amount
        return true
    end,
    AddSociety = function(account, amount)
        SOCIETY[#SOCIETY + 1] = { account = account, amount = amount }
        return true
    end,
}

PLAYERS = { [1] = { citizenid = 'CID1' }, [2] = { citizenid = 'CID2' } }
Core = {
    GetPlayer = function(src) return PLAYERS[src] end,
    GetPlayerByCitizenId = function(cid)
        for s, p in pairs(PLAYERS) do if p.citizenid == cid then return { source = s } end end
        return nil
    end,
    Log = function(_, line) LOG[#LOG + 1] = line end,
}

-- Where each source is standing. A source with no entry has no ped at all, which is what a
-- player who has just dropped looks like.
PEDS = {}
function GetPlayerPed(src) return PEDS[src] and src or 0 end
function GetEntityCoords(ped) return PEDS[ped] end

INSTALLED = { [1] = { bleeter = true, snap = true }, [2] = { bleeter = true, snap = true } }
function PhoneHasApp(src, id) return (INSTALLED[src] or {})[id] == true end

-- No staff view session in any of these, which is every ordinary call.
function PhoneActingSource(src) return src end

REFRESHED = {}
function TriggerClientEvent(name, src, app)
    REFRESHED[#REFRESHED + 1] = { name = name, src = src, app = app }
end

-- The handle -> character lookup the staff exports start from. Faked: what is under test here
-- is which COLUMN a grant writes, not how a handle is resolved.
function cidOfHandle(app, handle)
    for k, r in pairs(ROWS) do
        local cid, rowApp = k:match('^(.-)/(.+)$')
        if rowApp == app and r.handle == handle then return cid end
    end
    return nil
end
""")


def grab(name):
    """One `local function <name>` block, by the brace-free rule the other suites use.

    `local` is dropped so each lands as a GLOBAL: every `lua.execute` is its own chunk, and a
    local declared in one is gone by the time the next runs.
    """
    start = src.index('local function %s(' % name)
    end = src.index('\nend\n', start) + len('\nend\n')
    return src[start:end].replace('local function', 'function', 1)


def grab_line(prefix):
    """One `local X = ...` line, as a global."""
    start = src.index(prefix)
    return src[start:src.index('\n', start)].replace('local ', '', 1)


def grab_wrapped(head, name, args):
    """A callback or an export body, re-headed as a plain function.

    The real body runs; only the registration around it is dropped. A test that re-implemented
    the purchase would pass while the resource charged somebody twice.
    """
    start = src.index(head)
    end = src.index('\nend)\n', start)
    body = src[start + len(head):end]
    return 'function %s(%s)%s\nend\n' % (name, args, body)


lua.execute(grab_line('local VERIFY_APPS ='))
lua.execute(grab_line('local APP_NAME ='))
lua.execute(grab_line('local VerifyBuying ='))
lua.execute(grab('truthy'))
lua.execute(grab('socOn'))
for fn in ('verifyCfg', 'verifySellOn', 'verifySells', 'verifyPrice', 'verifyPurse',
           'verifyInstalled', 'verifyBalance', 'verifyPoints', 'verifyDeskAt',
           'verifyPedCoords', 'verifyBadges', 'verifyVerdict'):
    lua.execute(grab(fn))

lua.execute(grab_wrapped("V.Callback('v-phone:soc:verifyDesk', function(src, resolve)",
                         'verifyDesk', 'src, resolve'))
lua.execute(grab_wrapped("V.Callback('v-phone:soc:verifyBuy', function(src, resolve, data)",
                         'verifyBuy', 'src, resolve, data'))
lua.execute(grab_wrapped("exports('SetVerified', function(app, handle, on)",
                         'SetVerified', 'app, handle, on'))
lua.execute(grab_wrapped("exports('SetOfficial', function(app, handle, on)",
                         'SetOfficial', 'app, handle, on'))

lua.execute("""
--- The desk, and only the desk. `verifyDeskAt` answers with the desk AND the distance, and a
--- two-value return of nil, nil crosses into Python as a pair rather than as nothing. The
--- brackets truncate it to one value, which is what the "am I at a desk" question wants.
function deskAt(coords) return (verifyDeskAt(coords)) end

--- The two callbacks answer through `resolve`. This hands the answer back as a return value.
function callDesk(src)
    local out
    verifyDesk(src, function(res) out = res end)
    return out
end

function callBuy(src, app)
    local out
    verifyBuy(src, function(res) out = res end, { app = app })
    return out
end

function reset()
    ROWS, CHARGED, SOCIETY, LOG, REFRESHED = {}, {}, {}, {}, {}
    VerifyBuying = {}
    -- Put the banking bridge back. One case below takes it away to check that an unreadable
    -- balance does not refuse, and a case that leaves the world broken behind it makes every
    -- test after it pass for the wrong reason.
    Bridge.Banking = { Balances = function() return { bank = BALANCE.bank, cash = BALANCE.cash } end }
    BALANCE = { bank = 100000, cash = 100000 }
    MONEY_OK = true
    CONVAR = {}
    PEDS = { [1] = vector3(100.0, 200.0, 30.0), [2] = vector3(100.0, 200.0, 30.0) }
    INSTALLED = { [1] = { bleeter = true, snap = true }, [2] = { bleeter = true, snap = true } }
    Config.Social.enabled = true
    Config.SocialVerify.enabled = true
    Config.SocialVerify.requireApp = nil
    Config.SocialVerify.account = ''
    Config.SocialVerify.money = 'bank'
    Config.SocialVerify.apps = { 'bleeter', 'snap' }
    Config.SocialVerify.price = { bleeter = 25000, snap = 10000 }
end
""")

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


def facts(**kw):
    """One set of facts for `verifyVerdict`, with the passing case as the default."""
    base = {'on': True, 'sells': True, 'atDesk': True, 'installed': True, 'account': True,
            'verified': False, 'paying': False, 'price': 25000, 'balance': 100000}
    base.update(kw)
    return lua.table_from(base)


def verdict(**kw):
    return g.verifyVerdict(facts(**kw))


def charged():
    return len(list(g.CHARGED.values()))


# ══ The verdict, one refusal at a time ════════════════════════════════════
print('every reason to say no')
check(verdict() == 'ok', 'a player at the desk, with an account and the money, may buy')
check(verdict(on=False) == 'off', 'the desk switched off refuses first of all')
check(verdict(sells=False) == 'badapp', 'an app the desk does not sell')
check(verdict(atDesk=False) == 'range', 'a player who is not at a desk')
check(verdict(installed=False) == 'notinstalled', 'an app that is not on their phone',
      'a badge on an app they cannot open is money taken for nothing')
check(verdict(account=False) == 'noaccount', 'no account on that app - no row to badge')
check(verdict(verified=True) == 'hasbadge', 'already verified there',
      'selling the same badge twice is selling nothing')
check(verdict(paying=True) == 'paying', 'a purchase of theirs already in flight')
check(verdict(balance=24999) == 'nomoney', 'a dollar short of the price')
check(verdict(balance=25000) == 'ok', 'and exactly the price is enough')
check(verdict(balance=None) == 'ok', 'a balance the bridge could not read does NOT refuse',
      'nil is "it could not say", and the debit is the authority either way')

print('')
print('the ORDER of the refusals, which is part of the design')
check(verdict(atDesk=False, account=False, verified=True) == 'range',
      'range is answered before anything about the account',
      'a forged request must not learn whether a handle exists from which refusal comes back')
check(verdict(on=False, atDesk=False) == 'off', 'and the feature switch before even that')
check(verdict(verified=True, balance=0) == 'hasbadge',
      'somebody who already holds it is told so rather than told they are poor')

print('')
print('a free badge')
check(verdict(price=0, balance=0) == 'ok', 'price 0 is a price, not a refusal')
check(verdict(price=0, balance=0, verified=True) == 'hasbadge',
      '...and free does not mean it can be bought twice')


# ══ Where the desk is ═════════════════════════════════════════════════════
print('')
print('standing at a desk, measured from the ped')
lua.execute('reset()')
check(g.deskAt(g.vector3(100.0, 200.0, 30.0)) is not None, 'on the spot')
check(g.deskAt(g.vector3(101.5, 200.0, 30.0)) is not None, 'inside the 2m default')
check(g.deskAt(g.vector3(103.0, 200.0, 30.0)) is None, 'three metres away is too far')
check(g.deskAt(g.vector3(100.0, 200.0, 34.0)) is None,
      'and so is four metres straight up', 'a floor above the desk is not at the desk')
check(g.deskAt(None) is None, 'a player with no ped is nowhere')

lua.execute('Config.SocialVerify.points[1].radius = 8.0')
check(g.deskAt(g.vector3(107.0, 200.0, 30.0)) is not None,
      "a desk's own radius widens it")
lua.execute('Config.SocialVerify.points[1].radius = nil')

lua.execute('Config.SocialVerify.points[1].enabled = false')
check(g.deskAt(g.vector3(100.0, 200.0, 30.0)) is None, 'a closed desk is not a desk')
lua.execute('Config.SocialVerify.points[1].enabled = nil')

lua.execute("Config.SocialVerify.points[2] = { label = 'typo, no position' }")
check(len(list(g.verifyPoints().values())) == 1,
      'a row with no coordinates is skipped rather than crashing the thread')
lua.execute('Config.SocialVerify.points[2] = nil')


# ══ What the operator asked for ═══════════════════════════════════════════
print('')
print('the operator switches')
lua.execute('reset()')
check(g.verifySellOn() is True, 'the desk is open by default')
lua.execute('Config.SocialVerify.enabled = false')
check(g.verifySellOn() is False, 'and closed when the config says so')
lua.execute('Config.SocialVerify.enabled = true')
lua.execute('Config.Social.enabled = false')
check(g.verifySellOn() is False, 'the social apps being off closes it too',
      'there is nothing to badge when there are no accounts')
lua.execute('Config.Social.enabled = true')
lua.execute('CONVAR.socialVerify = false')
check(g.verifySellOn() is False, 'phone_socialVerify false closes it on a running server')
lua.execute('CONVAR = {}')

check(g.verifySells('bleeter') is True, 'Bleeter is sold')
check(g.verifySells('hush') is False, 'Hush is not an app with a badge')
check(g.verifySells('') is False, 'and neither is nothing at all')
lua.execute("Config.SocialVerify.apps = { 'bleeter' }")
check(g.verifySells('snap') is False, 'an app taken off the list stops being sold')
check(g.verifySells('bleeter') is True, '...and the other one is untouched')
lua.execute("Config.SocialVerify.apps = { 'bleeter', 'snap' }")

check(g.verifyPrice('bleeter') == 25000, 'the price is per app', str(g.verifyPrice('bleeter')))
check(g.verifyPrice('snap') == 10000, '...and the second app has its own',
      str(g.verifyPrice('snap')))
lua.execute('Config.SocialVerify.price = { bleeter = -5 }')
check(g.verifyPrice('bleeter') == 0, 'a negative price is 0, never a payout')
check(g.verifyPrice('snap') == 0, 'an app with no price named is free')
lua.execute('Config.SocialVerify.price = { bleeter = 25000, snap = 10000 }')


# ══ The purchase, end to end ══════════════════════════════════════════════
print('')
print('buying the blue tick')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody')")
r = g.callBuy(1, 'bleeter')
check(r.ok is True, 'a player at the desk with an account buys it')
check(g.badgeOf('CID1', 'bleeter', 'verified') is True, 'the badge is on the account')
check(g.badgeOf('CID1', 'bleeter', 'official') is False,
      '...and the orange mark was not touched by it')
check(g.BALANCE.bank == 75000, 'the price came out of the bank', str(g.BALANCE.bank))
check(charged() == 1, 'exactly one debit')

print('')
print('**nothing is charged by a refusal**')
for case, setup, why in (
    ('already verified', "seed('CID1', 'bleeter', 'somebody', true)", 'hasbadge'),
    ('no account on that app', '', 'noaccount'),
    ('the app is not installed', "seed('CID1', 'bleeter', 'somebody'); INSTALLED[1].bleeter = nil",
     'notinstalled'),
    ('too far from the desk',
     "seed('CID1', 'bleeter', 'somebody'); PEDS[1] = vector3(400.0, 200.0, 30.0)", 'range'),
    ('no ped at all', "seed('CID1', 'bleeter', 'somebody'); PEDS[1] = nil", 'range'),
    ('the desk is switched off',
     "seed('CID1', 'bleeter', 'somebody'); Config.SocialVerify.enabled = false", 'off'),
    ('an app the desk does not sell', "seed('CID1', 'hush', 'somebody')", 'badapp'),
    ('a name that is not an app', '', 'badapp'),
    ('not enough money',
     "seed('CID1', 'bleeter', 'somebody'); BALANCE.bank = 10", 'nomoney'),
):
    lua.execute('reset()')
    if setup:
        lua.execute(setup)
    app = 'hush' if 'not sell' in case else ('nonsense' if 'not an app' in case else 'bleeter')
    res = g.callBuy(1, app)
    check(res.error == why, '%s -> %s' % (case, why), str(res.error))
    check(charged() == 0, '   ...and nothing was charged')

print('')
print('a bridge that cannot read a balance')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody'); Bridge.Banking = nil")
check(g.verifyBalance(1) is None, 'reads as unknown, not as nothing')
lua.execute('BALANCE.bank = 0')
r = g.callBuy(1, 'bleeter')
check(r.error == 'nomoney', 'and the DEBIT is what refuses, so the answer is still right',
      'a player with a full account must never be told they are poor by a failed read')
check(charged() == 1, 'the debit was the thing that decided it')

print('')
print('an operator who does not gate on the app being installed')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody'); INSTALLED[1].bleeter = nil")
lua.execute('Config.SocialVerify.requireApp = false')
check(g.verifyInstalled(1, 'bleeter') is True, 'requireApp false stops asking')
check(g.callBuy(1, 'bleeter').ok is True, '...and the badge is sold anyway')
lua.execute('Config.SocialVerify.requireApp = nil')
check(g.verifyInstalled(1, 'bleeter') is False, 'and the default asks again')

print('')
print('a debit the framework refuses grants nothing')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody'); MONEY_OK = false")
r = g.callBuy(1, 'bleeter')
check(r.error == 'nomoney', 'the purchase fails closed', str(r.error))
check(g.badgeOf('CID1', 'bleeter', 'verified') is False, 'and no badge was written')
check(charged() == 1, 'the debit was attempted exactly once')

print('')
print('a free badge still has to pass every other gate')
lua.execute('reset()')
lua.execute('Config.SocialVerify.price = { bleeter = 0 }; BALANCE.bank = 0')
lua.execute("seed('CID1', 'bleeter', 'somebody')")
r = g.callBuy(1, 'bleeter')
check(r.ok is True, 'a price of 0 is granted to somebody with nothing')
check(charged() == 0, '...without a debit for zero',
      'a framework asked for 0 writes a statement line saying nothing happened')

print('')
print('where the money goes')
lua.execute('reset()')
lua.execute("Config.SocialVerify.account = 'weazel'")
lua.execute("seed('CID1', 'bleeter', 'somebody')")
g.callBuy(1, 'bleeter')
society = list(g.SOCIETY.values())
check(len(society) == 1 and society[0].account == 'weazel' and society[0].amount == 25000,
      'the named account is credited with the price')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody')")
g.callBuy(1, 'bleeter')
check(len(list(g.SOCIETY.values())) == 0, "an empty account name credits nobody")

print('')
print('cash instead of a card')
lua.execute('reset()')
lua.execute("Config.SocialVerify.money = 'cash'")
lua.execute("seed('CID1', 'bleeter', 'somebody')")
g.callBuy(1, 'bleeter')
check(g.BALANCE.cash == 75000 and g.BALANCE.bank == 100000,
      'the cash purse pays and the bank is untouched')
check(list(g.CHARGED.values())[0].account == 'cash', 'and the bridge was told which purse')


# ══ Two badges that never touch ═══════════════════════════════════════════
print('')
print('blue and orange are independent')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'mayor', false, true)")
r = g.callBuy(1, 'bleeter')
check(r.ok is True, 'an official account may still buy the blue tick')
check(g.badgeOf('CID1', 'bleeter', 'official') is True, 'and keeps the orange mark',
      'buying one must never be a way of writing the other')
check(g.badgeOf('CID1', 'bleeter', 'verified') is True, '...alongside the one it just bought')

lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'mayor', true, true)")
g.SetOfficial('bleeter', 'mayor', False)
check(g.badgeOf('CID1', 'bleeter', 'official') is False, 'revoking orange takes orange off')
check(g.badgeOf('CID1', 'bleeter', 'verified') is True,
      '...and leaves the tick they paid for alone')

g.SetVerified('bleeter', 'mayor', False)
lua.execute("ROWS['CID1/bleeter'].official = true")
g.SetVerified('bleeter', 'mayor', True)
check(g.badgeOf('CID1', 'bleeter', 'official') is True,
      'and granting blue leaves an orange mark where it was')

print('')
print('grant and revoke, both colours')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody')")
ok, handle = g.SetVerified('bleeter', '@somebody', True)
check(ok is True and handle == 'somebody', 'a leading @ is accepted and stripped back')
check(g.badgeOf('CID1', 'bleeter', 'verified') is True, 'blue granted')
g.SetVerified('bleeter', 'somebody', False)
check(g.badgeOf('CID1', 'bleeter', 'verified') is False, 'blue revoked')
g.SetOfficial('bleeter', 'somebody', True)
check(g.badgeOf('CID1', 'bleeter', 'official') is True, 'orange granted')
g.SetOfficial('bleeter', 'somebody', False)
check(g.badgeOf('CID1', 'bleeter', 'official') is False, 'orange revoked')

ok, why = g.SetOfficial('bleeter', 'nobody', True)
check(ok is False and why == 'nosuchhandle', 'a handle nobody holds is refused, clearly')
ok, why = g.SetOfficial('bleeter', '  ', True)
check(ok is False and why == 'nohandle', 'and so is no handle at all')

print('')
print('each app keeps its own pair')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody'); seed('CID1', 'snap', 'somebody')")
g.callBuy(1, 'bleeter')
check(g.badgeOf('CID1', 'snap', 'verified') is False,
      'buying the tick on Bleeter leaves Snapmatic unverified')
g.SetOfficial('snap', 'somebody', True)
check(g.badgeOf('CID1', 'snap', 'official') is True, 'and Snapmatic can be made official')
check(g.badgeOf('CID1', 'bleeter', 'official') is False, '...without touching Bleeter')
r = g.callBuy(1, 'snap')
check(r.ok is True and r.price == 10000, "Snapmatic charges Snapmatic's price", str(r.price))


# ══ What the desk offers ══════════════════════════════════════════════════
print('')
print('what the desk shows before anything is tapped')
lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody', true); INSTALLED[1].snap = nil")
d = g.callDesk(1)
check(d.ok is True, 'the desk answers to somebody standing at it')
check(d.label == 'Weazel News, reception', 'and names itself', str(d.label))
rows = {row.app: row for row in list(d.apps.values())}
check(rows['bleeter'].verdict == 'hasbadge', 'the row for an app already verified says so')
check(rows['snap'].verdict == 'notinstalled', 'and an app they have not installed says that')
check(rows['bleeter'].price == 25000, 'each row carries its own price')
check(charged() == 0, 'and looking at the desk costs nothing')

lua.execute('reset()')
lua.execute("seed('CID1', 'bleeter', 'somebody'); PEDS[1] = vector3(400.0, 0.0, 0.0)")
check(g.callDesk(1).error == 'range', 'a phone opened away from a desk is refused the listing',
      'the listing is what the page draws its rows from, so it is gated too')

lua.execute('reset()')
lua.execute("Config.SocialVerify.apps = { 'bleeter' }; seed('CID1', 'bleeter', 'somebody')")
d = g.callDesk(1)
check(len(list(d.apps.values())) == 1, 'an app the desk stopped selling is not even listed')

print()
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all verification cases pass')
