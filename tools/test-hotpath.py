# -*- coding: utf-8 -*-
"""The server's battery clocks, under real Lua: what they cost, and that they still do the same.

    python tools/test-hotpath.py

Loads the real bridge/shared/v.lua, bridge/server/kv.lua, bridge/server/framework.lua,
server/adminview.lua, server/outage.lua, server/charging.lua and config.lua, compat.lua's
GetResourceState override, and the battery and signal section of server/main.lua lifted out by
text anchors. Natives and the five frameworks are faked, and every call that costs something is
counted.

The same world is also built from the files as they were at BASE, the last commit before the
state tick stopped building a player per player, and the two are run side by side on one fixture.
BASE is pinned rather than HEAD on purpose: once this change is committed HEAD would be the new
code, and a comparison of the code against itself passes whatever it does.

What it holds:

  * Bridge.HasPlayer and Core.HasPlayer answer exactly what the truthiness of Bridge.GetPlayer and
    Core.GetPlayer answers, on every framework, for every shape of source and for a staff member
    holding somebody's phone (open, run out, target gone).
  * The state tick builds no player wrapper and reads v-world's state at most once a pass.
  * The players ticked, the signal, the charge and every push are the same as BASE.
  * An admin view nobody touches runs out at viewSeconds; real use still extends it. No clock keeps
    it alive: not the bank balance poll, not the call check on a staff member who is on a call.
  * A staff member who drops leaves no refusal behind for the next player given that server id.
  * A session that ends without the staff member asking refuses their first request afterwards,
    and no clock spends that refusal. The phone closes on the end and acknowledges it.
  * A FruitBrawl payout, which runs from the round clock, does not keep a session alive.

Lua 5.4 is pinned: FiveM runs 5.4, and a bare `import lupa` picks the newest bundled Lua.
  * The drain tick and the shutdown save write a staff member's battery into their own row, never
    into the row of the character they are holding.
  * Two ox_core players on the character selection screen never share a battery row.

Exit code 1 if anything fails.
"""
import os
import subprocess
import sys

try:
    import lupa.lua54 as lupa
except ImportError:
    print('lupa with Lua 5.4 is not installed: pip install lupa')
    sys.exit(1)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = '5b02d5c'
PLAYERS = 64
FRAMEWORKS = ['qb', 'qbx', 'ox', 'esx', 'standalone']
# The files this change touched. Everything else is read from the working tree for both worlds,
# so the comparison is about these and nothing else.
CHANGED = {'bridge/server/framework.lua', 'server/adminview.lua', 'server/charging.lua',
           'server/main.lua', 'server/bank.lua', 'server/brawl.lua'}

_sources = {}


def source(rel, base=False):
    key = (rel, base and rel in CHANGED)
    if key not in _sources:
        if key[1]:
            p = subprocess.run(['git', 'show', '%s:%s' % (BASE, rel)], cwd=ROOT,
                               capture_output=True, text=True, encoding='utf-8', errors='replace')
            if p.returncode != 0:
                print('cannot read %s at %s (%s): this test compares against that commit'
                      % (rel, BASE, (p.stderr or '').strip()))
                sys.exit(1)
            text = p.stdout
        else:
            with open(os.path.join(ROOT, rel), encoding='utf-8') as f:
                text = f.read()
        _sources[key] = text.replace('\r\n', '\n')
    return _sources[key]


def between(text, start, end, include_end=True):
    a = text.index(start)
    b = text.index(end, a + len(start))
    return text[a:b + (len(end) if include_end else 0)]


fails = []
checks = [0]


def check(ok, what, detail=''):
    checks[0] += 1
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


