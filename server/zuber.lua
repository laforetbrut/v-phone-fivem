-- v-phone | server/zuber.lua
--
-- **Zuber: food, ordered from the phone.**
--
-- Two providers, one app. Which one answers is decided at runtime and the page never knows:
--
--   * **doc-restaurant**, when it is running. Its restaurants, its menus, its prices, its
--     loyalty scheme, its orders. That side is driven from client/zuber.lua, because what
--     doc-restaurant publishes is a set of QB *server callbacks* - reachable from any client
--     and from no server - so this file deliberately does not touch it beyond READING its
--     order table for the history the original app never showed. Nothing here writes to a
--     doc-restaurant table, calls into it, or replaces any part of it.
--   * **`Config.Zuber.restaurants`** otherwise, which is what makes the app worth installing
--     on an ESX, ox or standalone server where doc-restaurant does not exist. Its own menu, its
--     own orders table, its own money path.
--
-- Everything money and stock is decided here in config mode:
--
--   * the price of a line is read from the config, never from the page - a client that sends
--     `price = 1` is ignored, and the total is recomputed from scratch;
--   * the debit goes through `Bridge.RemoveMoney`, which fails closed, and the restaurant is
--     only credited once the debit is confirmed;
--   * an order that cannot be credited to the restaurant still stands, because the customer
--     has already paid and refusing the food would be taking their money for nothing.
--
-- The courier side is deliberately absent. doc-restaurant already delivers with its own staff,
-- its own statuses and its own commission, and a second thing moving those statuses is how two
-- systems start disagreeing about who is bringing the food.

local CFG = Config.Zuber or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

