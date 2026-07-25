-- v-phone | client/vehicle.lua
--
-- **The half of the remote that actually touches the car.**
--
-- The server decides whether a command is allowed and writes it to the vehicle's state bag;
-- this reads the bag and calls the natives. Doing it that way means every player nearby sees
-- the same lights and the same underglow, rather than only the one who pressed the button.
--
-- There is no dependency here and there is nothing to integrate with. Neons, lights, doors
-- and locks are engine state, identical on every framework and every garage script. A
-- mechanic script like jim-mechanic writes the same values through its own item, and the two
-- do not collide: the last write wins, exactly as it would if two players used the item.

local RC = Config.VehicleRemote or {}

local function num(v, d) return tonumber(v) or d or 0 end

-- ══════════════════════════════════════════════════════════════
-- Finding the car
-- ══════════════════════════════════════════════════════════════
--- The nearest vehicle to the player carrying this plate, within the configured reach.
--- Returns its network id, which is what the server can resolve back to an entity.
local function findByPlate(plate)
    local wanted = tostring(plate or ''):upper():gsub('%s', '')
    if wanted == '' then return nil end

    local here = GetEntityCoords(PlayerPedId())
    local reach = num(RC.distance, 20.0)
    local best, bestDist = nil, reach + 0.01

    -- GetGamePool is the cheap way to walk the vehicles the client actually has: no polling
    -- loop, and it only ever runs when the player opens the remote.
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(vehicle) then
            local vplate = tostring(GetVehicleNumberPlateText(vehicle) or ''):upper():gsub('%s', '')
            if vplate == wanted then
                local d = #(here - GetEntityCoords(vehicle))
                if d < bestDist then best, bestDist = vehicle, d end
            end
        end
    end

    if not best then return nil end
    return VehToNet(best), math.floor(bestDist + 0.5)
end

RegisterNUICallback('vehicleFind', function(data, cb)
    if RC.enabled ~= true then cb({ error = 'off' }) return end
    local netId, distance = findByPlate(data and data.plate)
    if not netId then cb({ error = 'novehicle' }) return end
    cb({ ok = true, netId = netId, distance = distance })
end)

RegisterNUICallback('vehicleControl', function(data, cb)
    if RC.enabled ~= true then cb({ error = 'off' }) return end
    -- The net id is resolved here rather than trusted from the page, so the page cannot name
    -- a vehicle the player is nowhere near. The server re-checks the distance regardless.
    local netId = findByPlate(data and data.plate)
    if not netId then cb({ error = 'novehicle' }) return end

    V.Request('v-phone:vehicle:control', function(res) cb(res or { error = 'x' }) end, {
        netId = netId,
        action = data and data.action,
        value = data and data.value,
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Applying a command
-- ══════════════════════════════════════════════════════════════
--- Flash the headlights a couple of times. A remote that only toggles a light is useless in
--- a car park; what you want is something you can see from thirty metres.
local function flash(vehicle)
    CreateThread(function()
        for _ = 1, 3 do
            SetVehicleLights(vehicle, 2)      -- forced on
            Wait(220)
            SetVehicleLights(vehicle, 1)      -- forced off
            Wait(180)
        end
        SetVehicleLights(vehicle, 0)          -- back to whatever the game wanted
    end)
end

local function applyNeon(vehicle, value)
    -- `value` is either false to switch the underglow off, or {r, g, b} to set it and turn
    -- every strip on.
    if value == false or value == nil then
        for i = 0, 3 do SetVehicleNeonLightEnabled(vehicle, i, false) end
        return
    end
    local r = math.floor(num(value[1] or value.r, 255))
    local g = math.floor(num(value[2] or value.g, 255))
    local b = math.floor(num(value[3] or value.b, 255))
    SetVehicleNeonLightsColour(vehicle, r, g, b)
    for i = 0, 3 do SetVehicleNeonLightEnabled(vehicle, i, true) end
end

local function applyDoors(vehicle, value)
    local door = math.floor(num(value and value.door, -1))
    -- -1 means every door, which is the "show me everything" button.
    local first, last = door, door
    if door < 0 then first, last = 0, 5 end
    for i = first, last do
        if value and value.open == false then
            SetVehicleDoorShut(vehicle, i, false)
        else
            SetVehicleDoorOpen(vehicle, i, false, false)
        end
    end
end

local function apply(vehicle, cmd)
    if not DoesEntityExist(vehicle) then return end
    local action, value = cmd.action, cmd.value

    if action == 'lights' then
        -- A named mode sets the lights; anything else is the attention-getting flash.
        if value == 'on' then SetVehicleLights(vehicle, 2)
        elseif value == 'off' then SetVehicleLights(vehicle, 1)
        elseif value == 'full' then SetVehicleFullbeam(vehicle, true)
        elseif value == 'auto' then SetVehicleLights(vehicle, 0)
        else flash(vehicle) end

    elseif action == 'neon' then
        applyNeon(vehicle, value)

    elseif action == 'doors' then
        applyDoors(vehicle, value)

    elseif action == 'locks' then
        -- 2 is locked, 1 is unlocked, in the engine's own numbering.
        SetVehicleDoorsLocked(vehicle, (value == 'lock') and 2 or 1)
        flash(vehicle)

    elseif action == 'engine' then
        local on = value ~= 'off'
        SetVehicleEngineOn(vehicle, on, true, true)

    elseif action == 'horn' then
        StartVehicleHorn(vehicle, 900, 'HELDDOWN', false)

    elseif action == 'alarm' then
        SetVehicleAlarm(vehicle, true)
        StartVehicleAlarm(vehicle)
    end
end

-- Every client applies the command, so a car unlocking is a car everyone sees unlock. The
-- state bag is the sync: the server writes once, this fires everywhere the vehicle exists.
AddStateBagChangeHandler('vphoneRemote', nil, function(bagName, _, value)
    if type(value) ~= 'table' or not value.action then return end
    local netId = tonumber(bagName:match('entity:(%d+)'))
    if not netId then return end

    -- The entity may not have streamed in on this client yet.
    local vehicle = NetworkDoesEntityExistWithNetworkId(netId) and NetToVeh(netId) or nil
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    apply(vehicle, value)
end)
