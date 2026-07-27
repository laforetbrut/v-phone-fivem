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

--- **Which voice script is actually going to carry a call.**
---
--- Exposed because `GetResourceState('v-voice')` is the wrong question and was being asked: this
--- resource has no `v-voice`, it has a STUB that drives pma-voice or SaltyChat on its behalf. A
--- caller gating on the resource being started therefore gated on something that is never true,
--- and the whole branch behind it did nothing. Ask this instead.
---
--- Returns the resource name, or nil when nothing here can carry audio.
function PhoneVoiceScript()
    return voiceResource()
end

--- The channel a call runs on. Spread over a range so two calls in the same minute do
--- not share one, which would let each side hear the other conversation.
--- How many channels calls may spread over. Read in one place, because the server's call-id
--- allocator has to agree with this exactly: it hands out ids inside this span and refuses to
--- reuse a live one, which is what keeps two conversations off the same channel. pma-voice
--- puts everybody on `callData[channel]` and lets them hear each other, so a collision is not
--- a glitch - it is one call listening to another.
function VoiceChannelSpan()
    return math.max(4, math.min(4096,
        math.floor(tonumber((Config.Compat and Config.Compat.voiceChannels) or 256) or 256)))
end

local function callChannel(callId)
    local base = tonumber((Config.Compat and Config.Compat.voiceChannel) or 700) or 700
    return base + (math.floor(tonumber(callId) or 0) % VoiceChannelSpan())
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
-- The headphone sound's name. One per client is enough: a phone plays one track, and giving
-- it a fixed name is what makes "stop whatever is playing" a single call.
local PRIVATE_SOUND = 'vphone_music'

--- Does xsound currently hold a sound by this name?
---
--- Every one of xsound's manipulation exports indexes its own table without checking first:
--- `Pause`, `Resume`, `setVolume` and `Destroy` all do `soundInfo[name].field = ...`. Calling any
--- of them for a sound that was never created throws inside xsound - and a `pcall` on THIS side
--- cannot catch it, because the export runs in xsound's runtime and the error is raised and
--- printed there. The console filled with `manipulation.lua:87: attempt to index a nil value`
--- every time the volume moved with nothing playing, which is most of the time.
---
--- So the guard has to be asked, not assumed. `soundExists` is the one export that is safe to
--- call for a name that is not there.
local function xsoundHas(name)
    local ok, exists = pcall(function() return exports.xsound:soundExists(name) end)
    return ok and exists == true
end

--- A track URL xsound can actually deal with.
---
--- xsound reads a YouTube link with this, in its own NUI:
---
---     if (url.indexOf("youtube") !== -1) {
---         let urlParts = url.split("?v=");
---         videoId = urlParts[1].substring(0, 11);   // undefined.substring on a miss
---     }
---
--- So any URL containing "youtube" but no `?v=` - a `music.youtube.com` link, a `/shorts/`
--- link, an `/embed/` link, a playlist - throws inside THEIR page. Nothing reaches the server
--- console, nothing reaches F8, and the player gets silence with no error: exactly the report
--- that led here.
---
--- This is not ours to fix in their resource, but it is ours not to hand them a URL we know
--- they cannot read. Every YouTube form is reduced to the one canonical shape their matcher
--- handles, and a form with no video id in it at all is refused with a message that says so
--- rather than played into silence.
---
--- Returns url, err.
function MusicNormaliseUrl(url)
    url = tostring(url or '')
    if url == '' then return nil, 'nourl' end
    if not url:match('^https?://') then return nil, 'nourl' end

    local lower = url:lower()
    if not (lower:find('youtube', 1, true) or lower:find('youtu.be', 1, true)) then
        -- Anything else is a direct media link as far as we are concerned, and xsound hands it
        -- to an audio element. Not our business to second-guess.
        return url, nil
    end

    -- Every shape a YouTube link comes in, reduced to its eleven-character id.
    local id = url:match('[?&]v=([%w_-]+)')
        or url:match('youtu%.be/([%w_-]+)')
        or url:match('/shorts/([%w_-]+)')
        or url:match('/embed/([%w_-]+)')
        or url:match('/live/([%w_-]+)')
    if id then id = id:sub(1, 11) end

    -- A playlist or a channel link has no single video in it. Refused, because there is
    -- nothing to play and silence would be the alternative.
    if not id or #id < 11 then return nil, 'ytform' end

    return ('https://www.youtube.com/watch?v=%s'):format(id), nil
