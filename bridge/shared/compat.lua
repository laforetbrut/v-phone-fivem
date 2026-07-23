-- v-phone | bridge/shared/compat.lua
--
-- **The v-* resources this phone was written against, answered locally.**
--
-- Upstream the phone lives beside a dozen sibling modules and calls them by name:
-- `exports['v-voice']:PhoneCallStart(id)`, `GetResourceState('v-banking')`, and so on.
-- None of them ship here.
--
-- Two shims make every one of those call sites work unmodified:
--
--  1. `exports` gains a small set of STUBS for the v-* names, forwarding to whatever
--     this server actually runs (pma-voice for the voice ones, the framework for the
--     rest) or doing nothing when there is nothing to forward to.
--  2. `GetResourceState` answers for a v-* name by asking whether its stub has anything
--     behind it, so an app that is gated on a missing module is still correctly hidden.
--
-- Both are scoped to this resource's Lua state. Nothing outside the phone sees them.
--
-- This is deliberate: it keeps the diff against upstream to the manifest and this
-- folder, so an upstream fix can be pulled in without re-solving a merge every time.

local isServer = IsDuplicityVersion()
local realExports = exports
local realGetResourceState = GetResourceState

--- Does the server run any of these?
local function anyStarted(list)
    for _, res in ipairs(list) do
        if realGetResourceState(res) == 'started' then return res end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- The stubs
-- ══════════════════════════════════════════════════════════════
local STUBS = {}

-- ── v-core ─────────────────────────────────────────────────────
-- Upstream's core answers two questions: is another full-screen menu open (so the phone
-- does not fight it), and here is the shared player object.
STUBS['v-core'] = {
    IsAnyMenuOpen = function()
        -- ox_lib and qb both publish a "is the player in a menu" flag. Neither is
        -- required: with no answer the phone assumes nothing is in its way.
        if not isServer then
            if realGetResourceState('ox_lib') == 'started' then
                local ok, open = pcall(function() return realExports.ox_lib:isTextUIOpen() end)
                if ok and open then return true end
            end
            if LocalPlayer and LocalPlayer.state and LocalPlayer.state.invBusy then return true end
        end
        return false
    end,
    MenuOpened = function(_, name)
        if isServer then return end
        -- ox_inventory and most qb inventories read this to stay shut while a full
        -- screen UI is up.
        LocalPlayer.state:set('invBusy', true, false)
        TriggerEvent('v-phone:opened', name)
    end,
    MenuClosed = function(_, name)
        if isServer then return end
        LocalPlayer.state:set('invBusy', false, false)
        TriggerEvent('v-phone:closed', name)
    end,
    GetCore = function() return Core end,
}

-- ── v-voice ────────────────────────────────────────────────────
-- A phone call is a voice channel both parties join. pma-voice and saltychat both do
-- this; the config picks, `auto` finds.
local VOICE = { 'pma-voice', 'saltychat', 'mumble-voip' }

local function voiceResource()
    local wanted = tostring((Config.Compat and Config.Compat.voice) or 'auto'):lower()
    if wanted == 'off' then return nil end
    if wanted ~= 'auto' then return realGetResourceState(wanted) == 'started' and wanted or nil end
    return anyStarted(VOICE)
end

--- The channel a call runs on. Spread over a range so two calls in the same minute do
--- not share one, which would let each side hear the other conversation.
local function callChannel(callId)
    local base = tonumber((Config.Compat and Config.Compat.voiceChannel) or 700) or 700
    return base + (math.floor(tonumber(callId) or 0) % 24)
end

STUBS['v-voice'] = {
    PhoneCallStart = function(_, callId)
        if isServer or not callId then return end
        local voice = voiceResource()
        if voice == 'pma-voice' then
            exports['pma-voice']:setVoiceProperty('radioEnabled', true)
            exports['pma-voice']:setRadioChannel(callChannel(callId))
        elseif voice == 'saltychat' then
            TriggerEvent('SaltyChat_SetRadioChannel', tostring(callChannel(callId)), true)
        end
    end,
    PhoneCallEnd = function(_, callId)
        if isServer then return end
        local voice = voiceResource()
        if voice == 'pma-voice' then
            exports['pma-voice']:setRadioChannel(0)
        elseif voice == 'saltychat' then
            TriggerEvent('SaltyChat_SetRadioChannel', '', true)
        end
    end,
    --- Speaker mode: everyone nearby hears the call. Only pma-voice exposes the
    --- per-channel listen this needs; elsewhere the call stays private, which is the
    --- safe failure.
    SpeakerListen = function(_, callId, on)
        if isServer or voiceResource() ~= 'pma-voice' then return end
        if on then
            exports['pma-voice']:setVoiceProperty('radioEnabled', true)
            exports['pma-voice']:addPlayerToRadio(callChannel(callId))
        else
            exports['pma-voice']:removePlayerFromRadio(callChannel(callId))
        end
    end,
}

-- ── v-status ───────────────────────────────────────────────────
-- The health app. Vitals are read on the client, where the game already knows them, and
-- hunger and thirst come from whichever status script is running.
STUBS['v-status'] = {
    Get = function()
        if isServer then return Bridge and Bridge.Status and Bridge.Status.Get(source) or {} end
        local ped = PlayerPedId()
        local out = {
            health = math.max(0, math.floor(GetEntityHealth(ped) - 100)),
            armour = math.floor(GetPedArmour(ped)),
        }
        if realGetResourceState('esx_status') == 'started' then
            TriggerEvent('esx_status:getStatus', 'hunger', function(s) out.hunger = math.floor(s.getPercent()) end)
            TriggerEvent('esx_status:getStatus', 'thirst', function(s) out.thirst = math.floor(s.getPercent()) end)
        elseif LocalPlayer and LocalPlayer.state then
            out.hunger = LocalPlayer.state.hunger
            out.thirst = LocalPlayer.state.thirst
        end
        return out
    end,
}

