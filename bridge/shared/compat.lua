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

-- **A phone call is a CALL channel, not a radio channel.**
--
-- pma-voice ships two separate systems and they are not interchangeable:
--
--   radio  `setRadioChannel(n)`  push-to-talk. `addVoiceTargets` only includes the radio
--                                targets while the radio key is HELD:
--                                `(radioPressed and isRadioEnabled()) and radioData or {}`
--   call   `setCallChannel(n)`   open mic. The call targets are always included.
--
-- Routing a phone call over the radio therefore breaks it in four ways at once: the player
-- has to hold the radio key to be heard, taking a call KICKS them off the job radio they
-- were on (and hanging up leaves them off it, because the reset is `setRadioChannel(0)`),
-- a server that set `voice_enableRadios 0` gets silent calls, and the call lands in the
-- radio channel namespace where it can merge with a real radio channel and let strangers
-- hear each other.
--
-- So: calls use the call API. `voice_enableCalls` gates it, pma-voice tells its own server
-- about the change, and radio is left entirely alone.
STUBS['v-voice'] = {
    PhoneCallStart = function(_, callId)
        if isServer or not callId then return end
        local voice = voiceResource()
        if voice == 'pma-voice' then
            exports['pma-voice']:setCallChannel(callChannel(callId))
        elseif voice == 'saltychat' then
            TriggerEvent('SaltyChat_SetRadioChannel', tostring(callChannel(callId)), true)
        end
    end,
    PhoneCallEnd = function(_, callId)
        if isServer then return end
        local voice = voiceResource()
        if voice == 'pma-voice' then
            -- Channel 0 is pma-voice's own "leave the call" value.
            exports['pma-voice']:setCallChannel(0)
        elseif voice == 'saltychat' then
            TriggerEvent('SaltyChat_SetRadioChannel', '', true)
        end
    end,
    --- Speaker mode: the people around you hear the call. A listener simply joins the same
    --- call channel. Only pma-voice exposes this; elsewhere the call stays private, which
    --- is the safe failure.
    SpeakerListen = function(_, callId, on)
        if isServer or voiceResource() ~= 'pma-voice' then return end
        exports['pma-voice']:setCallChannel(on and callChannel(callId) or 0)
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

-- ── v-cityhall ─────────────────────────────────────────────────
-- The Jobs app's "Openings" tab. Upstream this is a city hall module with vacancies an
-- admin posts; here every job the framework knows about is an opening, listed at its entry
-- rank and starting pay, which is the honest answer without inventing a vacancies table.
--
-- This stub is not optional. `stubIsLive` reports v-cityhall as started (the config's
-- `modules` list enables it), so without an entry here `V.Use('v-cityhall')` fell through
-- to the real exports of a resource that does not exist, and the whole `v-phone:jobs`
-- callback died on the OpenPositions call - taking the Jobs app with it.
STUBS['v-cityhall'] = {
    OpenPositions = function()
        if not isServer then return {} end
        local jobs = (Bridge and Bridge.Jobs and Bridge.Jobs.All()) or {}
        local out = {}
        for _, job in ipairs(jobs) do
            local grades = job.grades or {}
            local entry = grades[1] or {}
            out[#out + 1] = {
                name = job.name,
                label = job.label or job.name,
                grade = entry.label or '',
                ranks = #grades,
                salary = tonumber(entry.pay) or 0,
            }
        end
        return out
    end,
}

-- ── v-music ────────────────────────────────────────────────────
-- **The phone is a remote, not an audio engine.**
--
-- Nothing in a NUI page can stream a URL into the game world, so the sound always belongs to
-- a music resource the server already runs. Two are supported out of the box, both from
-- rcore: the car radio for a player sitting in a vehicle, and the DJ deck for one on foot.
--
-- Their public APIs are UI-only. `rcore_radiocar` publishes `OpenPlayerUI` and the
-- plate-keyed ownership helpers; `xdiskjockey` publishes `OpenDiskjockeyUI` and
-- `HideDiskjockeyUI`. Neither documents an export that takes a URL and plays it. So the
-- phone hands off rather than pretending: it opens the right deck and puts the track's URL
-- on the clipboard, and the player pastes.
--
-- A server whose music script CAN be driven fills `Config.Music.hooks.play`, and that wins
-- outright - no deck, no paste, the track simply plays.
local MUSIC_DECKS = { 'rcore_radiocar', 'xdiskjockey' }

--- Which deck this server has, or `hooks` when the operator drives playback themselves.
--- nil means the app has nothing to talk to and stays hidden.
local function musicProvider()
    local M = Config.Music or {}
    if M.enabled == false then return nil end

    local wanted = tostring(M.provider or 'auto'):lower()
    if wanted == 'off' then return nil end
    -- A filled play hook is a working integration on its own, whatever else is installed.
    if type(M.hooks) == 'table' and type(M.hooks.play) == 'function' then return 'hooks' end
    if wanted == 'hooks' then return nil end
    if wanted ~= 'auto' then
        return realGetResourceState(wanted) == 'started' and wanted or nil
    end
    return anyStarted(MUSIC_DECKS)
end

--- `auto` again, but at the moment of playing rather than at boot: the car radio only makes
--- sense when the player is actually in a car.
local function musicDeckFor()
    local wanted = tostring((Config.Music or {}).provider or 'auto'):lower()
    if wanted ~= 'auto' then return musicProvider() end
    local inVehicle = not isServer and IsPedInAnyVehicle(PlayerPedId(), false)
    if inVehicle and realGetResourceState('rcore_radiocar') == 'started' then return 'rcore_radiocar' end
    if realGetResourceState('xdiskjockey') == 'started' then return 'xdiskjockey' end
    -- On foot with only a car radio installed: still the honest answer, it just opens in a car.
    return anyStarted(MUSIC_DECKS)
end

STUBS['v-music'] = {
    --- Hand a track to the deck. Returns what the page needs to finish the job:
    --- `driven` when a hook played it outright, `copy` when the player has to paste.
    Play = function(_, track, output)
        if isServer then return nil end
        local M = Config.Music or {}
        track = type(track) == 'table' and track or {}

        if type(M.hooks) == 'table' and type(M.hooks.play) == 'function' then
            local ok, played = pcall(M.hooks.play, track, output)
            if ok and played then return { ok = true, driven = true } end
        end

        local deck = musicDeckFor()
        if not deck or deck == 'hooks' then return { error = 'nodeck' } end

        if deck == 'rcore_radiocar' then
            -- The export is the documented route; the event is its published alias, and some
            -- builds only carry one of the two.
            if not pcall(function() realExports.rcore_radiocar:OpenPlayerUI() end) then
                TriggerEvent('rcore_radiocar:API:OpenPlayerUI')
            end
        elseif deck == 'xdiskjockey' then
            if not pcall(function() realExports.xdiskjockey:OpenDiskjockeyUI() end) then
                TriggerEvent('xdiskjockey:openMixer')
            end
        end

        return { ok = true, deck = deck,
                 -- The page owns the clipboard; Lua has no access to it.
                 copy = (M.copyUrl ~= false) and tostring(track.url or '') or nil }
    end,

    Stop = function(_)
        if isServer then return nil end
        local M = Config.Music or {}
        if type(M.hooks) == 'table' and type(M.hooks.stop) == 'function' then
            local ok, stopped = pcall(M.hooks.stop)
            if ok and stopped then return { ok = true, driven = true } end
        end
        -- The decks own their own transport; the most the phone can do is put the DJ mixer
        -- away. A car radio has no documented close.
        pcall(function() realExports.xdiskjockey:HideDiskjockeyUI() end)
        return { ok = true }
    end,

    Volume = function(_, level)
        if isServer then return nil end
        local M = Config.Music or {}
        if type(M.hooks) == 'table' and type(M.hooks.volume) == 'function' then
            local ok, done = pcall(M.hooks.volume, level)
            return { ok = ok and done == true }
        end
        return { error = 'nohook' }
    end,

    --- Which deck is live, for the app to describe itself accurately.
    Provider = function() return musicProvider() end,
}

MusicProvider = musicProvider

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
        -- Fail open only when there is nothing to ask. When the bridge IS here its answer is
        -- the answer, including "no": `... and Bridge.HasItem(src, item) or true` collapses a
        -- real `false` back to `true`, which would make requireItem pass for everybody.
        --
        -- This key is the one both this stub and bridge/server/integrations.lua register, so
        -- whichever wins the provider merge has to behave the same. It did not.
        if Bridge and Bridge.HasItem then return Bridge.HasItem(src, item) end
        return true
    end,
    --- Consume an item. Upstream's v-inventory offers this and callers here expect it: the
    --- power bank spends itself, and a payphone eats a prepaid card. Without it in the stub
    --- those call sites reach a nil field on a server with no v-inventory resource, which is
    --- every server this bridge exists for.
    RemoveItem = function(_, src, item, count)
        if not isServer then return false end
        return (Bridge and Bridge.RemoveItem and Bridge.RemoveItem(src, item, count)) or false
    end,
    ItemCount = function(_, src, item)
        if not isServer then return 0 end
        return (Bridge and Bridge.ItemCount and Bridge.ItemCount(src, item)) or 0
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
    -- Live when there is a deck to hand a track to, or a hook that plays one. Before 1.2.0
    -- this was hardcoded false, which hid a complete Music app on every server.
    if name == 'v-music' then return MusicProvider ~= nil and MusicProvider() ~= nil end
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