# ----------------------------------------------------------------------------------------------
# The fake world
# ----------------------------------------------------------------------------------------------
PRELUDE = r'''
C = {}
function resetC()
    C = { natives = {}, convar = 0, cross = 0, selfExport = 0, playerProxy = 0, wraps = 0,
          world = 0, kvWrites = {} }
    EVENTS, ENDED, PED_ASKED = {}, {}, {}
end
resetC()
local function native(name) C.natives[name] = (C.natives[name] or 0) + 1 end

CLOCK = 1000000
os.time = function() return CLOCK end

STARTED, PLAYERS, PED_IN_VEHICLE, STATES, COORDS, GONE = {}, {}, {}, {}, {}, {}

function IsDuplicityVersion() return true end
function GetCurrentResourceName() native('GetCurrentResourceName') return 'v-phone' end
function GetResourceState(res) native('GetResourceState') return STARTED[res] and 'started' or 'missing' end
function GetConvar(name, default) native('GetConvar') C.convar = C.convar + 1 return default end
function GetPlayers()
    native('GetPlayers')
    local out = {}
    for i = 1, NPLAYERS do if not GONE[i] then out[#out + 1] = tostring(i) end end
    return out
end
function GetPlayerPed(src)
    native('GetPlayerPed')
    PED_ASKED[#PED_ASKED + 1] = src
    return GONE[src] and 0 or 1000 + src
end
function GetPlayerName(src) native('GetPlayerName') return 'Player' .. tostring(src) end
function GetNumPlayerIdentifiers(src) native('GetNumPlayerIdentifiers') return 3 end
function GetPlayerIdentifier(src, i)
    native('GetPlayerIdentifier')
    return ({ 'fivem:test', 'license:testlicence' .. tostring(src), 'discord:test' })[i + 1]
end
function IsPedInAnyVehicle(ped) native('IsPedInAnyVehicle') return PED_IN_VEHICLE[ped - 1000] == true end
function IsPlayerAceAllowed() return true end
function dump(v)
    local t = type(v)
    if t == 'number' then return string.format('%.9g', v) end
    if t ~= 'table' then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. '=' .. dump(v[k]) end
    return '{' .. table.concat(out, ',') .. '}'
end
function TriggerClientEvent(name, target, ...)
    local args = { ... }
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = dump(args[i]) end
    EVENTS[#EVENTS + 1] = name .. '>' .. tostring(target) .. ':' .. table.concat(parts, ';')
end
function TriggerEvent() end
HANDLERS = {}
function RegisterNetEvent(name, fn) if fn then HANDLERS[CURRENT_FILE .. '|' .. name] = fn end end
function AddEventHandler(name, fn) HANDLERS[CURRENT_FILE .. '|' .. name] = fn end
function RegisterCommand() end
function print() end

local vmt = {}
vmt.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, vmt) end
vmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vmt) end
vec3 = vector3
function GetEntityCoords(ped)
    native('GetEntityCoords')
    local c = COORDS[ped - 1000]
    return vector3(c and c[1] or 0.0, c and c[2] or 0.0, 30.0)
end

-- Player(src).state as the citizen scheduler builds it: a fresh proxy per Player() call, a native
-- read per key.
local playerMT = {
    __index = function(t, k)
        if k ~= 'state' then return nil end
        local src = rawget(t, '__data')
        local bag = setmetatable({}, { __index = function(_, key)
            native('GetStateBagValue')
            return (STATES[src] or {})[key]
        end })
        rawset(t, 'state', bag)
        return bag
    end,
}
function Player(src) C.playerProxy = C.playerProxy + 1 return setmetatable({ __data = src }, playerMT) end

EXPORTS = { ['v-phone'] = { GetNumber = function() return nil end } }
local proxyCache = {}
exports = setmetatable({}, {
    __index = function(_, res)
        local px = proxyCache[res]
        if px then return px end
        px = setmetatable({}, { __index = function(_, m)
            return function(_, ...)
                local impl = EXPORTS[res] and EXPORTS[res][m]
                if not impl then error('no such export ' .. res .. ':' .. m) end
                if res == 'v-phone' then C.selfExport = C.selfExport + 1 else C.cross = C.cross + 1 end
                return impl(...)
            end
        end })
        proxyCache[res] = px
        return px
    end,
    __call = function() end,
})
function funcref(fn) return function(...) C.cross = C.cross + 1 return fn(...) end end

json = { encode = function(v) return dump(v) end, decode = function() return nil end }
local function kvWrite(p)
    if type(p) == 'table' and p[3] ~= nil then
        C.kvWrites[#C.kvWrites + 1] = tostring(p[1]) .. '.' .. tostring(p[2]) .. '=' .. tostring(p[3])
    end
end
MySQL = {
    scalar = { await = function() return nil end },
    query = setmetatable({ await = function(_, p) kvWrite(p) return {} end },
                         { __call = function(_, _, p) kvWrite(p) end }),
    insert = { await = function() return 1 end },
    update = { await = function() return 1 end },
}

THREADS = {}
CURRENT_FILE = '?'
function CreateThread(fn) THREADS[#THREADS + 1] = { file = CURRENT_FILE, co = coroutine.create(fn) } end
Citizen = { CreateThread = CreateThread, Wait = function(ms) coroutine.yield(ms) end }
function Wait(ms) if coroutine.isyieldable() then coroutine.yield(ms) end end
function SetTimeout() end
Locales = { fr = {}, en = {} }

-- What server/main.lua keeps elsewhere in the file.
Calls, CallOf = {}, {}
-- The position of a configured row, built once (main.lua keeps this beside signalAt).
local rowVec = setmetatable({}, { __mode = 'k' })
function vecOf(row)
    local v = rowVec[row]
    if not v then
        v = vector3((row.x or 0) + 0.0, (row.y or 0) + 0.0, (row.z or 0) + 0.0)
        rowVec[row] = v
    end
    return v
end
function callPeers(c) return c.peers or {} end
function endCall(id, why) ENDED[#ENDED + 1] = tostring(id) .. ':' .. tostring(why) end
function prefsOf(p) p.GetMetadata('phone') return {} end
BALANCE_ASKED = {}
PAID = {}
'''

# Counts v-world reads through compat.lua's override without changing what they answer.
COUNT_WORLD = r'''
local compatGetResourceState = GetResourceState
GetResourceState = function(res)
    if res == 'v-world' then C.world = C.world + 1 end
    return compatGetResourceState(res)
end
'''

FIXED_MAP = r'''
Config.Framework = 'auto'
Config.DeadZones = {
    { id = 'tunnel', x = 1000.0, y = 0.0, z = 30.0, radius = 50.0, bars = 0 },
    { id = 'weak',   x = 2000.0, y = 0.0, z = 30.0, radius = 50.0, bars = 1 },
}
Config.Chargers = { { id = 'c1', x = 3000.0, y = 0.0, z = 30.0, radius = 5.0 } }
'''

FRAMEWORK_SETUP = {
    'qb': r'''
        STARTED['qb-core'] = true
        for i = 1, NPLAYERS do
            PLAYERS[i] = { PlayerData = { source = i, citizenid = 'QB' .. i,
                charinfo = { firstname = 'Test', lastname = 'Player' .. i },
                job = { name = 'police', label = 'Police', payment = 50, onduty = true,
                        grade = { level = 2, name = 'Sergeant', isboss = false } } } }
        end
        EXPORTS['qb-core'] = { GetCoreObject = function()
            return { Functions = { GetPlayer = funcref(function(src) return PLAYERS[src] end) } }
        end }
    ''',
    'qbx': r'''
        STARTED['qbx_core'] = true
        for i = 1, NPLAYERS do
            PLAYERS[i] = { PlayerData = { source = i, citizenid = 'QBX' .. i,
                charinfo = { firstname = 'Test', lastname = 'Player' .. i },
                job = { name = 'police', label = 'Police', payment = 50, onduty = true,
                        grade = { level = 2, name = 'Sergeant', isboss = false } } } }
        end
        EXPORTS['qbx_core'] = { GetPlayer = function(src) return PLAYERS[src] end,
                                GetCoreObject = function() error('qbx_core has no GetCoreObject') end }
    ''',
    'ox': r'''
        STARTED['ox_core'] = true
        for i = 1, NPLAYERS do
            PLAYERS[i] = { charId = i, firstName = 'Test', lastName = 'Player' .. i,
                           groups = { police = 2, garage = 1 } }
        end
        EXPORTS['ox_core'] = {
            GetPlayer = function(src) return PLAYERS[src] end,
            CallPlayer = function(src) local p = PLAYERS[src] return p and p.groups end,
        }
    ''',
    'esx': r'''
        STARTED['es_extended'] = true
        for i = 1, NPLAYERS do
            local job = { name = 'police', label = 'Police', grade = 2, grade_label = 'Sergeant',
                          grade_name = 'sergeant', grade_salary = 50 }
            PLAYERS[i] = { source = i, identifier = 'char1:esx' .. i,
                getJob = funcref(function() return job end),
                getName = funcref(function() return 'Test Player' .. i end) }
        end
        EXPORTS['es_extended'] = { getSharedObject = function()
            return { GetPlayerFromId = funcref(function(src) return PLAYERS[src] end) }
        end }
    ''',
    'standalone': '',
}