--- Is doc-restaurant the provider?
---
--- Asked on every request rather than cached: an operator who starts the resource mid-session
--- should not have to restart the phone as well.
local function docMode()
    local want = tostring(CFG.provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-restaurant' then return true end
    return GetResourceState('doc-restaurant') == 'started'
end

-- ══════════════════════════════════════════════════════════════
-- The config provider
-- ══════════════════════════════════════════════════════════════

local function restaurants()
    return type(CFG.restaurants) == 'table' and CFG.restaurants or {}
end

local function restaurantById(id)
    id = tostring(id or '')
    for _, r in ipairs(restaurants()) do
        if tostring(r.id) == id then return r end
    end
    return nil
end

--- Is this restaurant taking orders?
---
--- `open` may be a boolean or a pair of hours. Hours are read from the server clock, so every
--- customer agrees about whether the place is shut - a client-side clock would not.
local function isOpen(r)
    local open = r.open
    if open == nil then return true end
    if type(open) == 'boolean' then return open end
    if type(open) == 'table' then
        local from, to = math.floor(num(open.from, 0)), math.floor(num(open.to, 24))
        local hour = tonumber(os.date('%H')) or 0
        if from == to then return true end
        -- A window that crosses midnight is the normal case for a late-night place.
        if from < to then return hour >= from and hour < to end
        return hour >= from or hour < to
    end
    return true
end

--- One menu line, priced by the server. The page sends an item id and a quantity; everything
--- else about that line is looked up here.
local function menuItem(r, item)
    item = tostring(item or '')
    for _, line in ipairs(r.menu or {}) do
        if tostring(line.item) == item then return line end
    end
    return nil
end

local function menuFor(r)
    local out = {}
    for _, line in ipairs(r.menu or {}) do
        out[#out + 1] = {
            item = tostring(line.item),
            label = tostring(line.label or line.item),
            price = math.max(0, math.floor(num(line.price, 0))),
            category = tostring(line.category or 'mains'),
            -- A line the operator switched off stays listed and unbuyable, which reads as
            -- "sold out" rather than as a menu that changes shape.
            enabled = line.enabled ~= false,
        }
    end
    return out
end

local function cardFor(r)
    return {
        id = tostring(r.id),
        label = tostring(r.label or r.id),
        job = r.job and tostring(r.job) or nil,
        tint = r.tint and tostring(r.tint) or nil,
        tags = r.tags or {},
        open = isOpen(r),
        delivery = r.delivery ~= false,
        takeaway = r.takeaway ~= false,
        eta = math.max(1, math.floor(num(r.eta, num(CFG.etaMinutes, 12)))),
        -- The position travels: a restaurant is a published place, and routing to one is the
        -- point of the button.
        x = r.coords and (tonumber(r.coords.x) or tonumber(r.coords[1])) or nil,
        y = r.coords and (tonumber(r.coords.y) or tonumber(r.coords[2])) or nil,
        menu = menuFor(r),
    }
end

-- ══════════════════════════════════════════════════════════════
-- Storage
-- ══════════════════════════════════════════════════════════════

CreateThread(function()
    if not enabled() then return end
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_zuber_orders` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(60) NOT NULL,
        `restaurant` VARCHAR(60) NOT NULL,
        `label`     VARCHAR(80) NOT NULL DEFAULT '',
        `kind`      VARCHAR(12) NOT NULL DEFAULT 'delivery',
        `items`     TEXT,
        `total`     INT NOT NULL DEFAULT 0,
        `fee`       INT NOT NULL DEFAULT 0,
        `tip`       INT NOT NULL DEFAULT 0,
        `note`      VARCHAR(200) NOT NULL DEFAULT '',
        `status`    VARCHAR(16) NOT NULL DEFAULT 'pending',
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `citizenid` (`citizenid`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])
end)

local function favouritesOf(p)
    local m = p.GetMetadata and p.GetMetadata('zuber')
    if type(m) ~= 'table' or type(m.favourites) ~= 'table' then return {} end
    return m.favourites
end

local function saveFavourites(p, list)
    local cap = math.max(1, math.floor(num(CFG.favourites, 20)))
    while #list > cap do table.remove(list) end
    p.SetMetadata('zuber', { favourites = list })
end

local function historyLimit()
    return math.max(1, math.min(50, math.floor(num(CFG.history, 20))))
end

--- The customer's own orders, newest first.
---
--- In doc-restaurant mode this READS its order table and nothing more. That table is the only
--- record of what somebody ordered, the original app never showed it back to them, and a
--- read cannot break a system - which is the whole reason the history is done this way rather
--- than by keeping a second copy of every order.
local function historyOf(cid)
    if docMode() then
        local ok, rows = pcall(function()
            return MySQL.query.await([[SELECT id, job AS restaurant, type AS kind, items,
                    total_price AS total, status, order_comment AS note,
                    UNIX_TIMESTAMP(created_at) AS ts
                FROM doc_restaurant_orders WHERE citizenid = ?
                ORDER BY id DESC LIMIT ?]], { cid, historyLimit() })
        end)
        if ok and type(rows) == 'table' then return rows, true end
        return {}, true
    end

    local rows = MySQL.query.await([[SELECT id, restaurant, label, kind, items, total, fee, tip,
            note, status, UNIX_TIMESTAMP(at) AS ts
        FROM vphone_zuber_orders WHERE citizenid = ? ORDER BY id DESC LIMIT ?]],
        { cid, historyLimit() }) or {}
    return rows, false
end

--- The one order still on its way, if there is one. What the tracker at the top of the app is.
local function activeOf(cid)
    local rows = historyOf(cid)
    for _, r in ipairs(rows) do
        local status = tostring(r.status or '')
        if status ~= 'completed' and status ~= 'delivered' and status ~= 'cancelled' then
            return r
        end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Moving an order along
-- ══════════════════════════════════════════════════════════════
-- Config mode only. doc-restaurant moves its own orders with its own tablet, and this never
-- touches those.
--
-- The steps run on a timer because there is nobody to press a button: a server with no
-- restaurant script has no kitchen staff, and an order that stays "pending" for ever is worse
-- than one that cooks itself. A server that DOES have staff drives it with the export below
-- instead, and then the timer never fires - `SetZuberStatus` cancels it.

local Timed = {}      -- [order id] = true while the automatic run still owns it

local STEPS = { 'accepted', 'preparing', 'delivering', 'completed' }

local function tellCustomer(cid, order, status)
    local p = Core.GetPlayerByCitizenId(cid)
    if not p or not p.source then return end
    TriggerClientEvent('v-phone:client:zuber', p.source, {
        id = order.id,
        restaurant = order.label ~= '' and order.label or order.restaurant,
        status = status,
        sound = CFG.sound ~= false,
    })
end

local function setStatus(id, status, cid)
    id = math.floor(num(id, 0))
    if id <= 0 then return false end
    MySQL.update('UPDATE vphone_zuber_orders SET status = ? WHERE id = ?', { status, id })
    if cid then
        tellCustomer(cid, { id = id, restaurant = '', label = '' }, status)
    end
    return true
end

--- Walk one order through the steps, telling the customer at each one.
local function runOrder(id, cid, label)
    if CFG.autoStatus == false then return end
    Timed[id] = true
    local minutes = math.max(0.2, num(CFG.etaMinutes, 12))
    -- Spread across the ETA rather than a fixed delay per step, so a place that says twelve
    -- minutes takes about twelve minutes.
    local step = math.floor((minutes * 60 * 1000) / #STEPS)
    for i, status in ipairs(STEPS) do
        SetTimeout(step * i, function()
            if not Timed[id] then return end       -- somebody else took it over
            if i == #STEPS then Timed[id] = nil end
            MySQL.update('UPDATE vphone_zuber_orders SET status = ? WHERE id = ?', { status, id })
            tellCustomer(cid, { id = id, restaurant = label, label = label }, status)
        end)
    end
end

-- ══════════════════════════════════════════════════════════════
-- What the app asks for
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:zuber:open', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    -- In doc-restaurant mode the restaurants come from IT, through the client, so this answers
    -- only the parts doc-restaurant does not keep: favourites, and the history read above.
    -- `only` and `showClosed` filter the list HERE, so a restaurant an operator withheld is not
    -- merely hidden by the page - it never reaches it, and an order naming it is refused below.
    local only = {}
    local onlySome = false
    for _, id in ipairs(CFG.only or {}) do only[tostring(id)] = true onlySome = true end

    local list = {}
    if not docMode() then
        for _, r in ipairs(restaurants()) do
            local shown = r.enabled ~= false
            if shown and onlySome and not only[tostring(r.id)] then shown = false end
            if shown and CFG.showClosed == false and not isOpen(r) then shown = false end
            if shown then list[#list + 1] = cardFor(r) end
        end
    end

    local history, fromDoc = historyOf(p.citizenid)
    resolve({
        ok = true,
        doc = docMode(),
        restaurants = list,
        favourites = favouritesOf(p),
        history = history,
        active = activeOf(p.citizenid),
        fee = math.max(0, math.floor(num(CFG.deliveryFee, 0))),
        tax = math.max(0, num(CFG.taxPercent, 0)),
        tip = {
            on = (CFG.tip or {}).enabled ~= false,
            presets = (CFG.tip or {}).presets or { 0, 5, 10, 15 },
            max = math.max(0, math.floor(num((CFG.tip or {}).max, 500))),
        },
        min = math.max(1, math.floor(num(CFG.minOrder, 1))),
        max = math.max(0, math.floor(num(CFG.maxOrder, 0))),
        money = tostring(CFG.account or 'bank'),
        -- The feature switches, so the page draws only what the operator left on. Sent rather
        -- than read from the config on the page: the config is not the page's to see.
        features = type(CFG.features) == 'table' and CFG.features or {},
        sortByDistance = CFG.sortByDistance == true,
        -- Whether the history came from doc-restaurant, so the app can say where it is looking.
        historyFromDoc = fromDoc,
    })
end)

--- Order, in config mode. doc-restaurant's own order path is untouched and goes through its
--- own callback from the client.
V.Callback('v-phone:zuber:order', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if docMode() then resolve({ error = 'viadoc' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local r = restaurantById(data and data.restaurant)
    if not r or r.enabled == false then resolve({ error = 'noresto' }) return end
    -- The same withholding as the list: a restaurant left out of `only` cannot be ordered from
    -- by a request that names it directly either.
    if type(CFG.only) == 'table' and #CFG.only > 0 then
        local allowed = false
        for _, id in ipairs(CFG.only) do
            if tostring(id) == tostring(r.id) then allowed = true break end
        end
        if not allowed then resolve({ error = 'noresto' }) return end
    end
    if not isOpen(r) then resolve({ error = 'closed' }) return end

    local kind = (data and data.kind == 'takeaway') and 'takeaway' or 'delivery'
    if kind == 'delivery' and r.delivery == false then resolve({ error = 'nodelivery' }) return end
    if kind == 'takeaway' and r.takeaway == false then resolve({ error = 'notakeaway' }) return end

    -- One open order at a time. Two orders in flight is two trackers and one customer.
    if activeOf(p.citizenid) then resolve({ error = 'pending' }) return end

    -- **The basket is priced here, from the config.** Whatever the page said an item costs is
    -- read and thrown away: it sends an id and a quantity, and nothing else about a line is
    -- believed. Anything else is a menu the customer writes themselves.
    local lines, total, count = {}, 0, 0
    for _, raw in ipairs((data and data.items) or {}) do
        local line = menuItem(r, raw and raw.item)
        local qty = math.floor(num(raw and raw.qty, 0))
        if line and line.enabled ~= false and qty > 0 then
            qty = math.min(qty, math.max(1, math.floor(num(CFG.maxPerLine, 20))))
            local price = math.max(0, math.floor(num(line.price, 0)))
            total = total + price * qty
            count = count + qty
            lines[#lines + 1] = { item = tostring(line.item),
                                  label = tostring(line.label or line.item),
                                  qty = qty, price = price }
        end
    end
    if count <= 0 then resolve({ error = 'empty' }) return end

    local fee = (kind == 'delivery') and math.max(0, math.floor(num(CFG.deliveryFee, 0))) or 0
    local tax = math.floor(total * math.max(0, num(CFG.taxPercent, 0)) / 100)

    -- The tip is the customer's, and bounded: a page asking to tip a million is a page asking
    -- to empty an account by accident.
    local tip = 0
    if (CFG.tip or {}).enabled ~= false then
        tip = math.max(0, math.floor(num(data and data.tip, 0)))
        tip = math.min(tip, math.max(0, math.floor(num((CFG.tip or {}).max, 500))))
    end

    local charge = total + fee + tax + tip
    if charge < math.max(1, math.floor(num(CFG.minOrder, 1))) then resolve({ error = 'toosmall' }) return end
    local ceiling = math.max(0, math.floor(num(CFG.maxOrder, 0)))
    if ceiling > 0 and charge > ceiling then resolve({ error = 'toobig' }) return end

    -- The customer pays first, and it fails closed.
    local purse = tostring(CFG.account or 'bank')
    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not Bridge.RemoveMoney(acting, charge, purse) then
        resolve({ error = 'nomoney', price = charge })
        return
    end

    -- Then the restaurant is paid. A society account that will not take it is logged and the
    -- order still stands: the customer has paid, and refusing them the food as well would be
    -- taking their money for nothing.
    local account = r.account or r.job
    if CFG.paySociety ~= false and account and Bridge.AddSociety then
        local landed = Bridge.AddSociety(tostring(account), total + tax,
            ('v-phone: Zuber order by %s'):format(p.name or p.citizenid))
        if not landed then
            V.Log(('zuber: could not credit "%s" with %d - check the account exists')
                :format(tostring(account), total + tax))
        end
    end

    local id = MySQL.insert.await([[INSERT INTO vphone_zuber_orders
        (citizenid, restaurant, label, kind, items, total, fee, tip, note, status)
        VALUES (?,?,?,?,?,?,?,?,?,'pending')]], {
        p.citizenid, tostring(r.id), tostring(r.label or r.id), kind,
        json.encode(lines), total + tax, fee, tip,
        tostring((data and data.note) or ''):gsub('[%c]', ''):sub(1, 200),
    })
    if not id then
        -- Nothing was recorded, so nothing was ordered: give the money back.
        Bridge.AddMoney(acting, charge, purse, 'v-phone: Zuber order failed')
        resolve({ error = 'x' })
        return
    end

    -- The restaurant's staff are told, when there are any on duty. A notification rather than
    -- a queue: this app does not have a kitchen screen, and pretending otherwise would be a
    -- second half-built restaurant system next to whatever the server already runs.
    if CFG.notifyStaff ~= false and r.job then
        local self = exports[GetCurrentResourceName()]
        for _, raw in ipairs(GetPlayers()) do
            local other = tonumber(raw)
            local op = other and Core.GetPlayer(other)
            local job = op and op.job
            if type(job) == 'table' and tostring(job.name) == tostring(r.job)
                and job.onDuty ~= false then
                pcall(function()
                    self:Notify(other, 'zuber', LP(other, 'ph.zuber_staff_title'),
                        (LP(other, 'ph.zuber_staff_body') or '%s'):format(tostring(count)))
                end)
            end
        end
    end

    runOrder(id, p.citizenid, tostring(r.label or r.id))
    Core.Log('zuber', ('%s ordered %d item(s) from %s for %d')
        :format(p.name or p.citizenid, count, tostring(r.id), charge), nil, p.citizenid)

    resolve({ ok = true, id = id, total = total + tax, fee = fee, tip = tip, charge = charge,
              eta = math.max(1, math.floor(num(r.eta, num(CFG.etaMinutes, 12)))) })
end)

--- A restaurant, or a dish, kept for next time. Stored against the character, so it survives
--- a relog and follows them rather than the handset.
V.Callback('v-phone:zuber:favourite', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local key = tostring((data and data.key) or ''):sub(1, 80)
    if key == '' then resolve({ error = 'x' }) return end

    local list, found = favouritesOf(p), false
    local out = {}
    for _, existing in ipairs(list) do
        if tostring(existing) == key then found = true else out[#out + 1] = existing end
    end
    if not found then table.insert(out, 1, key) end
    saveFavourites(p, out)
    resolve({ ok = true, on = not found, favourites = out })
end)

--- Where a restaurant is. Config mode only: in doc-restaurant mode the coordinates come down
--- with its own payload and the client sets the waypoint from those.
V.Callback('v-phone:zuber:locate', function(src, resolve, data)
    local r = restaurantById(data and data.restaurant)
    if not r or not r.coords then resolve({ error = 'noresto' }) return end
    resolve({ ok = true,
              x = tonumber(r.coords.x) or tonumber(r.coords[1]),
              y = tonumber(r.coords.y) or tonumber(r.coords[2]) })
end)

-- ══════════════════════════════════════════════════════════════
-- For other scripts
-- ══════════════════════════════════════════════════════════════
-- A restaurant script of your own - on ESX, on ox, anywhere doc-restaurant is not - can drive
-- Zuber's orders rather than reimplementing a phone app. See API.md.

--- Move an order along, and tell the customer. Taking over cancels the automatic run, so a
--- server with real staff never has an order cooking itself behind their back.
exports('SetZuberStatus', function(id, status, citizenid)
    id = math.floor(num(id, 0))
    status = tostring(status or '')
    if id <= 0 or status == '' then return false end
    Timed[id] = nil
    local cid = citizenid
    if not cid then
        cid = MySQL.scalar.await('SELECT citizenid FROM vphone_zuber_orders WHERE id = ?', { id })
    end
    return setStatus(id, status, cid)
end)

--- Every order still in flight, for a kitchen screen of your own.
exports('GetZuberOrders', function(restaurant)
    if restaurant then
        return MySQL.query.await([[SELECT * FROM vphone_zuber_orders
            WHERE restaurant = ? AND status NOT IN ('completed','cancelled')
            ORDER BY id ASC]], { tostring(restaurant) }) or {}
    end
    return MySQL.query.await([[SELECT * FROM vphone_zuber_orders
        WHERE status NOT IN ('completed','cancelled') ORDER BY id ASC]]) or {}
end)

--- What the app would show, so a script can offer the same menu somewhere else.
exports('GetZuberRestaurants', function()
    local out = {}
    for _, r in ipairs(restaurants()) do
        if r.enabled ~= false then out[#out + 1] = cardFor(r) end
    end
    return out
end)
