-- v-phone | bridge/client/charging.lua
--
-- **Am I somewhere my phone charges?**
--
-- The battery charges in a vehicle, at a public charger, and inside a home you have a
-- key to. The first two the server can see for itself: the ped is in a vehicle, or the
-- ped's coordinates are near a charger from the config. The third it cannot, because
-- "inside my house" is a fact only the housing script knows, and every housing script
-- says it differently.
--
-- So the CLIENT works it out and reports one boolean up a replicated state bag. The
-- server reads `phoneAtHome` and adds it to what it already knows. This is the only
-- honest way to be right on qs-housing, ps-housing, qb-houses and the rest at once: ask
-- each one the way it wants to be asked, here, once.
--
-- A server whose housing script is none of these fills `Config.Compat.hooks.atHome`
-- with a function of its own and never touches this file.

local function housingResource()
    local wanted = tostring((Config.Compat and Config.Compat.housing) or 'auto'):lower()
    if wanted == 'off' then return nil end
    if wanted ~= 'auto' then
        return GetResourceState(wanted) == 'started' and wanted or nil
    end
    for _, res in ipairs({ 'qs-housing', 'ps-housing', 'qb-houses', 'ox_property', 'loaf_housing', 'esx_property' }) do
        if GetResourceState(res) == 'started' then return res end
    end
    return nil
end

--- Is this answer from a housing script actually "yes, in a house"?
---
--- **`house ~= nil and house ~= false` was not enough, and it is why a phone could charge for
--- ever.** In Lua an empty table is truthy. So is `0`, so is `''`, so is `'none'`. A housing
--- script that answers "not in a house" with any of those - and they all do, somewhere - was
--- being read as a yes, and the phone charged from then until the player reconnected.
---
--- The answer has to be SPECIFIC to count: a non-empty string, a number above zero, or a table
--- that names something. Anything else is outside, which is also the safe direction: the cost
--- of a false no is a phone that does not charge at home, and the player can see why.
local function reallyInside(value)
    if value == nil or value == false then return false end

    local kind = type(value)
    if kind == 'boolean' then return value end
    if kind == 'number' then return value > 0 end
    if kind == 'string' then
        local v = value:lower()
        return v ~= '' and v ~= '0' and v ~= 'none' and v ~= 'false' and v ~= 'nil'
    end
    if kind == 'table' then
        -- A named property. `next` alone would accept `{}` from a script that returns an empty
        -- table for "nowhere", which is the same mistake one level down.
        for _, key in ipairs({ 'id', 'house', 'houseId', 'property', 'propertyId', 'name', 'label' }) do
            if reallyInside(value[key]) then return true end
        end
        return false
    end
    return false
end

--- True when the player is inside a property. "Inside" is enough: you had to have a key
--- to get in, so a phone charging there is a phone charging at home.
local function insideProperty()
    -- The server's own hook wins, if the server wrote one. It runs on the client here.
    local hook = Config.Compat and Config.Compat.hooks and Config.Compat.hooks.atHome
    if type(hook) == 'function' then
        local ok, inside = pcall(hook)
        if ok then return inside == true end
    end

    local housing = housingResource()
    if not housing then return false end

    -- Quasar keeps the current house on a client export.
    --
    -- This is the one that was reported: spawn inside, walk out, and the battery charges for
    -- ever. Whatever that export answers with when you are outside, it is not `nil` and not
    -- `false` - the two things the old test looked for - so the phone believed the player was
    -- still at home for the rest of the session.
    if housing == 'qs-housing' then
        local ok, house = pcall(function() return exports['qs-housing']:getCurrentHouse() end)
        return ok and reallyInside(house)
    end

    -- ps-housing publishes the current property on the player's own state bag.
    if housing == 'ps-housing' then
        local state = LocalPlayer.state
        if not state then return false end
        return reallyInside(state.currentApartment) or reallyInside(state.property)
    end

    -- qb-houses fires enter/exit events; it also sets a well-known state bag on newer
    -- builds. The bag is the reliable read.
    if housing == 'qb-houses' then
        return LocalPlayer.state and LocalPlayer.state.inside == true
    end

    -- ox_property marks the player with the property they are in.
    if housing == 'ox_property' then
        return LocalPlayer.state and reallyInside(LocalPlayer.state.inProperty)
    end

    -- loaf_housing and esx_property both use a routing bucket the client cannot read,
    -- but both set a state bag flag when inside. A server that runs one and finds this
    -- wrong points Config.Compat.hooks.atHome at the right read.
    if housing == 'loaf_housing' then
        return LocalPlayer.state and LocalPlayer.state.inHouse == true
    end

    return false
