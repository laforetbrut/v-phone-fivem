-- v-phone | server/brawl.lua
--
-- **FruitBrawl: two players from the server, one duel.**
--
-- ══════════════════════════════════════════════════════════════
-- Why it is not a real-time fighting game
-- ══════════════════════════════════════════════════════════════
-- The obvious build is a side-on fighter with two characters moving frame by frame. It is the
-- wrong build for this medium and it would feel bad no matter how well it was written: every
-- input travels NUI -> client -> server -> client -> NUI, and a game whose whole skill is
-- reacting inside a tenth of a second cannot be played across four hops. What arrives is a
-- fighting game where the punch lands a beat after you threw it, which is not a hard game, it
-- is a broken one.
--
-- So this is a duel of SIMULTANEOUS CHOICES. Both fighters pick in secret, the server reveals
-- and resolves, and the round is scored. Latency stops mattering entirely - a round is a
-- decision, not a frame - and the skill moves to where it can actually live: reading the
-- person on the other end, watching their stamina, and knowing what they cannot afford.
--
-- **The server is the only thing that simulates anything.** The page picks a word and is told
-- what happened. There is no position, no hitbox and no timer on the client that matters, so
-- there is nothing a modified page could lie about beyond which of four buttons it pressed -
-- and pressing a button is what it is for.
--
-- ══════════════════════════════════════════════════════════════
-- The four actions
-- ══════════════════════════════════════════════════════════════
-- Plain rock-paper-scissors is a coin toss between strangers. What makes this a game is that
-- the actions cost STAMINA, so what somebody can do next is partly visible, and the strongest
-- action is the one you can least afford to keep throwing.
--
--   JAB     1 stamina   fast, small. Beats Grab.
--   HEAVY   3 stamina   slow, big.   Beats Jab, and goes through Block for chip damage.
--   BLOCK   regains 2   free.        Beats Jab. Loses badly to Grab.
--   GRAB    2 stamina   Beats Block and Heavy - it punishes commitment.
--
-- Which makes the loop: you cannot Heavy for ever, so you must Block to recover, and Block is
-- what Grab is for. Somebody sitting on 1 stamina can only Jab or Block, and their opponent
-- can see that, which is the whole mind game.

local CFG = Config.Brawl or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

local function maxHp() return math.max(20, math.floor(num(CFG.health, 100))) end
local function maxStam() return math.max(3, math.floor(num(CFG.stamina, 6))) end
local function startStam() return math.max(1, math.min(maxStam(), math.floor(num(CFG.startStamina, 4)))) end
local function roundSeconds() return math.max(4, math.floor(num(CFG.roundSeconds, 10))) end
local function inviteSeconds() return math.max(10, math.floor(num(CFG.inviteSeconds, 45))) end
local function stakesOn() return CFG.stakes ~= false end
local function maxStake() return math.max(0, math.floor(num(CFG.maxStake, 100))) end

--- A stake the operator allows, or nothing.
---
--- Zero is a real answer and the default: most fights are not for money, and a game that made
--- you name a number before you could throw a punch would be a betting app with a fight
--- attached rather than the other way round.
local function cleanStake(v)
    if not stakesOn() then return 0 end
    local n = math.floor(num(v, 0))
    if n <= 0 then return 0 end
    return math.min(n, maxStake())
end

local COST = { jab = 1, heavy = 3, block = 0, grab = 2 }
local BLOCK_REGAIN = 2

