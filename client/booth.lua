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
local INTERACT = BOOTH.interact or {}
local MARKER = INTERACT.marker or {}
local BLIP = BOOTH.blip or {}

local function num(v, d) return tonumber(v) or d or 0 end

--- The label on the prompt or the target option. A server may override it outright; nil
--- falls back to the translation, which is what almost everyone wants.
local function useLabel()
    local custom = INTERACT.label
    if type(custom) == 'string' and custom ~= '' then return custom end
    return L('ph.booth_use')
end

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
--- Does the payphone panel want the cursor? Read by the watchdog in bridge/client/safety.lua.
function BoothFocusWanted() return isOpen end

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
    if BOOTH.allowInVehicle ~= true and IsPedInAnyVehicle(ped, false) then
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
        -- The strings travel with the panel.
        --
        -- The page's table is filled by the phone's own `open` message, and a payphone is the
        -- one screen a player can reach WITHOUT ever opening their phone - that is the whole
        -- point of a payphone. So on a fresh connection every label on this panel rendered as
        -- its own key: `ph.booth_title`, `ph.booth_call`, and so on, exactly as reported.
        SendNUIMessage({ action = 'booth:open', data = res, call = boothCall,
                         strings = PhoneStrings and PhoneStrings() or nil })
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

    -- `auto` takes whichever target script is running, a name forces one, `off` ignores them
    -- all and falls through to the marker - which some servers prefer even when they do run
    -- a target script.
    local wanted = tostring(INTERACT.target or 'auto'):lower()
    local targetRes = nil
    if wanted ~= 'off' then
        if wanted ~= 'auto' then
            if GetResourceState(wanted) == 'started' then
                targetRes = wanted
            else
                print(('[v-phone] Config.Booth.interact.target names "%s", which is not started; falling back to the marker')
                    :format(wanted))
            end
        else
            for _, res in ipairs({ 'ox_target', 'qb-target', 'qtarget' }) do
                if GetResourceState(res) == 'started' then targetRes = res break end
            end
        end
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
                    icon = tostring(INTERACT.icon or 'fas fa-phone'),
                    label = useLabel(),
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
            options = { { label = useLabel(), icon = tostring(INTERACT.icon or 'fas fa-phone'),
                          action = openBooth } },
            distance = num(BOOTH.radius, 1.6) + 0.9,
        })
        return
    end

    -- No target script: the nearest box gets a marker and an E prompt.
    --
    -- Two cadences, deliberately separate. FINDING the box is five `GetClosestObjectOfType`
    -- calls, one per model, so it runs at most twice a second and the answer is cached.
    -- DRAWING the marker and reading the key must happen every frame, so it does - off the
    -- cache, costing nothing but a draw call. Scanning at frame rate, which is what a single
    -- combined loop would do, is 300 spatial queries a second for a player walking past a
    -- phone box, and it buys nothing: the props do not move.
    CreateThread(function()
        local reach = num(BOOTH.radius, 1.6)
        local interval = math.max(50, math.floor(num(INTERACT.scanInterval, 500)))
        local scanDist = num(INTERACT.scanDistance, 12.0)
        local key = math.floor(num(INTERACT.key, 38))
        local drawMarker = MARKER.enabled ~= false
        local mType = math.floor(num(MARKER.type, 2))
        local mHeight = num(MARKER.height, 1.35)
        local col = MARKER.colour or {}
        local mr, mg, mb, ma = math.floor(num(col.r, 60)), math.floor(num(col.g, 130)),
                               math.floor(num(col.b, 200)), math.floor(num(col.a, 140))
        local sc = MARKER.scale or {}
        local sx, sy, sz = num(sc.x, 0.18), num(sc.y, 0.18), num(sc.z, 0.12)
        local bob = MARKER.bob == true
        local nearby, nextScan = nil, 0

        while true do
            local sleep = interval
            if not isOpen then
                local coords = GetEntityCoords(PlayerPedId())
                local now = GetGameTimer()
                if now >= nextScan then
                    nearby = nearestBooth(coords, scanDist)
                    nextScan = now + interval
                end

                if nearby then
                    sleep = 0
                    if drawMarker then
                        DrawMarker(mType, nearby.x, nearby.y, nearby.z + mHeight, 0, 0, 0, 0, 180.0, 0,
                            sx, sy, sz, mr, mg, mb, ma, bob, true, 2, nil, nil, false)
                    end
                    if #(coords - vector3(nearby.x, nearby.y, nearby.z)) < reach + 0.9 then
                        SetTextComponentFormat('STRING')
                        AddTextComponentString('[E] ' .. useLabel())
                        DisplayHelpTextFromStringLabel(0, 0, 1, -1)
                        if IsControlJustReleased(0, key) then openBooth() end
                    end
                end
            end
            Wait(sleep)
        end
    end)
