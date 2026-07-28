-- v-phone | client
--
-- The bridge between the iFruit page and the modules it is a view of.
--
-- **App data is fetched from the module that owns it, not from v-phone.** The bank app
-- calls `v-banking:getData`, the garage app calls `v-vehicles:myVehicles`, the wallet app
-- calls `v-licenses:mine`. Routing those through the phone server would put a second copy
-- of each module's rules in the phone, and a second copy is a second answer.
--
-- The phone does **no audio**: a call hands both ends to `v-voice`, which owns the Mumble
-- channel. The phone only decides who is talking to whom, and the server decides that.

local isOpen  = false
local isOpening = false
local openingAssets = false
local openRequest = 0
local menuClaimed = false
local phoneTorch = false   -- control-centre flashlight
local myNumber = nil
local call    = nil          -- { id, state = 'out'|'in'|'active', number }
local power   = { battery = 100, charging = false, signal = 4 }
local activeSdkApp = nil     -- selected by the phone shell, never by an SDK payload
local activeSdkEpoch = 0     -- rejects late shell requests that arrive out of order
local sdkApps = {}           -- installed iframe apps allowed for this open session
local pendingUiActions = {}  -- prompts received while the asynchronous open is in flight
local applyServerCall
local camModeOff            -- defined with the camera mode, used by closePhone above it
-- The camera's state, declared here because `startGuard` sits above the block that owns it
-- and watches these. Lua binds lexically: from up there, a later `local` is a nil global.
local camActive = false
local camHidHud, camHidRadar = false, false   -- only restore what we hid
local camShooting = false   -- a capture is in flight; the help box must stay off screen for
                            -- all of it, not just the frame the shutter was pressed on
local camTick = 0           -- last frame the camera thread ran, so the guard can notice it
                            -- is flagged on with nothing running it
local refreshPose           -- re-plays the hold animation; the camera block below needs it
local selfieReset           -- clears the selfie framing; forceReset calls it from above
local frontCam              -- the selfie toggle, defined with the camera block; forceReset
                            -- calls it from above and would otherwise reach a nil global that
                            -- its own pcall would then hide
local selfieCam             -- the selfie's scripted cam, read by the camera-mode thread
                            -- which sits above the block that assigns it
local mediaOn = false        -- server-side capture and upload, decided by the server

local function sdkAppId(value)
    local id = tostring(value or '')
    if id == '' then return '' end
    if not id:match('^[%w_-]+$') then return nil end
    return id
end

local function syncSdkApps(apps)
    sdkApps = {}
    if type(apps) == 'table' then
        for _, app in ipairs(apps) do
            local id = type(app) == 'table' and sdkAppId(app.id) or nil
            if id and id ~= '' and app.page then sdkApps[id] = true end
        end
    end
    if activeSdkApp and not sdkApps[activeSdkApp] then activeSdkApp = nil end
end

--- The string table handed to the page.
---
--- `PhoneLang()` rather than a second copy of the same logic: this used to default to 'fr'
--- while `bridge/shared/locale.lua` defaulted to 'en', so a server that set `phone_locale`
--- with a non-replicated `set` got a French phone and an English payphone prompt. One
--- default, in one place.
---
--- A key missing from the chosen language falls back to English, exactly as `L` does, so a
--- half-translated locale file shows English rather than raw keys.
local function strings()
    local lang = PhoneLang()
    local chosen = Locales[lang]
    if not chosen then return Locales[LOCALE_FALLBACK] or Locales.fr or {} end
    if lang == LOCALE_FALLBACK then return chosen end
    local base = Locales[LOCALE_FALLBACK] or Locales.fr or {}
    local merged = {}
    for k, v in pairs(base) do merged[k] = v end
    for k, v in pairs(chosen) do merged[k] = v end
    return merged
end
local function L(k) return strings()[k] or k end

--- The same table, by a name another client file can reach. client/booth.lua sends it with
--- the payphone panel, which is the one screen reachable without opening the phone.
PhoneStrings = strings

--- The page asking for its own string table.
---
--- The table is sent with every `open` and that is not sufficient: the page can be drawn
--- before any open - a payphone, an incoming call, a banner - and NUI drops a message sent to
--- a page that has not finished loading, silently, with nothing logged. A page that ASKS
--- cannot be too early, because it only asks once it exists.
RegisterNUICallback('strings', function(_, cb)
    cb({ strings = strings(), locale = PhoneLang() })
end)

--- And when the language arrives after the page did.
---
--- The server pushes the language onto a state bag as the character loads. If the page had
--- already asked, it holds the fallback language - correct English rather than raw keys, but
--- still not what the operator configured. This hands over the right table the moment it can
--- be known, rather than waiting for the next time the phone is opened.
AddStateBagChangeHandler('lang', ('player:%s'):format(GetPlayerServerId(PlayerId())),
    function(_, _, value)
        if type(value) ~= 'string' or value == '' then return end
        SendNUIMessage({ action = 'strings', strings = strings(), locale = value })
    end)

--- The operator's palette, for the page to apply.
---
--- Only what was actually set: a nil stays nil and the page leaves the stylesheet's own value
--- alone. Sending the whole table with blanks in it would mean the page having to tell "not
--- configured" from "configured as empty", which is a distinction nobody needs to make twice.
function PhoneTheme()
    local cfg = Config.Theme or {}
    local out = {}
    for _, key in ipairs({ 'accent', 'green', 'red', 'orange', 'yellow',
                           'indigo', 'pink', 'teal', 'purple', 'grey' }) do
        local value = cfg[key]
        -- A hex code and nothing else. This ends up inside a CSS custom property, and a colour
        -- is the only thing that has any business being there - the same check the Alerts app
        -- makes on its category colours.
        if type(value) == 'string' and value:match('^#%x%x%x%x?%x?%x?%x?%x?$') then
            out[key] = value
        end
    end
    return out
end

RegisterNUICallback('theme', function(_, cb)
    cb({ ok = true, theme = PhoneTheme(), dark = (Config.Theme or {}).dark })
end)

--- Can a call carry audio at all?
---
--- **Not `GetResourceState('v-voice')`.** There is no `v-voice` resource - bridge/shared/compat.lua
--- serves that name from a stub that drives pma-voice or SaltyChat - so that check was false on
--- every server, and everything behind it was dead code. It is why the bad-signal cut-out had no
--- audible effect: `leaveCallAudio` was a no-op.
---
--- A real `v-voice`, if somebody ships one, still wins; otherwise the stub answers for whichever
--- voice script is running.
local function voice()
    if GetResourceState('v-voice') == 'started' then return true end
    return PhoneVoiceScript and PhoneVoiceScript() ~= nil
end

--- The client half of the same switch the server answers in the phone's payload. Config first,
--- then the convar, and off unless one of them says otherwise.
local function debugOn()
    if (Config.Log or {}).debug == true then return true end
    return GetConvar('phone_debug', '') == 'true'
end

-- ══════════════════════════════════════════════════════════════
-- Ring, buzz, and the peek out of the pocket
-- ══════════════════════════════════════════════════════════════
-- A phone that never made a sound was a phone you had to remember to look at. It rings
-- while a call comes in, buzzes for a message, and - when it is in your pocket rather than
-- in your hand - lifts the top of the handset into view to show you the notification.
local ringing = false
local ringSoundId = nil
local prefsCache = {
    dnd = false, vibrate = true, ringVolume = 0.7, ringtone = 'default',
    notifMuted = {},
    notifSilent = {},
}
local prefsCacheReady = false
local speakerListens = {}

local function buzz(strong)
    if prefsCache.dnd or prefsCache.vibrate == false then return end
    -- The handset shakes on screen; the pad rumbles if there is one.
    SendNUIMessage({ action = 'buzz' })
    SetPadShake(0, strong and 260 or 130, strong and 90 or 55)
end

local function stopRingSound()
    if not ringSoundId then return end
    StopSound(ringSoundId)
    ReleaseSoundId(ringSoundId)
    ringSoundId = nil
end

local function ringOnce()
    -- The base game's own phone ring, so it sits in the world's sound world.
    stopRingSound()
    ringSoundId = GetSoundId()
    PlaySoundFrontend(ringSoundId, 'Remote_Ring', 'Phone_SoundSet_Michael', true)
end

local function startRinging()
    if ringing then return end
    ringing = true
    CreateThread(function()
        while ringing do
            if not prefsCache.dnd and not isOpen then
                if prefsCache.ringVolume > 0 then ringOnce() end
                buzz(true)
            end
            Wait(1400)
        end
    end)
end

local function stopRinging()
    ringing = false
    stopRingSound()
end

local function syncPrefsCache(pf)
    if type(pf) ~= 'table' then return end
    prefsCache.dnd = pf.dnd == true
    prefsCache.vibrate = pf.vibrate ~= false
    -- Both default ON when the server has not said otherwise, matching prefsOf.
    prefsCache.previews = pf.previews ~= false
    prefsCache.peek = pf.peek ~= false
    prefsCache.ringVolume = tonumber(pf.ringVolume) or 0.7
    prefsCache.ringtone = pf.ringtone or 'default'
    prefsCache.notifMuted = {}
    for _, app in ipairs(type(pf.notifMuted) == 'table' and pf.notifMuted or {}) do
        prefsCache.notifMuted[tostring(app)] = true
    end
    -- The middle level: seen but not heard. A separate list rather than a value per app,
    -- because that is the shape the prefs already store and the shape the page already sends.
    prefsCache.notifSilent = {}
    for _, app in ipairs(type(pf.notifSilent) == 'table' and pf.notifSilent or {}) do
        prefsCache.notifSilent[tostring(app)] = true
    end
    prefsCacheReady = true
    if prefsCache.dnd then
        stopRingSound()
        StopPadShake(0)
    end
end

--- Which app a notification belongs to.
---
--- One place, because "which app is this" was being worked out at every call site and the
--- answer has to be the same for the mute check and the silence check or one of them applies to
--- the wrong app.
local function notificationApp(kind, data)
    local app = kind == 'message' and 'messages' or 'dot'
    if kind ~= 'message' and type(data) == 'table' then
        app = tostring(data.app or data.icon or app)
    end
    return app
end

--- Apps whose notifications a player may never switch off.
---
--- Exactly one, and it is the point of that app: a public alert is unsolicited by definition -
--- it reaches people who were not looking - so an off switch on it is an off switch on the thing
--- it exists to do. Everything else on the phone can be silenced or stopped entirely.
local NEVER_MUTABLE = { alerts = true }

function PhoneNotifiable(app)
    return NEVER_MUTABLE[tostring(app or '')] ~= true
end

--- Nothing at all: no banner, no card in the centre, no sound.
local function notificationMuted(kind, data)
    local app = notificationApp(kind, data)
    if not PhoneNotifiable(app) then return false end
    return prefsCache.notifMuted[app] == true
end

--- Seen but not heard: the banner and the card arrive, the buzz and the tone do not.
---
--- The level most people actually want. "Stop notifications" loses the message; this keeps it
--- and stops it interrupting, which is the difference between an app you mute and an app you
--- turn off and then miss something important from.
local function notificationSilent(kind, data)
    local app = notificationApp(kind, data)
    if not PhoneNotifiable(app) then return false end
    return prefsCache.notifSilent[app] == true
end

-- The peek: the phone is in a pocket, so the top of it rises into view with the
-- notification on it and slides back down. It never takes focus - you are being shown
-- something, not asked to do anything.
local function peek(kind, data)
    if isOpen or notificationMuted(kind, data) then return end
    if data and data.hasItem == false then return end   -- no phone on them, nothing to peek

    -- "Show previews" off: the notification says who it is from and nothing about what it
    -- says. The body is stripped HERE, before it ever reaches the page, so the content is
    -- not merely hidden by CSS - it is not sent.
    local shown = data or {}
    if prefsCache.previews == false and type(shown) == 'table' then
        local copy = {}
        for k, v in pairs(shown) do copy[k] = v end
        copy.body, copy.attachment, copy.preview = nil, nil, nil
        copy.hidden = true
        shown = copy
    end

    -- The archive is the notification centre, which is behind the lock: it keeps the real
    -- content either way.
    SendNUIMessage({ action = 'archive', kind = kind, data = data or {}, strings = strings() })
    if prefsCache.dnd then return end
    -- The peek itself is the handset rising out of a pocket. A player who does not want
    -- their phone announcing itself in the open turns it off and still gets the buzz.
    if prefsCache.peek ~= false then
        SendNUIMessage({ action = 'peek', kind = kind, data = shown, strings = strings() })
    end
    buzz(false)
end

--- One phone notification, raised from another client file.
---
--- `peek`, `isOpen`, `buzz` and `notificationMuted` are file-level locals in here, which is
--- right - the mute preferences and the pocket state have one owner. But client/taxi.lua listens
--- for events a third-party resource broadcasts, and a notification it cannot raise is a
--- notification that does not happen: that is exactly why a taxi booked through doc-taxijob
--- reached every driver's queue and no driver's phone.
---
--- Behaves like every other notification in here: a peek when the phone is pocketed, a banner
--- and a buzz when it is open, and both silent when the app is muted or DND is on.
function PhoneNotify(banner)
    if type(banner) ~= 'table' then return end
    if isOpen then
        SendNUIMessage({ action = 'banner', banner = banner })
        if not notificationMuted('banner', banner)
            and not notificationSilent('banner', banner) then buzz(false) end
    else
        peek('banner', banner)
    end
end

--- The locale table, for a client file that needs a phrase and has no strings() of its own.
function PhoneString(key)
    return L(key)
end

-- ══════════════════════════════════════════════════════════════
-- In hand: a prop and an animation, while you keep walking and driving
-- ══════════════════════════════════════════════════════════════
-- The phone is a real object in the world now. Opening it puts the prop in the right hand
-- and plays a one-handed animation; a call raises it to the ear. The NUI takes cursor
-- focus but keeps game input flowing, and a guard thread disables only aiming, shooting
-- and camera-look - so a tap on the screen does not fire a gun, but movement survives.
local stopSelfie = function() end   -- assigned below; forward-declared so closePhone can call it
local phoneProp = nil
local phoneAnim = nil        -- which clip is playing, so we do not restart it every frame

local function playHold(clip)
    if phoneAnim == clip then return end
    phoneAnim = clip
    local ped = PlayerPedId()
    local dict = Config.Hold.dict
    RequestAnimDict(dict)
    local tries = 0
    while not HasAnimDictLoaded(dict) and tries < 50 do Wait(10) tries = tries + 1 end
    -- Flag 51 = upper body + secondary + allow player movement, so the legs still walk.
    TaskPlayAnim(ped, dict, clip, 3.0, 3.0, -1, 51, 0, false, false, false)
end

local function attachProp()
    if phoneProp then return end
    local model = joaat(Config.Hold.prop)
    RequestModel(model)
    local tries = 0
    while not HasModelLoaded(model) and tries < 50 do Wait(10) tries = tries + 1 end
    if not HasModelLoaded(model) then return end
    local ped = PlayerPedId()
    phoneProp = CreateObject(model, GetEntityCoords(ped), true, true, false)
    local p, r = Config.Hold.pos, Config.Hold.rot
    AttachEntityToEntity(phoneProp, ped, GetPedBoneIndex(ped, Config.Hold.bone),
        p.x, p.y, p.z, r.x, r.y, r.z, true, true, false, true, 1, true)
    SetModelAsNoLongerNeeded(model)
end

local function clearHand()
    if phoneProp then DeleteObject(phoneProp) phoneProp = nil end
    phoneAnim = nil
    local ped = PlayerPedId()
    StopAnimTask(ped, Config.Hold.dict, Config.Hold.browse, 3.0)
    StopAnimTask(ped, Config.Hold.dict, Config.Hold.call, 3.0)
end

-- The pose depends on what the phone is doing: to the ear on an active call, otherwise
-- one-handed at reading height. Re-applied when the state changes.
refreshPose = function()
    if not isOpen then return end
    playHold((call and call.state == 'active') and Config.Hold.call or Config.Hold.browse)
end

-- The control guard: everything in Config.Hold.block is disabled each frame while the
-- phone is up. It also keeps the animation alive if something interrupts it.
-- Holding Alt hands the mouse back to the camera: cursor off, look around, let go and the
-- phone takes it again. `freeLook` is the latch, so focus is only touched on the frame the
-- key actually changes state rather than every frame it is held.
local freeLook = false

-- Escape closes the phone, and that is the whole problem: the page handles the key, the
-- phone closes, `isOpen` goes false and the guard thread below exits - on the same frame the
-- game is still processing that keypress. The block vanished exactly when it was needed, so
-- the phone shut and the pause menu opened behind it.
--
-- So the block outlives the phone by a fraction of a second. `swallowUntil` is set when the
-- phone closes and a small thread keeps refusing the pause menu until it passes.
local swallowUntil = 0

local function swallowPause(ms)
    swallowUntil = GetGameTimer() + (ms or 500)
    CreateThread(function()
        while GetGameTimer() < swallowUntil do
            for _, group in ipairs({ 0, 1, 2 }) do
                DisableControlAction(group, 199, true)
                DisableControlAction(group, 200, true)
            end
            if IsPauseMenuActive() then
                SetFrontendActive(false)
                SetPauseMenuActive(false)
            end
            Wait(0)
        end
    end)
end

