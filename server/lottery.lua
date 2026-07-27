-- v-phone | server/lottery.lua
--
-- **The lottery: the weekly draw, from the phone.**
--
-- Two providers, one app, and the page never learns which one answered.
--
--   * **doc-lottery**, when it is running. Everything is its own: the session, the jackpot, the
--     tickets, the draw sequence and the prize tiers. It publishes exactly what its own phone app
--     used - `doc_lottery:server:phoneGetData` and `doc_lottery:server:phoneBuyTicket`, both QB
--     *server callbacks* - and a server callback is registered on the framework rather than on the
--     resource, so any client may call one. That side is therefore driven from client/lottery.lua,
--     and this file deliberately does not touch it: nothing here reads or writes a
--     `doc_lottery_*` table, calls into it, or replaces any part of it.
--   * **`Config.Lottery`** otherwise, which is what makes the app worth installing on an ESX, ox
--     or standalone server. Its own tables, its own draw, its own money path.
--
-- Decided here in config mode and never by the page: the price, the number range, whether a line
-- is legal, and the draw itself. A client is told the result; it never contributes to one. The
-- debit fails closed and a ticket that cannot be recorded is refunded.
--
-- **The draw is irreversible and moves real money**, so the sequence writes the session to
-- `drawing` first. That row is the lock: a second draw finds it no longer pending and stops, and a
-- purchase arriving mid-draw is refused rather than landing in a pot already counted.

local CFG = Config.Lottery or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

