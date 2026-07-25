-- v-phone | client/booth.lua
--
-- **The phone box, on the street.**
--
-- There is no list of coordinates anywhere in this file. Every booth in the game is one of
-- a handful of props, so this looks for THOSE, around the player, using the engine's own
-- spatial query. A booth in a new MLO works the moment the MLO loads; a booth a map edit
-- moved moves with it; nothing needs a config entry.
--
-- With ox_target or qb-target running, the interaction is registered once PER MODEL and
-- therefore covers every box on the map at once. Without one, a short polling loop draws a
-- marker on the nearest box and listens for E.
--
-- The screen itself is the phone's NUI page in a different costume (see `booth*` in
-- html/app.js), the same way the forensics terminal is. This file opens the door and holds
-- the player to the handset; the server decides everything else.

local BOOTH = Config.Booth or {}

local function num(v, d) return tonumber(v) or d or 0 end

local isOpen = false
local current = nil          -- { x, y, z, number } while the box is open or in use
local boothCall = nil        -- the live call, mirrored from client/main.lua
local leash = 0              -- generation counter, so an old watchdog cannot fire

local function enabled() return BOOTH.enabled == true end

local function models()
    local out = {}
    for _, name in ipairs(BOOTH.models or {}) do
        out[#out + 1] = { name = name, hash = GetHashKey(name) }
    end
    return out
end

local MODELS = nil
local function modelList()
    MODELS = MODELS or models()
    return MODELS
end

-- ══════════════════════════════════════════════════════════════
-- Finding the box
-- ══════════════════════════════════════════════════════════════
--- The nearest phone box to these coordinates, or nil. Returns the prop's own position,
--- because that - not the player's - is what the booth's number is derived from, and both
--- ends of the call have to agree on it.
local function nearestBooth(coords, radius)
    local best, bestDist = nil, radius + 0.01
    for _, model in ipairs(modelList()) do
        local object = GetClosestObjectOfType(coords.x, coords.y, coords.z, radius, model.hash,
            false, false, false)
        if object and object ~= 0 and DoesEntityExist(object) then
            local at = GetEntityCoords(object)
            local d = #(coords - at)
            if d < bestDist then
                best, bestDist = { x = at.x, y = at.y, z = at.z, entity = object, model = model.name }, d
            end
        end
    end
    return best
end

-- ══════════════════════════════════════════════════════════════
-- The pose
-- ══════════════════════════════════════════════════════════════
-- The box has its own handset, so nothing is attached to the hand: only the arm-to-ear
-- anim plays. The player is left free to walk, and walking away is what ends the call.
local function startPose()
    local anim = BOOTH.anim or {}
    local dict, clip = tostring(anim.dict or 'cellphone@'), tostring(anim.clip or 'cellphone_call_listen_base')
    RequestAnimDict(dict)
    local waited = 0
    while not HasAnimDictLoaded(dict) and waited < 2000 do
        Wait(50)
        waited = waited + 50
    end
    if not HasAnimDictLoaded(dict) then return end
    TaskPlayAnim(PlayerPedId(), dict, clip, 3.0, -1.0, -1, 49, 0, false, false, false)
end

local function stopPose()
    local anim = BOOTH.anim or {}
    StopAnimTask(PlayerPedId(), tostring(anim.dict or 'cellphone@'),
        tostring(anim.clip or 'cellphone_call_listen_base'), 2.0)
end

-- ══════════════════════════════════════════════════════════════
-- Opening and closing the screen
-- ══════════════════════════════════════════════════════════════
local function closeBooth(keepCall)
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'booth:close' })
    if not keepCall then
        current = nil
        stopPose()
    end
end

local function openBooth()
    if isOpen or not enabled() then return end

    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then
        V.Notify(L('ph.booth_invehicle'), 'error')
        return
    end

    local booth = nearestBooth(GetEntityCoords(ped), num(BOOTH.radius, 1.6) + 1.0)
    if not booth then
        V.Notify(L('ph.booth_none'), 'error')
        return
    end

    -- The server re-derives the number from these coordinates after checking the player is
    -- really standing here, so what comes back is authoritative, not a guess made locally.
    V.Request('v-phone:booth:open', function(res)
        if not res or not res.ok then
            V.Notify(L('ph.booth_err_' .. tostring((res and res.error) or 'x')), 'error')
            return
        end
        current = { x = booth.x, y = booth.y, z = booth.z, number = res.number }
        isOpen = true
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'booth:open', data = res, call = boothCall })
    end, { x = booth.x, y = booth.y, z = booth.z })
end

-- ══════════════════════════════════════════════════════════════
-- NUI -> server
-- ══════════════════════════════════════════════════════════════
-- Every one of these re-sends the box's coordinates, and the server re-checks them. The
-- page cannot name a booth; it can only name the one this file found.
RegisterNUICallback('boothClose', function(_, cb)
    closeBooth(boothCall ~= nil)
    cb('ok')
end)

RegisterNUICallback('boothCall', function(data, cb)
    if not current then cb({ error = 'notatbooth' }) return end
    V.Request('v-phone:booth:call', function(res) cb(res or { error = 'x' }) end, {
        x = current.x, y = current.y, z = current.z,
        number = tostring((data and data.number) or ''),
    })
end)

RegisterNUICallback('boothCard', function(_, cb)
    if not current then cb({ error = 'notatbooth' }) return end
    V.Request('v-phone:booth:card', function(res) cb(res or { error = 'x' }) end,
        { x = current.x, y = current.y, z = current.z })
end)