-- ── v-ui ───────────────────────────────────────────────────────
-- The theme ships inside this resource now, so the version is this resource's.
STUBS['v-ui'] = {
    Version = function() return GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '1.0.0' end,
}

-- ── v-world ────────────────────────────────────────────────────
-- Upstream's world module stores map data an admin edits in game: where the chargers
-- are, which apps a server has hidden, the job list. Here those come from the config
-- file, so "seeding" it is a no-op and the reads answer from Config and the framework.
STUBS['v-world'] = {
    IsReady = function() return true end,
    GetJobs = function() return (Bridge and Bridge.Jobs and Bridge.Jobs.All()) or {} end,
    --- Upstream lets an admin add or hide phone apps from an in-game editor. The config
    --- file is that editor here, so there is nothing extra to report.
    GetPhoneApps = function() return {} end,
    --- Chargers and dead zones were rows an admin placed on a map. Here they are the
    --- config's own lists, read straight back, so the battery and signal code upstream
    --- needs no change.
    GetChargers = function() return (Config and Config.Chargers) or {} end,
    GetDeadZones = function() return (Config and Config.DeadZones) or {} end,
    SeedApps = function() end,
    SeedChargers = function() end,
    SeedDeadZones = function() end,
}

-- ── v-music ────────────────────────────────────────────────────
-- The music app plays through whatever media script the server runs. Without one it
-- stays hidden rather than pretending to play.
STUBS['v-music'] = {
    Play = function(_, ...) return nil end,
    Stop = function(_, ...) return nil end,
}

-- ── v-inventory ────────────────────────────────────────────────
-- One thing only: "using" an item runs a function. Every inventory script offers this
-- under its own name, and a server with none simply has no usable items.
STUBS['v-inventory'] = {
    RegisterUsableItem = function(_, item, fn)
        if not isServer then return end
        local inv = Bridge and Bridge.InventoryResource and Bridge.InventoryResource()

        -- ox_inventory declares items in its own data file and announces the use.
        if inv == 'ox_inventory' then
            AddEventHandler('ox_inventory:usedItem', function(src, name)
                if name == item then fn(src) end
            end)
            return
        end

        -- qb-core and qbx both expose CreateUseableItem as a direct export; the helper
        -- knows which one is running, so this works on either without a shared object.
        if Bridge and Bridge.framework == 'qb' and Bridge.QBUsable then
            if Bridge.QBUsable(item, fn) then return end
        end

        if Bridge and Bridge.framework == 'esx' then
            local ok, ESX = pcall(function() return realExports['es_extended']:getSharedObject() end)
            if ok and ESX and ESX.RegisterUsableItem then
                ESX.RegisterUsableItem(item, function(src) fn(src) end)
                return
            end
        end

        -- Nothing to register with. The item still exists in whatever inventory the
        -- server runs; it simply does nothing when used, which is honest.
    end,
    HasItem = function(_, src, item)
        return Bridge and Bridge.HasItem and Bridge.HasItem(src, item) or true
    end,
}

-- ══════════════════════════════════════════════════════════════
-- Which of these count as "started"
-- ══════════════════════════════════════════════════════════════
-- A stub with nothing behind it must NOT report as started, or the phone shows an app
-- that can never answer. Each entry says what makes its module real on this server.
local function stubIsLive(name)
    if name == 'v-core' or name == 'v-ui' or name == 'v-world' then return true end
    if name == 'v-phone' then return true end
    if name == 'v-voice' then return voiceResource() ~= nil end
    if name == 'v-status' then return true end
    if name == 'v-inventory' then return true end
    if name == 'v-banking' then return Bridge ~= nil and Bridge.Banking ~= nil end
    if name == 'v-music' then return false end
    if name == 'v-police' then
        return (Config.Compat and Config.Compat.policeJobs and #Config.Compat.policeJobs > 0) or false
    end
    if name == 'v-housing' or name == 'v-vehicles' or name == 'v-licenses' or name == 'v-cityhall' then
        -- These are only real if the app that reads them is shipped at all. The config
        -- decides; a server with no garage script removes the app rather than seeing an
        -- empty one.
        return (Config.Compat and Config.Compat.modules and Config.Compat.modules[name]) ~= false
    end
    return false
end

-- ══════════════════════════════════════════════════════════════
-- The shims themselves
-- ══════════════════════════════════════════════════════════════
exports = setmetatable({}, {
    __index = function(_, resource)
        local stub = STUBS[resource]
        if stub and realGetResourceState(resource) ~= 'started' then return stub end
        return realExports[resource]
    end,
    __call = function(_, name, fn) return realExports(name, fn) end,
})

function GetResourceState(resource)
    if type(resource) == 'string' and resource:sub(1, 2) == 'v-' then
        if resource == GetCurrentResourceName() then return 'started' end
        if realGetResourceState(resource) == 'started' then return 'started' end
        return stubIsLive(resource) and 'started' or 'missing'
    end
    return realGetResourceState(resource)
end

-- `V.Use('v-world').GetPhoneApps()` calls with a dot, `exports['v-world']:GetPhoneApps()`
-- calls with a colon. Same stub, two calling conventions, so the provider drops the self
-- the export form passes and the dot form never sends.
CreateThread(function()
    for name, stub in pairs(STUBS) do
        local provider = {}
        for key, fn in pairs(stub) do
            provider[key] = function(...) return fn(nil, ...) end
        end
        V.RegisterProvider(name, provider)
    end
end)