def main_chunk(base):
    m = source('server/main.lua', base)
    save = m.index("KvSetSync(player.citizenid, 'battery'")
    stop_start = m.rindex("AddEventHandler('onResourceStop', function(resource)", 0, save)
    stop_end = m.index('\nend)\n', save) + len('\nend)\n')
    return '\n'.join([
        'local Battery = {}\nSignal = {}\nlocal Charging = {}\nExternalCharge = {}\nExternalChargeUntil = {}\n',
        between(m, 'batteryOf = function(src)', '\nend\n'),
        between(m, 'function PhoneBattery(src)', '\nend\n'),
        between(m, 'local function hasBars(', '\nend\n'),
        between(m, 'local function pushPower(src)', "exports('PhoneUsable'", include_end=False),
        between(m, 'local function signalAt(', '-- One tick for everybody rather than per-player timers',
                include_end=False),
        between(m, 'local TICK = math.max(5', "exports('SetScreenOn'", include_end=False),
        m[stop_start:stop_end],
        "EXPORTS['v-phone'].GetBattery = function(src) return batteryOf(src) end",
        'BatteryTable, ChargingTable, ChargeRateTable, OpenTable = Battery, Charging, ChargeRate, Open',
        'STATE_EVERY = STATE_TICK DRAIN_EVERY = TICK',
        'HasBarsFn = hasBars',
    ])


def brawl_chunk(base):
    """server/brawl.lua's payPot, lifted by anchors, with a bank that records who was paid."""
    b = source('server/brawl.lua', base)
    return '\n'.join([
        "Bridge.AddMoney = function(src, amount) PAID[#PAID + 1] = tostring(src) .. '+' .. tostring(amount) return true end",
        between(b, 'local function payPot(m, winnerSide)', '\nend\n'),
        'PayPotFn = payPot',
    ])


def bank_chunk(base):
    """server/bank.lua's balance poll and the locals it reads, lifted by anchors."""
    b = source('server/bank.lua', base)
    start = b.index('CreateThread(function()\n    local every = pollEvery()')
    end = b.index('\nend)\n', start) + len('\nend)\n')
    return '\n'.join([
        between(b, 'local BANK = Config.Bank or {}', '\n'),
        between(b, 'local function num(v, d)', '\n'),
        between(b, 'local function enabled()', '\n'),
        between(b, 'local NOTIFY = BANK.notify or {}', '\n'),
        between(b, 'local function notifyOn()', '\n'),
        'local lastSeen, ownMoved = {}, {}',
        'local function moneyMoved() end',
        'Bridge.Banking = Bridge.Banking or {}',
        'Bridge.Banking.Balances = function(src) BALANCE_ASKED[#BALANCE_ASKED + 1] = src return { bank = 100 } end',
        between(b, 'local function pollEvery()', '\nend\n'),
        b[start:end],
    ])


def build(fw, base=False):
    lua = lupa.LuaRuntime(unpack_returned_tuples=False)
    g = lua.globals()
    lua.execute('NPLAYERS = %d' % PLAYERS)
    lua.execute(PRELUDE)

    def load(name, text):
        g.CURRENT_FILE = name
        lua.execute(text)

    load('bridge/shared/v.lua', source('bridge/shared/v.lua'))
    lua.execute("LOCALE_FALLBACK = 'fr'")
    compat = source('bridge/shared/compat.lua')
    load('compat', 'local realGetResourceState = GetResourceState\n'
                   'local function voiceResource() return nil end\n'
         + between(compat, 'local function stubIsLive(name)', '\nend\n')
         + between(compat, 'function GetResourceState(resource)', '\nend\n') + COUNT_WORLD)
    # compat.lua registers its v-world stub as a provider; GetDeadZones is the one signalAt reads.
    lua.execute("V.RegisterProvider('v-world', { GetDeadZones = function() "
                "return (Config and Config.DeadZones) or {} end })")
    load('config.lua', source('config.lua'))
    lua.execute(FIXED_MAP)
    lua.execute(FRAMEWORK_SETUP[fw])

    load('bridge/server/kv.lua', source('bridge/server/kv.lua'))
    fwtext = source('bridge/server/framework.lua', base)
    anchor = '    if not citizenid then return nil end\n    local p = {'
    assert fwtext.count(anchor) == 1, 'wrap() anchor moved'
    load('bridge/server/framework.lua', fwtext.replace(
        anchor, '    if not citizenid then return nil end\n    C.wraps = C.wraps + 1\n    local p = {'))
    lua.execute('Bridge.OxGroupLabels = function() return {} end')
    lua.execute(r'''
        for _, t in ipairs(THREADS) do
            if t.file == 'bridge/server/framework.lua' then
                while coroutine.status(t.co) ~= 'dead' do
                    local ok, err = coroutine.resume(t.co)
                    if not ok then error(err) end
                end
            end
        end
    ''')
    load('server/adminview.lua', source('server/adminview.lua', base))
    load('server/outage.lua', source('server/outage.lua'))
    load('server/charging.lua', source('server/charging.lua', base))
    load('main', main_chunk(base))
    load('bank', bank_chunk(base))
    load('brawl', brawl_chunk(base))
    lua.execute('resetC()')
    return lua