RegisterNUICallback('boothHangup', function(_, cb)
    V.Request('v-phone:booth:hangup', function(res) cb(res or { error = 'x' }) end)
end)

-- The meter, pushed by the server as it ticks down.
RegisterNetEvent('v-phone:client:boothCredit', function(payload)
    SendNUIMessage({ action = 'booth:credit', data = payload })
end)

-- ══════════════════════════════════════════════════════════════
-- The call, handed over from client/main.lua
-- ══════════════════════════════════════════════════════════════
-- main.lua owns the call state and the voice channel; a call flagged `booth` is forwarded
-- here so the box draws it instead of the handset.

--- Walk away and it hangs up, the way a handset on a metal cord would. The watchdog is
--- generational: starting a new call invalidates the previous one's loop, so two calls in a
--- row cannot leave two watchdogs racing to end the same thing.
local function watchLeash()
    leash = leash + 1
    local mine = leash
    local limit = num(BOOTH.leashDistance, 3.5)

    CreateThread(function()
        while leash == mine and boothCall and current do
            local at = GetEntityCoords(PlayerPedId())
            if #(at - vector3(current.x, current.y, current.z)) > limit then
                V.Notify(L('ph.booth_walked_off'), 'info')
                V.Request('v-phone:booth:hangup', function() end)
                break
            end
            Wait(500)
        end
    end)
end

AddEventHandler('v-phone:internal:boothCall', function(c)
    boothCall = c
    -- A call resynced after a resource restart arrives with no box on record. Find the one
    -- the player is standing at, so the leash and the screen have somewhere to anchor.
    if not current then
        local booth = nearestBooth(GetEntityCoords(PlayerPedId()), num(BOOTH.radius, 1.6) + 2.5)
        if booth then
            current = { x = booth.x, y = booth.y, z = booth.z,
                        number = Booth.NumberAt(booth.x, booth.y, booth.z) }
        end
    end
    startPose()
    watchLeash()
    -- The screen may be shut - the player closed it and kept talking. Only push if it is up.
    if isOpen then SendNUIMessage({ action = 'booth:call', call = c }) end
end)

AddEventHandler('v-phone:internal:boothCallEnd', function(reason)
    boothCall = nil
    leash = leash + 1
    stopPose()
    if isOpen then
        SendNUIMessage({ action = 'booth:call', call = nil, reason = reason })
    else
        current = nil
    end
end)

-- ══════════════════════════════════════════════════════════════
-- The interaction
-- ══════════════════════════════════════════════════════════════
CreateThread(function()
    if not enabled() then return end
    if #(BOOTH.models or {}) == 0 then
        print('[v-phone] Config.Booth.models is empty: no prop counts as a phone box, so none will work')
        return
    end

    local targetRes = nil
    for _, res in ipairs({ 'ox_target', 'qb-target', 'qtarget' }) do
        if GetResourceState(res) == 'started' then targetRes = res break end
    end

    -- A MODEL target: registered once, and every box on the map answers to it. This is why
    -- there is no coordinate list to keep in step with the map.
    if targetRes == 'ox_target' then
        exports.ox_target:addModel(
            (function()
                local hashes = {}
                for _, m in ipairs(modelList()) do hashes[#hashes + 1] = m.hash end
                return hashes
            end)(),
            {
                {
                    name = 'vphone_booth',
                    icon = 'fas fa-phone',
                    label = L('ph.booth_use'),
                    distance = num(BOOTH.radius, 1.6) + 0.9,
                    onSelect = openBooth,
                },
            })
        return
    end

    if targetRes == 'qb-target' or targetRes == 'qtarget' then
        local names = {}
        for _, m in ipairs(modelList()) do names[#names + 1] = m.name end
        exports[targetRes]:AddTargetModel(names, {
            options = { { label = L('ph.booth_use'), icon = 'fas fa-phone', action = openBooth } },
            distance = num(BOOTH.radius, 1.6) + 0.9,
        })
        return
    end

    -- No target script: the nearest box gets a marker and an E prompt. The scan runs once a
    -- second while there is nothing nearby, and every frame only when there is, so a player
    -- crossing the city is not paying for this.
    CreateThread(function()
        local reach = num(BOOTH.radius, 1.6)
        while true do
            local sleep = 1000
            if not isOpen then
                local ped = PlayerPedId()
                local coords = GetEntityCoords(ped)
                local booth = nearestBooth(coords, 12.0)
                if booth then
                    sleep = 0
                    DrawMarker(2, booth.x, booth.y, booth.z + 1.35, 0, 0, 0, 0, 180.0, 0,
                        0.18, 0.18, 0.12, 60, 130, 200, 140, false, true, 2, nil, nil, false)
                    if #(coords - vector3(booth.x, booth.y, booth.z)) < reach + 0.9 then
                        SetTextComponentFormat('STRING')
                        AddTextComponentString('[E] ' .. L('ph.booth_use'))
                        DisplayHelpTextFromStringLabel(0, 0, 1, -1)
                        if IsControlJustReleased(0, 38) then openBooth() end   -- E
                    end
                end
            end
            Wait(sleep)
        end
    end)
end)

-- A resource stop with the screen up would leave the player without a cursor and stuck in
-- the anim. Put both back.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if isOpen then SetNuiFocus(false, false) end
    stopPose()
end)
