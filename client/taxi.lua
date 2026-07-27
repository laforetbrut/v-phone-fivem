-- v-phone | client/taxi.lua
--
-- **The doc-taxijob side of the Taxi app.**
--
-- doc-taxijob publishes everything its own phone app needed as **QB server callbacks** and two
-- server events:
--
--     doc-taxijob:server:GetActiveTaxis      how many drivers are on duty
--     doc-taxijob:server:PhoneCallTaxi       book a ride  -> { ok, callId, taxisAvailable }
--     doc-taxijob:server:GetPendingCalls     the queue, for a driver
--     doc-taxijob:server:GetRatingState      may this passenger rate the ride they just took
--     doc-taxijob:server:SubmitRating        etoiles + commentaire
--     doc-taxijob:server:SubmitTip           amount + method
--     doc-taxijob:server:CancelCall          (event) callId
--     doc-taxijob:server:AcceptCall          (event) callId
--
-- A server callback is registered on the framework, not on the resource, so **any client may
-- call one**. That is the whole integration: this file asks the same questions its own page
-- asked. doc-taxijob is not edited, patched, wrapped or replaced.
--
-- Two things are computed HERE because only the client can:
--
--   * the distance to each waiting fare, from the driver's own ped - exactly as its app did it;
--   * whether this character is an on-duty driver, from the job the framework reports.
--
-- Everything else is the server's answer, passed through untouched.

local function taxiOn()
    return (Config.Taxi or {}).enabled ~= false
end

--- Is doc-taxijob the provider?
local function docMode()
    if not taxiOn() then return false end
    local want = tostring((Config.Taxi or {}).provider or 'auto'):lower()
    if want == 'config' then return false end
    return GetResourceState('doc-taxijob') == 'started'
end

--- qb-core's shared object, fetched once and only if it is there.
---
--- The same reason as client/zuber.lua: v-phone holds no framework object of its own, and a QB
--- server callback is only reachable through `QBCore.Functions.TriggerCallback`.
local QB, qbChecked = nil, false

local function qbCore()
    if qbChecked then return QB end
    qbChecked = true
    if GetResourceState('qb-core') ~= 'started' then return nil end
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    QB = ok and core or nil
    return QB
end

--- Ask one of doc-taxijob's callbacks and answer the page.
---
--- Guarded twice, for the reason every NUI callback in this resource is: a `pcall`, because an
--- export that moved would otherwise take this callback with it and leave the page waiting on a
--- request that can never be answered; and a timeout, because a callback that never fires is the
--- same silence seen from the page. Both end in an answer.
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
        core.Functions.TriggerCallback(name, function(res) answer(res) end, payload)
    end)
    if not ok then answer({ error = 'nodoc' }) return end
    SetTimeout(10000, function() answer({ error = 'timeout' }) end)
end

--- Is this character an on-duty taxi driver?
---
--- `Config.Taxi.job` is what this is compared against, and it has to match doc-taxijob's own
--- `Config.JobName` - its config is in ITS client, not readable from here. Documented in
--- config.lua next to the setting, because a mismatch shows up as a driver who cannot see the
--- queue, which looks like a broken app rather than a wrong job name.
local function driverInfo()
    local core = qbCore()
    local job = (Config.Taxi or {}).job or 'taxi'
    if core then
        local pd = core.Functions.GetPlayerData()
        if pd and pd.job then
            local onDuty = pd.job.onduty
            if onDuty == nil then onDuty = pd.job.onDuty end
            return pd.job.name == job and onDuty == true,
                   pd.charinfo and (((pd.charinfo.firstname or '') .. ' ' ..
                                     (pd.charinfo.lastname or '')):gsub('^%s+', '')) or ''
        end
    end
    -- No qb-core, no answer from here - and that is correct rather than a gap: this function is
    -- only ever reached in doc-taxijob mode, and doc-taxijob is a qb-core resource. On every
    -- other framework the config provider answers, and it decides who is a driver on the SERVER,
    -- where the job is known without asking a client at all.
    return false, ''
end

-- ══════════════════════════════════════════════════════════════
-- What the page asks for
-- ══════════════════════════════════════════════════════════════