RUN = r'''function(file, index)
    local n = 0
    for _, t in ipairs(THREADS) do
        if t.file == file then
            n = n + 1
            if n == index then
                local ok, err = coroutine.resume(t.co)
                if not ok then return tostring(err) end
                return true
            end
        end
    end
    return 'no thread ' .. file .. '#' .. index
end'''


THREAD_OF = {'state': ('main', 1), 'drain': ('main', 2), 'bank': ('bank', 1),
             'sweep': ('server/adminview.lua', 1)}


class World:
    def __init__(self, fw, base=False, setup='', bank=False):
        self.lua = build(fw, base)
        self._run = self.lua.eval(RUN)
        if setup:
            self.lua.execute(setup)
        # Park the clocks on their first Wait, so every later resume is exactly one pass. The bank
        # poll returns at once where the framework announces money itself (qb, qbx, ESX), so it is
        # only parked where it runs.
        self.run('state')
        self.run('drain')
        if bank:
            self.run('bank')

    def run(self, which):
        res = self._run(*THREAD_OF[which])
        if res is not True:
            raise RuntimeError('%s tick raised: %s' % (which, res))

    def ex(self, code):
        self.lua.execute(code)

    def ev(self, expr):
        return self.lua.eval(expr)


# ----------------------------------------------------------------------------------------------
# 1. Existence: HasPlayer against the truthiness of GetPlayer
# ----------------------------------------------------------------------------------------------
EXISTENCE = r'''function(which, src, followSrc)
    local fns = which == 'get' and { Bridge.GetPlayer, Core.GetPlayer }
                               or { Bridge.HasPlayer, Core.HasPlayer }
    local out = {}
    for i, fn in ipairs(fns) do
        local ok, v = pcall(fn, src)
        out[i] = ok and (v and 'yes' or 'no') or 'raised'
    end
    -- What the call left behind: who the staff member's NEXT real call is answered as.
    if followSrc then
        local ok, p = pcall(Core.GetPlayer, followSrc)
        out[3] = ok and (p and tostring(p.citizenid) or 'nil') or 'raised'
    end
    return table.concat(out, ' ')
end'''

ADMIN_OPEN = 'assert(AdminViewOpen(2, 1))'


def existence_cases(fw):
    cases = [
        ('a loaded player', '', '1', None, 'yes yes'),
        ('an absent source', 'PLAYERS[999] = nil', '999', None,
         'yes yes' if fw == 'standalone' else 'no no'),
        ('a string source', '', '"7"', None, 'yes yes'),
        ('a non-numeric source', '', '"abc"', None, 'no no'),
        ('nil', '', 'nil', None, 'no no'),
    ]
    if fw in ('qb', 'qbx'):
        cases += [('a nil citizenid', 'PLAYERS[1].PlayerData.citizenid = nil', '1', None, 'no no'),
                  ('a false citizenid', 'PLAYERS[1].PlayerData.citizenid = false', '1', None, 'no no')]
    if fw == 'ox':
        cases += [('ox without charId (character selection)', 'PLAYERS[1].charId = nil', '1', None, 'no no'),
                  ('ox with charId false', 'PLAYERS[1].charId = false', '1', None, 'no no')]
    if fw == 'esx':
        cases += [('esx without identifier', 'PLAYERS[1].identifier = nil', '1', None, 'no no'),
                  ('esx with identifier false', 'PLAYERS[1].identifier = false', '1', None, 'no no')]
    cases += [
        ('staff member with an admin view open', ADMIN_OPEN, '2', 2, ('yes yes T', 'yes yes T')),
        # Once the session is over a request and a clock answer differently, on purpose. The request
        # that finds it over is refused and spends the refusal, so the next request is the staff
        # member's own. The clock answers for the real character and leaves the refusal for the next
        # request, because the handset may still be showing the target.
        ('staff member whose admin view ran out', ADMIN_OPEN + ' CLOCK = CLOCK + 600', '2', 2,
         ('yes no S', 'yes yes nil')),
        ('staff member holding a target who left', ADMIN_OPEN + ' GONE[1] = true PLAYERS[1] = nil',
         '2', 2, ('yes no S', 'yes yes nil')),
    ]
    return cases


def test_existence():
    print('existence: HasPlayer answers what GetPlayer does')
    for fw in FRAMEWORKS:
        cids = World(fw).ev('function() return tostring(Bridge.GetPlayer(1).citizenid) .. " " '
                            '.. tostring(Bridge.GetPlayer(2).citizenid) end')().split(' ')
        for name, mutate, src, follow, expected in existence_cases(fw):
            answers = []
            for which in ('get', 'has'):
                w = World(fw)
                w.ex(mutate)
                answers.append(w.ev(EXISTENCE)(which, w.ev(src), follow))
            get, has = answers
            if isinstance(expected, tuple):
                want = [e.replace('T', cids[0]).replace('S', cids[1]) for e in expected]
                check(get == want[0], '%-10s %s: a request answers %s' % (fw, name, want[0]), 'got ' + get)
                check(has == want[1], '%-10s %s: a clock answers %s' % (fw, name, want[1]), 'got ' + has)
                continue
            g2, h2 = get.split(' '), has.split(' ')
            check(g2[0] == h2[0] and g2[1] == h2[1] and g2[2:] == h2[2:],
                  '%-10s %s: Bridge and Core agree' % (fw, name), 'get %s | has %s' % (get, has))
            check(' '.join(g2[:2]) == expected, '%-10s %s: answers %s' % (fw, name, expected),
                  'got ' + ' '.join(g2[:2]))


