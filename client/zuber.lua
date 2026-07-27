-- v-phone | client/zuber.lua
--
-- **The doc-restaurant side of Zuber.**
--
-- doc-restaurant publishes everything its own phone app needs as **QB server callbacks**:
--
--     doc-restaurant:server:getPublicRestaurants
--     doc-restaurant:server:submitOrder
--     doc-restaurant:server:getMyRatings
--     doc-restaurant:server:rateRestaurant
--     doc-restaurant:server:getRestaurantReviews
--
-- A server callback is registered on the framework, not on the resource, so **any client may
-- call it**. That is the whole integration: this file asks the same five questions its own app
-- asked, from here, and doc-restaurant is not edited, patched, wrapped or replaced. If it is
-- updated tomorrow, this keeps working; if it is removed, Zuber falls back to
-- `Config.Zuber.restaurants` and the app still runs.
--
-- The position sent with an order comes from the ped HERE, exactly as doc-restaurant's own app
-- did it, because that is what its server expects to receive and rounding it differently would
-- be a difference for no reason.

local function zuberOn()
    return (Config.Zuber or {}).enabled ~= false
end

--- Is doc-restaurant the provider? The same question server/zuber.lua asks, asked the same way.
local function docMode()
    if not zuberOn() then return false end
    local want = tostring((Config.Zuber or {}).provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-restaurant' then return GetResourceState('doc-restaurant') == 'started' end
    return GetResourceState('doc-restaurant') == 'started'
end

--- qb-core's shared object, fetched once and only if it is there.
---
--- v-phone is framework-agnostic and holds no framework object of its own - the bridge answers
--- what it needs through `Core`. This is the one place that needs the real thing, because a QB
--- server callback is only reachable through `QBCore.Functions.TriggerCallback`.
local QB = nil
local qbChecked = false

local function qbCore()
    if qbChecked then return QB end
    qbChecked = true
    if GetResourceState('qb-core') ~= 'started' then return nil end
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    QB = ok and core or nil
    return QB
end

--- Ask doc-restaurant one of its callbacks, and answer the page.
---
--- Guarded twice. `pcall`, because an export that moved would otherwise take the NUI callback
--- with it and leave the page waiting on a request that can no longer be answered - and a
--- timeout, because a callback that never fires is the same silence from the page's side. Both
--- end in an answer, which is the one thing a page cannot do without.
local function ask(name, payload, cb)
    local core = qbCore()
    if not core then cb({ error = 'noframework' }) return end

    local answered = false
    local function answer(res)
        if answered then return end
        answered = true
        cb(res)
    end

    local ok = pcall(function()
        core.Functions.TriggerCallback(name, function(res) answer(res or {}) end, payload)
    end)
    if not ok then answer({ error = 'nodoc' }) return end

    SetTimeout(10000, function()
        -- Ten seconds is long past a database round trip. Something is wrong, and saying so
        -- beats a spinner that never stops.
        answer({ error = 'timeout' })
    end)
end

-- ══════════════════════════════════════════════════════════════
-- What the page asks for
-- ══════════════════════════════════════════════════════════════

--- The restaurants, from whichever provider is live.
---
--- In doc-restaurant mode this is its own payload, passed through untouched and with its own
--- field names: the page reads `state.open`, `products`, `promotions`, `rating` and the rest
--- exactly as its app did. Reshaping it here would mean maintaining a translation of somebody
--- else's data model, and it would drift the first time they add a field.
RegisterNUICallback('zuberDoc', function(data, cb)
    if not docMode() then cb({ error = 'notdoc' }) return end
    local op = tostring((data and data.op) or 'restaurants')

    if op == 'restaurants' then
        ask('doc-restaurant:server:getPublicRestaurants', nil, function(res)
            if type(res) == 'table' and not res.error then
                -- The two facts doc-restaurant's own client adds before handing the payload to
                -- its page. Added here for the same reason: the order form needs a name and a
                -- number to put on the ticket.
                local pd = qbCore() and qbCore().Functions.GetPlayerData() or nil
                if pd and pd.charinfo then
                    res.playerName = ((pd.charinfo.firstname or '') .. ' '
                                      .. (pd.charinfo.lastname or '')):gsub('^%s+', '')
                    res.playerPhone = pd.charinfo.phone or ''
                end
            end
            cb(res)
        end)
        return
    end

    if op == 'order' then
        local body = (type(data) == 'table' and type(data.order) == 'table') and data.order or {}
        -- Rounded the way doc-restaurant's own app rounded it, so its server receives what it
        -- has always received.
        local c = GetEntityCoords(PlayerPedId())
        body.coords = {
            x = math.ceil(c.x * 100) / 100,
            y = math.ceil(c.y * 100) / 100,
            z = math.ceil(c.z * 100) / 100,
        }
        ask('doc-restaurant:server:submitOrder', body, cb)
        return
    end

    if op == 'ratings' then
        ask('doc-restaurant:server:getMyRatings', nil, cb)
        return
    end

    if op == 'rate' then
        ask('doc-restaurant:server:rateRestaurant',
            (type(data) == 'table' and data.rating) or {}, cb)
        return
    end

    if op == 'reviews' then
        ask('doc-restaurant:server:getRestaurantReviews',
            { job = data and data.job }, cb)
        return
    end

    cb({ error = 'x' })
end)

--- Route to a restaurant. Both providers end here: the coordinates arrive with the payload in
--- doc-restaurant mode and from the phone's own server in config mode, and either way the
--- waypoint is set on this side because that is where the map is.
RegisterNUICallback('zuberRoute', function(data, cb)
    local x, y = tonumber(data and data.x), tonumber(data and data.y)
    if not x or not y then cb({ error = 'nowhere' }) return end
    SetNewWaypoint(x + 0.0, y + 0.0)
    cb({ ok = true })
end)

-- The config-provider relays. Thin on purpose: everything about an order is decided in
-- server/zuber.lua, and these carry a request and an answer.
RegisterNUICallback('zuberOpen', function(_, cb)
    V.Request('v-phone:zuber:open', function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('zuberOrder', function(data, cb)
    V.Request('v-phone:zuber:order', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('zuberFavourite', function(data, cb)
    V.Request('v-phone:zuber:favourite', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('zuberLocate', function(data, cb)
    V.Request('v-phone:zuber:locate', function(res)
        if type(res) == 'table' and res.ok and res.x and res.y then
            SetNewWaypoint(res.x + 0.0, res.y + 0.0)
        end
        cb(res or { error = 'x' })
    end, data or {})
end)

-- The order-status notification lives in client/main.lua, with the other net events.
-- `isOpen`, `peek`, `buzz` and `strings` are file-locals of that file, and a handler here could
-- not see any of them: reaching for one would be a nil global, which is the single mistake this
-- resource has paid for most often.