--- Is doc-lottery the provider?
---
--- Asked per request rather than cached, so starting the resource mid-session works without
--- restarting the phone.
local function docMode()
    local want = tostring(CFG.provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-lottery' then return true end
    return GetResourceState('doc-lottery') == 'started'
end

-- ══════════════════════════════════════════════════════════════
-- Shape
-- ══════════════════════════════════════════════════════════════

local function ticketPrice() return math.max(0, math.floor(num(CFG.ticketPrice, 250))) end
local function numberCount() return math.max(1, math.floor(num(CFG.numberCount, 5))) end
local function numberMin() return math.floor(num(CFG.numberMin, 1)) end
local function numberMax() return math.floor(num(CFG.numberMax, 35)) end
local function maxLines() return math.max(1, math.floor(num(CFG.maxCombinations, 7))) end
local function historyLimit() return math.max(1, math.floor(num(CFG.history, 5))) end

--- The one purse a ticket is paid from.
---
--- Read here rather than taken from the page, which is the whole point: the page does not choose
--- how a ticket is paid for, it is told. A client sending `cash` on a server set to `bank` is
--- charged the bank, because that is what the operator configured.
local function payAccount()
    local want = tostring(CFG.account or 'bank')
    return want == 'cash' and 'cash' or 'bank'
end

--- The prize tiers, best first, in the shape the app draws.
local function tiers()
    local out = {}
    local rewards = CFG.rewards or {}
    for matches = numberCount(), 1, -1 do
        local tier = rewards[matches]
        if tier then
            out[#out + 1] = {
                matches = matches,
                payer = tier.payer,
                amount = tier.amount,
                percent = tier.percent,
            }
        end
    end
    return out
end

--- Numbers as doc-lottery stores them: sorted, slash separated. Same shape on purpose, so a
--- server that later installs doc-lottery finds a history it can still read.
local function formatNumbers(list)
    local copy = {}
    for i, n in ipairs(list) do copy[i] = math.floor(n) end
    table.sort(copy)
    local parts = {}
    for i, n in ipairs(copy) do parts[i] = tostring(n) end
    return table.concat(parts, '/')
end

local function parseNumbers(text)
    local out = {}
    for piece in tostring(text or ''):gmatch('%d+') do out[#out + 1] = tonumber(piece) end
    return out
end

-- ══════════════════════════════════════════════════════════════
-- The clock
-- ══════════════════════════════════════════════════════════════
-- The server usually runs on UTC while the time announced to players is local, so every date the
-- app shows is built from a shifted clock. Getting this wrong does not break anything visibly -
-- it just announces the wrong hour, which players discover by missing a draw.

local function localNow()
    return os.time() + math.floor(num(CFG.timezoneOffset, 0)) * 3600
end

local function localParts(at)
    return os.date('*t', at or localNow())
end

--- Is this a draw day? `os.date('*t').wday` is 1 for Sunday, which is the same convention the
--- config documents.
local function isDrawDay(wday)
    local days = (CFG.autoDraw or {}).days
    if type(days) ~= 'table' then return false end
    for _, d in ipairs(days) do
        if math.floor(num(d, 0)) == wday then return true end
    end
    return false
end

--- When the next draw is, as an epoch on the LOCAL clock, or nil when auto-draw is off.
local function nextDrawAt()
    local auto = CFG.autoDraw or {}
    if auto.enabled == false then return nil end
    if type(auto.days) ~= 'table' or #auto.days == 0 then return nil end

    local hour = math.floor(num(auto.hour, 21))
    local minute = math.floor(num(auto.minute, 30))
    local now = localNow()
    local t = localParts(now)

    -- Today, then each of the next seven days. Seven and not "the next matching weekday",
    -- because the answer for "today, in ten minutes" and "today, an hour ago" is different.
    for ahead = 0, 7 do
        local when = os.time({
            year = t.year, month = t.month, day = t.day + ahead,
            hour = hour, min = minute, sec = 0, isdst = t.isdst,
        })
        local parts = os.date('*t', when)
        if isDrawDay(parts.wday) and when > now then return when end
    end
    return nil
end

--- The next draw, written the way a player reads it.
local function nextDrawLabel()
    local at = nextDrawAt()
    if not at then return nil end
    return os.date('%d/%m/%Y %H:%M', at)
end

-- ══════════════════════════════════════════════════════════════
-- Tables
-- ══════════════════════════════════════════════════════════════
-- Deliberately shaped like doc-lottery's own, down to the slash-separated numbers column: a
-- server that starts with this provider and later installs doc-lottery keeps a readable history
-- rather than two unrelated archives.

local ready = false

CreateThread(function()
    if not enabled() then return end
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_lottery_sessions` (
        `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `draw_label` VARCHAR(64)  NOT NULL DEFAULT '',
        `jackpot`    INT UNSIGNED NOT NULL DEFAULT 0,
        `numbers`    VARCHAR(64)  DEFAULT NULL,
        `status`     VARCHAR(10)  NOT NULL DEFAULT 'pending',
        `drawn_at`   TIMESTAMP    NULL DEFAULT NULL,
        `at`         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `status` (`status`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_lottery_tickets` (
        `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `session_id` INT UNSIGNED NOT NULL,
        `citizenid`  VARCHAR(64)  NOT NULL,
        `name`       VARCHAR(120) NOT NULL DEFAULT '',
        `numbers`    VARCHAR(64)  NOT NULL,
        `matches`    TINYINT      NOT NULL DEFAULT 0,
        `reward`     INT UNSIGNED NOT NULL DEFAULT 0,
        `at`         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `session_id` (`session_id`),
        KEY `citizenid` (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    ready = true
end)

-- ══════════════════════════════════════════════════════════════
-- The session
-- ══════════════════════════════════════════════════════════════

--- The open session, or nil. Read fresh every time rather than cached in a local: the jackpot is
--- incremented in SQL so that two simultaneous purchases cannot lose one of the two additions,
--- and a cached copy would be exactly the stale value that arithmetic exists to avoid.
local function openSession()
    local row = MySQL.single.await(
        "SELECT * FROM `vphone_lottery_sessions` WHERE `status` IN ('pending','drawing') " ..
        'ORDER BY `id` DESC LIMIT 1')
    return row
end

--- Open a session if there is none. Returns the session.
local function ensureSession()
    if not ready then return nil end
    local session = openSession()
    if session then return session end

    local id = MySQL.insert.await(
        'INSERT INTO `vphone_lottery_sessions` (`draw_label`, `jackpot`, `status`) VALUES (?,?,?)',
        { nextDrawLabel() or '', math.max(0, math.floor(num(CFG.jackpotStart, 10000))), 'pending' })
    if not id then return nil end
    V.Log(('lottery: opened session #%d'):format(id))
    return openSession()
end

--- Keep the announced date honest.
---
--- The label is stored rather than computed on read so that a session opened before the operator
--- changed the schedule still shows what players were told. It is refreshed while the session is
--- pending, because until the draw happens the schedule IS the answer.
local function refreshLabel(session)
    if not session or session.status ~= 'pending' then return session end
    local label = nextDrawLabel()
    if not label or label == session.draw_label then return session end
    MySQL.update.await('UPDATE `vphone_lottery_sessions` SET `draw_label` = ? WHERE `id` = ?',
        { label, session.id })
    session.draw_label = label
    return session
end

-- ══════════════════════════════════════════════════════════════
-- Reading
-- ══════════════════════════════════════════════════════════════

local function historyOf()
    local rows = MySQL.query.await([[
        SELECT s.id, s.jackpot, s.numbers, s.status,
               UNIX_TIMESTAMP(COALESCE(s.drawn_at, s.at)) AS drawn_at,
               (SELECT COUNT(*) FROM `vphone_lottery_tickets` t
                  WHERE t.session_id = s.id AND t.reward > 0) AS winners,
               (SELECT COUNT(*) FROM `vphone_lottery_tickets` t2
                  WHERE t2.session_id = s.id AND t2.matches = ?) AS jackpots
        FROM `vphone_lottery_sessions` s
        WHERE s.status = 'drawn' AND s.numbers IS NOT NULL
        ORDER BY s.id DESC LIMIT ?]], { numberCount(), historyLimit() }) or {}

    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {
            id = r.id,
            jackpot = math.floor(num(r.jackpot, 0)),
            numbers = parseNumbers(r.numbers),
            at = math.floor(num(r.drawn_at, 0)),
            winners = math.floor(num(r.winners, 0)),
            -- Told apart on purpose. doc-lottery's own app printed "jackpot won" whenever
            -- `winners` was above nought, and `winners` counts every prize down to 2/5 - so a
            -- draw where two people matched two numbers announced that the jackpot had fallen.
            -- The pot rolling over is the whole drama of a lottery; it cannot be misreported.
            jackpots = math.floor(num(r.jackpots, 0)),
        }
    end
    return out
end

local function myTickets(sessionId, cid)
    if not sessionId then return {} end
    local rows = MySQL.query.await(
        'SELECT `numbers`, UNIX_TIMESTAMP(`at`) AS at, `matches`, `reward` ' ..
        'FROM `vphone_lottery_tickets` WHERE `session_id` = ? AND `citizenid` = ? ORDER BY `id`',
        { sessionId, cid }) or {}
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {
            numbers = parseNumbers(r.numbers),
            at = math.floor(num(r.at, 0)),
            matches = math.floor(num(r.matches, 0)),
            reward = math.floor(num(r.reward, 0)),
        }
    end
    return out
end

--- The player's own past results, which doc-lottery's app never showed at all.
---
--- "Did I ever win anything" is the second question anybody asks of a lottery app, and the answer
--- was unavailable: its own history was the public draw list with no mention of the reader.
local function myPast(cid)
    local rows = MySQL.query.await([[
        SELECT t.numbers, t.matches, t.reward, s.id AS session_id, s.numbers AS drawn,
               UNIX_TIMESTAMP(COALESCE(s.drawn_at, s.at)) AS at
        FROM `vphone_lottery_tickets` t
        JOIN `vphone_lottery_sessions` s ON s.id = t.session_id
        WHERE t.citizenid = ? AND s.status = 'drawn'
        ORDER BY t.id DESC LIMIT 30]], { cid }) or {}
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {
            session = r.session_id,
            numbers = parseNumbers(r.numbers),
            drawn = parseNumbers(r.drawn),
            matches = math.floor(num(r.matches, 0)),
            reward = math.floor(num(r.reward, 0)),
            at = math.floor(num(r.at, 0)),
        }
    end
    return out
end

--- Everything the app needs, in one answer. Same idea as doc-lottery's `phoneGetData`.
local function payloadFor(src, p)
    local session = refreshLabel(ensureSession())
    local cid = p.citizenid
    local mine = session and myTickets(session.id, cid) or {}

    return {
        ok = true,
        doc = false,
        sessionId = session and session.id or nil,
        jackpot = session and math.floor(num(session.jackpot, 0)) or 0,
        drawLabel = session and session.draw_label or nil,
        drawAt = nextDrawAt(),
        status = session and session.status or 'pending',
        tiers = tiers(),
        myTickets = mine,
        myPast = myPast(cid),
        history = historyOf(),
        config = {
            ticketPrice = ticketPrice(),
            numberCount = numberCount(),
            numberMin = numberMin(),
            numberMax = numberMax(),
            maxComb = maxLines(),
            account = payAccount(),
        },
    }
end

-- ══════════════════════════════════════════════════════════════
-- Buying
-- ══════════════════════════════════════════════════════════════

--- One line. Every rule is re-checked here.
local function buy(src, p, data)
    local session = refreshLabel(ensureSession())
    if not session then return { error = 'nosession' } end
    -- The draw is under way: the pot has been counted and the numbers may already be picked, so a
    -- ticket sold now would be a ticket sold into a finished draw.
    if session.status ~= 'pending' then return { error = 'drawing' } end

    local lines = myTickets(session.id, p.citizenid)
    if #lines >= maxLines() then return { error = 'full', max = maxLines() } end

    local account = payAccount()

    -- The numbers, cleaned rather than trusted: count, range, integers and duplicates.
    local want = numberCount()
    local raw = (type(data) == 'table' and type(data.numbers) == 'table') and data.numbers or {}
    local seen, clean = {}, {}
    for _, value in ipairs(raw) do
        local n = tonumber(value)
        if not n or n ~= math.floor(n) or n < numberMin() or n > numberMax() or seen[n] then
            return { error = 'badnumbers' }
        end
        seen[n] = true
        clean[#clean + 1] = math.floor(n)
    end
    if #clean ~= want then return { error = 'badcount', n = want } end

    local price = ticketPrice()
    local acting = PhoneActingSource and PhoneActingSource(src) or src

    -- Charged before anything is written, and it fails closed.
    if price > 0 then
        if not Bridge.RemoveMoney(acting, price, account, 'v-phone: lottery ticket') then
            return { error = 'nomoney' }
        end
    end

    local numbersStr = formatNumbers(clean)
    local id = MySQL.insert.await(
        'INSERT INTO `vphone_lottery_tickets` (`session_id`, `citizenid`, `name`, `numbers`) ' ..
        'VALUES (?,?,?,?)',
        { session.id, p.citizenid, tostring(p.name or ''), numbersStr })

    if not id then
        -- Refunded rather than kept. A ticket that was paid for and not recorded is a ticket that
        -- cannot win, and the player has no way to know it.
        if price > 0 then
            Bridge.AddMoney(acting, price, account, 'v-phone: lottery ticket refunded')
        end
        return { error = 'x' }
    end

    -- The pot's share, added ATOMICALLY in SQL. Two purchases landing in the same instant would
    -- otherwise read the same jackpot and one of the two additions would vanish.
    local share = math.max(0, math.min(100, math.floor(num(CFG.jackpotShare, 50))))
    local toPot = math.ceil(price * share / 100)
    local toGov = price - toPot
    if toPot > 0 then
        MySQL.update.await('UPDATE `vphone_lottery_sessions` SET `jackpot` = `jackpot` + ? WHERE `id` = ?',
            { toPot, session.id })
    end
    if toGov > 0 and CFG.govAccount and Bridge.AddSociety then
        Bridge.AddSociety(tostring(CFG.govAccount), toGov, 'v-phone: lottery ticket')
    end

    V.Log(('lottery: %s bought %s for %d (%s)')
        :format(tostring(p.citizenid), numbersStr, price, account))

    local fresh = openSession()
    return {
        ok = true,
        numbers = clean,
        jackpot = fresh and math.floor(num(fresh.jackpot, 0)) or nil,
        lines = #lines + 1,
        max = maxLines(),
    }
end

-- ══════════════════════════════════════════════════════════════
-- The draw
-- ══════════════════════════════════════════════════════════════

--- The live sequence, so a player arriving mid-draw can be shown where it is.
--- Nil between draws, which is also the answer to "is a draw running".
local Live = nil

local function tellEveryone(event, payload)
    TriggerClientEvent(event, -1, payload)
end

--- N distinct numbers in range.
local function pick()
    local pool = {}
    for n = numberMin(), numberMax() do pool[#pool + 1] = n end
    local out = {}
    for _ = 1, math.min(numberCount(), #pool) do
        local at = math.random(#pool)
        out[#out + 1] = pool[at]
        table.remove(pool, at)
    end
    return out
end

local function countMatches(ticket, drawn)
    local set = {}
    for _, n in ipairs(drawn) do set[n] = true end
    local hits = 0
    for _, n in ipairs(ticket) do
        if set[n] then hits = hits + 1 end
    end
    return hits
end

--- Run a draw. Returns ok, or nil and a reason.
---
--- Written as one function on purpose: every step depends on the one before it, and the money is
--- moved only after the numbers are committed to the row that locks the session.
local function runDraw(by)
    if not enabled() or docMode() then return nil, 'notdoc' end
    if Live then return nil, 'running' end

    local session = openSession()
    if not session then return nil, 'nosession' end
    if session.status ~= 'pending' then return nil, 'running' end

    -- The lock, and it is the row rather than a Lua flag: a second draw started from the staff
    -- menu, from the console, or by the scheduler one tick later finds this and stops. A Lua flag
    -- would not survive a restart in the middle of a draw; this does.
    local locked = MySQL.update.await(
        "UPDATE `vphone_lottery_sessions` SET `status` = 'drawing' WHERE `id` = ? AND `status` = 'pending'",
        { session.id })
    if not locked or locked == 0 then return nil, 'running' end

    local drawn = pick()
    local jackpot = math.floor(num(session.jackpot, 0))
    local count = numberCount()

    -- What each player's best line did, so a live viewer can watch their own grid fill in.
    local best = {}
    local rows = MySQL.query.await(
        'SELECT `id`, `citizenid`, `numbers` FROM `vphone_lottery_tickets` WHERE `session_id` = ?',
        { session.id }) or {}
    for _, r in ipairs(rows) do
        local nums = parseNumbers(r.numbers)
        local hits = countMatches(nums, drawn)
        if not best[r.citizenid] or hits > best[r.citizenid].matches then
            best[r.citizenid] = { numbers = nums, matches = hits }
        end
    end

    local countdown = math.max(0, math.floor(num(CFG.countdownSeconds, 60)))
    Live = {
        sessionId = session.id,
        jackpot = jackpot,
        numberCount = count,
        countdownEndsAt = countdown > 0 and (os.time() + countdown) or nil,
        revealed = {},
        started = false,
        result = nil,
        best = best,
    }

    V.Log(('lottery: draw on session #%d started by %s'):format(session.id, tostring(by or 'auto')))

    -- Per player, because each is shown their OWN grid and nobody else's.
    for _, raw in ipairs(GetPlayers()) do
        local other = tonumber(raw)
        local op = other and Core.GetPlayer(other)
        if op then
            TriggerClientEvent('v-phone:client:lotteryDraw', other, {
                kind = 'open',
                jackpot = jackpot,
                numberCount = count,
                countdown = countdown > 0 and countdown or nil,
                mine = best[op.citizenid] and best[op.citizenid].numbers or {},
            })
        end
    end

    CreateThread(function()
        if countdown > 0 then Wait(countdown * 1000) end

        Live.started = true
        Live.countdownEndsAt = nil
        tellEveryone('v-phone:client:lotteryDraw', { kind = 'start' })

        local gap = math.max(0, math.floor(num(CFG.ballSeconds, 3) * 1000))
        for _, n in ipairs(drawn) do
            Wait(gap)
            Live.revealed[#Live.revealed + 1] = n
            tellEveryone('v-phone:client:lotteryDraw', { kind = 'ball', number = n })
        end

        -- ── the money, after the show ──
        --
        -- **Order must not decide who gets paid.** Walking the tickets once and letting each take
        -- what was left of the pot as it went meant the prize depended on the row id: with a 5/5
        -- and a 4/5 in the same draw, whichever was inserted first took everything and the other
        -- got nothing at all. Found by the tests, and it is the kind of unfairness nobody would
        -- ever report as a bug - they would just conclude the lottery is rigged.
        --
        -- So: matches first, then the fixed tiers, then the percentage tiers, and the TOP tier
        -- last, splitting whatever is left between everybody who reached it.
        local byTier, paid = {}, 0
        local scored, top = {}, {}

        for _, r in ipairs(rows) do
            local nums = parseNumbers(r.numbers)
            local hits = countMatches(nums, drawn)
            scored[#scored + 1] = { row = r, hits = hits, reward = 0 }
            if hits >= count and (CFG.rewards or {})[hits] then top[#top + 1] = scored[#scored] end
        end

        -- Pass one: everything that is not the top tier.
        local left = jackpot
        for _, entry in ipairs(scored) do
            local tier = (CFG.rewards or {})[entry.hits]
            if tier and entry.hits < count then
                if tier.payer == 'jackpot' then
                    local percent = math.max(0, math.min(100, num(tier.percent, 0)))
                    -- A share of the pot AS IT WAS, capped by what is still in it. Two winners on
                    -- the same tier both get their share; a third that would overdraw gets what
                    -- remains rather than money the pot does not hold.
                    entry.reward = math.min(left, math.floor(jackpot * percent / 100))
                    left = math.max(0, left - entry.reward)
                else
                    local amount = math.max(0, math.floor(num(tier.amount, 0)))
                    -- Funded by the government account, and only if it can afford it. A fixed tier
                    -- paid out of nothing is money invented on a server that tracks its budget.
                    if amount > 0 and CFG.govAccount and Bridge.RemoveSociety then
                        if Bridge.RemoveSociety(tostring(CFG.govAccount), amount,
                                                'v-phone: lottery prize') then
                            entry.reward = amount
                        end
                    else
                        entry.reward = amount
                    end
                end
            end
        end

        -- Pass two: the top tier SPLITS what is left.
        --
        -- Shared rather than first-come, because that is what a jackpot is and what every
        -- announcement about one says. The rounding remainder stays in the pot and rolls over,
        -- which is the only direction that cannot pay out more than was held.
        if #top > 0 and left > 0 then
            local each = math.floor(left / #top)
            for _, entry in ipairs(top) do
                entry.reward = math.min(left, each)
                left = math.max(0, left - entry.reward)
            end
        end

        -- Pass three: record and pay.
        local jackpotWinners = 0
        for _, entry in ipairs(scored) do
            if entry.reward > 0 then
                byTier[entry.hits] = (byTier[entry.hits] or 0) + 1
                if entry.hits >= count then jackpotWinners = jackpotWinners + 1 end
                paid = paid + entry.reward

                -- Each payment is isolated: a winner whose account cannot be found must not stop
                -- the next winner being paid, nor the session being closed.
                local target = Core.GetPlayerByCitizenId
                    and Core.GetPlayerByCitizenId(entry.row.citizenid)
                local credited = false
                if target and target.source then
                    credited = Bridge.AddMoney(target.source, entry.reward, 'bank',
                                               'v-phone: lottery prize') and true or false
                end
                if not credited then
                    -- Offline, or the credit was refused. Recorded against the ticket either way,
                    -- so the win is visible in the app and an operator can settle it by hand
                    -- rather than it disappearing silently.
                    V.Log(('lottery: %s won %d and could not be paid now (offline or refused)')
                        :format(tostring(entry.row.citizenid), entry.reward))
                end
            end

            MySQL.update.await(
                'UPDATE `vphone_lottery_tickets` SET `matches` = ?, `reward` = ? WHERE `id` = ?',
                { entry.hits, entry.reward, entry.row.id })
        end

        -- ── the public result: counts only, never a name ──
        local parts = {}
        for m = count, 1, -1 do
            if byTier[m] then parts[#parts + 1] = { matches = m, n = byTier[m] } end
        end

        local rollover = math.max(0, jackpot - paid)
        local nextPot = jackpotWinners > 0
            and math.max(0, math.floor(num(CFG.jackpotStart, 10000)))
            or (rollover + math.max(0, math.floor(num(CFG.jackpotNoWinner, 1000))))

        local result = {
            numbers = drawn,
            jackpot = jackpot,
            jackpotWon = jackpotWinners > 0,
            jackpotWinners = jackpotWinners,
            tiers = parts,
            nextJackpot = nextPot,
        }
        Live.result = result
        tellEveryone('v-phone:client:lotteryDraw', { kind = 'result', result = result })

        MySQL.update.await(
            'UPDATE `vphone_lottery_sessions` SET `status` = ?, `numbers` = ?, `drawn_at` = NOW() ' ..
            'WHERE `id` = ?', { 'drawn', formatNumbers(drawn), session.id })

        -- The next session opens with the rolled-over pot, so the jackpot the app shows the moment
        -- the result lands is already the real one.
        MySQL.insert.await(
            'INSERT INTO `vphone_lottery_sessions` (`draw_label`, `jackpot`, `status`) VALUES (?,?,?)',
            { nextDrawLabel() or '', nextPot, 'pending' })

        V.Log(('lottery: session #%d drawn %s - %d paid, next pot %d')
            :format(session.id, formatNumbers(drawn), paid, nextPot))

        -- ── and privately, what YOUR ticket did ──
        if CFG.tellWinners ~= false then
            local told = {}
            for _, r in ipairs(rows) do
                if not told[r.citizenid] then
                    local target = Core.GetPlayerByCitizenId
                        and Core.GetPlayerByCitizenId(r.citizenid)
                    if target and target.source then
                        told[r.citizenid] = true
                        local mine = myTickets(session.id, r.citizenid)
                        local won, bestHits = 0, 0
                        for _, line in ipairs(mine) do
                            won = won + line.reward
                            if line.matches > bestHits then bestHits = line.matches end
                        end
                        TriggerClientEvent('v-phone:client:lotteryResult', target.source, {
                            session = session.id,
                            numbers = drawn,
                            reward = won,
                            matches = bestHits,
                            lines = #mine,
                        })
                    end
                end
            end
        end

        Wait(8000)
        Live = nil
        tellEveryone('v-phone:client:lotteryDraw', { kind = 'close' })
    end)

    return true
end

-- ══════════════════════════════════════════════════════════════
-- What the app asks for
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:lottery:open', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    -- doc-lottery mode: the app talks to it from the client, because its callbacks are QB server
    -- callbacks and only a client can reach one. All this has to say is who owns the answer.
    if docMode() then resolve({ ok = true, doc = true }) return end
    if not PhoneHasApp or not PhoneHasApp(src, 'lottery') then resolve({ error = 'noapp' }) return end

    local acting = PhoneActingSource and PhoneActingSource(src) or src
    local p = Core.GetPlayer(acting)
    if not p then resolve({ error = 'noplayer' }) return end
    resolve(payloadFor(src, p))
end)

V.Callback('v-phone:lottery:buy', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if docMode() then resolve({ error = 'viadoc' }) return end
    if not PhoneHasApp or not PhoneHasApp(src, 'lottery') then resolve({ error = 'noapp' }) return end

    local acting = PhoneActingSource and PhoneActingSource(src) or src
    local p = Core.GetPlayer(acting)
    if not p then resolve({ error = 'noplayer' }) return end
    resolve(buy(acting, p, data))
end)

--- Where the draw is, for an app opened in the middle of one.
V.Callback('v-phone:lottery:live', function(src, resolve)
    if not enabled() or docMode() or not Live then resolve({ ok = true, live = false }) return end
    local p = Core.GetPlayer(PhoneActingSource and PhoneActingSource(src) or src)
    local mine = p and Live.best[p.citizenid]

    -- The countdown is RECOMPUTED from when it ends, never replayed from the top: somebody opening
    -- the app with twelve seconds left must see twelve, not sixty.
    local countdown = nil
    if Live.countdownEndsAt then
        countdown = math.max(0, Live.countdownEndsAt - os.time())
        if countdown <= 0 then countdown = nil end
    end

    resolve({
        ok = true,
        live = true,
        jackpot = Live.jackpot,
        numberCount = Live.numberCount,
        countdown = countdown,
        started = Live.started,
        revealed = Live.revealed,
        result = Live.result,
        mine = mine and mine.numbers or {},
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Staff
-- ══════════════════════════════════════════════════════════════

local function isStaff(src)
    local ace = CFG.ace or (Config.Admin or {}).ace
    if not ace or ace == '' then return false end
    return IsPlayerAceAllowed(src, ace)
end

V.Callback('v-phone:lottery:admin', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if docMode() then resolve({ error = 'viadoc' }) return end
    if not isStaff(src) then resolve({ error = 'denied' }) return end

    local op = tostring((data and data.op) or '')

    if op == 'draw' then
        local ok, why = runDraw(GetPlayerName(src) or src)
        if not ok then resolve({ error = why or 'x' }) return end
        resolve({ ok = true })
        return
    end

    if op == 'jackpot' then
        local session = ensureSession()
        if not session then resolve({ error = 'nosession' }) return end
        if session.status ~= 'pending' then resolve({ error = 'drawing' }) return end
        local amount = math.floor(num(data and data.amount, 0))
        if amount == 0 then resolve({ error = 'args' }) return end
        -- Clamped at nought rather than allowed negative: a jackpot below zero would pay a winner
        -- a negative prize, which `AddMoney` would refuse and the app would report as a win.
        MySQL.update.await(
            'UPDATE `vphone_lottery_sessions` SET `jackpot` = GREATEST(0, `jackpot` + ?) WHERE `id` = ?',
            { amount, session.id })
        local fresh = openSession()
        V.Log(('lottery: %s changed the jackpot by %d'):format(tostring(GetPlayerName(src)), amount))
        resolve({ ok = true, jackpot = fresh and math.floor(num(fresh.jackpot, 0)) or nil })
        return
    end

    resolve({ error = 'x' })
end)

-- ══════════════════════════════════════════════════════════════
-- The scheduler
-- ══════════════════════════════════════════════════════════════
-- No catch-up, deliberately. A draw whose slot passed while the server was down is MISSED and
-- said so in the console: drawing four hours late is worse than not drawing, because the time
-- announced to players stops meaning anything.

CreateThread(function()
    if not enabled() then return end
    local lastFired = nil

    while true do
        Wait(30000)
        local auto = CFG.autoDraw or {}
        if enabled() and not docMode() and auto.enabled ~= false and ready then
            local t = localParts()
            local slot = ('%d-%d-%d-%d'):format(t.year, t.month, t.day, math.floor(num(auto.hour, 21)))
            local due = isDrawDay(t.wday)
                and t.hour == math.floor(num(auto.hour, 21))
                and t.min >= math.floor(num(auto.minute, 30))
                and t.min < math.floor(num(auto.minute, 30)) + math.max(1, math.floor(num(CFG.autoDrawWindow, 5)))

            if due and lastFired ~= slot then
                lastFired = slot
                local session = openSession()
                if session and session.status == 'pending' then
                    V.Log('lottery: automatic draw')
                    runDraw('auto')
                end
            end

            -- Keep the announced date current even between draws.
            refreshLabel(openSession())
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════

--- The public state of the lottery. Same idea as doc-lottery's `GetLotteryInfo`, so a dispatch
--- board or a news script can read whichever provider a server runs.
exports('GetLotteryState', function()
    if docMode() then
        -- Its own export, passed straight through rather than reimplemented: two functions
        -- answering the same question is how they start disagreeing.
        if GetResourceState('doc-lottery') == 'started' then
            local ok, info = pcall(function() return exports['doc-lottery']:GetLotteryInfo() end)
            if ok then return info end
        end
        return nil
    end
    local session = openSession()
    return {
        jackpot = session and math.floor(num(session.jackpot, 0)) or 0,
        status = session and session.status or 'pending',
        drawLabel = session and session.draw_label or nil,
        drawAt = nextDrawAt(),
        history = historyOf(),
        tiers = tiers(),
        ticketPrice = ticketPrice(),
    }
end)

--- Draw now, for a script or a console command of your own.
exports('RunLotteryDraw', function(by) return runDraw(by or 'export') end)