# ----------------------------------------------------------------------------------------------
# 2. Cost, per framework, before and after
# ----------------------------------------------------------------------------------------------
SCENARIOS = [
    ('on foot', ''),
    ('in a vehicle', 'for i = 1, NPLAYERS do PED_IN_VEHICLE[i] = true end'),
    ('at home', 'for i = 1, NPLAYERS do STATES[i] = { phoneAtHome = true } end'),
    # An assumed mix, not data: a quarter driving, a tenth at home, the rest on foot.
    ('mix 25/10/65', 'for i = 1, NPLAYERS do if i % 4 == 0 then PED_IN_VEHICLE[i] = true '
                     'elseif i % 10 == 1 then STATES[i] = { phoneAtHome = true } end end'),
]

COUNTS = r'''function()
    local natives = 0
    for _, n in pairs(C.natives) do natives = natives + n end
    return dump({ wraps = C.wraps, convar = C.convar, cross = C.cross, selfExport = C.selfExport,
                  proxies = C.playerProxy, natives = natives, world = C.world })
end'''


def counts(w):
    text = w.ev(COUNTS)()[1:-1]
    return {k: int(v) for k, v in (kv.split('=') for kv in text.split(','))}


def measure(fw, base, which, scenario):
    w = World(fw, base, scenario)
    w.run(which)                   # first sight: charge rates measured, kv cache filled
    w.ex('resetC()')
    w.run(which)
    per_min = 60 // int(w.ev('STATE_EVERY' if which == 'state' else 'DRAIN_EVERY'))
    return counts(w), per_min


def test_cost():
    print('cost: one pass of the state tick, %d players' % PLAYERS)
    rows = []
    for fw in FRAMEWORKS:
        for which, scenarios in (('state', SCENARIOS), ('drain', SCENARIOS[:1])):
            for sc_name, sc in scenarios:
                before, k = measure(fw, True, which, sc)
                after, _ = measure(fw, False, which, sc)
                rows.append((fw, which, sc_name, k, before, after))
                if which == 'state':
                    check(after['wraps'] == 0 and after['convar'] == 0,
                          '%-10s %-13s state tick builds no player wrapper' % (fw, sc_name),
                          'wraps %d convar %d' % (after['wraps'], after['convar']))
                    check(after['world'] <= 1,
                          '%-10s %-13s v-world state read at most once a pass' % (fw, sc_name),
                          'read %d times (before: %d)' % (after['world'], before['world']))
                    check(after['selfExport'] == 0,
                          '%-10s %-13s no export call back into this resource' % (fw, sc_name),
                          'calls %d (before: %d)' % (after['selfExport'], before['selfExport']))
    print('')
    print('per minute, %d players, shipped intervals (before -> after)' % PLAYERS)
    print('%-10s %-5s %-13s %15s %15s %15s %15s %13s %15s %15s' % (
        'framework', 'tick', 'scenario', 'wrappers', 'closures', 'GetConvar', 'cross-resource',
        'self-export', 'Player()', 'natives'))
    for fw, which, sc_name, k, b, a in rows:
        def pair(key, mult=1):
            return '%6d -> %6d' % (b[key] * k * mult, a[key] * k * mult)
        print('%-10s %-5s %-13s %15s %15s %15s %15s %13s %15s %15s' % (
            fw, which, sc_name, pair('wraps'), pair('wraps', 3), pair('convar'), pair('cross'),
            '%4d -> %4d' % (b['selfExport'] * k, a['selfExport'] * k), pair('proxies'),
            pair('natives')))
    print('')


# ----------------------------------------------------------------------------------------------
# 3. Behaviour: the state tick against BASE on one moving fixture
# ----------------------------------------------------------------------------------------------
def mixed_fixture(fw):
    # Driving, at home, on a free charger, in a tunnel, at one bar, on a call in a tunnel, with an
    # external charge lease, flat phones that plug themselves in, and sources GetPlayers lists
    # but no framework knows.
    lines = [r'''
        for i = 1, NPLAYERS do
            BatteryTable[i] = (i % 6 == 0) and 0 or (40 + i % 50)
            if i % 11 == 5 then PLAYERS[i] = nil end
        end
        CallOf[9], Calls['c9'] = 'c9', { state = 'active', peers = { 10 } }
        CallOf[22], Calls['c22'] = 'c22', { state = 'active', peers = { 23, 24 } }
        ExternalCharge[30], ExternalChargeUntil[30] = 0.5, CLOCK + 5
        ExternalCharge[31], ExternalChargeUntil[31] = 2.0, CLOCK + 60
        function movePass(k)
            for i = 1, NPLAYERS do
                PED_IN_VEHICLE[i] = ((i + k) % 4 == 0) or nil
                STATES[i] = ((i + 2 * k) % 10 == 1) and { phoneAtHome = true } or nil
                local spot = (i + k) % 5
                COORDS[i] = spot == 1 and { 1000.0, 10.0 } or spot == 2 and { 2000.0, 0.0 }
                            or spot == 3 and { 3000.0, 1.0 } or { 500.0 + i, 0.0 }
            end
            COORDS[9], COORDS[22] = { 1000.0, 0.0 }, { 2000.0, 0.0 }
            if k == 3 then COORDS[9] = { 0.0, 0.0 } end
        end
    ''']
    if fw in ('qb', 'qbx'):
        lines.append('PLAYERS[13].PlayerData.citizenid = nil')
    if fw == 'esx':
        lines.append('PLAYERS[13].identifier = nil')
    return '\n'.join(lines)


PASS = r'''function()
    return dump({ signal = Signal, charging = ChargingTable, rate = ChargeRateTable,
                  reason = ChargeReason, source = ChargeSource, events = EVENTS, ended = ENDED,
                  asked = PED_ASKED })
end'''


def test_same_as_base():
    print('behaviour: the state tick against %s, same fixture, six moving passes' % BASE)
    for fw in FRAMEWORKS:
        worlds = [World(fw, base, mixed_fixture(fw)) for base in (True, False)]
        same, first_diff = True, ''
        for k in range(6):
            snaps = []
            for w in worlds:
                w.ex('movePass(%d) CLOCK = CLOCK + 2 resetC()' % k)
                w.run('state')
                snaps.append(w.ev(PASS)())
            if snaps[0] != snaps[1] and same:
                same = False
                a, b = snaps
                i = next(j for j in range(min(len(a), len(b))) if a[j] != b[j])
                first_diff = 'pass %d: base ...%s | now ...%s' % (k, a[max(0, i - 60):i + 60],
                                                                  b[max(0, i - 60):i + 60])
        ticked = worlds[1].ev('function() return #PED_ASKED end')()
        check(same, '%-10s players ticked, signal, charge and pushes identical' % fw,
              first_diff or 'last pass ticked %d sources' % ticked)