local function startGuard()
    freeLook = false
    CreateThread(function()
        while isOpen do
            -- Controls 1 and 2 are look left/right and up/down. Blocking them is right
            -- while the player is browsing - a drag across the screen should not spin the
            -- camera - and it is exactly wrong during free look, which exists to spin the
            -- camera. This is why Alt appeared to do nothing even once focus was released:
            -- the cursor was gone, the game had the mouse, and this line threw the movement
            -- away every frame.
            for _, c in ipairs(Config.Hold.block) do
                -- 1 and 2 are look left/right and up/down. Blocked while browsing, released
                -- for free look AND for the camera: a viewfinder the mouse cannot aim is a
                -- photograph of wherever the player last happened to be looking.
                if not ((freeLook or camActive) and (c == 1 or c == 2)) then
                    DisableControlAction(0, c, true)
                end
            end

            -- The pause menu, held shut three ways because one is not enough.
            --
            -- 199/200 are blocked across control groups 0, 1 and 2: the frontend reads them
            -- from its own group, so blocking group 0 alone leaves Escape working. And when
            -- it opens anyway - it still can, the frontend does not always route through a
            -- control - `SetFrontendActive(false)` is what actually dismisses it.
            -- `SetPauseMenuActive(false)` alone does not, which is why the first attempt
            -- here failed.
            for _, group in ipairs({ 0, 1, 2 }) do
                DisableControlAction(group, 199, true)
                DisableControlAction(group, 200, true)
            end
            if IsPauseMenuActive() then
                SetFrontendActive(false)
                SetPauseMenuActive(false)
            end

            -- Camera mode flagged on with nothing running it: the thread never spawned, or
            -- it died on a native. That state has no exit keys and no cursor, and it is the
            -- phone a player had to reconnect to leave. End it from here, which is the one
            -- loop guaranteed to be running whenever the phone is open.
            if camActive and (GetGameTimer() - camTick) > 1500 then
                camModeOff()
            end

            local ped = PlayerPedId()
            if phoneAnim and not IsEntityPlayingAnim(ped, Config.Hold.dict, phoneAnim, 3) then
                phoneAnim = nil
                refreshPose()
            end
            Wait(0)
        end
        -- The phone closed while Alt was down: do not leave the cursor released.
        freeLook = false
        -- And hold the pause menu shut a moment longer, because the keypress that closed
        -- the phone is very often the one the frontend is about to act on.
        swallowPause(500)
    end)
end

-- ══════════════════════════════════════════════════════════════
-- Open / close
-- ══════════════════════════════════════════════════════════════
local function openPhone()
    if isOpen or isOpening or openingAssets then return end
    if exports['v-core']:IsAnyMenuOpen() then return end

    isOpening = true
    openRequest = openRequest + 1
    local request = openRequest

    -- A missing callback must not leave the key locked forever. Invalidating the request
    -- also prevents a very late answer from taking focus after the timeout.
    SetTimeout(10000, function()
        if isOpening and openRequest == request then
            isOpening = false
            openRequest = openRequest + 1
        end
    end)

    V.Request('v-phone:open', function(state)
        if request ~= openRequest then return end
        isOpening = false
        if not state or state.error then
            V.Notify(L('ph.err_' .. ((state and state.error) or 'x')), 'error')
            return
        end

        -- Another menu may have opened while the server was answering. Re-check at the
        -- last possible moment before this resource takes cursor and keyboard focus.
        if isOpen or exports['v-core']:IsAnyMenuOpen() then return end

        isOpen = true
        myNumber = state.number
        mediaOn = state.media == true
        SetNuiFocus(true, true)          -- focus is per-resource: only the page owner may take it
        -- Keep game input flowing so the player can still walk and drive; the guard thread
        -- disables only aim/shoot/look so the cursor and the world do not fight.
        SetNuiFocusKeepInput(true)
        exports['v-core']:MenuOpened('v-phone')
        menuClaimed = true
        startGuard()
        -- The screen is what drains a phone, so the server has to know it is on.
        TriggerServerEvent('v-phone:server:screen', true)
        syncPrefsCache(state.prefs or {})
        syncSdkApps(state.apps)
        if state.call ~= nil and applyServerCall then applyServerCall(state.call, false) end
        power = {
            battery = tonumber(state.battery) or power.battery,
            charging = state.charging == true,
            signal = tonumber(state.signal) or power.signal,
        }
        state.action  = 'open'
        state.locale  = (LocalPlayer.state and LocalPlayer.state.lang) or 'fr'
        state.strings = strings()
        state.call    = call
        state.power   = power
        SendNUIMessage(state)
        if call and call.state == 'in' then stopRingSound() end

        -- `action=open` resets every transient sheet in the page. Deliver prompts only
        -- after that reset has been queued, in the same FIFO order as NUI messages.
        local queued = pendingUiActions
        pendingUiActions = {}
        local now = GetGameTimer()
        for _, entry in ipairs(queued) do
            if not entry.expires or now <= entry.expires then
                local remaining = entry.expires and math.max(1, entry.expires - now) or nil
                entry.message.ttlMs = remaining
                if entry.message.offer then entry.message.offer.ttlMs = remaining end
                SendNUIMessage(entry.message)
            end
        end

        -- The NUI is fully initialised before model/animation loading can yield. Incoming
        -- prompts therefore cannot arrive ahead of `action=open` and be reset by it.
        openingAssets = true
        attachProp()
        if not isOpen or request ~= openRequest then
            openingAssets = false
            clearHand()
            return
        end
        refreshPose()
        if not isOpen or request ~= openRequest then
            openingAssets = false
            clearHand()
            return
        end
        openingAssets = false
    end)
end

local function closePhone()
    if isOpening or isOpen then
        openRequest = openRequest + 1
    end
    if isOpening then
        isOpening = false
    end
    if not isOpen then return end
    isOpen = false
    phoneTorch = false
    activeSdkApp = nil
    if not call then stopRinging() end
    stopSelfie()
    -- Focus first. camModeOff touches the engine, and anything that raises in there used to
    -- abort the rest of this function - leaving the handset drawn, the prop in hand and no
    -- cursor. The phone key must always be able to close the phone.
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    camModeOff()
    clearHand()
    if menuClaimed then
        menuClaimed = false
        exports['v-core']:MenuClosed('v-phone')
    end
    TriggerServerEvent('v-phone:server:screen', false)
    SendNUIMessage({ action = 'close' })
end

-- The command stays registered whatever Config.Key says: it is how the phone is opened from
-- the item, from an admin action, and from a console while testing.
V.Sub('phone', 'open', 'open the phone', function() openPhone() end,
      -- The bare `phone`: toggle, which is what typing one word is asking for.
      function() if isOpen then closePhone() else openPhone() end end)
V.Sub('phone', 'close', 'put the phone away', function() closePhone() end)

-- The old name, kept because a player has it in a keybind and a server has it in a script.
-- `Config.Commands.legacy = false` retires it.
if (Config.Commands or {}).legacy ~= false then
    RegisterCommand('vphone', function() if isOpen then closePhone() else openPhone() end end, false)
end

-- No fallback if Config.Key is false: that means the operator wants no binding at all, and a
-- default would quietly hand one back.
--
-- The description below is what the player sees in Settings -> Key Bindings -> FiveM, and
-- rebinding it there overrides Config.Key for that player permanently. That is the whole
-- mechanism by which the key is player-configurable - there is nothing for the phone to
-- store or sync.
if Config.Key then
    RegisterKeyMapping('vphone', 'iFruit - open the phone', 'keyboard', Config.Key)
end

-- The server can open or close the phone from an admin action or an API call. Close is
-- also how a number change, a wipe or an import make the phone reload rather than show
-- what was just changed underneath it.
--- A citywide alert. Forwarded to the page whether or not the phone is open: the page is
--- always loaded, and its alert overlay is drawn outside the handset for exactly this.
--- `/phonemusic` - why is there no sound?
---
--- Staff only, through the same server check `/phonediag` uses. It exists because "xsound is
--- installed, no error, no music" gave nobody anything to work with: every one of the answers
--- below is a thing that silently produces silence, and this prints all of them at once.
V.Sub('phonedebug', 'music', 'why is there no sound?', function()
    -- The ACE, not the debug flag: this command exists to explain a silence, and refusing it
    -- because tracing is off is refusing the one person trying to diagnose the problem.
    V.Request('v-phone:staff', function(res)
        if not res or res.error then
            print('[v-phone] music: staff only (ace vphone.admin).')
            return
        end

        local M = Config.Music or {}
        local music = V.Use('v-music')
        local provider = music.Provider and music.Provider() or nil

        print('[v-phone] music ─────────────────────────────────────')
        print(('  Config.Music.enabled   %s'):format(tostring(M.enabled ~= false)))
        print(('  Config.Music.provider  %s'):format(tostring(M.provider or 'auto')))
        -- **The deck that will actually be used**, not the one `Provider()` reports.
        --
        -- These are two different questions and they had two different answers: `Provider` names
        -- the best deck INSTALLED, `musicDeckFor` names the one a track is handed to. Printing
        -- the first while the second decided is how a diagnostic written to explain a silence
        -- said `xsound` on a server that was sending every track to xdiskjockey.
        local using = MusicDeckInUse and MusicDeckInUse() or provider
        print(('  best deck installed    %s'):format(tostring(provider or 'NONE')))
        print(('  deck actually used     %s'):format(tostring(using or 'NONE')))
        if using ~= provider then
            print('  ^^ these disagree. The second one is what plays your music.')
        end
        for _, res2 in ipairs({ 'xsound', 'rcore_radiocar', 'xdiskjockey' }) do
            print(('  %-22s %s'):format(res2, GetResourceState(res2)))
        end

        -- The two things inside xsound that produce silence with no error at all.
        if GetResourceState('xsound') == 'started' then
            local ok = pcall(function() return exports.xsound end)
            print(('  xsound exports         %s'):format(ok and 'reachable' or 'NOT REACHABLE'))
            print('  NOTE: xsound has a /streamermode command that mutes ALL of its sound')
            print('        silently. If you have ever run it, run it again to toggle it back.')
            print('        Its YouTube reader also throws on a link with no `?v=` in it, which')
            print('        is why the phone now rewrites every YouTube link before handing it')
            print('        over. A playlist or channel link is refused rather than played.')
        end

        -- And what the phone would actually send for the current track.
        local now = MusicLastUrl
        if now and now ~= '' then
            local fixed, err = MusicNormaliseUrl(now)
            print(('  last track asked for   %s'):format(now))
            print(('  after normalising      %s'):format(tostring(fixed or ('REFUSED: ' .. tostring(err)))))
        else
            print('  last track asked for   (nothing yet this session)')
        end
    end)
end)

-- Somebody nearby has a phone ringing.
--
-- The owner's own ring is `PlaySoundFrontend`, which is 2D and private to their client. This is
-- the same GTA sound placed ON THEIR PED, so it arrives from the right direction and fades with
-- distance - which is the whole point: a ringing phone should give its owner away.
--
-- Looped here rather than by the engine, because `Remote_Ring` is a single ring and a phone rings
-- until it is answered. The loop ends when the server says so, or when the ped goes away.
local ringingPeds = {}

--- Play the ring on one ped, once.
---
--- The sound and the set come from the config rather than being written in here. `Remote_Ring`
--- in Michael's phone set is what every script that does this reaches for, and GTA meant it for
--- your own ear rather than for a room - so when somebody reports hearing nothing, the first
--- thing worth trying is a different pair, and that should not need a code edit.
--- The sound currently ringing for one player, so it can always be stopped.
---
--- **`Remote_Ring` LOOPS.** It plays until something calls `StopSound` on its id, which is why
--- the id has to outlive the call that started it and be reachable from the code that ends the
--- ring. 1.5.2 replaced a synchronous stop with a fixed 1500ms timer, so the sound was no
--- longer tied to the loop at all: clearing `ringingPeds` ended the loop and left whatever was
--- playing to a timer, and any id whose timer had already fired while the loop kept going was
--- simply lost. A looping sound with a lost id rings until the player reconnects, which is the
--- "tuu tuu tuu that never stops" the caller standing next to the phone was hearing.
local ringOutIds = {}

local function ringOutStop(who)
    local id = ringOutIds[who]
    if not id then return end
    ringOutIds[who] = nil
    StopSound(id)
    ReleaseSoundId(id)
end

local function ringOutSound(who, ped)
    local cfg = Config.RingOut or {}
    local name = tostring(cfg.sound or 'Remote_Ring')
    local set = tostring(cfg.soundSet or 'Phone_SoundSet_Michael')
    -- One at a time per player: the previous pass is stopped before the next begins, so ids
    -- can never pile up whatever the repeat interval is set to.
    ringOutStop(who)
    local id = GetSoundId()
    ringOutIds[who] = id
    PlaySoundFromEntity(id, name, ped, set, false, 0)
end

--- `phonedebug ringout` - does that sound work on this build at all?
---
--- Hearing nothing has two very different causes: the event is not arriving, or the sound is
--- inaudible. Testing it needed a second player and an incoming call, which is why it stayed a
--- guess. This plays it on your OWN ped, so the answer takes five seconds.
V.Sub('phonedebug', 'ringout', 'play the nearby-phone ring on yourself', function()
    local cfg = Config.RingOut or {}
    print(('[v-phone] ring-out: enabled=%s sound=%s set=%s range=%s')
        :format(tostring(cfg.enabled ~= false), tostring(cfg.sound or 'Remote_Ring'),
                tostring(cfg.soundSet or 'Phone_SoundSet_Michael'), tostring(cfg.range or 12.0)))
    print('[v-phone] playing it three times on your own ped - if you hear nothing, the sound is')
    print('[v-phone] the problem and not the event. Try another pair in Config.RingOut.')
    CreateThread(function()
        -- Keyed on 0, which is not a server id, so a real ring-out for somebody nearby cannot
        -- be stopped by this test and this test cannot be stopped by theirs.
        for _ = 1, 3 do
            ringOutSound(0, PlayerPedId())
            Wait(1500)
        end
        ringOutStop(0)
    end)
end)

RegisterNetEvent('v-phone:client:ringOut', function(who, on)
    who = tonumber(who)
    if not who then return end

    if not on then
        ringingPeds[who] = nil
        -- At once, rather than waiting for the loop to come round: the loop is inside a Wait of
        -- up to a second and a half, and a ring that carries on after the call was answered is
        -- exactly what the caller hears as it never stopping.
        ringOutStop(who)
        return
    end
    if ringingPeds[who] then return end
    ringingPeds[who] = true

    CreateThread(function()
        while ringingPeds[who] do
            local other = GetPlayerFromServerId(who)
            local ped = other ~= -1 and GetPlayerPed(other) or 0
            -- Out of scope, or gone: stop rather than ringing at nothing for the length of a
            -- call somebody else is having on the far side of the map.
            if not ped or ped == 0 or not DoesEntityExist(ped) then
                ringingPeds[who] = nil
                break
            end
            ringOutSound(who, ped)
            Wait(math.max(400, math.floor(tonumber((Config.RingOut or {}).everyMs) or 1400)))
        end
        -- However the loop ended - told to stop, ped gone, player left - the sound ends with
        -- it. This is the line whose absence let a looping ring outlive its own loop.
        ringOutStop(who)
    end)
end)

--- A city-wide alert.
---
--- It is a NOTIFICATION, not a takeover: it buzzes hard, it sounds loudly, it lands in the
--- notification centre, and it lifts the handset out of a pocket the way any notification
--- does. It used to draw a full-screen card over the whole screen, which is a lot of screen
--- for something a phone announces - `Config.Admin.emergencyFullScreen` puts that back for a
--- server that wants the takeover.
---
--- Two things it does that no other notification does, and both are deliberate: the buzz
--- ignores Do Not Disturb, and the sound ignores the ring volume. That is the whole point of
--- an emergency channel, and it is why it sits behind a staff ace and its own switch.
-- ══════════════════════════════════════════════════════════════
-- A staff voice, in every phone
-- ══════════════════════════════════════════════════════════════
-- `/phoneadmin voice`. The channel is what makes the broadcaster audible; everything below is
-- about making it ONE-WAY, because pma-voice has no listen-only channel to ask for.
--
-- Every listener turns every OTHER listener down to zero and keeps only the speaker. That is
-- local, instant, and needs nothing from any other resource - it is the same
-- `MumbleSetVolumeOverrideByServerId` the bad-line effect uses.
--
-- **Everything here is undone on a timer that runs whether or not the broadcast ends cleanly.**
-- A restore that only happens on the closing event is one that never happens when the server
-- restarts mid-broadcast, and the symptom of that is a player who can no longer hear anybody -
-- which they would report as the phone breaking their voice chat, correctly.

local vbOn = false          -- true while a broadcast is being listened to
local vbQuieted = {}        -- [serverId] = true for everyone we turned down
local vbGuard = nil         -- the id of the safety timer, so a second broadcast replaces it
local vbJoined = false      -- did WE actually join the channel? Only then do we leave it.

--- Hand everybody their voice back, and let go of the channel.
---
--- Written to be safe to call at any time, including twice: this is the function that stops a
--- failed broadcast from leaving somebody deaf, so it must never depend on the state being what
--- it is expected to be.
local function vbRelease()
    for id in pairs(vbQuieted) do
        if type(MumbleSetVolumeOverrideByServerId) == 'function' then
            pcall(MumbleSetVolumeOverrideByServerId, id, -1.0)   -- -1 is "back to normal"
        end
    end
    vbQuieted = {}

    if vbJoined then
        pcall(function() exports['v-voice']:VoiceBroadcast(0, false) end)
        vbJoined = false
    end

    if vbOn then
        vbOn = false
        SendNUIMessage({ action = 'voiceBroadcast', on = false })
    end
end