end

-- Said once per session, not once per call: a warning that repeats every time somebody
-- dials is noise that hides the next real line.
local warnedNoCalls = false

STUBS['v-voice'] = {
    PhoneCallStart = function(_, callId)
        if isServer or not callId then return end
        local voice = voiceResource()
        if voice == 'pma-voice' then
            -- pma-voice's own `setCallChannel` opens with `if GetConvarInt('voice_enableCalls',
            -- 1) ~= 1 then return end` - it returns SILENTLY, on both the client and the
            -- server. With calls disabled the phone therefore works perfectly except that
            -- nobody can hear anybody, which is a support ticket rather than a symptom. Said
            -- once, here, where it is about to matter.
            if GetConvarInt('voice_enableCalls', 1) ~= 1 and not warnedNoCalls then
                warnedNoCalls = true
                print('[v-phone] pma-voice has calls disabled (voice_enableCalls is not 1), '
                    .. 'so a phone call will carry no audio. Remove `setr voice_enableCalls 0` '
                    .. 'from server.cfg, or set Config.Compat.voice = "off" to stop trying.')
            end
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
    --- Speaker mode: the people around you are ON the call.
    ---
    --- They hear it and the far end hears them, which is what a speakerphone is. That is not a
    --- choice this makes - it is what pma-voice does with a call channel. `addPlayerToCall`
    --- wires each arrival to every member already there and sends the new member the whole
    --- list, so voice flows both ways between all of them. There is no listen-only channel to
    --- ask for.
    ---
    --- Only pma-voice exposes calls this way. On saltychat and on a server with no voice
    --- script the call stays private, which is the safe failure: a feature that does nothing
    --- is better than one that leaks a conversation somewhere nobody expected.
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
    --- The Maps app asks v-world for the places it can pin. Upstream those are rows an
    --- admin placed; there is no such table here, and inventing garage coordinates for
    --- every server would put wrong pins on real maps.
    ---
    --- They return empty rather than being absent: `stubIsLive` reports v-world as started,
    --- so `V.Use('v-world')` hands back THIS table, and a missing key is a nil call that
    --- takes the whole `v-phone:places` callback down with it.
    GetGarages = function() return {} end,
    GetShopLocations = function() return {} end,
    GetStations = function() return {} end,
    GetMechShops = function() return {} end,
    GetCityHalls = function() return {} end,
    GetDealers = function() return {} end,
    SeedApps = function() end,
    SeedChargers = function() end,
    SeedDeadZones = function() end,
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
-- **xsound first, and deliberately.**
--
-- The other two are paid resources. A phone whose Music app only works if you have bought
-- something is a Music app most servers cannot use, which is how this app spent its life
-- hidden. xsound is MIT, free, and does the one thing needed: play a URL, positioned or
-- private, and stop it again.
--
-- It is also the only one of the three the phone can DRIVE. The two decks below open their
-- own interface and the player pastes the link; with xsound the phone plays the track itself,
-- which is what the app looked like it did all along.
local MUSIC_DECKS = { 'xsound', 'rcore_radiocar', 'xdiskjockey' }

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
--- Which deck will actually be handed this track.
---
--- **xsound first, always.** It is the only one of the three the phone can DRIVE: it plays a URL
--- where the phone tells it to, so the Music app's own outputs - headphones, speaker, car - all
--- work. The other two can only be OPENED: the phone puts the link on the clipboard and their
--- interface appears for the player to paste into.
---
--- The old order asked for the car radio in a vehicle and then xdiskjockey, and only fell back
--- to `anyStarted` after both. That was written before xsound was supported and became exactly
--- backwards once it was: a server running xsound AND xdiskjockey handed every track to the deck
--- that cannot play it, while the one that can sat there started. From the player's side that is
--- silence with no error, because opening somebody else's mixer is a perfectly successful thing
--- to have done.
---
--- `Config.Music.provider` still overrides all of this by name, for an operator who wants their
--- own deck's interface rather than sound from the phone.
local function musicDeckFor()
    local wanted = tostring((Config.Music or {}).provider or 'auto'):lower()
    if wanted ~= 'auto' then return musicProvider() end

    if realGetResourceState('xsound') == 'started' then return 'xsound' end

    -- No xsound. Now the question is which interface to open, and in a car the car radio is the
    -- one that makes sense.
    local inVehicle = not isServer and IsPedInAnyVehicle(PlayerPedId(), false)
    if inVehicle and realGetResourceState('rcore_radiocar') == 'started' then return 'rcore_radiocar' end
    if realGetResourceState('xdiskjockey') == 'started' then return 'xdiskjockey' end
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

        -- xsound: the phone plays the track itself rather than opening somebody else's UI.
        --
        -- Two different problems behind one button. Headphones are private, so the sound is
        -- started on THIS client and nobody else ever holds it. The speaker and the car radio
        -- have to exist on every client near you, so they are the server's to broadcast - and
        -- the server also has to keep pushing the position, or the music stands still while
        -- the player walks away from it. See server/music.lua.
        if deck == 'xsound' then
            -- Normalised before it is handed over, because xsound's own YouTube matcher throws
            -- on several perfectly ordinary link shapes and the failure is silent.
            local url, urlErr = MusicNormaliseUrl(track.url)
            if not url then return { error = urlErr or 'nourl' } end
            local volume = math.max(0.0, math.min(1.0, tonumber(track.volume) or 0.65))

            if output == nil or output == 'headphones' then
                -- Whatever was playing goes first: one phone, one track.
                if xsoundHas(PRIVATE_SOUND) then
                    pcall(function() exports.xsound:Destroy(PRIVATE_SOUND) end)
                end
                local ok = pcall(function()
                    exports.xsound:PlayUrl(PRIVATE_SOUND, url, volume, false)
                end)
                return ok and { ok = true, driven = true, deck = 'xsound' } or { error = 'nodeck' }
            end

            -- The speaker and the car. A private sound left over from headphone mode would
            -- otherwise play on top of the broadcast one, in the same ears.
            if xsoundHas(PRIVATE_SOUND) then
                pcall(function() exports.xsound:Destroy(PRIVATE_SOUND) end)
            end
            local answer
            V.Request('v-phone:music:play', function(res) answer = res end,
                { url = url, volume = volume, mode = output })
            local waited = 0
            while answer == nil and waited < 5000 do Wait(50); waited = waited + 50 end
            return answer or { error = 'timeout' }
        end

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
        -- xsound: both halves, because the player may have switched output mid-track and
        -- either one could be the live one.
        if musicDeckFor() == 'xsound' then
            if xsoundHas(PRIVATE_SOUND) then
                pcall(function() exports.xsound:Destroy(PRIVATE_SOUND) end)
            end
            V.Request('v-phone:music:stop', function() end)
            return { ok = true, driven = true }
        end

        -- The decks own their own transport; the most the phone can do is put the DJ mixer
        -- away. A car radio has no documented close.
        pcall(function() realExports.xdiskjockey:HideDiskjockeyUI() end)
        return { ok = true }
    end,

    --- Pause, or pick the track up again.
    ---
    --- Deliberately NOT "stop, then play from the top". A stream restarted from zero is not a
    --- pause, and on a long mix that is the difference between a working button and a
    --- baffling one. Only xsound can do this: the other two decks own their own transport and
    --- expose no pause, so the honest answer there is that the phone cannot.
    Pause = function(_, resume)
        if isServer then return nil end
        local M = Config.Music or {}
        if type(M.hooks) == 'table' and type(M.hooks.pause) == 'function' then
            local ok, done = pcall(M.hooks.pause, resume == true)
            if ok and done then return { ok = true, driven = true } end
        end
        if musicDeckFor() ~= 'xsound' then return { error = 'nopause' } end

        -- Both halves, because either could be the live one: the player may have switched
        -- output mid-track. The private sound is only touched when xsound actually holds it -
        -- pausing one it does not know about is not a no-op, it is an error in its runtime.
        if xsoundHas(PRIVATE_SOUND) then
            pcall(function()
                if resume then exports.xsound:Resume(PRIVATE_SOUND)
                else exports.xsound:Pause(PRIVATE_SOUND) end
            end)
        end
        local answer
        V.Request('v-phone:music:pause', function(res) answer = res end, { resume = resume == true })
        local waited = 0
        while answer == nil and waited < 3000 do Wait(50); waited = waited + 50 end
        -- The private sound is this client's own and needs no server answer, so a server that
        -- had nothing playing is not a failure - it just means the track was in the earphones.
        return { ok = true, driven = true, paused = resume ~= true }
    end,

    Volume = function(_, level)
        if isServer then return nil end
        local M = Config.Music or {}
        if type(M.hooks) == 'table' and type(M.hooks.volume) == 'function' then
            local ok, done = pcall(M.hooks.volume, level)
            return { ok = ok and done == true }
        end

        if musicDeckFor() == 'xsound' then
            local volume = math.max(0.0, math.min(1.0, tonumber(level) or 0.65))
            -- Whichever one is live. The private sound is asked about first: this line ran on
            -- every movement of the slider, and with nothing in the earphones each one printed
            -- a stack trace from inside xsound.
            if xsoundHas(PRIVATE_SOUND) then
                pcall(function() exports.xsound:setVolume(PRIVATE_SOUND, volume) end)
            end
            V.Request('v-phone:music:volume', function() end, { volume = volume })
            return { ok = true, driven = true }
        end

        return { error = 'nohook' }
    end,

    --- Which deck is live, for the app to describe itself accurately.
    Provider = function() return musicProvider() end,
}

MusicProvider = musicProvider

--- The deck a track would be handed right now. Exposed for `/phonemusic`, which has to be able
--- to print the answer that decides rather than the answer that sounds right.
MusicDeckInUse = musicDeckFor

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
-- The apps this resource answers for
-- ══════════════════════════════════════════════════════════════
--- Has the operator switched this app off?
---
--- `Config.Compat.apps` names them plainly. The older `Config.Compat.modules` used the
--- author's v-* module names and is still honoured, because ignoring a switch somebody set is
--- worse than carrying two spellings for it.
---
--- Shared rather than duplicated: the home screen decides whether to draw the icon and the
--- server callback decides whether to answer, and those two must never disagree - an icon
--- that opens onto "not available" is worse than no icon.
local APP_LEGACY_KEY = {
    bank = 'v-banking', garage = 'v-vehicles', property = 'v-housing',
    wallet = 'v-licenses', jobs = 'v-cityhall',
}

function Bridge_AppEnabled(id)
    id = tostring(id or '')
    local compat = (Config and Config.Compat) or {}
    local apps = compat.apps
    if type(apps) == 'table' and apps[id] ~= nil then return apps[id] ~= false end
    local legacy, name = compat.modules, APP_LEGACY_KEY[id]
    if type(legacy) == 'table' and name and legacy[name] ~= nil then
        return legacy[name] ~= false
    end
    return true
end

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
    -- Live, always.
    --
    -- This used to answer "only when a deck is installed", and the effect was that the whole
    -- Music app vanished from the home screen of every server that has no radio script -
    -- which is most of them. That conflated two different questions. The SHIM is live: it
    -- exists, it answers, and `Play` returns `nodeck` honestly when there is nothing to hand
    -- a track to. Whether a DECK exists is `Provider()`, and it is the app's business to say
    -- so on screen, not a reason to hide a library, playlists and favourites that all work
    -- perfectly well on their own.
    if name == 'v-music' then return true end
    if name == 'v-police' then
        return (Config.Compat and Config.Compat.policeJobs and #Config.Compat.policeJobs > 0) or false
    end
    -- v-banking, v-vehicles, v-licenses, v-cityhall and v-housing are deliberately absent
    -- from this list, and must stay absent.
    --
    -- Reporting them as started was the single cause of four broken apps. Nothing in this
    -- resource answers `v-vehicles:myVehicles` or `v-banking:getData` - those belong to the
    -- author's own suite - so an app that believed the module was running asked a callback
    -- into the void and told the player it was not installed. The apps read the bridge
    -- directly now, and these names answer `missing`, which is the truth.
    --
    -- Anything still genuinely gated on one of them - the Fleeca card, paying rent - now
    -- reports unavailable instead of failing, which is also the truth: those features do
    -- need a resource this server does not have.
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