end)

-- ══════════════════════════════════════════════════════════════
-- Blips
-- ══════════════════════════════════════════════════════════════
-- Off by default: there are around a hundred payphones in Los Santos and blipping all of
-- them at once turns the map into confetti.
--
-- This runs on its own slow thread rather than inside the marker loop, because the marker
-- loop does not exist when a target script is running - and a server with ox_target still
-- wants its blips. Boxes are blipped as the player comes near them and keyed by position,
-- so passing the same one twice does not stack two blips on it.
CreateThread(function()
    if not enabled() or BLIP.enabled ~= true then return end
    if #(BOOTH.models or {}) == 0 then return end

    local seen = {}        -- [key] = { blip = handle, x, y, z }
    local sprite = math.floor(num(BLIP.sprite, 64))
    local colour = math.floor(num(BLIP.colour, 3))
    local scale = num(BLIP.scale, 0.6)
    local shortRange = BLIP.shortRange ~= false
    local label = (type(BLIP.label) == 'string' and BLIP.label ~= '') and BLIP.label or L('ph.booth_title')
    local scanDist = num(INTERACT.scanDistance, 12.0)
    -- The cull radius. Zero means "keep everything discovered", which is the old behaviour.
    local cull = num(BLIP.distance, 0)
    local refresh = math.max(250, math.floor(num(BLIP.refresh, 2000)))

    local function drop(key)
        local entry = seen[key]
        if not entry then return end
        if entry.blip and DoesBlipExist(entry.blip) then RemoveBlip(entry.blip) end
        seen[key] = nil
    end

    while true do
        local here = GetEntityCoords(PlayerPedId())

        -- Discovery: wider than the interaction scan and far slower. A blip that appears a
        -- second late costs nobody anything.
        local booth = nearestBooth(here, math.max(scanDist, 60.0))
        if booth then
            local key = Booth.Key(booth.x, booth.y, booth.z)
            -- Within the cull radius, or no radius at all.
            if not seen[key] and (cull <= 0 or #(here - vector3(booth.x, booth.y, booth.z)) <= cull) then
                local blip = AddBlipForCoord(booth.x, booth.y, booth.z)
                SetBlipSprite(blip, sprite)
                SetBlipColour(blip, colour)
                SetBlipScale(blip, scale + 0.0)
                SetBlipAsShortRange(blip, shortRange)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentString(label)
                EndTextCommandSetBlipName(blip)
                seen[key] = { blip = blip, x = booth.x, y = booth.y, z = booth.z }
            end
        end

        -- The cull. Walks the handful of boxes already blipped and drops the ones the player
        -- has left behind; they come back on the next approach. Skipped entirely when no
        -- radius is set, so the default costs nothing.
        if cull > 0 then
            for key, entry in pairs(seen) do
                if #(here - vector3(entry.x, entry.y, entry.z)) > cull then drop(key) end
            end
        end

        Wait(refresh)
    end
end)

-- A resource stop with the screen up would leave the player without a cursor and stuck in
-- the anim. Put both back.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if isOpen then SetNuiFocus(false, false) end
    stopPose()
end)