RegisterNUICallback('taxiDoc', function(data, cb)
    if not docMode() then cb({ error = 'notdoc' }) return end
    local op = tostring((data and data.op) or 'state')

    -- The opening state: how many drivers are out, and whether this player is one of them.
    if op == 'state' then
        local isDriver, name = driverInfo()
        ask('doc-taxijob:server:GetActiveTaxis', nil, function(count)
            cb({
                ok = true,
                doc = true,
                playerName = name,
                -- The count arrives as a bare number, not a table: its own app read it that way.
                taxisAvailable = (type(count) == 'number' and count) or 0,
                isDriver = isDriver,
            })
        end)
        return
    end

    if op == 'call' then
        local body = (type(data) == 'table' and type(data.call) == 'table') and data.call or {}
        ask('doc-taxijob:server:PhoneCallTaxi', {
            name = body.name,
            passengers = body.passengers,
            destination = body.destination,
        }, cb)
        return
    end

    -- The driver's queue, with the distance to each fare worked out from this ped. The server
    -- cannot do that part: it does not know where the driver is standing at the moment they look.
    if op == 'pending' then
        ask('doc-taxijob:server:GetPendingCalls', nil, function(calls)
            if type(calls) ~= 'table' then cb({ ok = true, calls = {} }) return end
            local me = GetEntityCoords(PlayerPedId())
            for _, c in ipairs(calls) do
                if type(c) == 'table' and type(c.coords) == 'table' then
                    c.dist = math.floor(#(me - vector3(c.coords.x + 0.0, c.coords.y + 0.0,
                                                       c.coords.z + 0.0)))
                else
                    c.dist = -1
                end
            end
            cb({ ok = true, calls = calls })
        end)
        return
    end

    if op == 'rating' then
        ask('doc-taxijob:server:GetRatingState', nil, cb)
        return
    end

    -- **`etoiles` and `commentaire`.** Its callback reads those names; the English ones would
    -- rate every ride at nought, which is what happened to Zuber before it was checked.
    if op == 'rate' then
        local r = (type(data) == 'table' and data.rating) or {}
        ask('doc-taxijob:server:SubmitRating',
            { etoiles = r.etoiles, commentaire = r.commentaire }, cb)
        return
    end

    if op == 'tip' then
        local tip = (type(data) == 'table' and data.tip) or {}
        ask('doc-taxijob:server:SubmitTip', { amount = tip.amount, method = tip.method }, cb)
        return
    end

    -- Two events rather than callbacks, because doc-taxijob made them events: they answer
    -- nothing, and pretending to wait for an answer would hang the page.
    if op == 'cancel' then
        local id = data and data.callId
        if type(id) == 'string' and id ~= '' then
            TriggerServerEvent('doc-taxijob:server:CancelCall', id)
            cb({ ok = true })
        else
            cb({ error = 'nocall' })
        end
        return
    end

    if op == 'accept' then
        local id = data and data.callId
        if type(id) == 'string' and id ~= '' then
            TriggerServerEvent('doc-taxijob:server:AcceptCall', id)
            cb({ ok = true })
        else
            cb({ error = 'nocall' })
        end
        return
    end

    cb({ error = 'x' })
end)

--- Route to a waiting fare, or to anywhere else the app points at.
RegisterNUICallback('taxiRoute', function(data, cb)
    local x, y = tonumber(data and data.x), tonumber(data and data.y)
    if not x or not y then cb({ error = 'nowhere' }) return end
    SetNewWaypoint(x + 0.0, y + 0.0)
    cb({ ok = true })
end)

-- The config provider's relays. Thin: every decision is in server/taxi.lua.
RegisterNUICallback('taxiOpen', function(_, cb)
    V.Request('v-phone:taxi:open', function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('taxiCall', function(data, cb)
    V.Request('v-phone:taxi:call', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('taxiAct', function(data, cb)
    V.Request('v-phone:taxi:act', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('taxiPay', function(data, cb)
    V.Request('v-phone:taxi:pay', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('taxiRate', function(data, cb)
    V.Request('v-phone:taxi:rate', function(res) cb(res or { error = 'x' }) end, data or {})
end)

--- The config provider's own ride events: a call came in, a driver took it, the ride ended.
---
--- `strings()` is a file-local of client/main.lua, so it cannot be reached from here - the page
--- already has its table by the time an app is open, and this only ever fires while the player is
--- in the world with the phone loaded.
RegisterNetEvent('v-phone:client:taxi', function(d)
    if type(d) ~= 'table' then return end
    SendNUIMessage({ action = 'taxi', update = d })
end)

--- doc-taxijob tells a driver a call arrived, and tells a passenger theirs was accepted. Both
--- are ITS events; this only forwards them to the page so an open app stops being stale, and
--- files the notification the original app had no way to show.
---
--- Registered here rather than in client/main.lua because nothing in it needs that file's
--- locals: the page owns the card, and `SendNUIMessage` is global.
RegisterNetEvent('doc-taxijob:client:ReceiveCall', function()
    SendNUIMessage({ action = 'taxiPing', kind = 'incoming' })
end)

RegisterNetEvent('doc-taxijob:client:CallAccepted', function()
    SendNUIMessage({ action = 'taxiPing', kind = 'accepted' })
end)
