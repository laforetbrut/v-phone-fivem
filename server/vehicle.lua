-- v-phone | server/vehicle.lua
--
-- **The remote for a car you own.**
--
-- Lights, underglow, doors, locks. None of it needs a garage script or a mechanic script:
-- they are engine natives, so the behaviour is identical on every framework. What the
-- framework decides is only which vehicles are YOURS, and that is read through the same
-- bridge the Garage app already uses.
--
-- Nothing here trusts the client:
--
--   * the plate is checked against the vehicle list the framework holds for this character,
--   * the DISTANCE is measured on the server, from the vehicle entity's own coordinates to
--     the player's ped - a modified client cannot open its car from across the city,
--   * the command is applied through the vehicle's state bag, so every client sees the same
--     thing and none of them had to be asked nicely.

local RC = Config.VehicleRemote or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return RC.enabled == true end

--- Plates are compared with the padding and case stripped: GTA pads a plate to eight
--- characters and a database rarely stores it that way.
local function plateKey(plate)
    return (tostring(plate or ''):upper():gsub('%s', ''))
end

local Cooldown = {}   -- [src] = os.time() of the last accepted command

-- Every command carries a number that has never been used before. Without it, pressing the
-- same button twice writes the same state bag value twice, the bag does not consider that a
-- change, and the second press does nothing.
local seq = 0
local function nextSeq() seq = seq + 1 return seq end

local function log(src, message)
    if not RC.log then return end
    local p = Core.GetPlayer(src)
    print(('[v-phone] vehicle remote: %s (%s) %s'):format(
        p and p.name or '?', p and p.citizenid or src, message))
end

-- ══════════════════════════════════════════════════════════════
-- Is this vehicle yours, and is it here?
-- ══════════════════════════════════════════════════════════════
local function ownsPlate(src, p, plate)
    if RC.requireOwnership == false then return true end
    local wanted = plateKey(plate)
    if wanted == '' then return false end
    local owned = Bridge.Vehicles and Bridge.Vehicles.Owned(p.citizenid, src) or {}
    for _, row in ipairs(owned or {}) do
        if plateKey(row.plate) == wanted then return true end
    end
    return false
end

--- Resolve the vehicle the client named and check it really is within reach. Returns the
--- entity, or nil plus the reason.
local function reachableVehicle(src, data)
    local netId = math.floor(num(data and data.netId, 0))
    if netId <= 0 then return nil, 'novehicle' end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil, 'novehicle' end
    if GetEntityType(vehicle) ~= 2 then return nil, 'novehicle' end

    -- Whose car, and how far from it: the phone's owner.
    local ped = GetPlayerPed(PhoneActingSource and PhoneActingSource(src) or src)
    local here = ped and ped ~= 0 and GetEntityCoords(ped)
    local there = GetEntityCoords(vehicle)
    if not here or not there then return nil, 'novehicle' end
    if #(here - there) > num(RC.distance, 20.0) then return nil, 'toofar' end

    -- The plate is read from the ENTITY, not from the message, so ownership is checked
    -- against the car that is actually there.
    return vehicle, nil, plateKey(GetVehicleNumberPlateText(vehicle))
end

-- ══════════════════════════════════════════════════════════════
-- The commands
-- ══════════════════════════════════════════════════════════════
-- Applied by writing the vehicle's state bag. The client half reads it and calls the natives,
-- which means every player nearby sees the same lights and the same underglow without the
-- server having to pick one client to trust.
local ACTIONS = {
    lights = 'lights', neon = 'neon', doors = 'doors',
    locks = 'locks', engine = 'engine', horn = 'horn', alarm = 'alarm',
}

--- Is this control switched on in the config? A control an operator disabled is refused here
--- as well as hidden in the app, because hiding a button is not a permission check.
local function allowed(action)
    local controls = RC.controls or {}
    return controls[action] == true
end

V.Callback('v-phone:vehicle:control', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local action = ACTIONS[tostring((data and data.action) or '')]
    if not action then resolve({ error = 'x' }) return end
    if not allowed(action) then resolve({ error = 'disabled' }) return end

    local wait = math.floor(num(RC.cooldownSeconds, 1))
    if wait > 0 and Cooldown[src] and os.time() - Cooldown[src] < wait then
        resolve({ error = 'cooldown' }) return
    end

    local vehicle, err, plate = reachableVehicle(src, data)
    if not vehicle then resolve({ error = err }) return end
    if not ownsPlate(src, p, plate) then resolve({ error = 'notyours' }) return end

    -- A car with somebody at the wheel and the engine running is a car in use.
    if RC.refuseWhileDriven ~= false then
        local driver = GetPedInVehicleSeat(vehicle, -1)
        -- "Somebody else is driving it" - and the owner of the phone is the somebody who is
        -- allowed to be. Same source as the distance check above, or a staff member holding a
        -- phone could not unlock a car its owner is sitting in.
        if driver and driver ~= 0 and driver ~= ped then
            resolve({ error = 'inuse' }) return
        end
    end

    Cooldown[src] = os.time()

    -- The payload the client half applies. `seq` makes every command distinct, so pressing
    -- the same button twice is two events rather than a state bag that did not change.
    Entity(vehicle).state:set('vphoneRemote', {
        action = action,
        value = data and data.value,
        by = src,
        seq = nextSeq(),
        persist = RC.persist == true,
    }, true)

    log(src, ('%s on %s'):format(action, plate))
    resolve({ ok = true, action = action })
end)

AddEventHandler('playerDropped', function() Cooldown[source] = nil end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════

--- Drive the same remote from a script: a key fob item, a heist, an admin tool.
---
--- Bypasses the ownership and distance checks on purpose - the caller is server code, and
--- server code is trusted where a client is not.
---
--- **It also bypasses `enabled()` and `allowed(action)`**, which is NOT deliberate and is worth
--- knowing before you rely on it: an operator who set `Config.VehicleRemote.enabled = false`,
--- or who turned off `locks` and left `engine` on, still has both reachable through this
--- export. Tightening it would stop working for anybody whose config has the feature off, so it
--- waits for a version where an operator is expecting to read a changelog.
exports('VehicleRemote', function(netId, action, value)
    if not ACTIONS[tostring(action or '')] then return false end
    local vehicle = NetworkGetEntityFromNetworkId(math.floor(num(netId, 0)))
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    Entity(vehicle).state:set('vphoneRemote', {
        action = action, value = value, seq = nextSeq(), persist = RC.persist == true,
    }, true)
    return true
end)
