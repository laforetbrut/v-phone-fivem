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

    -- Quasar keeps the current house on a client export; nil means outside.
    if housing == 'qs-housing' then
        local ok, house = pcall(function() return exports['qs-housing']:getCurrentHouse() end)
        return ok and house ~= nil and house ~= false
    end

    -- ps-housing publishes the current property on the player's own state bag.
    if housing == 'ps-housing' then
        local state = LocalPlayer.state
        return state ~= nil and (state.currentApartment ~= nil or state.property ~= nil)
    end

    -- qb-houses fires enter/exit events; it also sets a well-known state bag on newer
    -- builds. The bag is the reliable read.
    if housing == 'qb-houses' then
        return LocalPlayer.state and LocalPlayer.state.inside == true
    end

    -- ox_property marks the player with the property they are in.
    if housing == 'ox_property' then
        return LocalPlayer.state and LocalPlayer.state.inProperty ~= nil
    end

    -- loaf_housing and esx_property both use a routing bucket the client cannot read,
    -- but both set a state bag flag when inside. A server that runs one and finds this
    -- wrong points Config.Compat.hooks.atHome at the right read.
    if housing == 'loaf_housing' then
        return LocalPlayer.state and LocalPlayer.state.inHouse == true
    end

    return false
end

-- One light thread. The value changes rarely and drives a slow battery tick, so a check
-- every few seconds is far more often than it needs to be.
CreateThread(function()
    local last = nil
    while true do
        Wait(4000)
        local atHome = false
        -- A server can switch the whole idea off.
        if Config.Battery == nil or Config.Compat == nil or Config.Compat.chargeAtProperty ~= false then
            local ok, inside = pcall(insideProperty)
            atHome = ok and inside or false
        end
        if atHome ~= last then
            last = atHome
            LocalPlayer.state:set('phoneAtHome', atHome, true)   -- replicated to the server
        end
    end
end)