--- What one exchange does. Read as `OUTCOME[mine][theirs]`, giving the damage TAKEN by the
--- player on the left and a word for what happened, which is what the page animates.
---
--- Written out in full rather than derived from a "beats" table, on purpose: a fighting game's
--- balance is a set of specific numbers, and a formula that produced them would be one more
--- thing to reverse-engineer every time one of them needs changing.
local OUTCOME = {
    jab = {
        jab   = { take = 4,  tag = 'clash' },
        heavy = { take = 14, tag = 'lose' },
        block = { take = 0,  tag = 'blocked' },
        grab  = { take = 0,  tag = 'win' },
    },
    heavy = {
        jab   = { take = 0,  tag = 'win' },
        heavy = { take = 10, tag = 'clash' },
        block = { take = 0,  tag = 'chip' },
        grab  = { take = 16, tag = 'lose' },
    },
    block = {
        jab   = { take = 0,  tag = 'win' },
        heavy = { take = 6,  tag = 'chipped' },
        block = { take = 0,  tag = 'stare' },
        grab  = { take = 12, tag = 'lose' },
    },
    grab = {
        jab   = { take = 8,  tag = 'lose' },
        heavy = { take = 0,  tag = 'win' },
        block = { take = 0,  tag = 'win' },
        grab  = { take = 5,  tag = 'clash' },
    },
}

-- ══════════════════════════════════════════════════════════════
-- The sparring partner
-- ══════════════════════════════════════════════════════════════
-- Somebody has to be online to fight, and on a quiet server that is nobody. So there is a bot -
-- and it is written to be BEATABLE BY READING, not by luck, because that is the same skill the
-- real game rewards and the whole reason to practise against it.
--
-- It counts what you have thrown and answers the counter to whatever you throw most. That is
-- deliberately exploitable: change your habits and it follows you a beat late, which is exactly
-- what a person does. `noise` is how often it ignores its own read and picks freely, and it is
-- the only thing the difficulty changes.
--
-- **A fight against it is never recorded.** A leaderboard filled by beating a machine is not a
-- leaderboard, and the moment one counted, every record on the server would mean nothing.

local BOT_NAMES = {
    easy = 'Sparring Dummy',
    normal = 'Club Fighter',
    hard = 'The Landlord',
}
local BOT_NOISE = { easy = 0.62, normal = 0.34, hard = 0.14 }

--- What answers what. Two options for some, so it is not a lookup table somebody memorises.
local COUNTER = {
    jab   = { 'heavy', 'block' },
    heavy = { 'grab' },
    block = { 'grab' },
    grab  = { 'jab' },
}

