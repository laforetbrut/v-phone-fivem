-- v-phone | server/export.lua
--
-- **The market board: what your haul is worth, and where the price is going.**
--
-- Two providers, one app, and the page never learns which one answered.
--
--   * **doc-shops**, when it is running. Its markets, its items, its fluctuating prices and its
--     five points of history, read through `exports['doc-shops']:GetMarketData(market)` - a
--     **server** export, which is the whole reason this file exists rather than a client bridge
--     like the other doc integrations. The phone's own server can read the board with no player
--     involved, so a price alert fires while the app is closed and its owner is in a field
--     somewhere. **Nothing in doc-shops is edited, wrapped or replaced.**
--   * **`Config.Export.items`** otherwise, which is what makes the app worth installing on an
--     ESX, ox or standalone server: the phone's own board, its own fluctuation, its own history.
--
-- **The app never sells anything.** It says what a thing is worth; selling happens at the shop,
-- in front of the person buying it. Nothing here moves an item or a dollar.
--
-- The poll is what makes the app more than a price list. doc-shops fluctuates every twenty
-- minutes and broadcasts nothing at all - its own phone app found out by being opened - so the
-- board is read on a timer, compared against the last reading, and every standing alert is
-- measured against the change.

local CFG = Config.Export or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

--- Is doc-shops the provider?
---
--- Asked per request rather than cached, so starting the resource mid-session works without
--- restarting the phone.
local function docMode()
    local want = tostring(CFG.provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-shops' then return true end
    return GetResourceState('doc-shops') == 'started'
end

--- The markets this server shows, in the order the operator wrote them.
local function markets()
    local out = {}
    for _, m in ipairs(CFG.markets or {}) do
        local key = tostring(type(m) == 'table' and m.key or m)
        if key ~= '' then
            local label = tostring((type(m) == 'table' and m.label) or key)
            out[#out + 1] = { key = key, label = label }
        end
    end
    if #out == 0 then out[1] = { key = 'export', label = 'ph.export_m_export' } end
    return out
end

local function knownMarket(key)
    for _, m in ipairs(markets()) do
        if m.key == key then return key end
    end
    return markets()[1].key
end

-- ══════════════════════════════════════════════════════════════
-- The board
-- ══════════════════════════════════════════════════════════════
-- One cache per market, refreshed by the poll below. Everything - the app, the alerts, the
-- export - reads THIS rather than asking the provider again, so twenty players opening the app
-- at once is still one read.

local Board = {}        -- [market] = { at, categories = { { key, label, items } } }
local Prev = {}         -- [market] = { [item] = the price at the previous poll }
local Moved = {}        -- [market] = os.time() of the last time ANY price changed
local Gap = {}          -- [market] = the measured seconds between the last two changes
local History = {}      -- [market] = { [item] = { price, ... } } oldest first
local ready = false

local function historyCap()
    return math.max(2, math.floor(num(CFG.history, 24)))
end

--- Remember where a price has been.
---
--- Kept in memory rather than a table of its own: it is a chart on a phone screen, not an audit
--- trail, and a restart losing it costs a line that redraws itself within the hour. doc-shops
--- already keeps five points in a real table, and those are used as the starting shape.
local function remember(market, name, price)
    History[market] = History[market] or {}
    local h = History[market][name]
    if not h then h = {} History[market][name] = h end
    -- Only when it actually moved. A flat line of forty identical points is not history, it is
    -- the poll interval drawn as a chart.
    if h[#h] ~= price then h[#h + 1] = price end
    while #h > historyCap() do table.remove(h, 1) end
end

--- doc-shops' board, in the shape the page already draws.
---
--- Its field names are its own - `current`, `minPrice`, `maxPrice`, `trend`, `history` - and
--- translating here rather than teaching the page two vocabularies is what keeps the app from
--- having to know which provider answered.
local function readDoc(market)
    if GetResourceState('doc-shops') ~= 'started' then return nil end

    local ok, data = pcall(function()
        return exports['doc-shops']:GetMarketData(market)
    end)
    if not ok or type(data) ~= 'table' or type(data.categories) ~= 'table' then return nil end

    local cats = {}
    for _, c in ipairs(data.categories) do
        local items = {}
        for _, it in ipairs(c.items or {}) do
            local name = tostring(it.name or '')
            if name ~= '' then
                local price = math.floor(num(it.current, 0))
                items[#items + 1] = {
                    name = name,
                    label = tostring(it.label or name),
                    -- **Its own picture URL, passed through untouched.** It builds
                    -- `nui://qs-inventory/html/images/<item>.png` and that is the URL that works
                    -- on a server running it - rebuilding one here from our own base would be
                    -- guessing at an inventory doc-shops already knows the answer for.
                    image = tostring(it.image or ''),
                    price = price,
                    min = math.floor(num(it.minPrice, 0)),
                    max = math.floor(num(it.maxPrice, 0)),
                    -- Its own five points first, so an item has a line the moment the phone is
                    -- installed rather than after an hour of watching.
                    history = type(it.history) == 'table' and it.history or nil,
                }
                remember(market, name, price)
            end
        end
        if #items > 0 then
            cats[#cats + 1] = {
                key = tostring(c.key or ''),
                label = tostring(c.label or c.key or ''),
                items = items,
            }
        end
    end
    if #cats == 0 then return nil end
    return { at = os.time(), categories = cats,
             shop = type(data.shop) == 'table' and tostring(data.shop.label or '') or '' }
end

-- ── The config provider's own board ────────────────────────────

local Prices = {}       -- [item] = the current price, config mode only

local function itemsOf()
    return CFG.items or {}
end

--- Where item pictures come from, for the config provider.
---
--- doc-shops builds its own - `nui://qs-inventory/html/images/<item>.png` - and that URL is
--- passed straight through rather than rebuilt, because it is the one its own app uses and it is
--- the one that works on that server. This is the same idea for everybody else.
local function imageBase()
    local base = tostring(CFG.imageBase or '')
    if base == '' then return '' end
    -- A trailing slash whether or not the operator wrote one: forgetting it produces
    -- `imagesgold.png`, which is a broken picture and a confusing thing to debug.
    if base:sub(-1) ~= '/' then base = base .. '/' end
    return base
end

local function fluctuate()
    for _, it in ipairs(itemsOf()) do
        local name = tostring(it.name or '')
        local lo, hi = math.floor(num(it.min, 0)), math.floor(num(it.max, 0))
        if name ~= '' and hi >= lo and hi > 0 then
            -- A new value in the range rather than a drift, which is what doc-shops does: a
            -- market that only ever creeps is one nobody watches.
            Prices[name] = math.random(lo, hi)
        end
    end
end

--- A label the operator wrote, resolved if it is one of ours.
---
--- **This is what put `ph.export_c_metal` on screen.** `Config.Export.categories` holds LOCALE
--- KEYS, because a category called "Metals" has to read "Métaux" for somebody playing in French -
--- and they were sent to the page as they were written. doc-shops sends finished text, the config
--- sends keys, and the page must not have to know which; so the resolving happens here.
---
--- `ph.` marks a phrase this resource ships. Anything else is the operator's own words and is
--- passed through untouched, which is how a server names a category the phone has never heard of.
local function phrase(src, value)
    value = tostring(value or '')
    return value:sub(1, 3) == 'ph.' and LP(src, value) or value
end

local function readConfig(market, src)
    local cats, byCat, order = {}, {}, {}
    local labels = CFG.categories or {}

    for _, it in ipairs(itemsOf()) do
        local name = tostring(it.name or '')
        local price = Prices[name]
        if name ~= '' and price then
            local key = tostring(it.category or 'general')
            if not byCat[key] then byCat[key] = {} order[#order + 1] = key end
            byCat[key][#byCat[key] + 1] = {
                name = name,
                label = tostring(it.label or name),
                -- Where the picture lives. `image` on the item wins; otherwise the base plus the
                -- item name, which is how every inventory in FiveM lays its images out. Empty
                -- leaves the row with its initial, which is what an unknown item looked like
                -- before there were any pictures at all.
                image = tostring(it.image or (imageBase() ~= '' and
                    (imageBase() .. name .. '.png') or '')),
                price = price,
                min = math.floor(num(it.min, 0)),
                max = math.floor(num(it.max, 0)),
            }
            remember(market, name, price)
        end
    end

    for _, key in ipairs(order) do
        cats[#cats + 1] = { key = key, label = phrase(src, labels[key] or key), items = byCat[key] }
    end
    if #cats == 0 then return nil end
    return { at = os.time(), categories = cats, shop = '' }
end

--- Read the board and work out what moved.
---
--- The comparison is the point: a price on its own is a number, and "up 12% since the last time
--- you looked" is the thing somebody acts on. Every item's previous value is kept so the arrow
--- and the alerts measure against the same reading.
local AlertsCheck        -- forward declaration; defined once the alert store exists

--- Who has the app open, and on which board.
---
--- **This is what makes the board live.** The poll runs whether or not anybody is looking, so
--- without a list of who is looking the only way to see a new price was to close the app and
--- open it again. A player is added when the app opens and dropped when it closes, so the push
--- costs nothing on a server where nobody has it open - which is almost always.
local Watching = {}      -- [src] = market

-- Declared here and defined below, because the push needs the countdown and the countdown needs
-- the reading that the push is part of. A forward declaration rather than a global: an
-- undeclared name would have been nil at call time and silently sent no countdown at all.
local nextChangeIn

local function pushMoved(market, moved)
    if #moved == 0 then return end

    -- Only what changed, and only the fields that can change. Sending the whole board every two
    -- minutes to everybody with the app open would be the reload flash with extra steps.
    local slim = {}
    for i, it in ipairs(moved) do
        slim[i] = {
            name = it.name, price = it.price, previous = it.previous,
            percent = it.percent, history = it.history,
        }
    end

    for src, m in pairs(Watching) do
        if m == market then
            TriggerClientEvent('v-phone:client:exportBoard', src, {
                market = market, items = slim,
                -- The clock is reset by the same push that carries the prices, so an open app
                -- never has to refetch just to start counting again.
                nextIn = nextChangeIn and select(1, nextChangeIn(market)) or nil,
            })
        end
    end
end

local function refresh(market, src)
    local board = docMode() and readDoc(market) or readConfig(market, src)
    if not board then return nil end

    local prev = Prev[market] or {}
    local now = {}
    local moved = {}

    for _, c in ipairs(board.categories) do
        for _, it in ipairs(c.items) do
            now[it.name] = it.price
            local was = prev[it.name]
            it.previous = was
            if was and was > 0 then
                it.change = it.price - was
                -- One decimal: a market board reading "+12.4%" is precise enough to act on and
                -- short enough to fit beside a price.
                it.percent = math.floor(((it.price - was) / was) * 1000 + 0.5) / 10
                if it.price ~= was then moved[#moved + 1] = it end
            end
            -- The line, as the page draws it: whatever the provider gave, then what has been
            -- watched since. One list, oldest first.
            it.history = (History[market] or {})[it.name] or it.history
        end
    end

    Prev[market] = now
    Board[market] = board

    -- **When does it move next?**
    --
    -- In config mode this is known exactly - it is our own timer. Under doc-shops it is not:
    -- its twenty-minute loop started when IT started and it publishes nothing at all, so the
    -- honest answer is a measurement rather than a guess. The gap between the last two times
    -- prices actually changed IS the interval, and it is right from the second change onward;
    -- until then the config's own figure stands in, which is doc-shops' own twenty minutes.
    --
    -- Sent to the page marked as an estimate under doc-shops, because a countdown that claims to
    -- be exact and is thirty seconds out is worse than one that admits it is approximate.
    if #moved > 0 then
        local was = Moved[market]
        if was and os.time() - was > 5 then Gap[market] = os.time() - was end
        Moved[market] = os.time()
    end

    if #moved > 0 and AlertsCheck then AlertsCheck(market, moved) end
    pushMoved(market, moved)
    return board
end

--- Seconds until the next change, or nil when there is nothing to base one on.
function nextChangeIn(market)
    local last = Moved[market]
    if not last then return nil end
    local gap = Gap[market] or math.max(30, math.floor(num(CFG.fluctuateSeconds, 1200)))
    local left = (last + gap) - os.time()
    -- A countdown that has run out sits at zero rather than going negative: the change is due,
    -- and the next poll will find it. Negative seconds on a screen read as a broken clock.
    return math.max(0, left), gap
end

-- ══════════════════════════════════════════════════════════════
-- What a player has asked to be told about
-- ══════════════════════════════════════════════════════════════

CreateThread(function()
    if not enabled() then return end

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_export_watch` (
        `citizenid` VARCHAR(64) NOT NULL,
        `market`    VARCHAR(24) NOT NULL,
        `item`      VARCHAR(64) NOT NULL,
        `at`        INT UNSIGNED NOT NULL,
        PRIMARY KEY (`citizenid`, `market`, `item`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- `kind` is 'above', 'below' or 'move'; `value` is a price for the first two and a
    -- percentage for the third. `armed` is what stops a price sitting just over the line from
    -- buzzing on every single poll.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_export_alerts` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(64) NOT NULL,
        `market`    VARCHAR(24) NOT NULL,
        `item`      VARCHAR(64) NOT NULL,
        `kind`      VARCHAR(8) NOT NULL DEFAULT 'above',
        `value`     INT NOT NULL DEFAULT 0,
        `armed`     TINYINT(1) NOT NULL DEFAULT 1,
        `fired_at`  INT UNSIGNED NOT NULL DEFAULT 0,
        `at`        INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        KEY `citizenid` (`citizenid`),
        KEY `item` (`market`, `item`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    if not docMode() then fluctuate() end

    -- One reading before anybody can open the app, so the first person in does not see an
    -- empty board while the first poll is still a minute away.
    --
    -- No source to resolve phrases against on the boot pass or on the poll, so category names
    -- come out in the server's default language. `open` re-reads them per player below, which is
    -- the only place a language is actually known.
    for _, m in ipairs(markets()) do refresh(m.key) end
    ready = true

    -- The poll. Everything the app shows comes from here, so this loop IS the app: twenty
    -- players opening it at once is still one read of the provider.
    local every = math.max(15, math.floor(num(CFG.pollSeconds, 120)))
    local flux = math.max(30, math.floor(num(CFG.fluctuateSeconds, 1200)))
    local since = 0

    while true do
        Wait(every * 1000)
        if not docMode() then
            since = since + every
            if since >= flux then since = 0 fluctuate() end
        end
        for _, m in ipairs(markets()) do refresh(m.key) end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Alerts
-- ══════════════════════════════════════════════════════════════

--- Has this alert come true?
---
--- Split out so the rule is one readable thing rather than three branches inside a loop, and so
--- the test can put a price against it directly.
local function alertHit(kind, value, price, previous)
    if kind == 'above' then return price >= value end
    if kind == 'below' then return price <= value end
    if kind == 'move' then
        if not previous or previous <= 0 or value <= 0 then return false end
        local pct = math.abs((price - previous) / previous) * 100
        return pct >= value
    end
    return false
end

--- Every standing alert on the items that moved.
---
--- Only the items that MOVED, which is the difference between one query per poll and one per
--- item per poll. An alert on something that did not change cannot have come true - except a
--- `move` alert, which is about the change itself and so is doubly true.
AlertsCheck = function(market, moved)
    if not enabled() then return end

    local names, byName = {}, {}
    for _, it in ipairs(moved) do
        names[#names + 1] = it.name
        byName[it.name] = it
    end

    -- Built rather than passed as a list, because oxmysql has no array binding and a hand-built
    -- IN clause on values that came from a config is the honest way to do this.
    local marks = {}
    for i = 1, #names do marks[i] = '?' end
    local args = { market }
    for _, n in ipairs(names) do args[#args + 1] = n end

    local rows = MySQL.query.await(([[SELECT id, citizenid, item, kind, value, armed, fired_at
        FROM vphone_export_alerts WHERE market = ? AND item IN (%s)]])
        :format(table.concat(marks, ',')), args) or {}
    if #rows == 0 then return end

    local now = os.time()
    local cool = math.max(0, math.floor(num(CFG.alertCooldown, 1800)))
    local rearm = CFG.alertRearm ~= false
    local keep = CFG.alertKeep ~= false

    for _, r in ipairs(rows) do
        local it = byName[r.item]
        local hit = it and alertHit(tostring(r.kind), math.floor(num(r.value, 0)),
                                    it.price, it.previous) or false

        if not hit then
            -- Back the other side of the line: the alert may sound again next time it crosses.
            if rearm and math.floor(num(r.armed, 1)) == 0 then
                MySQL.update('UPDATE vphone_export_alerts SET armed = 1 WHERE id = ?', { r.id })
            end
        elseif (rearm and math.floor(num(r.armed, 1)) == 0)
            or (now - math.floor(num(r.fired_at, 0))) < cool then
            -- True, but it has already been said. A price that sits just over the line would
            -- otherwise buzz on every poll for as long as it stays there, which is how somebody
            -- ends up muting the app and missing the one that mattered.
        else
            if keep then
                MySQL.update(
                    'UPDATE vphone_export_alerts SET armed = 0, fired_at = ? WHERE id = ?',
                    { now, r.id })
            else
                MySQL.update('DELETE FROM vphone_export_alerts WHERE id = ?', { r.id })
            end

            -- Only if they are here. An alert for somebody offline is not queued: a price that
            -- was worth telling them about an hour ago has moved again by the time they log in,
            -- and a stale price is worse than none.
            local p = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(r.citizenid)
            if p and p.source and CFG.notify ~= false then
                TriggerClientEvent('v-phone:client:exportAlert', p.source, {
                    market = market,
                    item = it.name,
                    label = it.label,
                    kind = tostring(r.kind),
                    value = math.floor(num(r.value, 0)),
                    price = it.price,
                    percent = it.percent,
                })
            end
        end
    end
end

-- ══════════════════════════════════════════════════════════════
-- What the app asks for
-- ══════════════════════════════════════════════════════════════

--- Everything the app draws, in one answer.
---
--- One round trip on purpose: three tabs over the same board, and asking again per tab is how a
--- phone gets the reload flash this resource spent an audit removing.
V.Callback('v-phone:export:open', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if not ready then resolve({ error = 'wait' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local market = knownMarket(tostring((data and data.market) or ''))
    local board = Board[market]
    if not board then resolve({ error = 'noboard' }) return end

    -- From now until they close it, this player is told when a price moves.
    Watching[src] = market

    -- The categories, named in THIS player's language. The cached board holds whatever the poll
    -- resolved them to, which is the server's default; a phone set to English on a French server
    -- would otherwise read the operator's French. Copied rather than edited in place, because
    -- the cache is shared and rewriting it would give the next player the previous one's
    -- language.
    local cats = {}
    for i, c in ipairs(board.categories) do
        cats[i] = { key = c.key, label = phrase(src, c.label), items = c.items }
    end

    local watch = {}
    for _, r in ipairs(MySQL.query.await(
        'SELECT item FROM vphone_export_watch WHERE citizenid = ? AND market = ?',
        { p.citizenid, market }) or {}) do
        watch[r.item] = true
    end

    local alerts = {}
    for _, r in ipairs(MySQL.query.await([[SELECT id, market, item, kind, value, armed
        FROM vphone_export_alerts WHERE citizenid = ? ORDER BY id DESC]], { p.citizenid }) or {}) do
        alerts[#alerts + 1] = {
            id = math.floor(num(r.id, 0)),
            market = tostring(r.market or ''),
            item = tostring(r.item or ''),
            kind = tostring(r.kind or 'above'),
            value = math.floor(num(r.value, 0)),
            armed = math.floor(num(r.armed, 1)) == 1,
        }
    end

    resolve({
        ok = true,
        doc = docMode(),
        market = market,
        markets = markets(),
        shop = board.shop,
        at = board.at,
        categories = cats,
        -- The countdown, and whether it can be trusted to the second.
        nextIn = select(1, nextChangeIn(market)),
        interval = select(2, nextChangeIn(market)),
        estimated = docMode(),
        watch = watch,
        alerts = alerts,
        kinds = {
            above = (CFG.alerts or {}).above ~= false,
            below = (CFG.alerts or {}).below ~= false,
            move = (CFG.alerts or {}).move ~= false,
        },
        maxWatch = math.floor(num(CFG.maxFavourites, 24)),
        maxAlerts = math.floor(num(CFG.maxAlerts, 12)),
        every = math.max(15, math.floor(num(CFG.pollSeconds, 120))),
    })
end)

--- Star an item, or unstar it.
V.Callback('v-phone:export:watch', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local market = knownMarket(tostring((data and data.market) or ''))
    local item = tostring((data and data.item) or ''):sub(1, 64)
    if item == '' then resolve({ error = 'args' }) return end

    if data and data.on == false then
        MySQL.update.await(
            'DELETE FROM vphone_export_watch WHERE citizenid = ? AND market = ? AND item = ?',
            { p.citizenid, market, item })
        resolve({ ok = true, on = false })
        return
    end

    -- Counted before it is written, and the cap is the config's: a hundred favourites is the
    -- whole board again with extra steps.
    local have = math.floor(num(MySQL.scalar.await(
        'SELECT COUNT(*) FROM vphone_export_watch WHERE citizenid = ?', { p.citizenid }), 0))
    if have >= math.floor(num(CFG.maxFavourites, 24)) then
        resolve({ error = 'toomany' })
        return
    end

    MySQL.query.await([[INSERT IGNORE INTO vphone_export_watch (citizenid, market, item, at)
        VALUES (?,?,?,?)]], { p.citizenid, market, item, os.time() })
    resolve({ ok = true, on = true })
end)

--- Set an alert, or drop one.
V.Callback('v-phone:export:alert', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    -- Dropping one is keyed on the CHARACTER as well as the id, so this can only ever remove
    -- your own however the id was arrived at.
    local drop = math.floor(num(data and data.remove, 0))
    if drop > 0 then
        MySQL.update.await('DELETE FROM vphone_export_alerts WHERE id = ? AND citizenid = ?',
            { drop, p.citizenid })
        resolve({ ok = true, removed = true })
        return
    end

    local market = knownMarket(tostring((data and data.market) or ''))
    local item = tostring((data and data.item) or ''):sub(1, 64)
    local kind = tostring((data and data.kind) or 'above')
    local value = math.floor(num(data and data.value, 0))

    if item == '' then resolve({ error = 'args' }) return end
    if (CFG.alerts or {})[kind] == false then resolve({ error = 'kind' }) return end
    if kind ~= 'above' and kind ~= 'below' and kind ~= 'move' then
        resolve({ error = 'kind' })
        return
    end
    -- A percentage over a hundred is not a swing anybody is waiting for, and a price of zero is
    -- an alert that fires on the next poll and every one after it.
    if value <= 0 or (kind == 'move' and value > 100) then resolve({ error = 'value' }) return end

    local have = math.floor(num(MySQL.scalar.await(
        'SELECT COUNT(*) FROM vphone_export_alerts WHERE citizenid = ?', { p.citizenid }), 0))
    if have >= math.floor(num(CFG.maxAlerts, 12)) then resolve({ error = 'toomany' }) return end

    local id = MySQL.insert.await([[INSERT INTO vphone_export_alerts
        (citizenid, market, item, kind, value, armed, at) VALUES (?,?,?,?,?,1,?)]],
        { p.citizenid, market, item, kind, value, os.time() })
    if not id then resolve({ error = 'x' }) return end

    resolve({ ok = true, id = math.floor(id) })
end)

--- The app was closed, so stop pushing prices at it.
---
--- A net event rather than a callback: there is nothing to answer, and a player whose game shut
--- down mid-frame never sends it - which is what the disconnect below is for.
RegisterNetEvent('v-phone:export:leave', function()
    Watching[source] = nil
end)

AddEventHandler('playerDropped', function()
    Watching[source] = nil
end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════

--- The board as the phone last read it, for a price sign in the world or a news ticker.
---
--- Answers under BOTH providers, unlike the other apps' exports, because this one is not a
--- second source of truth: under doc-shops it is a cached copy of that resource's own answer,
--- and saying so is more useful than answering nil to a script that only wants a number.
exports('GetExportMarket', function(market)
    if not enabled() or not ready then return nil end
    local board = Board[knownMarket(tostring(market or ''))]
    if not board then return nil end
    return { at = board.at, shop = board.shop, categories = board.categories, doc = docMode() }
end)

--- One item's price, which is the question most callers actually have.
exports('GetExportPrice', function(item, market)
    if not enabled() or not ready then return nil end
    local board = Board[knownMarket(tostring(market or ''))]
    if not board then return nil end
    item = tostring(item or '')
    for _, c in ipairs(board.categories) do
        for _, it in ipairs(c.items) do
            if it.name == item then return it.price, it end
        end
    end
    return nil
end)

-- ══════════════════════════════════════════════════════════════
-- The home screen widget
-- ══════════════════════════════════════════════════════════════
-- The biggest mover on the player's market. **No query and no provider call**: the board is
-- already in memory, refreshed by the poll above, and that is the entire point of the cache -
-- twenty phones drawing this tile is twenty table reads.
WidgetSource('export', 'export', function(src)
    if not enabled() or not ready then return { ok = false } end
    -- Whichever market they last had open, else the first one configured. Watching[src] is set
    -- when the app opens and cleared when it closes, so this follows the player without asking.
    local market = knownMarket(tostring(Watching[src] or ''))
    local board = Board[market]
    if not board then return { ok = false } end

    -- One pass for the largest absolute move, up or down. Absolute rather than signed: a
    -- market that has fallen twelve percent is exactly as worth knowing about as one that rose.
    --
    -- **And a headline for when nothing has moved at all**, which is the ordinary state of this
    -- board rather than the exception: `percent` is only non-zero when a price changed between
    -- the last two polls, and under doc-shops those are twenty minutes apart. The widget used
    -- to say "nothing has moved" and stop there, so on most servers it never showed a price at
    -- all. The dearest item is the fallback - it is stable, it is the one worth running, and it
    -- is a real answer rather than an apology.
    local top, best = nil, 0
    local head, dearest = nil, -1
    local moved = 0
    for _, c in ipairs(board.categories) do
        for _, it in ipairs(c.items) do
            local pct = tonumber(it.percent)
            if pct and pct ~= 0 then
                moved = moved + 1
                if math.abs(pct) > best then best = math.abs(pct); top = it end
            end
            local price = tonumber(it.price) or 0
            if price > dearest then dearest = price; head = it end
        end
    end
    -- The mover if there is one, the headline otherwise.
    top = top or head

    local out = { ok = true, market = market, moved = moved,
                  shop = WidgetText(board.shop, 28),
                  nextIn = select(1, nextChangeIn(market)),
                  estimated = docMode() or nil }
    if top then
        out.item = WidgetText(phrase(src, top.label or top.name), 24)
        out.price = math.floor(tonumber(top.price) or 0)
        -- Sent only when it is a real movement. A headline item carries no percent, and the
        -- page draws the difference rather than printing a confident "0%".
        local pct = tonumber(top.percent)
        out.percent = (pct and pct ~= 0) and pct or nil
    end
    return out
end)