# ----------------------------------------------------------------------------------------------
# 4. The three defects
# ----------------------------------------------------------------------------------------------
NEXT_CALL = 'function() local p = Core.GetPlayer(2) return p and tostring(p.citizenid) or "nil" end'

EXPIRED_AT = r'''function(opened)
    for _, e in ipairs(EVENTS) do
        if e == 'v-phone:client:adminView>2:false' then return CLOCK - opened end
    end
    return -1
end'''


ON_A_CALL = ("CallOf[2], Calls['c2'] = 'c2', { state = 'active', peers = { 3 } } "
             "CallOf[1], Calls['c1'] = 'c1', { state = 'active', peers = { 4 } }")


def run_session(fw, base, seconds, touch_at=None, request='Core.GetPlayer(2)', bank=False, call=False):
    """Staff member 2 holds player 1's phone and does nothing while the clocks run: the battery
    state and drain ticks always, the bank balance poll when `bank`, and with the staff member and
    the target both on a call when `call`. `request` is made once at `touch_at`, as a callback from
    the held phone would. Returns the second the session was seen to run out (or -1), what is held
    at the end, who the staff member's next call is answered as, and how many calls were ended."""
    w = World(fw, base, ON_A_CALL if call else '', bank=bank)
    w.ex(ADMIN_OPEN + ' OPENED = CLOCK')
    expired_at = -1
    for t in range(2, seconds + 1, 2):
        w.ex('CLOCK = CLOCK + 2 EVENTS = {}')
        if touch_at is not None and t == touch_at:
            w.ex(request)
        w.run('state')
        if t % 20 == 0:
            w.run('drain')
        if bank and t % 30 == 0:
            w.run('bank')
        if expired_at < 0:
            expired_at = w.ev(EXPIRED_AT)(w.ev('OPENED'))
    held = w.ev('function() return AdminViewTarget(2) or "nothing" end')()
    after = w.ev(NEXT_CALL)() + ' then ' + w.ev(NEXT_CALL)()
    ended = int(w.ev('function() return #ENDED end')())
    if bank:
        check(int(w.ev('function() return #BALANCE_ASKED end')()) > 0,
              '%-10s the bank poll really ran during the session' % fw)
    return expired_at, held, after, ended


def test_bug_session():
    print('bug: an admin view nobody touches runs out')
    at, held, _, _ = run_session('qb', True, 700)
    check(at == -1 and held == 'QB1', 'baseline reproduces: still held after 700 s of ticks',
          'expired at %s, holding %s' % (at, held))
    at, held, after, _ = run_session('qb', False, 700)
    check(at == 600, 'runs out at viewSeconds (600 s) with no staff activity', 'expired at %s s' % at)
    check(held == 'nothing' and after == 'nil then QB2',
          'a request sent after an unnoticed expiry is refused, and only the next is their own phone',
          'holding %s, two requests answered as %s' % (held, after))
    at, _, _, _ = run_session('qb', False, 960, touch_at=300)
    check(at == 900, 'a real use at 300 s still extends the session to 900 s', 'expired at %s s' % at)


PAIR = r'''function(first)
    local ok, v = pcall(load('return ' .. first))
    local a = ok and (type(v) == 'table' and tostring(v.citizenid) or tostring(v)) or 'raised'
    local p = Core.GetPlayer(2)
    return a .. ' then ' .. (p and tostring(p.citizenid) or 'nil')
end'''



def test_bug_clocks():
    print('bug: no clock keeps an idle admin view alive')
    for fw in ('ox', 'standalone'):
        at, _, _, _ = run_session(fw, False, 700, bank=True)
        check(at == 600, '%-10s bank balance poll running: runs out at 600 s' % fw, 'expired at %s s' % at)
        at, _, _, ended = run_session(fw, False, 700, call=True)
        check(at == 600 and ended == 0, '%-10s staff member and target on calls: runs out at 600 s' % fw,
              'expired at %s s, calls ended %d' % (at, ended))
        at, _, _, _ = run_session(fw, False, 960, touch_at=300, request='PhoneActingSource(2)', bank=True)
        check(at == 900, '%-10s a money request through PhoneActingSource at 300 s still extends to 900 s' % fw,
              'expired at %s s' % at)
        at, _, _, ended = run_session(fw, False, 960, touch_at=300, request='HasBarsFn(2)', call=True)
        check(at == 900 and ended == 0,
              '%-10s a request through hasBars at 300 s still extends to 900 s' % fw, 'expired at %s s' % at)
    # What each form answers, then who the next request is answered as. While the session is open
    # the clock forms answer what the requests do. Once it is over a clock answers for the real
    # character and leaves the refusal for the next request instead of spending it.
    want = {
        ('open', 'Core.GetPlayer(2)'): 'QB1 then QB1', ('open', 'Core.PeekPlayer(2)'): 'QB1 then QB1',
        ('ran out', 'Core.GetPlayer(2)'): 'nil then QB2', ('ran out', 'Core.PeekPlayer(2)'): 'QB2 then nil',
        ('target left', 'Core.GetPlayer(2)'): 'nil then QB2',
        ('target left', 'Core.PeekPlayer(2)'): 'QB2 then nil',
        ('open', 'PhoneActingSource(2)'): '1 then QB1', ('open', 'PhoneActingSource(2, true)'): '1 then QB1',
        ('ran out', 'PhoneActingSource(2)'): '2 then nil',
        ('ran out', 'PhoneActingSource(2, true)'): '2 then nil',
        ('target left', 'PhoneActingSource(2)'): '2 then QB2',
        ('target left', 'PhoneActingSource(2, true)'): '2 then nil',
    }
    for name, mutate in (('open', ADMIN_OPEN), ('ran out', ADMIN_OPEN + ' CLOCK = CLOCK + 600'),
                         ('target left', ADMIN_OPEN + ' GONE[1] = true PLAYERS[1] = nil')):
        for expr in ('Core.GetPlayer(2)', 'Core.PeekPlayer(2)', 'PhoneActingSource(2)',
                     'PhoneActingSource(2, true)'):
            w = World('qb', False, mutate)
            got = w.ev(PAIR)(expr)
            check(got == want[(name, expr)], 'session %s: %s answers %s' % (name, expr, want[(name, expr)]),
                  'got ' + got)

    pay = "PayPotFn({ stake = 10, a = { src = 2, cid = 'staff' }, b = { src = 5, cid = 'other' } }, 'a')"
    for fw in ('qb', 'ox'):
        at, _, _, _ = run_session(fw, False, 700, touch_at=300, request=pay)
        check(at == 600, '%-10s a FruitBrawl payout at 300 s, from the round clock, does not extend it' % fw,
              'expired at %s s' % at)
    w = World('qb', False, ADMIN_OPEN)
    w.ex(pay)
    paid = w.ev('function() return table.concat(PAID, " ") end')()
    check(paid == '1+20', 'the payout still goes to the account of the phone being held', paid)