RegisterNetEvent('v-phone:client:voiceBroadcast', function(d)
    if type(d) ~= 'table' then return end

    if not d.on then vbRelease() return end

    -- Somebody on their own call is left alone unless the operator said otherwise. Joining
    -- them to this channel would drop them out of their conversation, and closing the
    -- broadcast would set their channel to zero - hanging up on them from across the map.
    -- They still get the banner, so they know they missed something.
    local onCall = call and call.state == 'active'
    local join = (not onCall) or d.interruptCalls == true

    local speaker = tonumber(d.speaker)
    local me = GetPlayerServerId(PlayerId())

    if join then
        vbJoined = pcall(function()
            return exports['v-voice']:VoiceBroadcast(math.floor(tonumber(d.channel) or 0), true)
        end) and true or false

        -- **The one-way part.** Everybody on the channel is a mutual voice target, so every
        -- other listener is turned down here - keeping the speaker, and keeping ourselves,
        -- which the native ignores anyway.
        if type(MumbleSetVolumeOverrideByServerId) == 'function' then
            for _, pid in ipairs(GetActivePlayers()) do
                local id = GetPlayerServerId(pid)
                if id and id ~= speaker and id ~= me then
                    if pcall(MumbleSetVolumeOverrideByServerId, id, 0.0) then
                        vbQuieted[id] = true
                    end
                end
            end
        end
    end

    vbOn = true

    -- The banner is drawn whether or not this player joined the channel: somebody on a call
    -- who was deliberately left out still wants to know a broadcast happened.
    if d.banner ~= false then
        SendNUIMessage({ action = 'voiceBroadcast', on = true, muted = not join })
    end

    -- The same buzz an emergency alert gets. A voice arriving out of nowhere with no warning
    -- is worse than one announced.
    if d.ring ~= false and prefsCache.vibrate ~= false then
        SendNUIMessage({ action = 'buzz' })
        SetPadShake(0, 300, 90)
    end

    -- The safety net. A little longer than the broadcast, so the server's own close arrives
    -- first in the ordinary case and this only fires when something went wrong.
    if vbGuard then vbGuard = nil end
    local seconds = math.max(1, math.floor(tonumber(d.seconds) or 60))
    local mine = {}
    vbGuard = mine
    SetTimeout(seconds * 1000 + 4000, function()
        if vbGuard ~= mine then return end   -- a newer broadcast owns the state now
        vbGuard = nil
        vbRelease()
    end)
end)

--- Leaving the server with a broadcast running must not be how somebody discovers this.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then vbRelease() end
end)

RegisterNetEvent('v-phone:client:emergency', function(alert)
    if type(alert) ~= 'table' then return end

    -- The page always hears about it, open or shut: it owns the sound and the notification
    -- centre, and it is loaded for as long as the resource is running.
    SendNUIMessage({ action = 'emergency', alert = alert, strings = strings() })

    -- Straight to the pad rather than through `buzz`, which stands down for Do Not Disturb.
    if prefsCache.vibrate ~= false then
        SendNUIMessage({ action = 'buzz' })
        SetPadShake(0, 420, 110)
    end

    -- And the handset rises out of a pocket, if it is away.
    --
    -- The `peek` message on its own, not the `peek()` helper: that one also sends `archive`,
    -- and the page files its own card for this from `emergencyAlert` - going through the
    -- helper would leave two identical notifications in the centre for one alert.
    if not isOpen and prefsCache.peek ~= false then
        SendNUIMessage({ action = 'peek', kind = 'banner', strings = strings(), data = {
            app = 'settings', icon = 'warning',
            title = tostring(alert.kind or ''),
            body = tostring(alert.title or alert.body or ''),
            hasItem = true,
        } })
    end
end)

-- ══════════════════════════════════════════════════════════════
-- 911
-- ══════════════════════════════════════════════════════════════
-- A service being called out, and a responder finding the place.

-- One blip per alert, kept so it can be taken back off the map when the alert stops being
-- one. Without the table the phone could add blips and never remove them, which is how a
-- busy evening ends with a map nobody can read.
local Alert911Blips = {}

local function clearAlertBlip(id)
    local blip = Alert911Blips[id]
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    Alert911Blips[id] = nil
end

--- Put an alert on the map, or move the one already there. Everything about how it looks was
--- decided on the server; this only draws it.
local function drawAlertBlip(id, pin, route)
    if type(pin) ~= 'table' then return end
    local x, y, z = tonumber(pin.x), tonumber(pin.y), tonumber(pin.z)
    if not x or not y then return end
    clearAlertBlip(id)

    local radius = tonumber(pin.radius) or 0
    local blip
    if radius > 0 then
        -- An area to search rather than a doorstep. A radius blip takes a colour and an alpha
        -- and nothing else - no sprite, no name - so the two paths cannot be merged.
        blip = AddBlipForRadius(x + 0.0, y + 0.0, (z or 0.0) + 0.0, radius + 0.0)
        SetBlipColour(blip, math.floor(tonumber(pin.colour) or 1))
        SetBlipAlpha(blip, math.floor(tonumber(pin.alpha) or 128))
    else
        blip = AddBlipForCoord(x + 0.0, y + 0.0, (z or 0.0) + 0.0)
        SetBlipSprite(blip, math.floor(tonumber(pin.sprite) or 280))
        SetBlipColour(blip, math.floor(tonumber(pin.colour) or 1))
        SetBlipScale(blip, (tonumber(pin.scale) or 0.9) + 0.0)
        SetBlipAlpha(blip, math.floor(tonumber(pin.alpha) or 255))
        SetBlipAsShortRange(blip, false)
        if pin.flash then SetBlipFlashes(blip, true) end
        if route then SetBlipRoute(blip, true) end
        BeginTextCommandSetBlipName('STRING')
        -- **Translated here.** A reason travels as a LOCALE KEY, because a config that says
        -- `ph.911_r_violence` is a config that reads in the player's own language - and the map
        -- was drawing that key verbatim, so every 911 blip was labelled `ph.911_r_violence`.
        -- `L()` on a plain string a server wrote itself returns it unchanged, so both shapes
        -- work: a key is translated, free text is left alone.
        AddTextComponentSubstringPlayerName(tostring(
            pin.label and L(tostring(pin.label)) or L('ph.911_new')))
        EndTextCommandSetBlipName(blip)
    end
    Alert911Blips[id] = blip

    -- It expires on its own even if nothing else happens to it. A responder who never opens
    -- the app should not accumulate an evening of pins.
    local seconds = math.max(10, math.floor(tonumber(pin.seconds) or 300))
    SetTimeout(seconds * 1000, function()
        if Alert911Blips[id] == blip then clearAlertBlip(id) end
    end)
end

--- An alert for a service this player works. Arrives whether or not the phone is open: a
--- responder with their phone in their pocket is exactly who this is for.
RegisterNetEvent('v-phone:client:911', function(d)
    if type(d) ~= 'table' or type(d.alert) ~= 'table' then return end
    local a = d.alert
    local service = d.service or {}

    -- On the map straight away, for everybody working the service. No button, and no need to
    -- have the phone out - which is the whole point of a dispatch pin.
    if d.pin then drawAlertBlip(a.id, d.pin, d.pin.route) end

    -- The page owns the sound and the notification centre, and it is loaded whether or not
    -- the handset is out.
    SendNUIMessage({ action = 'emergencyAlert', alert = a, service = service,
                     sound = d.sound ~= false, file = d.file, volume = d.volume,
                     strings = strings() })

    -- Straight to the pad rather than through `buzz`, which stands down for Do Not Disturb.
    -- Somebody on duty asked to be reachable; that is what being on duty is.
    if d.vibrate ~= false and prefsCache.vibrate ~= false then
        SendNUIMessage({ action = 'buzz' })
        SetPadShake(0, 350, 95)
    end

    -- And the handset rises out of a pocket. The peek message on its own, not the `peek`
    -- helper: that one files its own notification and the page files one from the message
    -- above, which would leave two cards for one alert.
    if d.peek ~= false and not isOpen and prefsCache.peek ~= false then
        SendNUIMessage({ action = 'peek', kind = 'banner', strings = strings(), data = {
            app = 'emergency', icon = 'warning',
            title = L('ph.911_new'),
            -- Translated, for the same reason as the blip name: a reason is a locale key.
            body = a.reason and L(tostring(a.reason)) or '',
            hasItem = true,
        } })
    end
end)

--- An alert changed hands or was closed. Nothing but a repaint.
RegisterNetEvent('v-phone:client:911update', function(d)
    if type(d) ~= 'table' then return end
    SendNUIMessage({ action = 'emergencyUpdate', update = d })
end)

--- The map, after something happened to an alert: taken by somebody, closed, or handed to the
--- one responder who is actually going.
RegisterNetEvent('v-phone:client:911blip', function(d)
    if type(d) ~= 'table' or not d.id then return end
    if d.clear then clearAlertBlip(d.id) return end
    drawAlertBlip(d.id, d.pin, d.route)
end)

-- ══════════════════════════════════════════════════════════════
-- Zuber
-- ══════════════════════════════════════════════════════════════
--- An order moved along in the kitchen.
---
--- Config-provider only. On a doc-restaurant server that script tells its own customers through
--- its own notifications, and a second announcement for one order would be the phone talking
--- over it - so nothing sends this event in that mode.
RegisterNetEvent('v-phone:client:zuber', function(d)
    if type(d) ~= 'table' then return end
    SendNUIMessage({ action = 'zuberStatus', update = d, strings = strings() })

    local b = {
        app = 'zuber', icon = 'zuber',
        title = tostring(d.restaurant ~= '' and d.restaurant or L('app.zuber')),
        body = L('ph.zuber_st_' .. tostring(d.status or 'pending')),
        hasItem = true,
    }
    if isOpen then
        if not notificationMuted('banner', b) and not notificationSilent('banner', b) then buzz(false) end
    else
        peek('banner', b)
    end
end)

--- The caller's side: somebody picked up their alert, or closed it. This is the answer to the
--- silence - without it there is no way to tell "on their way" from "nobody is coming", and
--- the reasonable thing to do about silence is to send the alert again.
RegisterNetEvent('v-phone:client:911status', function(d)
    if type(d) ~= 'table' then return end
    local service = d.service or {}
    SendNUIMessage({ action = 'emergencyStatus', update = d, strings = strings() })

    if d.vibrate ~= false and prefsCache.vibrate ~= false then
        SendNUIMessage({ action = 'buzz' })
        SetPadShake(0, 220, 70)
    end

    if not isOpen and prefsCache.peek ~= false then
        local key = d.state == 'closed' and 'ph.911_c_closed' or 'ph.911_c_taken'
        SendNUIMessage({ action = 'peek', kind = 'banner', strings = strings(), data = {
            app = 'emergency', icon = 'shield',
            title = service.label and L(service.label) or L('ph.911_new'),
            body = d.by and (L(key .. '_by'):gsub('{n}', tostring(d.by))) or L(key),
            hasItem = true,
        } })
    end
end)

--- Where it happened.
---
--- A waypoint always, because that is what a responder actually navigates with, and a blip
--- when the operator wants one - a blip is the thing that accumulates on a map, so it goes
--- away on its own.
RegisterNetEvent('v-phone:client:911locate', function(d)
    if type(d) ~= 'table' then return end
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not x or not y then return end

    -- Always the exact spot, even for a service whose blip is a search area: a responder
    -- pressed a button that says "take me there".
    if d.waypoint ~= false then SetNewWaypoint(x + 0.0, y + 0.0) end

    local b = d.blip
    if type(b) ~= 'table' then return end
    -- Through the same registry as the automatic pin, keyed on the alert. Pressing the button
    -- twice used to leave two blips stacked on one spot, and closing the alert removed
    -- neither of them.
    b.x, b.y, b.z = x, y, z
    drawAlertBlip(d.id or ('locate' .. tostring(x)), b, d.route == true)
end)

--- A responder reconnecting, or the resource restarting, must not leave pins behind: a blip
--- outlives the script that made it, and one that nothing owns can never be removed.
AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for id in pairs(Alert911Blips) do clearAlertBlip(id) end
end)

RegisterNetEvent('v-phone:client:open', function() if not isOpen then openPhone() end end)
RegisterNetEvent('v-phone:client:close', function() if isOpen then closePhone() end end)

-- A get-out-of-jail command: the phone stuck to the hand, the browse animation frozen,
-- the cursor captured with nothing on screen. It happens when another resource kills the
-- ped's tasks mid-open, or a script error leaves the state half-set. This tears every
-- phone-related thing down unconditionally - prop, animation, NUI focus, control guard -
-- so the player can move again, whatever state the phone thinks it is in.
--- `quiet` suppresses the "phone reset" line.
---
--- The player typing `/refreshphone` asked and should be told. Everything else that calls this
--- - the watchdog, dying, respawning - did not, and a reset the player did not ask for that
--- announces itself is noise. During character selection `playerSpawned` fires more than once
--- and every one of them printed a line, which is a phone shouting at somebody who has not
--- even chosen a character yet.
local function forceReset(quiet)
    isOpen = false
    isOpening = false
    openRequest = openRequest + 1
    phoneTorch = false
    activeSdkApp = nil
    stopRinging()

    -- The camera too. This is the documented way out of a stuck phone, and it used to free
    -- the cursor while leaving the game in the cellphone camera view with the HUD hidden.
    camActive = false
    pcall(function()
        frontCam(false)
        CellCamActivate(false, false)
        DestroyMobilePhone()
        ClearHelp(true)
        if camHidHud then DisplayHud(true) end
        if camHidRadar then DisplayRadar(true) end
    end)
    camHidHud, camHidRadar = false, false
    camShooting = false
    selfieReset()

    -- Focus back to the game, both kinds, in case only one was cleared.
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)

    -- The prop and the pose, unconditionally: clearHand only deletes a prop it is still
    -- tracking, so also sweep any stray attached phone model and stop the clips by name.
    clearHand()
    local ped = PlayerPedId()
    ClearPedSecondaryTask(ped)
    if Config.Hold and Config.Hold.dict then
        StopAnimTask(ped, Config.Hold.dict, Config.Hold.browse or '', 3.0)
        StopAnimTask(ped, Config.Hold.dict, Config.Hold.call or '', 3.0)
    end

    -- Hand the menu lock back, or the player can never open anything else.
    if menuClaimed then
        menuClaimed = false
        pcall(function() exports['v-core']:MenuClosed('v-phone') end)
    end

    TriggerServerEvent('v-phone:server:screen', false)
    SendNUIMessage({ action = 'close' })
    if not quiet then V.Notify(L('ph.phone_reset') or 'Phone reset', 'success') end
end

-- Both spellings, because a panicking player types whichever they remember.
--
-- Wrapped rather than passed directly: `RegisterCommand` calls its handler with (source,
-- args, raw), so handing it `forceReset` would put the source into `quiet` - a number, which
-- is truthy - and silence the one reset that should always speak.
V.Sub('phone', 'refresh', 'unstick the phone: drop the cursor, close everything, reload',
      function() forceReset(false) end)

-- Both old spellings, because a panicking player types whichever they remember.
if (Config.Commands or {}).legacy ~= false then
    RegisterCommand('refreshphone', function() forceReset(false) end, false)
    RegisterCommand('refresh-phone', function() forceReset(false) end, false)
end

--- The same reset, reachable from the watchdog and from a key.
---
--- A command is only a way out for a player who knows it exists and can still open the chat.
--- Neither is a safe assumption for somebody who is stuck, which is why there is also a key
--- binding and a thread that does this without being asked. See client/watchdog.lua.
PhoneForceReset = function() forceReset(true) end

--- Does the phone believe it should own the cursor right now?
---
--- Read by the watchdog. The two camera states are deliberately excluded: both hand the
--- cursor BACK to the game on purpose so the mouse can frame a shot, and a watchdog that did
--- not know that would treat the camera as a stuck phone every time.
function PhoneFocusWanted()
    if camActive or freeLook then return false end
    return isOpen or isOpening
end

--- An unstick key, unbound by default.
---
--- No default: a phone that claims a second key on every server is a phone that collides with
--- something. It appears in Settings -> Key Bindings -> FiveM for a player who wants one, and
--- the command works for everybody else.
RegisterKeyMapping('refreshphone', 'iFruit - unstick the phone', 'keyboard', '')

--- `/phonediag` - why an app is not working, printed into F8.
---
--- An app that cannot read its data says one short sentence, which is right for a player and
--- useless for anybody fixing it. This prints the two facts that actually decide it: whether
--- each server file loaded and registered its callback, and whether the bridge provider
--- behind it returns anything on this server.
V.Sub('phonedebug', 'diag', 'which server files loaded, and which providers answer',
      function()
    V.Request('v-phone:diag', function(r)
        if type(r) ~= 'table' or not r.ok then
            -- The server refuses unless debug is on and the caller is staff, so say which.
            local why = type(r) == 'table' and tostring(r.error or '?') or 'nil'
            if why == 'off' then
                print('[v-phone] diag is off. Enable it with `set phone_debug true`.')
            elseif why == 'denied' then
                print('[v-phone] diag: staff only (ace vphone.admin).')
            else
                print('[v-phone] diag: no answer - ' .. why)
            end
            return
        end
        print(('[v-phone] diag | framework=%s (%s)')
            :format(tostring(r.framework), tostring(r.resource)))
        for _, c in ipairs(r.callbacks or {}) do
            print(('[v-phone] diag | callback %-24s %s')
                :format(tostring(c.name), c.ok and 'registered' or 'MISSING - its server file is not loading'))
        end
        for _, pr in ipairs(r.providers or {}) do
            print(('[v-phone] diag | provider %-12s %s'):format(tostring(pr.name), tostring(pr.state)))
        end
    end)
end)

-- Assigned in the bad-line section far below, which is where `badLine` and the levels live.
-- Forward-declared here because `/phonevoice` is written above that point: reading `badLine`
-- directly from up here would read a nil GLOBAL and print "nil" for a state that is a boolean -
-- a diagnostic that lies is worse than one that is missing, since this is the command somebody
-- runs precisely because they cannot tell what the effect is doing.
local badLineReport = function() return nil, nil end