local function pickFrom(list, stamina)
    local ok = {}
    for _, a in ipairs(list) do
        if stamina >= COST[a] then ok[#ok + 1] = a end
    end
    if #ok == 0 then return nil end
    return ok[math.random(#ok)]
end

--- The bot's choice for this round.
local function botPick(bot, me)
    -- Out of breath: guard. Not a strategy, a fact - it is the only thing it can afford, and
    -- a bot that threw anyway would be a bot that cannot lose stamina.
    if me.stamina < 1 then return 'block' end

    -- Low and it wants the two back, most of the time. Enough of the time that a player who
    -- notices can punish it with a Grab, which is the read the game is built around.
    if me.stamina <= 1 and math.random() < 0.75 then return 'block' end

    if math.random() < (BOT_NOISE[bot.level] or 0.34) then
        local all = { 'jab', 'heavy', 'block', 'grab' }
        return pickFrom(all, me.stamina) or 'block'
    end

    -- What they throw most, and the answer to it.
    local best, bestN = nil, -1
    for action, n in pairs(bot.seen) do
        if n > bestN then best, bestN = action, n end
    end
    if not best then
        -- Nothing to go on yet: open with something cheap rather than committing.
        return pickFrom({ 'jab', 'block' }, me.stamina) or 'block'
    end

    return pickFrom(COUNTER[best] or { 'jab' }, me.stamina)
        or pickFrom({ 'jab', 'block' }, me.stamina)
        or 'block'
end

-- ══════════════════════════════════════════════════════════════
-- Schema
-- ══════════════════════════════════════════════════════════════
-- Only the RECORD is stored. A match is minutes long and lives in memory: writing every round
-- to a table would be a write per second per duel to keep something nobody will ever read.

CreateThread(function()
    if not enabled() then return end
    Wait(800)
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_brawl_stats` (
        `citizenid` VARCHAR(16)  NOT NULL,
        `nick`      VARCHAR(16)  NOT NULL DEFAULT '',
        `wins`      INT UNSIGNED NOT NULL DEFAULT 0,
        `losses`    INT UNSIGNED NOT NULL DEFAULT 0,
        `streak`    INT UNSIGNED NOT NULL DEFAULT 0,
        `best`      INT UNSIGNED NOT NULL DEFAULT 0,
        `at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`citizenid`),
        KEY `board` (`wins`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

-- ══════════════════════════════════════════════════════════════
-- State
-- ══════════════════════════════════════════════════════════════

local Matches = {}      -- id -> match
local ByCid = {}        -- citizenid -> match id, so one person is in one fight
local Invites = {}      -- to citizenid -> { from, fromName, at }
local Queue = {}        -- citizenids waiting for anybody
local nextId = 0

local function nameOf(cid)
    local ok, name = pcall(function()
        return Bridge.CharacterName and Bridge.CharacterName(cid) or nil
    end)
    if ok and type(name) == 'string' and name ~= '' then return name end
    return '?'
end

local function statsOf(cid)
    local row = MySQL.single.await(
        'SELECT wins, losses, streak, best FROM vphone_brawl_stats WHERE citizenid = ?', { cid })
    return {
        wins = math.floor(num(row and row.wins, 0)),
        losses = math.floor(num(row and row.losses, 0)),
        streak = math.floor(num(row and row.streak, 0)),
        best = math.floor(num(row and row.best, 0)),
    }
end

--- Tell one side's phone what the fight looks like FROM THEIR SIDE.
---
--- The opponent's pick for the round in progress is never in here. That is the entire game: a
--- page that was sent both choices before the reveal would be a page that could show you the
--- answer, and no amount of not-drawing-it would change that it had arrived.
local function viewFor(m, side)
    local me, them = m[side], m[side == 'a' and 'b' or 'a']
    return {
        id = m.id,
        round = m.round,
        me = { hp = me.hp, stamina = me.stamina, name = me.name, picked = me.pick ~= nil },
        them = { hp = them.hp, stamina = them.stamina, name = them.name, picked = them.pick ~= nil },
        endsAt = m.deadline,
        stake = m.stake or 0,
        over = m.over or nil,
        -- **What has been thrown so far, both sides.**
        --
        -- This is the difference between a guessing game and a reading game. Without it every
        -- round is a fresh coin toss between strangers; with it, somebody who has thrown three
        -- Heavies is telling you something, and you can see them do it.
        history = (function()
            local out = {}
            for _, h in ipairs(m.history or {}) do
                out[#out + 1] = { mine = h[side], theirs = h[side == 'a' and 'b' or 'a'] }
            end
            return out
        end)(),
        -- The previous round, revealed. Both picks, because it has already happened.
        last = m.last and {
            mine = m.last[side], theirs = m.last[side == 'a' and 'b' or 'a'],
            tookMe = m.last.take[side], tookThem = m.last.take[side == 'a' and 'b' or 'a'],
            tagMe = m.last.tag[side], tagThem = m.last.tag[side == 'a' and 'b' or 'a'],
        } or nil,
    }
end

local function pushMatch(m)
    for _, side in ipairs({ 'a', 'b' }) do
        -- The bot has no phone to send to. Checked by `src` rather than by a flag, because a
        -- disconnected human has no source either and both want the same thing done.
        local src = m[side].src
        if src then
            TriggerClientEvent('v-phone:client:brawl', src, viewFor(m, side))
        end
    end
end

local function costOf(action) return COST[action] end

--- What this fighter can afford right now. Sent with the view so the page greys out what is
--- unaffordable rather than offering it and refusing - and so the OPPONENT's stamina, which is
--- public, means something to read.
local function affordable(stamina)
    local out = {}
    for action, cost in pairs(COST) do out[action] = stamina >= cost end
    return out
end

-- ══════════════════════════════════════════════════════════════
-- The pot
-- ══════════════════════════════════════════════════════════════
-- Both stakes are taken BEFORE the first round and held by the match. Nothing is promised out
-- of a balance that might not be there when the fight ends - a bet settled at the end against
-- an empty account is a bet one side simply does not pay.
--
-- The money moves through the same bridge as every other app, so it works the same on qb-core,
-- on ESX and with doc-banking.

--- Take both stakes. All or nothing: if the second debit fails, the first is put back and the
--- fight does not start. Half a pot is worse than no fight.
local function takePot(srcA, srcB, stake)
    if stake <= 0 then return true end
    local actingA = PhoneActingSource and PhoneActingSource(srcA) or srcA
    local actingB = PhoneActingSource and PhoneActingSource(srcB) or srcB

    if not Bridge.RemoveMoney(actingA, stake, 'bank', 'v-phone: FruitBrawl stake') then
        return false, 'a'
    end
    if not Bridge.RemoveMoney(actingB, stake, 'bank', 'v-phone: FruitBrawl stake') then
        Bridge.AddMoney(actingA, stake, 'bank', 'v-phone: FruitBrawl refund')
        return false, 'b'
    end
    return true
end

--- Pay it out. The winner takes both; a draw gives each their own back.
---
--- A credit that cannot be delivered is PRINTED rather than swallowed. It is somebody's money,
--- and an operator who can see the line can put it right.
local function payPot(m, winnerSide)
    local stake = m.stake or 0
    if stake <= 0 then return end

    local function give(side, amount, why)
        local src = m[side].src
        if not src or amount <= 0 then
            print(('[v-phone] FruitBrawl: %d owed to %s (%s) and nobody to pay')
                :format(amount, tostring(m[side].cid), why))
            return
        end
        local acting = PhoneActingSource and PhoneActingSource(src) or src
        if not Bridge.AddMoney(acting, amount, 'bank', 'v-phone: FruitBrawl ' .. why) then
            print(('[v-phone] FruitBrawl: %d could not be paid to %s (%s)')
                :format(amount, tostring(m[side].cid), why))
        end
    end

    if winnerSide == 'a' or winnerSide == 'b' then
        give(winnerSide, stake * 2, 'winnings')
    else
        -- A draw, or a fight that ended with nobody standing: each takes their own back.
        give('a', stake, 'refund')
        give('b', stake, 'refund')
    end
    m.stake = 0     -- paid once, whatever else happens to this match afterwards
end

-- ══════════════════════════════════════════════════════════════
-- Resolving a round
-- ══════════════════════════════════════════════════════════════

local function finish(m, winnerSide, why)
    if m.over then return end
    m.over = { winner = winnerSide, why = why, stake = m.stake or 0 }
    payPot(m, winnerSide)

    -- Nothing is written for a fight against the bot. A leaderboard filled by beating a
    -- machine is not a leaderboard, and the moment one counted, every record on the server
    -- would be worth nothing.
    for _, side in ipairs({ 'a', 'b' }) do
        local won = side == winnerSide
        local cid = m[side].cid
        if m.bot then goto continue end
        -- `GREATEST` on the best streak so a longer run is never lost to a shorter one landing
        -- last, and the streak itself is set rather than incremented when it breaks.
        MySQL.query.await([[INSERT INTO vphone_brawl_stats (citizenid, nick, wins, losses, streak, best)
            VALUES (?,?,?,?,?,?)
            ON DUPLICATE KEY UPDATE
                wins = wins + ?, losses = losses + ?,
                streak = IF(? = 1, streak + 1, 0),
                best = GREATEST(best, IF(? = 1, streak + 1, 0))]],
            { cid, m[side].name, won and 1 or 0, won and 0 or 1, won and 1 or 0, won and 1 or 0,
              won and 1 or 0, won and 0 or 1, won and 1 or 0, won and 1 or 0 })
        ::continue::
        if cid then ByCid[cid] = nil end
    end

    pushMatch(m)
    -- Kept for a moment so both pages can draw the ending, then dropped.
    SetTimeout(20000, function() Matches[m.id] = nil end)
end

local function resolve(m)
    local a, b = m.a, m.b
    -- Nobody who ran out of time gets a free action: covering up is what a fighter does when
    -- they have stopped deciding, and it is also the only thing that costs nothing.
    a.pick = a.pick or 'block'
    b.pick = b.pick or 'block'

    local ra = OUTCOME[a.pick][b.pick]
    local rb = OUTCOME[b.pick][a.pick]

    a.hp = math.max(0, a.hp - ra.take)
    b.hp = math.max(0, b.hp - rb.take)

    for _, side in ipairs({ 'a', 'b' }) do
        local f = m[side]
        if f.pick == 'block' then
            f.stamina = math.min(maxStam(), f.stamina + BLOCK_REGAIN)
        else
            f.stamina = math.max(0, f.stamina - costOf(f.pick))
        end
    end

    -- Kept to the last six. It is a strip on a phone screen, and a fight long enough to fill
    -- more of one is a fight where the first rounds stopped meaning anything.
    m.history = m.history or {}
    m.history[#m.history + 1] = { a = a.pick, b = b.pick }
    if #m.history > 6 then table.remove(m.history, 1) end

    -- What the bot has watched them do. Counted AFTER the round, so it is always answering
    -- what has already happened rather than what is happening.
    if m.bot then
        local human = m.a.bot and 'b' or 'a'
        m.bot.seen[m[human].pick] = (m.bot.seen[m[human].pick] or 0) + 1
    end

    m.last = {
        a = a.pick, b = b.pick,
        take = { a = ra.take, b = rb.take },
        tag = { a = ra.tag, b = rb.tag },
    }
    a.pick, b.pick = nil, nil
    m.round = m.round + 1
    m.deadline = os.time() + roundSeconds()
    if m.bot then m.botAt = os.time() + math.random(1, math.max(2, roundSeconds() - 4)) end

    if a.hp <= 0 and b.hp <= 0 then
        -- Both down in the same exchange. Whoever has more health left cannot be the answer -
        -- they are both at zero - so it is a draw, and a draw counts for nobody.
        finish(m, nil, 'double')
    elseif a.hp <= 0 then finish(m, 'b', 'knockout')
    elseif b.hp <= 0 then finish(m, 'a', 'knockout')
    else pushMatch(m) end
end

-- The clock. One thread for every fight on the server, because a duel is a handful of state
-- and a timer each would be a thread per pair of players.
CreateThread(function()
    while true do
        Wait(500)
        local now = os.time()
        for _, m in pairs(Matches) do
            if not m.over then
                -- The bot picks partway through the round rather than instantly. A "ready"
                -- badge that lit the moment you opened the screen would tell you it is a
                -- machine before the first punch.
                if m.bot then
                    local botSide = m.a.bot and 'a' or 'b'
                    local bot = m[botSide]
                    if not bot.pick and now >= (m.botAt or 0) then
                        bot.pick = botPick(m.bot, bot)
                        pushMatch(m)
                    end
                end
                if m.a.pick and m.b.pick then resolve(m)
                elseif now >= m.deadline then resolve(m) end
            end
        end
        for cid, inv in pairs(Invites) do
            if now - inv.at > inviteSeconds() then Invites[cid] = nil end
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Starting one
-- ══════════════════════════════════════════════════════════════

local function begin(cidA, srcA, cidB, srcB, stake)
    nextId = nextId + 1
    local m = {
        id = nextId,
        stake = stake or 0,
        round = 1,
        deadline = os.time() + roundSeconds(),
        a = { cid = cidA, src = srcA, hp = maxHp(), stamina = startStam(), name = nameOf(cidA) },
        b = { cid = cidB, src = srcB, hp = maxHp(), stamina = startStam(), name = nameOf(cidB) },
    }
    Matches[m.id] = m
    if cidA then ByCid[cidA] = m.id end
    if cidB then ByCid[cidB] = m.id end
    if cidA then Invites[cidA] = nil end
    if cidB then Invites[cidB] = nil end
    pushMatch(m)
    return m
end

local function matchOf(cid)
    local id = ByCid[cid]
    return id and Matches[id] or nil
end

local function sideOf(m, cid)
    if not m then return nil end
    if m.a.cid == cid then return 'a' end
    if m.b.cid == cid then return 'b' end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- What the app asks for
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:brawl:open', function(src, resolveCb)
    if not enabled() then resolveCb({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolveCb(false) return end
    local cid = p.citizenid

    -- Rejoining a fight that was already running: somebody closed the phone mid-duel and came
    -- back, which has to work or a pocketed phone is a forfeit.
    local m = matchOf(cid)
    if m then m[sideOf(m, cid)].src = src end

    local board = MySQL.query.await([[SELECT nick, wins, losses, best FROM vphone_brawl_stats
        WHERE wins > 0 ORDER BY wins DESC, best DESC LIMIT 20]]) or {}
    local top = {}
    for i, r in ipairs(board) do
        top[#top + 1] = { rank = i, name = tostring(r.nick or '?'),
                          wins = math.floor(num(r.wins, 0)), losses = math.floor(num(r.losses, 0)),
                          best = math.floor(num(r.best, 0)) }
    end

    resolveCb({
        ok = true,
        stats = statsOf(cid),
        match = m and viewFor(m, sideOf(m, cid)) or nil,
        invite = Invites[cid] and { from = Invites[cid].fromName, number = Invites[cid].number,
                                    stake = Invites[cid].stake or 0 } or nil,
        queued = (function()
            for _, q in ipairs(Queue) do if q.cid == cid then return q.stake or 0, true end end
            return false
        end)(),
        stakes = { on = stakesOn(), max = maxStake() },
        board = top,
        rules = {
            health = maxHp(), stamina = maxStam(), start = startStam(),
            cost = COST, regain = BLOCK_REGAIN, roundSeconds = roundSeconds(),
        },
    })
end)

--- When each player last tried to invite somebody.
---
--- **This callback answers a question about a phone number**: `nouser` for one nobody holds,
--- something else for one somebody does - and on success it hands back the holder's name. Asked
--- in a loop that is a directory of every character on the server, built by anybody, from a
--- number space small enough to walk. A floor between attempts is what turns an oracle back
--- into a feature: a person challenging a friend types one number, and a script enumerating
--- seven digits needs millions.
local InviteLast = {}

AddEventHandler('playerDropped', function() InviteLast[source] = nil end)

--- Challenge somebody by their phone number. It is a phone; that is the address people have.
V.Callback('v-phone:brawl:invite', function(src, resolveCb, data)
    if not enabled() then resolveCb({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolveCb(false) return end
    -- Owning the app is what entitles somebody to ask. Checked here rather than trusted from
    -- the page, which is where every other entitlement in this resource is checked.
    if PhoneHasApp and not PhoneHasApp(src, 'brawl') then resolveCb({ error = 'off' }) return end

    local now = GetGameTimer()
    if InviteLast[src] and (now - InviteLast[src]) < 2000 then
        resolveCb({ error = 'toosoon' }) return
    end
    InviteLast[src] = now

    local cid = p.citizenid
    if matchOf(cid) then resolveCb({ error = 'busy' }) return end

    local number = tostring((data and data.number) or ''):gsub('%s', '')
    if number == '' then resolveCb({ error = 'nonumber' }) return end

    -- Through the resource's own export rather than a global: `cidOfNumber` is local to
    -- server/main.lua, and a global that happened to exist today would be a global to keep
    -- existing. `FindByNumber` is the published name for exactly this.
    local targetCid
    pcall(function() targetCid = exports[GetCurrentResourceName()]:FindByNumber(number) end)
    if targetCid == '' then targetCid = nil end
    if not targetCid then resolveCb({ error = 'nouser' }) return end
    if targetCid == cid then resolveCb({ error = 'self' }) return end
    if matchOf(targetCid) then resolveCb({ error = 'theybusy' }) return end

    local target = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(targetCid)
    if not target or not target.source then resolveCb({ error = 'offline' }) return end

    local stake = cleanStake(data and data.stake)
    Invites[targetCid] = { from = cid, fromName = nameOf(cid), at = os.time(), stake = stake,
                           number = (function()
                               local n
                               pcall(function() n = exports[GetCurrentResourceName()]:GetNumber(cid) end)
                               return tostring(n or '')
                           end)() }
    pcall(function()
        exports[GetCurrentResourceName()]:Notify(target.source, 'brawl',
            LP(target.source, 'ph.brawl_notif_title'), nameOf(cid))
    end)
    TriggerClientEvent('v-phone:client:appRefresh', target.source, 'brawl')
    resolveCb({ ok = true, sent = nameOf(targetCid), stake = stake })
end)

V.Callback('v-phone:brawl:answer', function(src, resolveCb, data)
    if not enabled() then resolveCb({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolveCb(false) return end
    local cid = p.citizenid

    local inv = Invites[cid]
    if not inv then resolveCb({ error = 'noinvite' }) return end
    Invites[cid] = nil

    if not (data and data.accept) then
        local other = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(inv.from)
        if other and other.source then
            TriggerClientEvent('v-phone:client:appRefresh', other.source, 'brawl')
        end
        resolveCb({ ok = true, declined = true })
        return
    end

    if matchOf(cid) then resolveCb({ error = 'busy' }) return end
    if matchOf(inv.from) then resolveCb({ error = 'theybusy' }) return end
    local other = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(inv.from)
    if not other or not other.source then resolveCb({ error = 'offline' }) return end

    -- Both stakes, before the first round. A refusal here is a fight that never starts rather
    -- than a debt at the end of one.
    local stake = cleanStake(inv.stake)
    local paid, whose = takePot(other.source, src, stake)
    if not paid then
        resolveCb({ error = whose == 'b' and 'nomoney' or 'theybroke', stake = stake })
        return
    end

    local m = begin(inv.from, other.source, cid, src, stake)
    resolveCb({ ok = true, match = viewFor(m, sideOf(m, cid)) })
end)

--- Anybody. The queue is one deep in practice: the moment a second person joins, they fight.
V.Callback('v-phone:brawl:queue', function(src, resolveCb, data)
    if not enabled() then resolveCb({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolveCb(false) return end
    local cid = p.citizenid
    if matchOf(cid) then resolveCb({ error = 'busy' }) return end

    for i = #Queue, 1, -1 do if Queue[i].cid == cid then table.remove(Queue, i) end end
    if data and data.leave then resolveCb({ ok = true, queued = false }) return end

    local stake = cleanStake(data and data.stake)

    -- Only somebody waiting for the SAME stake. Matching a hundred-dollar challenge with
    -- somebody who wanted a friendly would be taking money off them for a fight they thought
    -- was free.
    for i = 1, #Queue do
        local q = Queue[i]
        local other = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(q.cid)
        if q.stake == stake and other and other.source and not matchOf(q.cid) then
            table.remove(Queue, i)
            local paid, whose = takePot(other.source, src, stake)
            if not paid then
                -- Whoever could not pay drops out; the other stays in the queue rather than
                -- being punished for somebody else's empty account.
                if whose == 'a' then
                    resolveCb({ error = 'theybroke' })
                else
                    Queue[#Queue + 1] = q
                    resolveCb({ error = 'nomoney', stake = stake })
                end
                return
            end
            local m = begin(q.cid, other.source, cid, src, stake)
            resolveCb({ ok = true, match = viewFor(m, sideOf(m, cid)) })
            return
        end
    end

    Queue[#Queue + 1] = { cid = cid, stake = stake }
    resolveCb({ ok = true, queued = true, stake = stake })
end)

--- One choice, for one round. The ONLY thing a page can send about a fight.
V.Callback('v-phone:brawl:pick', function(src, resolveCb, data)
    if not enabled() then resolveCb({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolveCb(false) return end
    local cid = p.citizenid

    local m = matchOf(cid)
    if not m or m.over then resolveCb({ error = 'nomatch' }) return end
    local side = sideOf(m, cid)
    if not side then resolveCb({ error = 'nomatch' }) return end

    local action = tostring((data and data.action) or '')
    if COST[action] == nil then resolveCb({ error = 'action' }) return end

    local me = m[side]
    -- Checked here and nowhere else. The page greys out what cannot be afforded, but a page is
    -- a browser: the rule is that a fighter cannot throw what they cannot pay for, and this is
    -- where that rule lives.
    if me.stamina < COST[action] then resolveCb({ error = 'stamina' }) return end
    -- A pick is final for the round. Changing it after seeing the timer run down would be
    -- playing the clock rather than the opponent.
    if me.pick then resolveCb({ error = 'picked' }) return end

    me.src = src
    me.pick = action
    -- The opponent is told SOMEBODY has chosen, never what. That is the tell a real fight has.
    pushMatch(m)
    resolveCb({ ok = true, picked = action, afford = affordable(me.stamina) })
end)

--- A fight against the machine. No invite, no queue, no waiting.
V.Callback('v-phone:brawl:solo', function(src, resolveCb, data)
    if not enabled() then resolveCb({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolveCb(false) return end
    local cid = p.citizenid
    if matchOf(cid) then resolveCb({ error = 'busy' }) return end

    local level = tostring((data and data.level) or 'normal')
    if not BOT_NOISE[level] then level = 'normal' end

    -- No stake, ever. Betting against a machine the server controls is not a bet.
    local m = begin(cid, src, nil, nil, 0)
    m.b.name = BOT_NAMES[level]
    m.b.bot = true
    m.bot = { level = level, seen = {} }
    m.botAt = os.time() + math.random(1, math.max(2, roundSeconds() - 4))
    pushMatch(m)
    resolveCb({ ok = true, match = viewFor(m, 'a') })
end)

V.Callback('v-phone:brawl:forfeit', function(src, resolveCb)
    local p = Core.GetPlayer(src)
    if not p then resolveCb(false) return end
    local m = matchOf(p.citizenid)
    if not m or m.over then resolveCb({ error = 'nomatch' }) return end
    local side = sideOf(m, p.citizenid)
    finish(m, side == 'a' and 'b' or 'a', 'forfeit')
    resolveCb({ ok = true })
end)

-- Dropping is forfeiting. A duel where one side simply vanished would otherwise sit there
-- until its round timer ran out for ever, and the other player would never be told why.
AddEventHandler('playerDropped', function()
    local src = source
    local p = Core.GetPlayer and Core.GetPlayer(src)
    if not p then return end
    local cid = p.citizenid
    for i = #Queue, 1, -1 do if Queue[i].cid == cid then table.remove(Queue, i) end end
    Invites[cid] = nil
    local m = matchOf(cid)
    if m and not m.over then
        local side = sideOf(m, cid)
        finish(m, side == 'a' and 'b' or 'a', 'left')
    end
end)

--- Somebody's record, for a script that wants to put a fight card on a wall.
---
---     local r = exports['v-phone']:GetBrawlRecord(citizenid)
exports('GetBrawlRecord', function(citizenid)
    if not enabled() then return nil end
    local cid = tostring(citizenid or '')
    if cid == '' then return nil end
    return statsOf(cid)
end)