def test_bug_reused_id():
    print('bug: a dropped staff member leaves no refusal for the next player on that server id')

    def reused(base):
        w = World('qb', base, ADMIN_OPEN)
        # A money request finds the session over: the staff member's next call is to be refused.
        w.ex('CLOCK = CLOCK + 600 PhoneActingSource(2)')
        w.ex("source = 2 HANDLERS['server/adminview.lua|playerDropped']()")
        w.ex("PLAYERS[2].PlayerData.citizenid = 'NEWCOMER'")
        return w.ev(NEXT_CALL)()

    got = reused(True)
    check(got == 'nil', 'baseline reproduces: the next player on that id is refused once', 'answered ' + got)
    got = reused(False)
    check(got == 'NEWCOMER', 'the next player on that id gets their own phone', 'answered ' + got)
    w = World('qb', False, ADMIN_OPEN)
    w.ex('CLOCK = CLOCK + 600 PhoneActingSource(2)')
    first, second = w.ev(NEXT_CALL)(), w.ev(NEXT_CALL)()
    check(first == 'nil' and second == 'QB2',
          'without a drop the staff member is still refused once, then gets their own phone',
          '%s then %s' % (first, second))


def test_bug_teardown():
    print('bug: a session that ends on its own is refused once, and the phone closes')

    def requests(w):
        return w.ev(NEXT_CALL)() + ' then ' + w.ev(NEXT_CALL)()

    # The 15-second sweep, with no other clock running.
    w = World('qb', False, ADMIN_OPEN)
    w.run('sweep')
    w.ex('CLOCK = CLOCK + 615 EVENTS = {}')
    w.run('sweep')
    told = 'v-phone:client:adminView>2:false' in list(w.ev('EVENTS').values())
    got = requests(w)
    check(told and got == 'nil then QB2', 'run out by the sweep: phone told, first request refused',
          'told %s, requests %s' % (told, got))

    # The target disconnects.
    w = World('qb', False, ADMIN_OPEN)
    w.ex("EVENTS = {} source = 1 HANDLERS['server/adminview.lua|playerDropped']()")
    told = 'v-phone:client:adminView>2:false' in list(w.ev('EVENTS').values())
    got = requests(w)
    check(told and got == 'nil then QB2', 'target disconnects: phone told, first request refused',
          'told %s, requests %s' % (told, got))

    # The phone acknowledges its teardown: the reopen is not the request that gets refused.
    ack = "source = 2 HANDLERS['server/adminview.lua|v-phone:server:adminViewClosed']()"
    w = World('qb', False, ADMIN_OPEN)
    w.ex('CLOCK = CLOCK + 600 Core.HasPlayer(2)')
    w.ex(ack)
    got = w.ev(NEXT_CALL)()
    check(got == 'QB2', 'after the phone reports it closed, the next open is their own phone', got)

    # A request already on its way when the phone closed arrives before the acknowledgement.
    w = World('qb', False, ADMIN_OPEN)
    w.ex('CLOCK = CLOCK + 600 Core.HasPlayer(2)')
    first = w.ev(NEXT_CALL)()
    w.ex(ack)
    second = w.ev(NEXT_CALL)()
    check(first == 'nil' and second == 'QB2', 'a request in flight before the close is still refused',
          '%s then %s' % (first, second))

    # An acknowledgement while a session is open changes nothing.
    w = World('qb', False, ADMIN_OPEN)
    w.ex(ack)
    got = w.ev(NEXT_CALL)()
    check(got == 'QB1', 'an acknowledgement during an open session is ignored', got)


CLIENT_PRELUDE = r'''
Config = { Admin = {} }
SENT, HANDLERS = {}, {}
function RegisterNetEvent(name, fn) if fn then HANDLERS[name] = fn end end
function AddEventHandler(name, fn) HANDLERS[name] = fn end
function TriggerEvent(name) SENT[#SENT + 1] = 'local:' .. name end
function TriggerServerEvent(name) SENT[#SENT + 1] = 'server:' .. name end
function GetResourceState() return 'missing' end
function CreateThread() end
function L(k) return k end
V = { Notify = function() end }
exports = setmetatable({}, { __index = function() return setmetatable({}, { __index = function()
    return function() end end }) end })
'''