end

-- One light thread. It used to run every four seconds on the reasoning that it fed a
-- twenty-second battery tick, so being slow cost nothing - but the server now re-checks
-- charging every couple of seconds, and this flag is what it reads for "at home". A detector
-- slower than the thing reading it sets the real delay, so it matches the server's state tick.
--
-- The work is one state-bag read or one export call, which is nothing; the flag is written only
-- when it changes, so the traffic did not go up with the frequency.
local function stateTick()
    local ms = math.floor((tonumber((Config.Battery or {}).stateSeconds) or 2) * 1000)
    return math.max(500, ms)
end

CreateThread(function()
    local last = nil
    local lastWrite = 0   -- game-timer ms of the last write; 0 forces one on the first pass
    while true do
        Wait(stateTick())
        local atHome = false
        -- A server can switch the whole idea off.
        if Config.Battery == nil or Config.Compat == nil or Config.Compat.chargeAtProperty ~= false then
            local ok, inside = pcall(insideProperty)
            atHome = ok and inside or false
        end

        -- Written when it CHANGES, and again every minute regardless.
        --
        -- A state bag is a value that persists until something overwrites it, and "write only
        -- on change" means one missed write is permanent. That is the difference between a
        -- phone that charges for a minute too long and one that charges until the player
        -- reconnects - and the second is what gets reported.
        --
        -- The re-assert is on a CLOCK, not a tick count: counting ticks tied the interval to
        -- the tick rate, so making the detector faster silently made the safety net fire twice
        -- as often for no reason.
        local now = GetGameTimer()
        if atHome ~= last or (now - lastWrite) >= 60000 then
            last = atHome
            lastWrite = now
            LocalPlayer.state:set('phoneAtHome', atHome, true)   -- replicated to the server
        end
    end
end)

--- `/phonecharge` - why does the phone think it is charging?
---
--- "The battery charges for ever" is a report with five possible causes and no way for the
--- person reporting it to tell them apart. This prints the one that fired, on both sides: what
--- the housing script answered here, and which branch the server took.
RegisterCommand('phonecharge', function()
    local housing = housingResource()
    local raw, answer = nil, nil
    if housing == 'qs-housing' then
        local ok, house = pcall(function() return exports['qs-housing']:getCurrentHouse() end)
        raw = ok and house or '<the export raised>'
    elseif housing == 'ps-housing' then
        raw = LocalPlayer.state and (LocalPlayer.state.currentApartment or LocalPlayer.state.property)
    elseif housing == 'qb-houses' then
        raw = LocalPlayer.state and LocalPlayer.state.inside
    elseif housing == 'ox_property' then
        raw = LocalPlayer.state and LocalPlayer.state.inProperty
    elseif housing == 'loaf_housing' then
        raw = LocalPlayer.state and LocalPlayer.state.inHouse
    end
    local okInside, inside = pcall(insideProperty)
    answer = okInside and inside or false

    print(('[v-phone] housing script: %s'):format(tostring(housing or 'none detected')))
    print(('[v-phone] it answered: %s (%s)'):format(
        type(raw) == 'table' and json.encode(raw) or tostring(raw), type(raw)))
    print(('[v-phone] the phone reads that as: %s'):format(tostring(answer)))
    print(('[v-phone] phoneAtHome on the state bag: %s')
        :format(tostring(LocalPlayer.state and LocalPlayer.state.phoneAtHome)))
    print(('[v-phone] in a vehicle: %s'):format(tostring(IsPedInAnyVehicle(PlayerPedId(), false))))
    TriggerServerEvent('v-phone:charge:why')
end, false)