--- `/phonevoice` - can this server carry a call at all, and can a speaker be heard?
---
--- "Nobody hears anybody" and "the other end cannot hear the people next to me" are the same
--- question underneath: which voice script answered, and is it one that has call channels.
--- Every answer below is something that silently produces silence.
V.Sub('phonedebug', 'voice', 'can a call carry audio, and why a weak signal does or does not break it',
      function()
    local voiceRes = nil
    for _, res in ipairs({ 'pma-voice', 'saltychat', 'mumble-voip' }) do
        if GetResourceState(res) == 'started' then voiceRes = res break end
    end
    print('[v-phone] voice ─────────────────────────────────────')
    print(('  Config.Compat.voice     %s'):format(tostring((Config.Compat or {}).voice or 'auto')))
    print(('  running voice script    %s'):format(tostring(voiceRes or 'none found')))
    print(('  calls enabled           %s (voice_enableCalls)')
        :format(tostring(GetConvarInt('voice_enableCalls', 1) == 1)))
    print(('  speaker range           %s m'):format(tostring((Config.Calls or {}).speakerRange or 8.0)))
    if voiceRes == 'pma-voice' then
        print('  speaker is TWO-WAY: people near you join the call channel, so the far end')
        print('  hears them and they hear the far end. That is what a call channel is.')
    else
        print('  speaker cannot work: only pma-voice exposes call channels. On anything else')
        print('  the call stays between the two handsets.')
    end
    print(('  you are on a call now   %s'):format(tostring(call ~= nil and call.state or 'no')))

    -- The bad-line effect, because "calls do not break up at one bar" has four possible causes
    -- and no way for the person reporting it to tell them apart.
    local bad = (Config.Calls or {}).badSignal or {}
    local bars = math.max(0, math.min(4, math.floor(tonumber(power.signal) or 4)))
    print('[v-phone] bad line ───────────────────────────────────')
    print(('  effect enabled          %s'):format(tostring(bad.enabled ~= false)))
    print(('  breaks up at or below   %s bar(s)'):format(tostring(math.floor(tonumber(bad.atBars) or 1))))
    print(('  your signal right now   %d bar(s)%s'):format(bars,
        bars == 0 and ' - no service at all, which ends a call rather than glitching it' or ''))
    print(('  chance per second       %s'):format(tostring(tonumber(bad.chancePerSecond) or 0.18)))
    print(('  audio can be cut        %s (voice script: %s)'):format(
        tostring(voice()), tostring((PhoneVoiceScript and PhoneVoiceScript()) or 'none')))
    if not voice() then
        print('  -> no voice script is running, so the line can only glitch visually.')
    end

    -- Which of the two audio routes is live, and what it is doing right now. The whole reason
    -- "the effect does nothing" was hard to pin down is that the answer was never on screen.
    local native = type(MumbleSetVolumeOverrideByServerId) == 'function'
    print(('  volume override native  %s'):format(native and 'yes - per-player volume, instant'
        or 'NO - falling back to leaving the call channel'))
    local levels = bad.volumeAtBars
    if type(levels) == 'table' then
        local level = tonumber(levels[bars])
        print(('  level at %d bar(s)       %s'):format(bars,
            level and (tostring(level) .. ' of normal volume') or 'not set - full volume'))
    else
        print('  level per bar           not configured: badSignal.volumeAtBars is missing, so')
        print('                          the line drops out but is never muffled between drops.')
    end
    print(('  far end                 %s'):format(
        (call and call.peer) and ('player ' .. tostring(call.peer))
        or 'not on a call, so nothing to turn down'))
    local cutting, held = badLineReport()
    print(('  cutting out right now   %s'):format(tostring(cutting)))
    print(('  far end held at         %s'):format(held and tostring(held) or 'normal volume'))

end)

-- And a server nudge, so an admin can un-stick a player's phone remotely. Quiet: a reset the
-- player did not ask for should not announce itself, and passing `forceReset` straight to the
-- handler would hand it the event's first argument as `quiet` - a value nobody chose.
RegisterNetEvent('v-phone:client:forceReset', function() forceReset(true) end)

local function sendWhenOpen(message)
    if isOpen then
        SendNUIMessage(message)
        return
    end
    local now = GetGameTimer()
    for i = #pendingUiActions, 1, -1 do
        if pendingUiActions[i].expires and now > pendingUiActions[i].expires then
            table.remove(pendingUiActions, i)
        end
    end
    -- A prompt storm must remain bounded even if the phone cannot currently open.
    while #pendingUiActions >= 6 do table.remove(pendingUiActions, 1) end
    local seconds = message.action == 'airdrop'
        and tonumber(Config.Airdrop and Config.Airdrop.offerTtl) or 30
    pendingUiActions[#pendingUiActions + 1] = {
        message = message,
        expires = now + math.max(1, seconds) * 1000,
    }
    openPhone()
end

-- ══════════════════════════════════════════════════════════════
-- App data
-- ══════════════════════════════════════════════════════════════
-- One table, so adding an app is one row rather than a branch. `res` is the module that
-- must be running for the app to have anything to say.
-- Where each app's data comes from: a callback in this resource, reading the framework
-- through the bridge.
--
-- These used to name a companion `v-*` resource - v-banking, v-vehicles, v-licenses,
-- v-cityhall, v-housing - and ask ITS callback, falling back to the bridge only if the
-- resource looked absent. Those resources are part of the author's own private suite. They
-- do not exist on a qb-core, qbx, ESX or ox server and they never will, so the fallback was
-- the only path that could ever run, and the check in front of it was a liability: the
-- compatibility layer reports a `v-*` name as started whenever its stub is enabled, so the
-- phone believed v-vehicles was running, asked a callback nobody answers, and told the
-- player the garage was not loaded while the bridge behind it was reading their car
-- perfectly. Bank, Wallet and Property failed the same way.
--
-- One name each, no prediction, nothing to get wrong.
local APP_SOURCE = {
    bank     = 'v-phone:bank:data',
    bankpro  = 'v-phone:bankpro:open',
    garage   = 'v-phone:garage:data',
    wallet   = 'v-phone:wallet:data',
    jobs     = 'v-phone:jobs:data',
    property = 'v-phone:property:data',
    -- Music is answered locally by `musicAppData` below: a player's tracks are their own
    -- phone storage, so there is nothing to ask the server for.
}

--- The music app answers from the CONFIG and the local deck, not from a server callback.
--- There is no shared library to fetch: a player's tracks live in their own phone storage,
--- and everything else the app needs - which deck is live, the operator's playlists, the
--- limits - is decided here.
local function musicAppData()
    local M = Config.Music or {}
    local music = V.Use('v-music')
    local provider = music.Provider and music.Provider() or nil

    -- The operator's own playlists, cleaned on the way out so a malformed config entry
    -- cannot reach the page as something it has to defend against.
    local playlists = {}
    for _, row in ipairs(M.defaultPlaylists or {}) do
        if type(row) == 'table' and row.id and row.name then
            local tracks = {}
            for _, t in ipairs(row.tracks or {}) do
                if type(t) == 'table' and t.url and t.url ~= '' then
                    tracks[#tracks + 1] = { title = tostring(t.title or t.url),
                                            artist = tostring(t.artist or ''), url = tostring(t.url) }
                end
            end
            playlists[#playlists + 1] = {
                id = tostring(row.id), name = tostring(row.name),
                icon = tostring(row.icon or 'music'), tint = row.tint and tostring(row.tint) or nil,
                tracks = tracks, readonly = true,
            }
        end
    end

    return {
        ok = true,
        -- The OPERATOR's switch, and only that. This used to be `provider ~= nil`, so a
        -- server with no radio script opened Music onto "unavailable" - even though the
        -- library, the playlists and the favourites are entirely the phone's own and work
        -- with no deck at all. What a missing deck costs is playback, which `provider`
        -- below already says, and the app now explains rather than hiding itself.
        enabled = (M.enabled ~= false),
        provider = provider,
        -- True when the deck cannot be driven and the player has to paste. The app says so
        -- rather than leaving them wondering why nothing started.
        handoff = provider ~= nil and provider ~= 'hooks',
        sources = {},
        playlists = playlists,
        allowCustomUrl = M.allowCustomUrl ~= false,
        hosts = M.hosts or {},
        limits = {
            library = math.floor(tonumber(M.maxLibrary) or 120),
            playlists = math.floor(tonumber(M.maxPlaylists) or 20),
            tracks = math.floor(tonumber(M.maxTracksPerPlaylist) or 100),
        },
    }
end

RegisterNUICallback('app', function(data, cb)
    local id = data and tostring(data.app or '')
    if id == 'music' then cb(musicAppData()) return end
    local callback = APP_SOURCE[id]
    if not callback then cb({ error = 'unknown' }) return end
    V.Request(callback, function(res) cb(res or { error = 'x' }) end)
end)

-- ══════════════════════════════════════════════════════════════
-- Messages, contacts, preferences
-- ══════════════════════════════════════════════════════════════
local function relay(callback)
    return function(data, cb)
        V.Request(callback, function(res) cb(res or { error = 'x' }) end, data)
    end
end

-- The bank's two writes. Relays on purpose: the amount, the recipient, the limits and the
-- fee are all decided on the server, so there is nothing for this side to check and
-- nothing it could usefully lie about.
RegisterNUICallback('bankTransfer', relay('v-phone:bank:transfer'))
RegisterNUICallback('bankFavourite', relay('v-phone:bank:favourite'))

-- 911. Relays: which service, who receives it, where the caller is and who may act on an
-- alert are all the server's to decide. Down here with the others rather than beside the
-- events above, because `relay` is declared on the line before this one - a local called
-- above its own declaration is a nil global, which is how the phone lost every call once.
RegisterNUICallback('emergency',       relay('v-phone:911:open'))
RegisterNUICallback('emergencySend',   relay('v-phone:911:send'))
RegisterNUICallback('emergencyTake',   relay('v-phone:911:take'))
RegisterNUICallback('emergencyClose',  relay('v-phone:911:close'))
RegisterNUICallback('emergencyLocate', relay('v-phone:911:locate'))

-- Bank Pro. Relays, like the bank's: the account, who may reach it and whether the money
-- moved are all decided on the server, so there is nothing here to check and nothing this
-- side could usefully lie about. See server/bankpro.lua.
RegisterNUICallback('bankproStaff',    relay('v-phone:bankpro:staff'))
RegisterNUICallback('bankproWithdraw', relay('v-phone:bankpro:withdraw'))
RegisterNUICallback('bankproDeposit',  relay('v-phone:bankpro:deposit'))
RegisterNUICallback('bankproPay',      relay('v-phone:bankpro:pay'))

RegisterNUICallback('conversation',  relay('v-phone:conversation'))
-- `send` is registered in client/outbox.lua, not here: a message written where there is no
-- signal is held by the handset and sent when the bars come back, and that wrapper has to
-- be the one the page reaches. Registering it in both files would leave which one wins
-- depending on the manifest order.
RegisterNUICallback('contactSave',   relay('v-phone:contactSave'))
RegisterNUICallback('contactDelete', relay('v-phone:contactDelete'))
RegisterNUICallback('groupCreate',   relay('v-phone:groupCreate'))
RegisterNUICallback('groupMembers',  relay('v-phone:groupMembers'))
RegisterNUICallback('calls',         relay('v-phone:calls'))
RegisterNUICallback('airdropScan',    relay('v-phone:airdropScan'))
RegisterNUICallback('airdropSend',    relay('v-phone:airdropSend'))
RegisterNUICallback('airdropRespond', relay('v-phone:airdropRespond'))
RegisterNUICallback('unlock',         relay('v-phone:unlock'))

--- Share where you are. The coordinates come from the PED, not from the page: a page
--- that could name a position could claim to be anywhere.
RegisterNUICallback('sendloc', function(data, cb)
    local c = GetEntityCoords(PlayerPedId())
    local payload = { kind = 'location', attachment = string.format('%.1f;%.1f', c.x, c.y) }
    if data and data.group then payload.group = data.group else payload.number = data and data.number end
    V.Request('v-phone:send', function(res) cb(res or { error = 'x' }) end, payload)
end)
RegisterNUICallback('prefs', function(data, cb)
    V.Request('v-phone:prefs', function(res)
        -- Keep the sound layer in step with what the player just changed.
        syncPrefsCache(res and res.prefs)
        cb(res or { error = 'x' })
    end, data)
end)
RegisterNUICallback('seenAll',       relay('v-phone:seenAll'))
RegisterNUICallback('voicemail',     relay('v-phone:voicemail'))
RegisterNUICallback('mail',          relay('v-phone:mail'))
RegisterNUICallback('notes',         relay('v-phone:notes'))
RegisterNUICallback('cipher',        relay('v-phone:cipher'))
RegisterNUICallback('speaker',       relay('v-phone:speaker'))

--- Somebody near you put their phone on speaker.
---
--- **You hear their call, and the far end hears you.** That is what a speakerphone is, and it
--- is what pma-voice does: joining a call channel makes every member of it a mutual voice
--- target - `addPlayerToCall` wires the new arrival to everybody already there, both ways.
--- (The comment here used to claim this was listening only. It never was.)
---
--- Two guards, both about not touching a voice channel that is not ours to touch:
RegisterNetEvent('v-phone:client:speaker', function(d)
    local id = tonumber(d and d.id)
    if not id then return end
    local on = d and d.on == true

    -- One: somebody on their OWN call is left alone. Joining them to a stranger's channel
    -- would drop them out of their conversation, and turning the speaker off again would set
    -- their channel to zero - hanging up on them from across the street.
    if call and call.state == 'active' then
        speakerListens[id] = nil
        return
    end

    if on then
        speakerListens[id] = true
    else
        -- Two: only leave a channel we actually joined. Without this, any speaker being
        -- switched off anywhere near you resets your voice channel whether or not you were
        -- ever on it.
        if not speakerListens[id] then return end
        speakerListens[id] = nil
    end
    if voice() then exports['v-voice']:SpeakerListen(id, on) end
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= 'v-voice' then return end
    if call and call.state == 'active' then exports['v-voice']:PhoneCallStart(call.id) end
    for id in pairs(speakerListens) do
        exports['v-voice']:SpeakerListen(id, true)
    end
end)

-- ── Steps ──────────────────────────────────────────────────────
-- A step count the game can actually justify: distance covered on foot, converted at a
-- normal stride. Reported in batches rather than every frame, because a health app does
-- not need to know about each footfall.
CreateThread(function()
    local last = nil
    local pending = 0.0
    while true do
        Wait(2000)
        local ped = PlayerPedId()
        if ped and ped ~= 0 and not IsPedInAnyVehicle(ped, false) then
            local at = GetEntityCoords(ped)
            if last and IsPedOnFoot(ped) then
                local d = #(at - last)
                -- Ignore teleports and spawns; a person does not cover 50 m in two seconds.
                if d > 0.2 and d < 50.0 then pending = pending + d end
            end
            last = at
        else
            last = nil
        end
        -- 0.75 m to a stride, sent once it is worth sending.
        if pending >= 40.0 then
            local steps = math.floor(pending / 0.75)
            pending = 0.0
            V.Request('v-phone:health', function() end, { op = 'steps', steps = steps })
        end
    end
end)
RegisterNUICallback('lookup',        relay('v-phone:lookup'))

RegisterNUICallback('close', function(_, cb) closePhone(); cb('ok') end)

-- Re-ask the server for everything it owns. The page calls this after any write instead of
-- patching its local copy, because a UI that edits its own snapshot is a UI that will
-- eventually disagree with the database.
RegisterNUICallback('refresh', function(_, cb)
    V.Request('v-phone:open', function(res)
        if res and res.ok then
            myNumber = res.number
            mediaOn = res.media == true
            syncSdkApps(res.apps)
        end
        cb(res or { error = 'x' })
    end)
end)

-- ══════════════════════════════════════════════════════════════
-- The apps that do more than read
-- ══════════════════════════════════════════════════════════════
-- Each of these forwards to the module that owns the action, so the module's own
-- validation, notifications and settings all still apply. None of them decide anything.

RegisterNUICallback('threadDelete', relay('v-phone:threadDelete'))
RegisterNUICallback('callsDelete', relay('v-phone:callsDelete'))
RegisterNUICallback('places', relay('v-phone:places'))
RegisterNUICallback('install', relay('v-phone:install'))

--- The card the Wallet app draws. It used to ask `v-banking:card`, a callback that exists
--- only in the author's own suite, so no server outside it ever showed a card. The phone
--- mints and keeps the number itself now, and the balance comes from the framework.
RegisterNUICallback('card', relay('v-phone:card'))

--- Setting a waypoint is the one thing a phone map is actually for. Purely local: it
--- moves a marker on this player's own minimap and touches nothing else.
-- The flashlight is the phone's own: a light drawn at the handset while it is out, so
-- the control centre torch does something you can see in the dark.
-- The NUI raises this when a text field takes or loses focus. While typing, the keyboard
-- must go to the page only (or 'w' walks you off); the rest of the time it flows to the
-- game so movement works.
RegisterNUICallback('holdInput', function(data, cb)
    if isOpen then SetNuiFocusKeepInput(not (data and data.focused == true)) end
    cb({ ok = true })
end)

RegisterNUICallback('torch', function(data, cb)
    if not isOpen then
        phoneTorch = false
        cb({ error = 'closed' })
        return
    end
    phoneTorch = data and data.on == true
    cb({ ok = true })
end)

RegisterNUICallback('waypoint', function(data, cb)
    local x, y = tonumber(data and data.x), tonumber(data and data.y)
    if not x or not y then cb({ error = 'x' }) return end
    SetNewWaypoint(x + 0.0, y + 0.0)
    cb({ ok = true })
end)

-- The music deck is a CLIENT concern: the car radio and the DJ deck are both client-side
-- UIs, and a hook an operator writes runs where the sound does. So this answers locally
-- rather than asking a server callback that never existed.
RegisterNUICallback('music', function(data, cb)
    if GetResourceState('v-music') ~= 'started' then cb({ error = 'off' }) return end
    local action = tostring((data and data.action) or '')
    local music = V.Use('v-music')

    if action == 'play' then
        -- Remembered for `/phonemusic`: when there is no sound, the single most useful fact is
        -- which URL the phone actually tried to play.
        MusicLastUrl = tostring((data and data.url) or '')
        cb(music.Play({
            url = data and data.url, title = data and data.title,
            artist = data and data.artist, volume = data and data.volume,
        }, data and data.kind) or { error = 'x' })
    elseif action == 'pause' or action == 'resume' then
        -- Neither of these existed. The page has had a pause button since the app shipped and
        -- it fell through to the `else` below, which answers `x` - so the button reported an
        -- error the page then swallowed, and pausing has never once worked.
        cb(music.Pause(action == 'resume') or { error = 'x' })
    elseif action == 'stop' then
        cb(music.Stop() or { error = 'x' })
    elseif action == 'volume' then
        cb(music.Volume(data and data.volume) or { error = 'x' })
    elseif action == 'provider' then
        cb({ ok = true, provider = music.Provider() })
    else
        cb({ error = 'x' })
    end
end)