def test_client_teardown():
    print('client: the staff phone closes when a session ends')
    lua = lupa.LuaRuntime(unpack_returned_tuples=False)
    lua.execute(CLIENT_PRELUDE)
    lua.execute(source('client/admin.lua'))
    sent = lambda: ' '.join(lua.eval('SENT').values())
    lua.execute("HANDLERS['v-phone:client:adminView']({ name = 'Test Player1', seconds = 600 })")
    check(sent() == '', 'a session starting closes nothing', sent() or 'nothing sent')
    lua.execute("HANDLERS['v-phone:client:adminView'](false)")
    check(sent() == 'local:v-phone:client:close server:v-phone:server:adminViewClosed',
          'a session ending closes the phone, then tells the server', sent())
    check("RegisterNetEvent('v-phone:client:close'" in source('client/main.lua'),
          'client/main.lua still answers v-phone:client:close')
    check("RegisterNetEvent('v-phone:server:adminViewClosed'" in source('server/adminview.lua'),
          'server/adminview.lua listens for the acknowledgement')


KV = r'''function()
    return table.concat(C.kvWrites, ' ')
end'''


def staff_drain(fw, base):
    w = World(fw, base, ADMIN_OPEN + ' BatteryTable[1] = 88.0 BatteryTable[2] = 37.0')
    w.ex('CLOCK = CLOCK + 20 resetC()')
    w.run('drain')
    drain = w.ev(KV)().split(' ')
    w.ex('resetC()')
    w.ev("function() HANDLERS['main|onResourceStop']('v-phone') end")()
    stop = w.ev(KV)().split(' ')
    return drain, stop


def test_bug_staff_battery():
    print("bug: a staff member's battery lands in their own row during an admin view")
    # One drain pass takes the target from 88 to 87.99 and the staff member from 37 to 36.99, so
    # both saves write 87 and 36. The shutdown save runs after that pass.
    def pair(writes):
        return [x for x in writes if x.startswith(('QB1.', 'QB2.'))]

    drain, stop = staff_drain('qb', True)
    check('QB1.battery=36' in drain, "baseline reproduces (drain tick): the target's row takes the staff level",
          ' '.join(pair(drain)))
    check('QB1.battery=36' in stop, "baseline reproduces (shutdown save): the target's row takes the staff level",
          ' '.join(pair(stop)))
    drain, stop = staff_drain('qb', False)
    for label, writes in (('drain tick', drain), ('shutdown save', stop)):
        target = [x for x in writes if x.startswith('QB1.')]
        staff = [x for x in writes if x.startswith('QB2.')]
        check(target == ['QB1.battery=87'], "%s: the target's row holds only the target's level" % label,
              ' '.join(pair(writes)))
        check(staff == ['QB2.battery=36'], "%s: the staff member's own row is written" % label,
              ' '.join(pair(writes)))


def selection_drain(base):
    w = World('ox', base, 'PLAYERS[1].charId = nil PLAYERS[2].charId = nil '
                          'BatteryTable[1] = 40.0 BatteryTable[2] = 70.0')
    w.ex('CLOCK = CLOCK + 20 resetC()')
    w.run('drain')
    first = [x for x in w.ev(KV)().split(' ') if not x.startswith(tuple('%d.' % i for i in range(3, 65)))]
    w.ex('PLAYERS[1].charId = 11 PLAYERS[2].charId = 12 CLOCK = CLOCK + 20 resetC()')
    w.run('drain')
    second = [x for x in w.ev(KV)().split(' ') if x.startswith(('11.', '12.'))]
    return first, second


def unhydrated_drain(base):
    """A player the phone never loaded a battery for, and one drain pass."""
    w = World('qb', base)                    # no BatteryTable entry: nothing was ever read
    w.ex('CLOCK = CLOCK + 20 resetC()')
    w.run('drain')
    return [x for x in w.ev(KV)().split(' ') if x.startswith('QB1.')]


def test_bug_unhydrated_battery():
    print('bug: a battery that was never loaded is written to the row anyway')
    # `batteryRaw` answers 100 for a player whose row has not been read, which is right for
    # drawing a phone and wrong for saving one. The tick persists what it computes, so a player
    # it reached before their load wrote a full battery over whatever they really had - which is
    # a battery that goes back up after a restart, for some players and not others.
    before = unhydrated_drain(True)
    check(before == ['QB1.battery=99'], 'baseline reproduces: a full battery is written over the saved one',
          ' '.join(before) or 'no writes')
    after = unhydrated_drain(False)
    check(after == [], 'nothing is written for a player whose battery was never loaded',
          ' '.join(after) or 'no writes')


def test_bug_ox_selection():
    print('bug: ox_core players on the character selection screen')
    first, _ = selection_drain(True)
    check(first.count('nil.battery=39') + first.count('nil.battery=69') == 2,
          'baseline reproduces: both write the one row "nil"', ' '.join(first))
    first, second = selection_drain(False)
    keys = [x.split('.')[0] for x in first]
    check(len(keys) == len(set(keys)) and 'nil' not in keys,
          'two players in character selection never share a battery key', ' '.join(first) or 'no writes')
    check(sorted(second) == ['11.battery=39', '12.battery=69'],
          'once they pick characters, each battery lands in its own row', ' '.join(second))
    w = World('ox')
    w.ex('PLAYERS[1].charId = nil PLAYERS[2].charId = nil')
    check(w.ev('function() return Bridge.GetPlayerByCitizenId("nil") == nil end')(),
          'nobody is reachable under the citizen id "nil"')


def main():
    version = getattr(lupa.LuaRuntime(), 'lua_version', None)
    check(version == (5, 4), 'running under Lua 5.4, as FiveM does', 'lua_version %s' % (version,))
    test_existence()
    print('')
    test_cost()
    test_same_as_base()
    print('')
    test_bug_session()
    print('')
    test_bug_clocks()
    print('')
    test_bug_teardown()
    print('')
    test_client_teardown()
    print('')
    test_bug_reused_id()
    print('')
    test_bug_staff_battery()
    test_bug_unhydrated_battery()
    print('')
    test_bug_ox_selection()
    print('')
    if fails:
        print('%d of %d checks FAILED' % (len(fails), checks[0]))
        for f in fails:
            print('  - ' + f)
        return 1
    print('all %d checks passed' % checks[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
