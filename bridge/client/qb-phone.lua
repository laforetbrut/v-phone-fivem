-- ══════════════════════════════════════════════════════════════
--  qb-phone compatibility - client
-- ══════════════════════════════════════════════════════════════
-- The `qb-phone:client:*` events a stock qb-core server fires at a player. Every one of them
-- is fire-and-forget: nothing waits for an answer, so an unhandled one is silent rather than
-- broken. That is exactly why they are worth handling - a police dispatch that quietly never
-- arrives is harder to notice than one that errors.
--
-- These raise a phone notification, which is a SERVER decision: whether a banner shows
-- depends on whether the player is carrying a handset, and only the server knows that. So
-- each of these asks, rather than drawing something the phone would not have drawn itself.

if not V or not V.Setting then return end

-- Same lazy gate as the server half, and cached for the same reason: this is asked on every
-- event, and two natives per police alert is two more than it needs to be.
local claimed

local function enabled()
    local mode = (Config and Config.Compat and Config.Compat.qbPhone)
    if mode == false then return false end
    if mode == true then return true end

    if claimed == nil then
        local state = GetResourceState('qb-phone')
        claimed = (state ~= 'started' and state ~= 'starting')
            or GetResourceMetadata('qb-phone', 'vphone_compat', 0) == 'yes'
    end
    return claimed
end

AddEventHandler('onClientResourceStart', function(r) if r == 'qb-phone' then claimed = nil end end)
AddEventHandler('onClientResourceStop', function(r) if r == 'qb-phone' then claimed = nil end end)

local function banner(app, title, body)
    if not enabled() then return end
    TriggerServerEvent('v-phone:compat:qbBanner', app, title, body)
end

-- ── Police dispatch ───────────────────────────────────────────
-- Six call sites: qb-diving, qb-policejob (x3), qb-prison, qb-storerobbery.
-- Shape, from qb-policejob/server/main.lua: { title, coords = {x,y,z}, description }
--
-- Stock gated this on being police AND on duty. The job check is kept - an alert is not a
-- public broadcast - but it happens on the SERVER, which is the only side that knows the
-- player's job, and it reads Config.Compat.policeJobs rather than hardcoding 'police' so a
-- server with a sheriff department gets its alerts too.
-- qb resources are inconsistent about `coords`: qb-policejob, qb-prison and qb-storerobbery
-- build an explicit { x, y, z } table, while qb-diving forwards the raw GetEntityCoords it
-- was handed. With `lua54 'yes'` that is a native vector3, so `type(c) == 'table'` is false
-- and the waypoint - the useful half of a dispatch - would be dropped for those alerts.
-- The type name is checked before any field access, so a caller that puts a number in
-- `coords` cannot error the handler out and lose the banner as well.
local function alertXY(c)
    local t = type(c)
    if t ~= 'table' and t ~= 'vector2' and t ~= 'vector3' and t ~= 'vector4' then return nil end
    local x, y = tonumber(c.x), tonumber(c.y)
    if not x or not y then return nil end
    return { x = x, y = y }
end

RegisterNetEvent('qb-phone:client:addPoliceAlert', function(alertData)
    if not enabled() or type(alertData) ~= 'table' then return end
    TriggerServerEvent('v-phone:compat:qbAlert', {
        title = alertData.title,
        description = alertData.description,
        coords = alertXY(alertData.coords),
    })
end)

-- The waypoint half of a dispatch, set only after the server confirmed the job.
RegisterNetEvent('v-phone:compat:qbWaypoint', function(x, y)
    if x and y then SetNewWaypoint(x + 0.0, y + 0.0) end
end)

-- ── Money and invoices ────────────────────────────────────────
-- qb-policejob/server/commands.lua fires this to offer a fine. v-phone has no accept/deny
-- sheet, so the player is told what happened rather than being asked - the fine itself is
-- handled by qb-policejob either way.
RegisterNetEvent('qb-phone:client:AcceptorDenyInvoice', function(_, _, society, _, amount)
    banner('bank', 'Invoice', ('%s: $%s'):format(tostring(society or 'Society'), tostring(amount or 0)))
end)

RegisterNetEvent('qb-phone:client:RemoveBankMoney', function(amount)
    banner('bank', 'Payment', ('-$%s'):format(tostring(amount or 0)))
end)

RegisterNetEvent('qb-phone:client:AddTransaction', function(_, _, message, title)
    banner('bank', tostring(title or 'Transaction'), tostring(message or ''))
end)

-- ── Notifications proper ──────────────────────────────────────
RegisterNetEvent('qb-phone:client:CustomNotification', function(title, text)
    banner('phone', tostring(title or 'iFruit'), tostring(text or ''))
end)

RegisterNetEvent('qb-phone:client:RaceNotify', function(message)
    banner('phone', 'Race', tostring(message or ''))
end)

RegisterNetEvent('qb-phone:client:NewMailNotify', function()
    banner('mail', 'Mail', '')
end)

-- ── Contacts ──────────────────────────────────────────────────
-- "Give this person my number". The nearest player is picked here and re-checked on the
-- server, which is what actually writes both contacts.
RegisterNetEvent('qb-phone:client:GiveContactDetails', function()
    if not enabled() then return end

    local ped = PlayerPedId()
    local me = GetEntityCoords(ped)
    local best, bestDist = nil, 3.0

    for _, id in ipairs(GetActivePlayers()) do
        local other = GetPlayerPed(id)
        if other ~= ped and DoesEntityExist(other) then
            local d = #(me - GetEntityCoords(other))
            if d < bestDist then best, bestDist = GetPlayerServerId(id), d end
        end
    end

    if not best then return end
    TriggerServerEvent('v-phone:compat:qbGiveContact', best)
end)

-- ── Deliberately no-ops ───────────────────────────────────────
-- v-phone re-reads its data when an app is opened, so there is nothing to refresh.
--
-- `qb-phone:RefreshPhone` in particular must NOT be mapped to v-phone:client:close: several
-- qb resources fire it during normal play, and closing the phone underneath a player who is
-- typing would be a worse bug than the one it fixed.
RegisterNetEvent('qb-phone:RefreshPhone', function() end)
RegisterNetEvent('qb-phone:client:UpdateLapraces', function() end)
RegisterNetEvent('qb-phone:client:UpdateMails', function() end)
RegisterNetEvent('qb-phone:client:UpdateMessages', function() end)
RegisterNetEvent('qb-phone:client:UpdateTweets', function() end)