-- ══════════════════════════════════════════════════════════════
-- A charger that wants paying
-- ══════════════════════════════════════════════════════════════
-- The server offers, the page answers. Neither the price nor which charger it is comes from
-- this side - see server/charging.lua - so these two relays carry nothing but yes and no.
RegisterNUICallback('chargePay', function(_, cb)
    V.Request('v-phone:charge:pay', function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('chargeDecline', function(_, cb)
    V.Request('v-phone:charge:decline', function(res) cb(res or { error = 'x' }) end, {})
end)

-- The FruitCharge app: the charger list and the auto-accept preference. Coordinates come
-- down with the list (a public charger is a published place), so the waypoint is set here
-- from what the page was already given rather than a second server round-trip.
RegisterNUICallback('chargingApp', function(_, cb)
    V.Request('v-phone:charging:app', function(res) cb(res or { error = 'x' }) end, {})
end)

--- The cable came out.
---
--- Raised by the server the moment the player leaves the place they plugged in - out of the car,
--- out of the property. A banner rather than nothing, because it happens with the phone in a
--- pocket: without it the only symptom is a flat battery an hour later and no idea why.
---
--- Goes through `PhoneNotify` like everything else, so muting the app or turning on Do Not
--- Disturb silences it the same way.
RegisterNetEvent('v-phone:client:unplugged', function()
    if not PhoneNotify then return end
    PhoneNotify({
        app = 'charging', icon = 'charging',
        title = (PhoneString and PhoneString('app.charging')) or 'FruitCharge',
        body = (PhoneString and PhoneString('ph.charge_unplugged_left')) or '',
        hasItem = true,
    })
end)

--- The switch: put the phone on charge, or take it off.
---
--- Nothing is decided here. The server knows where the ped actually is, which is the only place
--- "there is something to plug into" can honestly be answered.
RegisterNUICallback('chargingPlug', function(data, cb)
    V.Request('v-phone:charge:plug', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('chargingPrefs', function(data, cb)
    V.Request('v-phone:charging:prefs', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('chargingWaypoint', function(data, cb)
    local x, y = tonumber(data and data.x), tonumber(data and data.y)
    if x and y then SetNewWaypoint(x + 0.0, y + 0.0) end
    cb({ ok = x ~= nil and y ~= nil })
end)

--- Somebody is standing at a paid charger.
---
--- It arrives as a real phone notification rather than a prompt on the world: the phone is
--- what is being charged, the money is on the phone, and a player whose handset is away should
--- still find out - which is what `peek` is for. The page raises the accept/refuse sheet when
--- it is open, and keeps the notification either way so a dismissed offer can be found again.
RegisterNetEvent('v-phone:client:chargeOffer', function(d)
    if type(d) ~= 'table' then return end
    if d.clear then
        SendNUIMessage({ action = 'chargeClear' })
        return
    end

    -- Standing at a paid charger without FruitCharge. A notification that opens the store, not
    -- an offer: there is nothing to accept an offer with until the app is bought.
    if d.needApp then
        local b = {
            app = 'store', icon = 'store',
            title = L('ph.charge_needapp_title'),
            body = L('ph.charge_needapp_body'):format(tostring(d.price or 0)),
            hasItem = true,
        }
        SendNUIMessage({ action = 'chargeClear' })
        if isOpen then
            if not notificationMuted('banner', b) and not notificationSilent('banner', b) then buzz(false) end
        else
            peek('banner', b)
        end
        return
    end

    -- Auto-accept paid it without asking. A quiet confirmation, and a refresh so the app shows
    -- the stop it just opened.
    if d.auto then
        local b = {
            app = 'charging', icon = 'charging',
            title = L('ph.charge_auto_title'),
            body = L('ph.charge_auto_body'):format(tostring(d.price or 0), tostring(d.label or '')),
            hasItem = true,
        }
        SendNUIMessage({ action = 'chargeRefresh' })
        if isOpen then
            if not notificationMuted('banner', b) and not notificationSilent('banner', b) then buzz(false) end
        else
            peek('banner', b)
        end
        return
    end

    -- Auto-accept was on but could not pay - no money, most likely. Say so, once, rather than
    -- silently not charging and leaving the player to wonder.
    if d.autofail then
        local b = {
            app = 'charging', icon = 'charging',
            title = L('ph.charge_auto_title'),
            body = L('ph.charge_autofail_body'),
            hasItem = true,
        }
        if isOpen then
            if not notificationMuted('banner', b) and not notificationSilent('banner', b) then buzz(false) end
        else
            peek('banner', b)
        end
        return
    end

    if not d.offer then return end

    local b = {
        app = 'charging', icon = 'charging',
        title = L('ph.charge_offer_title'),
        body = L('ph.charge_offer_body'):format(tostring(d.price or 0), tostring(d.label or '')),
        hasItem = true,
    }
    SendNUIMessage({ action = 'chargeOffer', offer = d, banner = b })
    if isOpen then
        if not notificationMuted('banner', b) and not notificationSilent('banner', b) then buzz(false) end
    else
        peek('banner', b)
    end
end)

RegisterNUICallback('payRent', function(data, cb)
    if GetResourceState('v-housing') ~= 'started' then cb({ error = 'off' }) return end
    V.Request('v-housing:payRent', function(res) cb(res or { error = 'x' }) end, data)
end)

--- The MDT reads v-police directly. `isCop` is re-checked there on every call, so the
--- app gate in the registry only decides whether the icon is drawn.
RegisterNUICallback('mdt', function(data, cb)
    local op = tostring((data and data.op) or '')

    -- The author's own police module first, if it is genuinely running: it has more than a phone
    -- directory and a server that has it should use it. `realGetResourceState` rather than the
    -- shimmed one, because the shim reports `v-police` as started on the strength of a config
    -- list - which is exactly how this app came to ask a question nobody was answering.
    local realPolice = PhoneRealResourceState and PhoneRealResourceState('v-police') == 'started'

    if op == 'lookup' then
        if realPolice then
            V.Request('v-police:lookup', function(res) cb(res or { error = 'x' }) end,
                { query = data.query })
        else
            V.Request('v-phone:mdt:lookup', function(res) cb(res or { error = 'x' }) end,
                { query = data.query })
        end
    elseif op == 'warrants' then
        if realPolice then
            V.Request('v-police:warrants', function(res) cb(res or { error = 'x' }) end)
        else
            V.Request('v-phone:mdt:warrants', function(res) cb(res or { error = 'x' }) end)
        end
    else
        cb({ error = 'x' })
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Camera, health and layout
-- ══════════════════════════════════════════════════════════════

--- The Health app has two data owners behind one stable NUI endpoint:
--- `get`/`set` are the persisted medical record owned by v-phone, while a request with no
--- operation is the live status snapshot owned by v-status.
RegisterNUICallback('health', function(data, cb)
    local op = data and data.op
    if op == 'get' or op == 'set' then
        V.Request('v-phone:health', function(res) cb(res or { error = 'x' }) end, data)
        return
    end
    if op ~= nil then cb({ error = 'x' }) return end

    -- Two halves, and neither is optional.
    --
    -- Health and armour are the PED's, and a ped can only be read on the client. Hunger,
    -- thirst and stress are the FRAMEWORK's, and on qb they live in the character's metadata,
    -- which only the server holds - the client's own reading looked for them on a state bag
    -- qb does not fill, so they came back as zero on every qb server while health worked.
    -- That is the "half working" this fixes.
    local ped = PlayerPedId()
    local live = {
        armour = math.floor(GetPedArmour(ped)),
        health = math.max(0, math.floor(GetEntityHealth(ped) - 100)),   -- GTA floors a living ped at 100
    }

    -- Whatever the client CAN read locally: esx_status keeps its vitals here and nowhere
    -- else, so on ESX this is the only source there is.
    local ok, st = pcall(function() return exports['v-status']:Get() end)
    if ok and type(st) == 'table' then
        live.hunger, live.thirst, live.stress = st.hunger, st.thirst, st.stress
        live.bleed, live.sick = st.bleed, st.sick
    end

    V.Request('v-phone:vitals', function(res)
        if type(res) == 'table' then
            -- The server wins where it knows: it reads the framework, the client was
            -- guessing. Where it knows nothing, the client's own reading stands.
            if res.hunger ~= nil then live.hunger = res.hunger end
            if res.thirst ~= nil then live.thirst = res.thirst end
            if res.stress ~= nil then live.stress = res.stress end
            if res.dead ~= nil then live.dead = res.dead end
            if res.bloodtype ~= nil then live.bloodtype = res.bloodtype end
            -- Armour is the exception: the ped is the truth, whatever a metadata copy says.
        end
        live.ok = true
        cb(live)
    end)
end)

--- The hospitals, from the config. Answered here rather than through the server because the
--- list IS the config: it is the same on every client, it never changes while the server is
--- up, and a round trip to be told what this client already has in memory would be waste.
--- The Music app's library is answered the same way and for the same reason.
--- This player's temporary server id.
---
--- The number staff ask for and the number a player has to read off something. It is not a
--- secret - it is in the player list and on every server console line about them - but it is
--- also not knowable from the page, so the page has to be told.
RegisterNUICallback('serverId', function(_, cb)
    cb({ ok = true, id = GetPlayerServerId(PlayerId()) })
end)

RegisterNUICallback('hospitals', function(_, cb)
    local out = {}
    for _, h in ipairs(Config.Hospitals or {}) do
        if type(h) == 'table' and h.label then
            out[#out + 1] = {
                label = tostring(h.label):sub(1, 60),
                address = h.address and tostring(h.address):sub(1, 80) or nil,
                -- Both or neither: half a coordinate cannot be pointed at, and sending one
                -- would put a marker in the sea.
                x = (tonumber(h.x) and tonumber(h.y)) and tonumber(h.x) or nil,
                y = (tonumber(h.x) and tonumber(h.y)) and tonumber(h.y) or nil,
            }
        end
    end
    cb({ ok = true, hospitals = out })
end)

RegisterNUICallback('photos', relay('v-phone:photo'))

--- The social apps. One relay with a whitelist, because the page names an operation and
--- the client decides which callbacks that can ever mean - the same shape as the SDK.
local SOCIAL_OPS = {
    me = true, setup = true, feed = true, post = true, like = true,
    hushMe = true, hushSetup = true, hushNext = true, hushChoice = true, hushMatches = true,
    hushRewind = true, hushUnmatch = true,
    -- Hush's own conversation. It does NOT go through the Messages app: a dating app that hands
    -- over a phone number to say hello is a directory, and a number cannot be taken back.
    hushChat = true, hushSay = true,
    -- The account system: SMS verification, sign-up, login, logout.
    requestCode = true, verifyCode = true, register = true, login = true, logout = true,
    -- Forgot the password: the same texted code, then a new one.
    resetCode = true, resetPassword = true,
    -- People: a profile, the directory, following.
    profile = true, search = true, follow = true,
    -- What a post can carry beyond a like.
    comments = true, comment = true, uncomment = true, repost = true, delete = true,
    -- What happened to you, what people are talking about, and one tag's posts.
    notifs = true, notifCount = true, notifSeen = true, tag = true, trending = true,
    -- Saved posts, the explore grid, and who watched a story.
    save = true, saved = true, explore = true, storyViewers = true,
    -- Stories, and the direct messages between two handles.
    stories = true, story = true, storySeen = true,
    dmList = true, dmThread = true, dmSend = true, dmDelete = true,
}

-- The page owns the keyboard while the phone is open, so it is the only side that sees Alt
-- go down. It says so here; the guard thread notices the release, because by then focus has
-- been dropped and the control reads normally again.
-- Alt TOGGLES the camera. One tap frees the mouse, another gives the phone back.
--
-- Holding was the original idea and it does not work, for a reason worth writing down: only
-- the page can see Alt go down (the browser owns the keyboard), and only the game can see it
-- come back up (by then focus is gone and the page has no keyboard). Neither side sees both
-- edges, so "held" is a state nothing can observe reliably - the release was read as instant
-- every time, and free look ended on the frame it began.
--
-- A toggle needs one edge from each side, which is exactly what is available.
local function endFreeLook()
    if not freeLook then return end
    freeLook = false
    if isOpen then
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(true)
        SendNUIMessage({ action = 'freelook', on = false })
    end
    if debugOn() then print('[v-phone] free look off') end
end

RegisterNUICallback('freelook', function(_, cb)
    cb({ ok = true })
    if not isOpen or freeLook then return end

    freeLook = true
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'freelook', on = true })
    if debugOn() then print('[v-phone] free look on') end

    CreateThread(function()
        -- The game has just been handed input and the player may still be holding the tap
        -- that got us here. Wait for Alt to be UP before watching for the next press, or the
        -- same keystroke toggles straight back off.
        while freeLook and isOpen and IsControlPressed(0, 19) do Wait(0) end
        Wait(120)

        -- Now the next tap ends it. Escape does too, since a player whose cursor is gone
        -- reaches for that first.
        while freeLook and isOpen do
            -- 199 and 200 are DISABLED by the guard thread, so the plain read never sees
            -- them; the disabled form does. 19 is not blocked, so either works for Alt.
            if IsControlJustPressed(0, 19)
                or IsDisabledControlJustPressed(0, 200) or IsControlJustPressed(0, 200)
                or IsDisabledControlJustPressed(0, 199) or IsControlJustPressed(0, 199) then
                break
            end
            Wait(0)
        end
        endFreeLook()
    end)
end)

RegisterNUICallback('social', function(data, cb)
    local op = tostring((data and data.op) or '')
    if not SOCIAL_OPS[op] then cb({ error = 'forbidden' }) return end
    -- The social layer is part of the phone now, so this is the phone's own server. No
    -- second resource to check for, and nothing to be off but the setting itself.
    V.Request('v-phone:soc:' .. op, function(res) cb(res or { error = 'x' }) end, data)
end)

--- What the widgets show. Both are the GAME's: the weather the server is actually
--- running (v-admin replicates it on GlobalState) and the in-game clock. A widget
--- showing the player's real-world time would be showing the wrong clock.
RegisterNUICallback('ambient', function(_, cb)
    cb({
        ok = true,
        weather = tostring(GlobalState.vweather or GetPrevWeatherTypeHashName() or 'CLEAR'),
        hours = GetClockHours(), minutes = GetClockMinutes(),
        day = GetClockDayOfMonth(), month = GetClockMonth() + 1,
    })
end)

--- Take a picture.
---
--- screenshot-basic uploads it and hands back a URL; the phone stores the URL. There is
--- deliberately no path for a data URI: a photo kept as base64 in a metadata column is
--- megabytes per shot, and the operator's upload target is the whole reason the camera
--- setting has one.
-- ══ Camera mode ═══════════════════════════════════════════════
-- qb-phone's sequence, because it is the one that produces a photograph: SetNuiFocus off,
-- CreateMobilePhone(1) - GTA's own phone camera, which is what draws the frame - then
-- CellCamActivate, the HUD hidden per frame, and both destroyed on the way out. The handset is
-- hidden while it runs so nothing of the page bleeds into the shot. Enter shoots, Backspace
-- leaves, arrow up flips to the selfie: the keys a QBCore player already knows.
--
-- **`camActive` is not redeclared here.** It lives at the top of this file because the input
-- guard and the stuck-detector both sit above this block and read it; a `local` here shadowed it
-- and left the camera writing one variable while both guards read another - which is a player in
-- camera mode with no cursor and no way out but reconnecting.

-- The selfie toggle has no name in FiveM's native list, so there is no global for it and it
-- can only be reached by hash - the same wrapper qb-phone declares. pcall'd inside, because the
-- hash is undocumented and a rejection must cost the selfie rather than the phone.
--
-- This is ASSIGNED to the forward declaration at the top of the file: forceReset calls it from
-- above, and a `local function` here would be a nil global up there.
-- The selfie framing controls. GTA exposes five of them and none has a Lua name, so each is
-- reached by hash. The ranges are the documented ones - feeding a value outside them does
-- nothing visible, so they are clamped rather than trusted.
local SELFIE = {
    pitch  = { hash = 0xD6ADE981781FCA09, min = -1.0, max = 1.0 },   -- head pitch, up/down
    roll   = { hash = 0xF1E22DC13F5EEBAD, min = -1.0, max = 1.0 },   -- head roll, tilt
    horiz  = { hash = 0x1B0B4AEED5B9B41C, min = -1.0, max = 1.0 },   -- shift left/right
    vert   = { hash = 0x3117D84EFA60F77B, min =  0.0, max = 2.0 },    -- raise/lower
    dist   = { hash = 0x53F4892D18EC90A4, min = -1.0, max = 1.0 },   -- arm's length
}

local selfie = { pitch = 0.0, roll = 0.0, horiz = 0.0, vert = 1.0, dist = 0.0 }

selfieReset = function()
    selfie.pitch, selfie.roll, selfie.horiz, selfie.vert, selfie.dist = 0.0, 0.0, 0.0, 1.0, 0.0
end

local function selfieApply()
    for key, axis in pairs(SELFIE) do
        local v = math.max(axis.min, math.min(axis.max, selfie[key]))
        selfie[key] = v
        pcall(Citizen.InvokeNative, axis.hash, v + 0.0)
    end
end

frontCam = function(on)
    pcall(Citizen.InvokeNative, 0x2491A93618B7D838, on == true)
end

camModeOff = function()
    if not camActive then return end
    camActive = false
    -- State and the page first, engine second. closePhone calls this on its way out and a
    -- native that raises here used to abort the close, leaving no cursor and no way back.
    if isOpen then
        SendNUIMessage({ action = 'camLive', on = false })
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(true)
    end
    pcall(function()
        frontCam(false)
        CellCamActivate(false, false)
        DestroyMobilePhone()
        ClearHelp(true)
        -- Only what we hid. Restoring the radar for a player whose own HUD script had
        -- deliberately hidden it is not this resource's business - npwd's guard.
        if camHidHud then DisplayHud(true) end
        if camHidRadar then DisplayRadar(true) end
    end)
    camHidHud, camHidRadar = false, false
    selfieReset()

    -- And the pose. `CreateMobilePhone` and `CellCamActivate` disturb the ped's task, so the
    -- hold animation is left frozen when the camera closes - the phone sits in the hand doing
    -- nothing. z-phone re-plays its animation at exactly this point for the same reason.
    if isOpen then
        -- The prop and pose were taken away to let GTA's phone camera have the ped. Give them
        -- back, or the player is left holding nothing with a frozen animation.
        phoneAnim = nil        -- force playHold to restart rather than think it is already on
        attachProp()
        refreshPose()
    end
end

RegisterNUICallback('camMode', function(data, cb)
    cb({ ok = true })
    local on = data and data.on == true
    if not on then camModeOff() return end
    if camActive or not isOpen then return end

    camActive = true
    camTick = GetGameTimer()
    local front = data.front == true

    -- The handset leaves the screen before anything else happens, and the cursor with it.
    SendNUIMessage({ action = 'camLive', on = true })
    SetNuiFocus(false, false)

    -- The prop and the pose come OFF first, and this is the part that was missing. v-phone
    -- holds its own model with its own animation, which occupies the ped's task - and
    -- `CreateMobilePhone` needs that task to raise the arm and hand the camera over. With ours
    -- still running, the call did nothing: the view stayed a normal third-person gameplay
    -- camera pointed at the player's back, and the arm never came up. qb-phone does not hit
    -- this because its hold animation IS a GTA phone task.
    clearHand()
    ClearPedSecondaryTask(PlayerPedId())

    -- Hide the HUD and radar only if something else has not already done it, and remember
    -- which, so the way out restores exactly what was taken. Turning the radar back on for a
    -- player whose own HUD script had deliberately hidden it is not this resource's business.
    camHidHud = not IsHudHidden()
    camHidRadar = not IsRadarHidden()

    pcall(function()
        CreateMobilePhone(1)
        CellCamActivate(true, true)
        frontCam(front)
        if camHidHud then DisplayHud(false) end
        if camHidRadar then DisplayRadar(false) end
    end)

    CreateThread(function()
        while camActive and isOpen do
            camTick = GetGameTimer()

            -- In selfie mode the mouse aims the SELFIE rather than the player: the front
            -- camera is pinned to the head, so turning the ped does not move the shot and the
            -- framing felt stuck. Look left/right and up/down are taken here instead and fed
            -- into the head pitch and the horizontal offset; the scroll wheel is arm's length.
            if front then
                DisableControlAction(0, 1, true)
                DisableControlAction(0, 2, true)
                local dx = GetDisabledControlNormal(0, 1)
                local dy = GetDisabledControlNormal(0, 2)
                if dx ~= 0.0 or dy ~= 0.0 then
                    selfie.horiz = selfie.horiz + dx * 0.06
                    selfie.pitch = selfie.pitch - dy * 0.06
                end
                if IsControlJustPressed(0, 241) or IsControlJustPressed(0, 15) then
                    selfie.dist = selfie.dist + 0.12
                elseif IsControlJustPressed(0, 242) or IsControlJustPressed(0, 14) then
                    selfie.dist = selfie.dist - 0.12
                end
                -- Q and E tilt the head, which is the one thing a real selfie does that
                -- pointing the phone cannot.
                if IsControlPressed(0, 44) then selfie.roll = selfie.roll - 0.02 end
                if IsControlPressed(0, 38) then selfie.roll = selfie.roll + 0.02 end
                selfieApply()
            end

            -- 27 is arrow up, 176 is Enter, 177 is Backspace: qb-phone's bindings.
            if IsControlJustPressed(1, 27) then
                front = not front
                selfieReset()
                frontCam(front)
                if front then selfieApply() end
            elseif IsControlJustPressed(1, 177) then
                break
            elseif IsControlJustPressed(1, 176) then
                -- Off screen for the whole capture, not just this frame. `shoot` lowers this
                -- again when the photograph is actually finished.
                camShooting = true
                ClearHelp(true)
                Wait(0)
                -- One capture path, the same one the shutter button uses, so there is one set
                -- of error messages rather than two.
                SendNUIMessage({ action = 'camShoot' })

                -- Wait for the capture rather than a guessed 1200ms, and keep the watchdog fed
                -- while doing it: it kills camera mode after 1500ms without a tick, which a
                -- blind wait came within 200ms of tripping - close enough to explain a camera
                -- that occasionally died mid-photograph. Capped so a capture that never calls
                -- back cannot strand the player in the viewfinder.
                local waited = 0
                while camShooting and camActive and isOpen and waited < 15000 do
                    camTick = GetGameTimer()
                    Wait(50)
                    waited = waited + 50
                end
                camShooting = false
                ClearHelp(true)

                -- Re-assert the camera, because the capture is not ours: screencapture does
                -- the grab in its OWN NUI, and a second browser taking the screen can leave
                -- focus and the phone camera where it found them rather than where we left
                -- them. Framing the second photograph then failed - the camera would not move
                -- any more - while the first had worked perfectly.
                --
                -- Idempotent: re-activating a camera that is already active costs nothing, and
                -- doing it unconditionally is cheaper than trying to detect which of the two
                -- browsers won.
                if camActive and isOpen then
                    SetNuiFocus(false, false)
                    pcall(function()
                        CellCamActivate(true, true)
                        frontCam(front)
                    end)
                    if front then selfieApply() end
                end
            end

            -- The handset is not on screen, so the keys have to be. `~INPUT_...~` rather
            -- than key names: the game substitutes whatever the player actually has bound, so
            -- this stays true for somebody who rebound them - which hardcoded "ENTER" did not.
            -- Nothing on screen while a capture is in flight. `ClearHelp` on the shutter
            -- frame was not enough: the shot lands several frames later, and this loop redrew
            -- the box on every one of them - so the instructions were in the photograph.
            if not camShooting then
                BeginTextCommandDisplayHelp(front and 'FOURSTRINGS' or 'THREESTRINGS')
                AddTextComponentString(L('ph.cam_shoot_hint'))
                AddTextComponentString(L('ph.cam_flip_hint'))
                AddTextComponentString(L('ph.cam_exit_hint'))
                if front then AddTextComponentString(L('ph.cam_selfie_hint')) end
                -- `loop = false`. With it true the box keeps itself on screen after the loop
                -- stops drawing, which is why the help sometimes stayed up after the camera
                -- closed. Drawn every frame anyway, so nothing is lost letting each expire.
                EndTextCommandDisplayHelp(0, false, false, -1)
            end

            HideHudComponentThisFrame(6)
            HideHudComponentThisFrame(7)
            HideHudComponentThisFrame(8)
            HideHudComponentThisFrame(9)
            HideHudComponentThisFrame(19)
            HideHudAndRadarThisFrame()
            -- Everything back on, every frame: the phone's guard thread disables looking
            -- while it is open, which would leave the camera pointing wherever the player last
            -- happened to be facing.
            EnableAllControlActions(0)
            -- Except the fists. `EnableAllControlActions` hands attack back too, so a player
            -- clicking to take a photograph threw a punch instead. The shutter is Enter.
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            Wait(0)
        end
        camModeOff()
    end)
end)

--- The selfie from the phone's own button, for the moment before the camera view opens.
RegisterNUICallback('camFacing', function(data, cb)
    cb({ ok = true })
    if camActive then frontCam(data and data.front == true) end
end)

RegisterNUICallback('shoot', function(_, cb)
    local finished = false
    local focusReleased = false
    local captureRequest = openRequest
    -- Held here rather than in the key handler so both routes to a photograph - the Enter key
    -- and the on-screen shutter - keep the help box out of the frame for the whole capture.
    if camActive then camShooting = true end

    -- screenshot-basic and the upload endpoint are both asynchronous. Whichever path
    -- finishes first owns the reply; late callbacks become harmless no-ops.
    local function finish(result)
        if finished then return end
        finished = true
        result = type(result) == 'table' and result or { error = 'x' }

        -- The photograph is taken: the viewfinder may show its instructions again.
        camShooting = false
        ClearHelp(true)

        -- Not while the camera is framing. In camera mode Lua has deliberately taken the
        -- cursor away so the mouse aims the shot, and handing it back after every capture
        -- would drop a cursor into the middle of the next one.
        if focusReleased and isOpen and not camActive and openRequest == captureRequest then
            SetNuiFocus(true, true)
            SetNuiFocusKeepInput(true)
        end
        SendNUIMessage({
            action = 'shutterDone',
            ok = result.ok == true,
            error = result.error,
        })
        cb(result)
    end

    -- The media backend (screencapture + a CDN, key server-side) is preferred when the
    -- operator turned it on: the server does the capture and the upload, so the phone only
    -- has to get out of the shot. It falls through to screenshot-basic when media is off.
    -- `mediaOn` comes from the server with the open payload. Reading Config here was the
    -- bug: the operator's switch is a convar the server resolves, and a client that reads
    -- the file instead disagrees with it.
    local useMedia = mediaOn and GetResourceState('screencapture') == 'started'

    if useMedia then
        SendNUIMessage({ action = 'shutter' })
        focusReleased = true
        SetNuiFocus(false, false)
        Wait(120)
        SetTimeout(20000, function() finish({ error = 'upload' }) end)
        V.Request('v-phone:media:photo', function(r)
            if not r or not r.ok then finish(r or { error = 'upload' }) return end
            -- The server already put it in the gallery - it made the URL, so it needs no
            -- allowlist check and no second round trip. Older builds answered without
            -- `stored`, so that case still adds it the long way.
            if r.stored then finish({ ok = true, url = r.url }) return end
            V.Request('v-phone:photo', function(res) finish(res or { error = 'x' }) end,
                { op = 'add', url = r.url })
        end, {})
        return
    end

    if GetResourceState('screenshot-basic') ~= 'started' then
        finish({ error = 'nocam' })
        return
    end
    local target = tostring(V.Setting('cameraUpload', '') or '')
    if target == '' then
        finish({ error = 'noupload' })
        return
    end

    -- Hide the phone for the shot, or every photo is a picture of the phone.
    SendNUIMessage({ action = 'shutter' })
    focusReleased = true
    SetNuiFocus(false, false)
    Wait(120)

    -- A broken upload target must still release the NUI request and restore the shutter.
    SetTimeout(20000, function() finish({ error = 'upload' }) end)

    local called = pcall(function()
        exports['screenshot-basic']:requestScreenshotUpload(
            target,
            'files[]',
            { encoding = 'jpg', quality = 0.85 },
            function(raw)
                if finished then return end
                local ok, res = pcall(json.decode, raw)
                -- Upload targets disagree about where they put the URL, so look in the two
                -- shapes that cover almost all of them and fail honestly otherwise.
                local url = ok and res and (
                    (res.attachments and res.attachments[1] and res.attachments[1].url)
                    or res.url or res.link or (res.data and res.data.link))
                if not url then finish({ error = 'upload' }) return end
                if finished then return end
                V.Request('v-phone:photo', function(r) finish(r or { error = 'x' }) end,
                    { op = 'add', url = url })
            end
        )
    end)
    if not called then finish({ error = 'upload' }) end
end)

-- Selfie: a game camera placed in front of the ped's head, looking back, so a photo or a
-- clip is of the player. screencapture / screenshot-basic capture whatever is rendered, so
-- the same shot path works front or back - only the camera moves.
selfieCam = nil
stopSelfie = function()
    if not selfieCam then return end
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(selfieCam, false)
    selfieCam = nil
    ClearPedTasks(PlayerPedId())
end

local function setSelfie(on)
    if on then
        if not selfieCam then
            local ped = PlayerPedId()
            local head = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)   -- SKEL_Head
            local fwd = GetEntityForwardVector(ped)
            local eye = vector3(head.x + fwd.x * 0.9, head.y + fwd.y * 0.9, head.z + 0.05)
            selfieCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
                eye.x, eye.y, eye.z, 0.0, 0.0, 0.0, 45.0, false, 0)
            PointCamAtPedBone(selfieCam, ped, 31086, 0.0, 0.0, 0.0, true)
            SetCamActive(selfieCam, true)
            RenderScriptCams(true, false, 0, true, true)
        end
    else
        stopSelfie()
    end
end

-- The scripted cam above is now ONLY for FaceTime, where the phone is at the player's ear
-- and there is no camera app open to hand the job to the engine.
--
-- The Camera app's own flip is registered further up and uses `CellFrontCamActivate`. There
-- used to be a second `camFacing` callback here that drove this scripted cam instead - and
-- being registered later it won, so the app's selfie button reached the wrong mechanism and
-- pointed a camera at a head the engine was not drawing.
AddEventHandler('v-phone:internal:selfie', function(on) setSelfie(on == true) end)

-- The camera closing (or the phone closing) drops the selfie cam whatever state it is in.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then stopSelfie() end
end)

-- Record a clip. The server (through screencapture) records the player's view for the
-- requested seconds, uploads it, and answers with the URL. The phone hides for the shot
-- and comes back when it is done.
RegisterNUICallback('record', function(data, cb)
    -- **This read `Config.Media.enabled` and refused every recording.**
    --
    -- Media hosting is switched on with `set phone_media true`, which is a server convar - it
    -- is not replicated, so a client cannot see it, and `Config.Media.enabled` is still false
    -- in the file. The Video tab appeared, because the page is told by the server in the open
    -- payload, and then the button it belonged to answered "not available on this server".
    -- Exactly the mistake the camera made before it: the operator's switch is a convar the
    -- SERVER resolves, so the server is the only thing that may answer this.
    --
    -- The gate is gone rather than corrected: `v-phone:media:video` already checks
    -- `Bridge.MediaVideoEnabled()`, which reads the convar, so a second opinion here could
    -- only ever disagree with the one that matters.
    if GetResourceState('screencapture') ~= 'started' then
        cb({ error = 'off' }) return
    end
    local finished = false
    local captureRequest = openRequest
    local function finish(result)
        if finished then return end
        finished = true
        if isOpen and openRequest == captureRequest then
            SetNuiFocus(true, true)
            SetNuiFocusKeepInput(true)
        end
        SendNUIMessage({ action = 'recordDone', ok = (result or {}).ok == true })
        cb(result or { error = 'x' })
    end

    -- Hide the phone for the whole recording, then restore.
    SendNUIMessage({ action = 'recording' })
    SetNuiFocus(false, false)
    V.Request('v-phone:media:video', function(r) finish(r or { error = 'x' }) end,
        { seconds = tonumber(data and data.seconds) })
end)

-- ══════════════════════════════════════════════════════════════
-- App SDK relays
-- ══════════════════════════════════════════════════════════════
-- The shell announces which installed iframe is active. SDK payloads are deliberately
-- unable to select or override this namespace.
RegisterNUICallback('activeApp', function(data, cb)
    if not isOpen then
        activeSdkApp = nil
        cb({ error = 'closed' })
        return
    end

    local epoch = math.floor(tonumber(data and data.epoch) or 0)
    if epoch <= activeSdkEpoch then
        cb({ error = 'stale' })
        return
    end
    activeSdkEpoch = epoch

    local app = sdkAppId(data and data.app)
    if app == '' then
        activeSdkApp = nil
        cb({ ok = true })
        return
    end
    if not app or not sdkApps[app] then
        activeSdkApp = nil
        cb({ error = 'forbidden' })
        return
    end

    activeSdkApp = app
    cb({ ok = true, app = app })
end)

local function sdkApp()
    if not isOpen then return nil end
    return activeSdkApp
end

RegisterNUICallback('sdkRequest', function(data, cb)
    local app = sdkApp()
    local method = tostring((data and data.method) or ''):gsub('[^%w_-]', '')
    if not app or method == '' then cb({ error = 'forbidden' }) return end
    V.Request(app .. ':' .. method, function(res) cb(res == nil and { ok = true } or res) end, data.payload)
end)

RegisterNUICallback('sdkEmit', function(data, cb)
    local app = sdkApp()
    local event = tostring((data and data.event) or ''):gsub('[^%w_-]', '')
    if not app or event == '' then cb({ error = 'forbidden' }) return end
    TriggerServerEvent(app .. ':' .. event, data.payload)
    cb({ ok = true })
end)

local function appStorage(app, data, cb)
    data = type(data) == 'table' and data or {}
    V.Request('v-phone:storage', function(res) cb(res or { error = 'x' }) end, {
        app = app, op = data.op, key = data.key, value = data.value,
    })
end

-- Built-in apps that use the generic key/value store have their own narrow route. The
-- payload chooses only between canonical ids held here; it cannot name a third-party app.
local BUILTIN_STORAGE_APPS = { music = 'music', reminders = 'reminders' }
RegisterNUICallback('appStorage', function(data, cb)
    local app = isOpen and BUILTIN_STORAGE_APPS[tostring((data and data.app) or '')] or nil
    if not app then cb({ error = 'forbidden' }) return end
    appStorage(app, data, cb)
end)

RegisterNUICallback('sdkStorage', function(data, cb)
    local app = sdkApp()
    if not app then cb({ error = 'forbidden' }) return end
    appStorage(app, data, cb)
end)

-- Device capabilities exposed to a sandboxed app. The coordinates are read here from
-- the player's ped, never accepted from the iframe, and only while that app is active.
RegisterNUICallback('sdkLocation', function(_, cb)
    if not sdkApp() then cb({ error = 'forbidden' }) return end
    local coords = GetEntityCoords(PlayerPedId())
    cb({
        ok = true,
        x = math.floor(coords.x * 10 + 0.5) / 10,
        y = math.floor(coords.y * 10 + 0.5) / 10,
        z = math.floor(coords.z * 10 + 0.5) / 10,
        heading = math.floor(GetEntityHeading(PlayerPedId()) * 10 + 0.5) / 10,
    })
end)

RegisterNUICallback('sdkHaptic', function(data, cb)
    if not sdkApp() then cb({ error = 'forbidden' }) return end
    local style = tostring((data and data.style) or 'light')
    local sounds = {
        light = { 'NAV_UP_DOWN', 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
        medium = { 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
        success = { 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET' },
        warning = { 'ERROR', 'HUD_AMMO_SHOP_SOUNDSET' },
        error = { 'CHECKPOINT_MISSED', 'HUD_MINI_GAME_SOUNDSET' },
    }
    local sound = sounds[style] or sounds.light
    PlaySoundFrontend(-1, sound[1], sound[2], true)
    cb({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Calls
-- ══════════════════════════════════════════════════════════════
-- The audio is v-voice's; these four handlers only start and stop it at the right moments.
local function joinCallAudio()
    if voice() then exports['v-voice']:PhoneCallStart(call and call.id) end
end

local function leaveCallAudio()
    if voice() then exports['v-voice']:PhoneCallEnd(call and call.id) end
end

-- Assigned below, next to the bad-line effect that owns the overrides. Declared here because
-- `endCallLocal` runs above that point and has to be able to hand a player's voice back: a call
-- that ended while the line was down must not leave the other person permanently quiet.
local releaseBadLine = function() end
-- Declared with it, and for the same reason: the call handlers below are far above the
-- bad-line block that fills these in, and a name that is not local yet is a global.
local releaseGonePeers = function() end

-- ── A call on a bad line ───────────────────────────────────────
-- One bar is not "a bit worse than four" - it is a call that keeps breaking up. While the
-- signal is at or below `Config.Calls.badSignal.atBars`, the line cuts out at random: the
-- player's own voice is muted for a moment so the FAR END hears the break too, the page
-- stutters and hisses, and a line this bad can drop the call outright.
--
-- The voice half is the honest half. A glitch drawn on a call you can still hear perfectly
-- reads as a broken phone rather than as a broken signal, which is the opposite of the point.
local badLine = false          -- true while a cut-out is in progress
-- **Per player, not per call.** These were single values, because a call had exactly one far
-- end. On a conference each person is on their OWN line: holding all of them at the level the
-- worst one deserves would make somebody standing under a mast sound like the one person in a
-- tunnel, which is a lie about where both of them are.
local peerLevel = {}           -- [serverId] = the volume they are held at, or absent for normal
local peerCuts = {}            -- [serverId] = true while THEIR line is cutting out on our side
local heldIds = {}             -- [serverId] = true for anyone we have turned down and not restored
local peerBars = {}            -- [serverId] = how many bars THEY have, from the server

local function badCfg()
    return (Config.Calls or {}).badSignal or {}
end

--- Turn one player's voice down, for us only.
---
--- `MumbleSetVolumeOverrideByServerId` is the CFX native the voice layer itself is built on: it
--- multiplies what we hear from one player, takes effect on the next audio frame, and needs no
--- round trip to anybody. `-1.0` gives the player back their normal volume.
---
--- Guarded rather than called outright. It is a client native that has to exist on the build the
--- player is running, and an unguarded call to a missing global is an error inside the effect -
--- which would take the whole bad-line thread with it and leave the phone with no signal handling
--- at all. A build without it degrades to the channel route below.
local function mumbleVolume(serverId, volume)
    if type(MumbleSetVolumeOverrideByServerId) ~= 'function' then return false end
    return pcall(MumbleSetVolumeOverrideByServerId, serverId, volume + 0.0)
end

local function volumeSupported()
    return type(MumbleSetVolumeOverrideByServerId) == 'function'
end

--- Everybody on the far end, as server ids. One on an ordinary call, several on a conference.
---
--- Falls back to the single `peer` field, which is what `callActive` sends before the roster
--- arrives and what a two-party call is described by from beginning to end.
local function farEnds()
    if not call then return {} end
    if type(call.peers) == 'table' and #call.peers > 0 then return call.peers end
    return call.peer and { call.peer } or {}
end

local function onCallWith(peer)
    if not (call and call.state == 'active') then return false end
    for _, id in ipairs(farEnds()) do if id == peer then return true end end
    return false
end

--- Hold one player at a level, or let them go.
---
--- Idempotent on purpose: the thread asks for the same level every second while the signal stays
--- where it is, and re-issuing an identical override each tick is work for no change.
local function holdOne(peer, level)
    if not peer then return false end
    if level == nil then
        if peerLevel[peer] == nil then return true end
        peerLevel[peer] = nil
        heldIds[peer] = nil
        return mumbleVolume(peer, -1.0)
    end
    if peerLevel[peer] == level then return true end
    -- Recorded only if the write LANDED. Setting it first meant that on a build with no volume
    -- native `peerLevel` read 0.2 while the audio was untouched, so `/phonevoice` reported the
    -- far end as held down when nothing was holding it - the diagnostic somebody runs precisely
    -- because they cannot hear a difference.
    if not mumbleVolume(peer, level) then return false end
    peerLevel[peer] = level
    heldIds[peer] = true
    return true
end

--- Give every override back. Called when a call ends, however it ends.
---
--- The one failure mode of a volume override is forgetting to undo it: a call that dropped mid-cut
--- would leave that player quiet for this one for the rest of the session, with nothing on screen
--- to explain it and no way for either of them to fix it. Every route out of a call goes through
--- here, including the resource being stopped.
local function releaseVoiceOverrides()
    -- Every id we have touched, from `heldIds` rather than from `call.peer`.
    --
    -- Reading the peer off `call` was wrong in the one case that matters: a call that ended while
    -- the line was down clears `call` first, so by the time this ran there was no id to restore
    -- and the other player stayed quiet - for this listener, silently, until they reconnected.
    -- The id is remembered the moment it is turned down, so losing the call cannot lose the way
    -- back.
    for id in pairs(heldIds) do mumbleVolume(id, -1.0) end
    for id in pairs(peerCuts) do mumbleVolume(id, -1.0) end
    heldIds = {}
    peerCuts = {}
    -- Whose signal we were told about goes with the call. Keeping it would open the next call
    -- already degraded on behalf of somebody who is no longer on it.
    peerBars = {}
    peerLevel = {}
    badLine = false
end

releaseBadLine = releaseVoiceOverrides

--- Hand back the voices of everybody who has LEFT, while the call carries on.
---
--- A conference somebody walks out of is the one case the end-of-call release cannot cover: the
--- call is still up, so nothing runs, and the override on the person who left is one that will
--- never be undone - they stay quiet for this listener for the rest of the session. Every roster
--- change goes through here, and the roster is the only thing that knows somebody has gone.
releaseGonePeers = function(keep)
    local live = {}
    for _, id in ipairs(keep or {}) do live[tonumber(id) or 0] = true end
    for id in pairs(heldIds) do
        if not live[id] then
            mumbleVolume(id, -1.0)
            heldIds[id], peerLevel[id], peerBars[id] = nil, nil, nil
        end
    end
    for id in pairs(peerCuts) do
        if not live[id] then mumbleVolume(id, -1.0) peerCuts[id] = nil end
    end
end

--- What the effect is doing, for `/phonevoice`. The level on the first far end, which on an
--- ordinary call is the only one there is.
badLineReport = function()
    for _, id in ipairs(farEnds()) do return badLine, peerLevel[id] end
    return badLine, nil
end

--- How loud the far end is at this many bars.
---
--- This is the part that was missing, and the reason the effect read as "nothing happens". A call
--- at one bar was a perfectly clear call interrupted by the occasional gap - and a gap every few
--- seconds in otherwise clean audio does not sound like bad reception, it sounds like the other
--- person pausing. Real one-bar reception is degraded THE WHOLE TIME, and the drop-outs happen on
--- top of that. `Config.Calls.badSignal.volumeAtBars` is the level per bar.
--- The floor, for a `config.lua` that predates this setting.
---
--- `config.lua` is the one file an update does not replace - correctly, it is the operator's - so
--- a server that updates has no `volumeAtBars` and would get drop-outs with no muffling between
--- them, which is the version of this effect that was reported as not working. The same mistake
--- was made with 911 and with the Bank Pro icon: what must be true has to be stated in code.
---
--- An operator who genuinely wants drop-outs only sets `volumeAtBars = false`.
local BAD_LEVELS = { [1] = 0.20, [2] = 0.55 }

local function levelForBars(bars)
    local levels = badCfg().volumeAtBars
    if levels == false then return nil end
    if type(levels) ~= 'table' then levels = BAD_LEVELS end
    local level = tonumber(levels[bars])
    if not level then return nil end
    return math.max(0.0, math.min(1.0, level))
end

--- How loud the far end should be, given BOTH ends of the line.
---
--- **A line is as bad as its worst end.** This is the fix for the half of the effect that was
--- one-sided: the degradation used to be worked out from this phone's bars alone, so somebody
--- at one bar heard the other person at a fifth of the volume while the other person heard them
--- perfectly. Only one of the two was on a bad line.
---
--- The weaker of the two levels wins, which is what a real line does: it does not matter which
--- end of it is in a tunnel.
---
--- nil means "nothing to hold" - both ends are fine.
local function lineLevel(peer)
    local mine = math.max(0, math.min(4, math.floor(tonumber(power.signal) or 4)))
    local bars = peer and peerBars[peer] or nil
    local theirs = bars and math.max(0, math.min(4, math.floor(bars))) or nil

    local threshold = math.floor(tonumber(badCfg().atBars) or 1)
    if threshold <= 0 then return nil end

    -- No service at all is not a bad line, it is no line - the server ends those calls - so a
    -- zero on either side is left to it rather than turned into silence here.
    local a = (mine > 0 and mine <= threshold) and levelForBars(mine) or nil
    local b = (theirs and theirs > 0 and theirs <= threshold) and levelForBars(theirs) or nil

    if a and b then return math.min(a, b) end
    return a or b
end

--- Every voice on the call at the level its own line deserves.
---
--- Anybody mid-cut is skipped: that override is a hard zero with its own timer, and writing the
--- standing level over it would end their drop-out early.
---
--- `force` re-issues the write even when the remembered level matches, which is what the restore
--- after a cut needs - the volume on the wire is not what `peerLevel` says it is at that moment.
local function applyHolds(force)
    for _, peer in ipairs(farEnds()) do
        if not peerCuts[peer] then
            if force then peerLevel[peer] = nil end
            holdOne(peer, lineLevel(peer))
        end
    end
end

--- Hand everybody back their normal volume, without ending anything.
local function releaseHolds()
    for _, peer in ipairs(farEnds()) do holdOne(peer, nil) end
end

--- Drop the line for a moment, and put it back.
---
--- The volume override is local and instant, so a 300ms cut is a 300ms cut. Leaving the call
--- channel is the fallback for a build without the native, and a poor one: joining a pma-voice
--- channel goes through its server, which rewires every member - too slow for this, twice a second.
---
--- The far end is told through our server, so the break is mutual: a cut only one side hears is
--- one person's phone glitching, not a bad line. The restore is unconditional and on its own
--- timer, because a cut that failed to undo itself is a call nobody can hear again.
local function cutOut(ms)
    if badLine then return end
    badLine = true
    local cfg = badCfg()
    local hold = math.max(60, math.floor(ms))

    if cfg.muteVoice ~= false then
        if volumeSupported() then
            -- Everybody on the call. A break that only silenced one of three voices would not
            -- be this phone's line failing - it would be one person going quiet.
            local cut = math.max(0.0, tonumber(cfg.cutVolume) or 0.0)
            for _, peer in ipairs(farEnds()) do
                if mumbleVolume(peer, cut) then heldIds[peer] = true end
            end
            -- And our own voice, on their side. They are the only ones who can turn us down.
            TriggerServerEvent('v-phone:call:badline', hold)
        else
            leaveCallAudio()
        end
    end

    SendNUIMessage({ action = 'callGlitch', on = true,
                     flicker = cfg.flicker ~= false, static = cfg.static ~= false })

    -- **Something happens even with the phone in a pocket.** Most of a call is spent with the
    -- handset away, and a glitch drawn on a screen nobody is looking at is a glitch that did not
    -- happen. A short buzz is the part that reaches somebody mid-conversation.
    if cfg.vibrate ~= false then SetPadShake(0, 120, 40) end

    SetTimeout(hold, function()
        badLine = false
        SendNUIMessage({ action = 'callGlitch', on = false })
        if cfg.muteVoice == false then return end
        -- Only if the call is still up: restoring audio for a conversation that ended would
        -- either open a channel for nobody or hand back a volume nobody is using.
        if not (call and call.state == 'active') then return end
        if volumeSupported() then
            -- Back to the level the LINE deserves, NOT to normal: it is still a bad line, and
            -- it is bad at whichever end is worse. Reading only this phone's bars here was the
            -- third place the effect was one-sided, and the easiest to miss - it is the restore
            -- rather than the cut.
            applyHolds(true)                    -- force the write, whatever it was before
        else
            joinCallAudio()
        end
    end)
end

--- The other end's line broke up. Their client said so and our server vouched for it.
--- How many bars the OTHER phone has.
---
--- Sent by the server when the call goes live and again whenever their signal changes. It is the
--- server's own measurement, never a client's claim, so somebody in a dead zone cannot announce
--- four bars and sound perfect to everybody else.
RegisterNetEvent('v-phone:client:peerSignal', function(who, bars)
    local peer = tonumber(who)
    if not peer or not onCallWith(peer) then return end

    peerBars[peer] = math.max(0, math.min(4, math.floor(tonumber(bars) or 4)))

    -- Applied at once rather than at the next tick: a second of hearing somebody perfectly
    -- after they have walked into a tunnel is a second that reads as the effect being late.
    if badCfg().muteVoice ~= false and not peerCuts[peer] then
        peerLevel[peer] = nil
        holdOne(peer, lineLevel(peer))
    end
end)

RegisterNetEvent('v-phone:client:peerBadLine', function(from, ms)
    local peer = tonumber(from)
    if not peer or not volumeSupported() then return end
    if not onCallWith(peer) then return end

    local cfg = badCfg()
    peerCuts[peer] = true
    heldIds[peer] = true
    mumbleVolume(peer, math.max(0.0, tonumber(cfg.cutVolume) or 0.0))

    -- **No glitch drawn here.** It used to be, on the reasoning that a break should read as the
    -- line rather than as somebody going quiet - but the screen effect is this HANDSET's own
    -- signal being bad, and this handset's signal is fine. Somebody standing under a mast
    -- watching their phone flicker and hiss is being told a lie about where they are.
    --
    -- The audio break is mutual and stays mutual; the picture belongs to the end that earned it.

    SetTimeout(math.max(60, math.floor(tonumber(ms) or 250)), function()
        peerCuts[peer] = nil
        if not onCallWith(peer) then
            mumbleVolume(peer, -1.0)
            return
        end
        -- Back to what the LINE deserves once their break is over - both ends of it, not just
        -- this one. Theirs only: the other people on the call never stopped.
        peerLevel[peer] = nil
        holdOne(peer, lineLevel(peer))
    end)
end)

CreateThread(function()
    while true do
        Wait(1000)
        local cfg = badCfg()
        local threshold = math.floor(tonumber(cfg.atBars) or 1)
        if cfg.enabled ~= false and threshold > 0
            and call and call.state == 'active' and not badLine then
            local bars = math.max(0, math.min(4, math.floor(tonumber(power.signal) or 4)))

            -- The standing degradation, before any drop-out is considered. Held while either
            -- signal stays where it is and given back the moment BOTH recover, so walking out of
            -- a dead spot mid-call is audible as the line clearing up - on both handsets.
            --
            -- Skipped while their line is mid-cut: that override is a hard zero with its own
            -- timer, and writing the standing level over it would end the drop-out early.
            if cfg.muteVoice == false then
                -- Switched off mid-session. Anything still held has to be handed back, or the
                -- setting only takes effect for calls that had not started yet.
                releaseHolds()
            else
                -- Per person, and anybody mid-cut is left alone inside `applyHolds` rather than
                -- the whole call being skipped because one of them is.
                applyHolds(false)
            end

            -- No service at all is not a bad line, it is no line - the server ends those.
            if bars > 0 and bars <= threshold then
                -- Weaker is proportionally worse: at 1 bar with a threshold of 2, twice the
                -- chance of the threshold bar itself.
                local severity = (threshold - bars + 1) / threshold
                local chance = (tonumber(cfg.chancePerSecond) or 0.18) * severity
                if math.random() < chance then
                    local lo = math.floor(tonumber(cfg.minMs) or 250)
                    local hi = math.floor(tonumber(cfg.maxMs) or 900)
                    if hi < lo then hi = lo end
                    cutOut(math.random(lo, hi))
                end

                -- And a line this bad can simply fail. Checked separately, so a server can
                -- have break-up without ever dropping a call.
                local dropChance = (tonumber(cfg.dropChancePerSecond) or 0) * severity
                if dropChance > 0 and math.random() < dropChance then
                    TriggerServerEvent('v-phone:call:dropped')
                end
            end
        end
    end
end)

applyServerCall = function(nextCall, notifyUi)
    local previous = call
    if type(nextCall) ~= 'table' then
        if previous and previous.state == 'active' then releaseBadLine() leaveCallAudio() end
        call = nil
        stopRinging()
    else
        call = {
            id = tonumber(nextCall.id),
            state = tostring(nextCall.state or ''),
            number = nextCall.number,
            booth = nextCall.booth == true,
            peer = tonumber(nextCall.peer),
            -- The whole call, for one that has more than two people on it. Without this a
            -- `restart v-phone` mid-conference left the phone able to degrade one line out of
            -- three and drawing a member list it no longer had.
            peers = (function()
                local out = {}
                for _, v in ipairs(nextCall.peers or {}) do
                    local n = tonumber(v)
                    if n then out[#out + 1] = n end
                end
                if #out == 0 and tonumber(nextCall.peer) then out[1] = tonumber(nextCall.peer) end
                return out
            end)(),
            group = nextCall.group == true,
            roster = nextCall.members,
            canAdd = nextCall.canAdd == true,
        }
        if call.state == 'active'
            and (not previous or previous.id ~= call.id or previous.state ~= 'active') then
            stopRinging()
            joinCallAudio()
        elseif call.state == 'in' then
            startRinging()
        end
        -- A booth call that survived a resource restart is handed back to the box rather
        -- than drawn on the handset, which was never holding it.
        if call.booth then
            TriggerEvent('v-phone:internal:boothCall', call)
            return
        end
    end
    refreshPose()
    if notifyUi ~= false then SendNUIMessage({ action = 'call', call = call }) end
end

CreateThread(function()
    Wait(1500)
    for _ = 1, 20 do
        local synced = false
        V.Request('v-phone:callState', function(res)
            if res and res.ok then
                applyServerCall(res.call, true)
                synced = true
            end
        end)
        for _ = 1, 20 do
            if synced then return end
            Wait(100)
        end
        Wait(1500)
    end
end)

--- Somebody unsent a message that is on this phone. Told rather than discovered, so an open
--- thread loses the bubble now instead of the next time it happens to be reopened.
RegisterNetEvent('v-phone:client:msgGone', function(d)
    if type(d) ~= 'table' then return end
    SendNUIMessage({ action = 'msgGone', id = tonumber(d.id) })
end)

--- Delete one message: unsend your own, or remove somebody else's from your copy.
RegisterNUICallback('msgDelete', function(data, cb)
    V.Request('v-phone:messages:delete', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('call', function(data, cb)
    -- The failure used to be announced here as a framework notification, outside the phone,
    -- and nowhere else - so the page said nothing and made no sound. The page owns it now: it
    -- plays the reorder tone and shows the reason on the handset, which is one message for one
    -- failure rather than two in two different places.
    V.Request('v-phone:call', function(res) cb(res or { error = 'x' }) end, data)
end)

RegisterNUICallback('answer', function(_, cb)
    V.Request('v-phone:answer', function(res) cb(res or { error = 'x' }) end)
end)

RegisterNUICallback('hangup', function(_, cb)
    V.Request('v-phone:hangup', function(res) cb(res or { error = 'x' }) end)
end)

--- Put somebody else on this call. The server decides whether that is allowed.
RegisterNUICallback('callAdd', function(data, cb)
    V.Request('v-phone:callAdd', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNetEvent('v-phone:client:callOut', function(data)
    call = { id = data.id, state = 'out', number = data.number, video = data.video == true,
             -- A call placed from a payphone belongs to the box, not to the handset in this
             -- player's pocket. The flag rides on the call so every handler below, and the
             -- pose code, can tell the two apart.
             booth = data.booth == true }
    if call.booth then
        -- client/booth.lua draws it, and the phone stays where it is.
        TriggerEvent('v-phone:internal:boothCall', call)
        return
    end
    SendNUIMessage({ action = 'call', call = call })
end)

RegisterNetEvent('v-phone:client:callIn', function(data)
    call = { id = data.id, state = 'in', number = data.number, video = data.video == true,
             -- Being invited onto a call already in progress is not the same as being rung,
             -- and the screen says so: how many people are already talking is the difference
             -- between answering a person and joining a room.
             group = data.group == true, members = tonumber(data.members) or 0 }
    -- "Silence unknown callers" was decided on the server, where the contact list lives. A
    -- silenced call still connects if the player happens to be looking at their phone and
    -- answers it, and still becomes a missed call if they do not - it simply does not ring
    -- and does not open the handset by itself.
    if data.silent == true then
        SendNUIMessage({ action = 'call', call = call })
        return
    end
    startRinging()
    -- An incoming call opens the phone if it is closed: a ringing phone the player cannot
    -- see is a missed call they never had the chance to take.
    SendNUIMessage({ action = 'call', call = call })
    if not isOpen then openPhone() end
end)

-- ── FaceTime live picture ──────────────────────────────────────
-- Experimental and opt-in. While a video call is active, the front camera is put up and
-- the screen is captured a few times a second. The raw capture is far too big to relay,
-- so the PAGE shrinks and crops it to a thumbnail first (see app.js), and only that tiny
-- frame goes to the server, which relays it to the other phone.
local faceLoop = 0

local function stopFaceFeed()
    faceLoop = faceLoop + 1                    -- invalidates any running loop
    SendNUIMessage({ action = 'facePeer', data = nil })
end

local function startFaceFeed()
    local ft = Config.FaceTime or {}
    if not ft.videoFeed then return end
    if GetResourceState('screenshot-basic') ~= 'started' then return end

    faceLoop = faceLoop + 1
    local mine = faceLoop
    local fps = math.max(1, math.min(12, math.floor(tonumber(ft.fps) or 6)))
    local gap = math.floor(1000 / fps)

    CreateThread(function()
        while faceLoop == mine and call and call.state == 'active' and call.video do
            -- The capture is asynchronous; the page answers with the shrunk frame through
            -- the `faceFrame` callback below.
            pcall(function()
                exports['screenshot-basic']:requestScreenshot(
                    { encoding = 'jpg', quality = 0.5 },
                    function(data)
                        if faceLoop ~= mine then return end
                        SendNUIMessage({ action = 'faceShrink', data = data })
                    end)
            end)
            Wait(gap)
        end
    end)
end

-- The page hands back the shrunk frame; this is the only thing that reaches the network.
RegisterNUICallback('faceFrame', function(data, cb)
    if call and call.state == 'active' and call.video and type(data) == 'table' and data.frame then
        TriggerServerEvent('v-phone:server:faceFrame', data.frame)
    end
    cb('ok')
end)

-- The other side's frame, straight to the page.
RegisterNetEvent('v-phone:client:faceFrame', function(frame)
    SendNUIMessage({ action = 'facePeer', data = frame })
end)

RegisterNetEvent('v-phone:client:callActive', function(data)
    local wasBooth = call and call.booth or false
    call = { id = data.id, state = 'active', number = call and call.number or nil,
             video = call and call.video or false, booth = wasBooth,
             -- Who is on the other end, as a server id. The bad-line effect turns THEIR voice
             -- down, and every way of doing that is addressed by id.
             --
             -- `peers` is the same fact for a call with more than two people on it. The roster
             -- event that follows fills it in; the single id is kept because it is what the
             -- two-party paths above and `/phonevoice` read.
             peer = tonumber(data.peer),
             peers = { tonumber(data.peer) },
             group = data.group == true,
             members = call and call.members or nil }
    stopRinging()
    -- The audio is the same on a payphone: the same v-voice channel, joined the same way.
    -- Only the picture is different.
    joinCallAudio()
    if call.booth then
        TriggerEvent('v-phone:internal:boothCall', call)
        return
    end
    refreshPose()
    -- A video call turns the front camera on and starts the picture feed. Focus is left
    -- exactly as it was: an answered call must not steal the cursor.
    if call.video then
        TriggerEvent('v-phone:internal:selfie', true)
        startFaceFeed()
    end
    SendNUIMessage({ action = 'call', call = call })
end)

--- Who is on this call, and which server ids are ours to degrade.
---
--- It never CREATES a call: a roster for a call this phone is not on would be a stranger's
--- conversation appearing on screen, so it only ever updates the one already here.
RegisterNetEvent('v-phone:client:callRoster', function(d)
    if type(d) ~= 'table' then return end
    if not (call and call.id == tonumber(d.id)) then return end

    local peers = {}
    for _, v in ipairs(d.peers or {}) do
        local n = tonumber(v)
        if n then peers[#peers + 1] = n end
    end
    call.peers = peers
    -- Kept in step, because it is what the two-party paths and `/phonevoice` read.
    call.peer = peers[1] or call.peer
    call.group = d.group == true
    call.roster = d.members
    call.canAdd = d.canAdd == true

    -- Anybody who left gets their voice back NOW rather than at the end of the call: the call
    -- has not ended, so nothing else will ever hand it back.
    releaseGonePeers(peers)

    SendNUIMessage({ action = 'callRoster', roster = d })
end)

RegisterNetEvent('v-phone:client:callEnd', function(reason)
    -- Leave the voice channel even if the UI never got the start: an end that does not
    -- release the channel leaves the player audible to strangers across the map. And hand back
    -- any volume the bad line was holding down, before `call` is cleared and the peer id with it.
    releaseBadLine()
    leaveCallAudio()
    stopRinging()
    -- And put the front camera and the picture feed away with it.
    stopFaceFeed()
    TriggerEvent('v-phone:internal:selfie', false)
    local wasBooth = call and call.booth or false
    call = nil
    if wasBooth then
        -- The booth clears its own screen and puts the player's arm down. The phone was
        -- never involved, so it is not told about it.
        TriggerEvent('v-phone:internal:boothCallEnd', reason)
    else
        refreshPose()
        SendNUIMessage({ action = 'call', call = nil })
    end
    if reason and reason ~= 'hangup' then V.Notify(L('ph.call_' .. reason), 'info') end
end)

--- An app is downloading, and how far along it is.
---
--- Straight through to the page: the progress ring on the tile and the bar in the store are the
--- same fact, and the client has nothing to add to it. The server owns the download - it keeps
--- running with the phone in a pocket, which is why nothing here holds a timer.
RegisterNetEvent('v-phone:client:download', function(d)
    if type(d) ~= 'table' then return end
    SendNUIMessage({ action = 'download', download = d })

    -- Finished, and worth a banner: a download that started ten seconds ago is a download
    -- somebody has already stopped watching.
    if d.done and not d.failed and PhoneNotify then
        PhoneNotify({
            app = 'store', icon = 'store',
            title = (PhoneString and PhoneString(d.update and 'ph.store_updated_title'
                                                          or 'ph.store_ready_title')) or '',
            body = (PhoneString and PhoneString('ph.store_ready')) or '',
            hasItem = true,
        })
    end
end)

RegisterNUICallback('downloadCancel', function(data, cb)
    V.Request('v-phone:download:cancel', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNetEvent('v-phone:client:power', function(p)
    local wasLow = power.battery
    power = p or power
    SendNUIMessage({ action = 'power', power = power })

    -- Warn once on the way past each threshold, not every tick past it. It arrives as a
    -- real phone notification - so it buzzes, lands in the notification centre, and peeks
    -- the handset out of a pocket - rather than as a message in the corner of the screen.
    local low = tonumber(Config.Battery and Config.Battery.lowAt) or 20
    local crit = tonumber(Config.Battery and Config.Battery.criticalAt) or 5
    local function batteryWarn(key)
        local b = { app = 'settings', icon = 'settings',
                    title = L('ph.battery_title'):format(math.floor(power.battery or 0)),
                    body = L(key), hasItem = true }
        if isOpen then
            SendNUIMessage({ action = 'banner', banner = b })
            if not notificationMuted('banner', b) and not notificationSilent('banner', b) then buzz(false) end
        else
            peek('banner', b)
        end
    end
    if power.battery <= crit and wasLow > crit then
        batteryWarn('ph.battery_critical')
    elseif power.battery <= low and wasLow > low then
        batteryWarn('ph.battery_low')
    end
    if power.battery <= 0 and wasLow > 0 then
        closePhone()
        V.Notify(L('ph.battery_dead'), 'error')
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Notifications
-- ══════════════════════════════════════════════════════════════
RegisterNetEvent('v-phone:client:airdrop', function(offer)
    sendWhenOpen({ action = 'airdrop', offer = offer })
end)

RegisterNetEvent('v-phone:client:airdropResult', function(res)
    SendNUIMessage({ action = 'airdropResult', result = res })
end)

RegisterNetEvent('v-phone:client:message', function(msg)
    if isOpen then
        SendNUIMessage({ action = 'message', message = msg })
        if not notificationMuted('message', msg) then buzz(false) end
    else
        peek('message', msg)
    end
end)

RegisterNetEvent('v-phone:client:cipher', function(packet)
    if isOpen then
        SendNUIMessage({ action = 'cipher', packet = packet })
        if not notificationMuted('banner', { app = 'cipher' }) then buzz(false) end
    else
        local profile = type(packet) == 'table' and packet.from or {}
        peek('banner', {
            app = 'cipher',
            icon = 'cipher',
            title = tostring(profile.displayName or profile.handle or L('app.cipher')),
            body = L('ph.cipher_packet'),
        })
    end
end)

--- A social account changed in a way the open phone cannot have noticed: staff granted or
--- took away a verified badge. The badge is on every card that account has posted, so the
--- view has to be redrawn rather than waiting for the player to navigate.
RegisterNetEvent('v-phone:client:socialRefresh', function(app)
    if not isOpen then return end
    SendNUIMessage({ action = 'socialRefresh', app = tostring(app or '') })
end)

RegisterNetEvent('v-phone:client:banner', function(b)
    if isOpen then
        SendNUIMessage({ action = 'banner', banner = b })
        if not notificationMuted('banner', b) and not notificationSilent('banner', b) then buzz(false) end
    else
        peek('banner', b)
    end
end)

-- Nobody picked up. Offer to leave a voicemail, on the phone, where it belongs.
RegisterNetEvent('v-phone:client:voicemailOffer', function(d)
    sendWhenOpen({ action = 'voicemailOffer', number = (d and d.number) or '' })
end)

-- The persisted Focus/sound preferences are needed before the first notification, not
-- only after the player has opened the phone once. The server also pushes them on load;
-- this retry covers a resource restart while the character is already online.
RegisterNetEvent('v-phone:client:prefsSync', function(prefs)
    syncPrefsCache(prefs)
end)

CreateThread(function()
    Wait(1500)
    for _ = 1, 20 do
        local answered = false
        V.Request('v-phone:prefs', function(res)
            syncPrefsCache(res and res.prefs)
            answered = true
        end)
        for _ = 1, 20 do
            if answered or prefsCacheReady then break end
            Wait(100)
        end
        if prefsCacheReady then return end
        Wait(1500)
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Housekeeping
-- ══════════════════════════════════════════════════════════════
exports('IsOpen',    function() return isOpen end)
exports('GetNumber', function() return myNumber end)
exports('Open',      function() openPhone() end)
exports('Close',     function() closePhone() end)
exports('OnCall',    function() return call end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end

    local wasOpen = isOpen
    local hadMenu = menuClaimed
    isOpening = false
    openingAssets = false
    openRequest = openRequest + 1
    pendingUiActions = {}

    -- Release every piece of state owned outside the Lua VM before this resource vanishes.
    -- A volume override outlives this resource: it is held by the game's audio layer, so stopping
    -- v-phone mid-call without clearing it leaves somebody inaudible until they reconnect.
    releaseBadLine()
    if call then leaveCallAudio() end
    if voice() then
        for id in pairs(speakerListens) do
            pcall(function() exports['v-voice']:SpeakerListen(id, false) end)
        end
    end
    speakerListens = {}
    call = nil
    stopRinging()
    StopPadShake(0)
    phoneTorch = false
    activeSdkApp = nil
    sdkApps = {}
    isOpen = false
    menuClaimed = false

    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    clearHand()

    if wasOpen then
        TriggerServerEvent('v-phone:server:screen', false)
    end
    if hadMenu and GetResourceState('v-core') == 'started' then
        pcall(function() exports['v-core']:MenuClosed('v-phone') end)
    end
end)

-- ── Theme ──────────────────────────────────────────────────────
-- A NUI page can only be messaged by the resource that owns it, so v-ui cannot reach this
-- one directly: it publishes a version and each module forwards it into its own page.
local function pushTheme()
    if GetResourceState('v-ui') ~= 'started' then return end
    SendNUIMessage({ action = 'v-ui:theme', version = exports['v-ui']:Version() })
end

AddEventHandler('v-ui:client:themeChanged', function() pushTheme() end)
-- The flashlight: a white light at the player while the phone is out and the control
-- centre torch is on. It costs a draw call only while lit.
--- Everyone else's torch, by server id.
---
--- github.com/laforetbrut/v-phone-fivem/issues/3 - the light was only ever visible to the
--- person holding the phone. `DrawLightWithRange` is a DRAW CALL: it exists for one frame on
--- one machine, so a torch nobody relayed is a torch nobody else can see. Standing in the dark
--- next to somebody using theirs showed nothing at all.
local peerTorch = {}

--- Tell the server whether this phone is currently lighting anything.
---
--- The effective state, not the switch: the light is drawn while the torch is ON and the phone
--- is OUT, so putting the handset away has to turn it off for everybody else too. Sent only when
--- it CHANGES - this is called from a watcher, and a phone out in the dark would otherwise be an
--- event every frame.
local torchSent = nil
local function pushTorch()
    local lit = (phoneTorch and isOpen) and true or false
    if lit == torchSent then return end
    torchSent = lit
    TriggerServerEvent('v-phone:torch', lit)
end

--- Somebody near us switched theirs on or off.
RegisterNetEvent('v-phone:client:peerTorch', function(who, on)
    who = tonumber(who)
    if not who then return end
    peerTorch[who] = on and true or nil
end)

--- Draw one torch at one ped.
local function drawTorch(ped)
    if not ped or ped == 0 then return end
    local c = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    DrawLightWithRange(c.x + fwd.x, c.y + fwd.y, c.z + 0.2, 255, 255, 240, 6.0, 3.0)
end

CreateThread(function()
    while true do
        -- The watcher: one place that notices the torch or the phone changing, rather than a
        -- call to remember at each of the six places that set either.
        pushTorch()

        local mine = phoneTorch and isOpen
        local anyone = next(peerTorch) ~= nil
        if mine or anyone then
            if mine then drawTorch(PlayerPedId()) end
            for id in pairs(peerTorch) do
                local other = GetPlayerFromServerId(id)
                local ped = other ~= -1 and GetPlayerPed(other) or 0
                -- Out of scope or gone: forget them rather than looking every frame for
                -- somebody on the far side of the map.
                if ped and ped ~= 0 and DoesEntityExist(ped) then drawTorch(ped)
                else peerTorch[id] = nil end
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)

CreateThread(function() Wait(4000); pushTheme() end)
