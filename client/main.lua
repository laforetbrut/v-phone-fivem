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

local function strings()
    return Locales[(LocalPlayer.state and LocalPlayer.state.lang) or 'fr'] or Locales.fr or {}
end
local function L(k) return strings()[k] or k end

local function voice() return GetResourceState('v-voice') == 'started' end

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
    prefsCache.ringVolume = tonumber(pf.ringVolume) or 0.7
    prefsCache.ringtone = pf.ringtone or 'default'
    prefsCache.notifMuted = {}
    for _, app in ipairs(type(pf.notifMuted) == 'table' and pf.notifMuted or {}) do
        prefsCache.notifMuted[tostring(app)] = true
    end
    prefsCacheReady = true
    if prefsCache.dnd then
        stopRingSound()
        StopPadShake(0)
    end
end

local function notificationMuted(kind, data)
    local app = kind == 'message' and 'messages' or 'dot'
    if kind ~= 'message' and type(data) == 'table' then
        app = tostring(data.app or data.icon or app)
    end
    return prefsCache.notifMuted[app] == true
end

-- The peek: the phone is in a pocket, so the top of it rises into view with the
-- notification on it and slides back down. It never takes focus - you are being shown
-- something, not asked to do anything.
local function peek(kind, data)
    if isOpen or notificationMuted(kind, data) then return end
    if data and data.hasItem == false then return end   -- no phone on them, nothing to peek
    SendNUIMessage({ action = 'archive', kind = kind, data = data or {}, strings = strings() })
    if prefsCache.dnd then return end
    SendNUIMessage({ action = 'peek', kind = kind, data = data or {}, strings = strings() })
    buzz(false)
end

-- ══════════════════════════════════════════════════════════════
-- In hand: a prop and an animation, while you keep walking and driving
-- ══════════════════════════════════════════════════════════════
-- The phone is a real object in the world now. Opening it puts the prop in the right hand
-- and plays a one-handed animation; a call raises it to the ear. The NUI takes cursor
-- focus but keeps game input flowing, and a guard thread disables only aiming, shooting
-- and camera-look - so a tap on the screen does not fire a gun, but movement survives.
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
local function refreshPose()
    if not isOpen then return end
    playHold((call and call.state == 'active') and Config.Hold.call or Config.Hold.browse)
end

-- The control guard: everything in Config.Hold.block is disabled each frame while the
-- phone is up. It also keeps the animation alive if something interrupts it.
local function startGuard()
    CreateThread(function()
        while isOpen do
            for _, c in ipairs(Config.Hold.block) do DisableControlAction(0, c, true) end
            local ped = PlayerPedId()
            if phoneAnim and not IsEntityPlayingAnim(ped, Config.Hold.dict, phoneAnim, 3) then
                phoneAnim = nil
                refreshPose()
            end
            Wait(0)
        end
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
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    clearHand()
    if menuClaimed then
        menuClaimed = false
        exports['v-core']:MenuClosed('v-phone')
    end
    TriggerServerEvent('v-phone:server:screen', false)
    SendNUIMessage({ action = 'close' })
end

RegisterCommand('vphone', function() if isOpen then closePhone() else openPhone() end end, false)
RegisterKeyMapping('vphone', 'Open the phone', 'keyboard', Config.Key or 'F1')

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
local APP_SOURCE = {
    bank   = { res = 'v-banking',  callback = 'v-banking:getData' },
    garage = { res = 'v-vehicles', callback = 'v-vehicles:myVehicles' },
    wallet = { res = 'v-licenses', callback = 'v-licenses:mine' },
    jobs     = { res = 'v-cityhall', callback = 'v-phone:jobs' },
    music    = { res = 'v-music',    callback = 'v-music:list' },
    property = { res = 'v-housing',  callback = 'v-housing:mine' },
}

RegisterNUICallback('app', function(data, cb)
    local id  = data and tostring(data.app or '')
    local src = APP_SOURCE[id]
    if not src then cb({ error = 'unknown' }) return end
    if GetResourceState(src.res) ~= 'started' then cb({ error = 'off' }) return end
    V.Request(src.callback, function(res) cb(res or { error = 'x' }) end)
end)

-- ══════════════════════════════════════════════════════════════
-- Messages, contacts, preferences
-- ══════════════════════════════════════════════════════════════
local function relay(callback)
    return function(data, cb)
        V.Request(callback, function(res) cb(res or { error = 'x' }) end, data)
    end
end

RegisterNUICallback('conversation',  relay('v-phone:conversation'))
RegisterNUICallback('send',          relay('v-phone:send'))
RegisterNUICallback('contactSave',   relay('v-phone:contactSave'))
RegisterNUICallback('contactDelete', relay('v-phone:contactDelete'))
RegisterNUICallback('groupCreate',   relay('v-phone:groupCreate'))
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
RegisterNUICallback('voicemail',     relay('v-phone:voicemail'))
RegisterNUICallback('mail',          relay('v-phone:mail'))
RegisterNUICallback('notes',         relay('v-phone:notes'))
RegisterNUICallback('cipher',        relay('v-phone:cipher'))
RegisterNUICallback('speaker',       relay('v-phone:speaker'))

--- Somebody near you put their phone on speaker, so you hear their call. Listening only:
--- the export never lets you transmit into a conversation you are not part of.
RegisterNetEvent('v-phone:client:speaker', function(d)
    local id = tonumber(d and d.id)
    if not id then return end
    local on = d and d.on == true
    if on then
        speakerListens[id] = true
    else
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

RegisterNUICallback('places', relay('v-phone:places'))
RegisterNUICallback('install', relay('v-phone:install'))

--- The card belongs to v-banking, which mints it and owns the number. The wallet app
--- only displays it, so this reads and never writes.
RegisterNUICallback('card', function(_, cb)
    if GetResourceState('v-banking') ~= 'started' then cb({ error = 'off' }) return end
    V.Request('v-banking:card', function(res) cb(res or { error = 'x' }) end)
end)

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

RegisterNUICallback('music', function(data, cb)
    if GetResourceState('v-music') ~= 'started' then cb({ error = 'off' }) return end
    -- Starting a track and controlling one already playing are two different calls.
    local cbName = (data and data.action == 'play') and 'v-music:play' or 'v-music:control'
    V.Request(cbName, function(res) cb(res or { error = 'x' }) end, data)
end)

RegisterNUICallback('payRent', function(data, cb)
    if GetResourceState('v-housing') ~= 'started' then cb({ error = 'off' }) return end
    V.Request('v-housing:payRent', function(res) cb(res or { error = 'x' }) end, data)
end)

--- The MDT reads v-police directly. `isCop` is re-checked there on every call, so the
--- app gate in the registry only decides whether the icon is drawn.
RegisterNUICallback('mdt', function(data, cb)
    if GetResourceState('v-police') ~= 'started' then cb({ error = 'off' }) return end
    local op = tostring((data and data.op) or '')
    if op == 'lookup' then
        V.Request('v-police:lookup', function(res) cb(res or { error = 'x' }) end,
            { query = data.query })
    elseif op == 'warrants' then
        V.Request('v-police:warrants', function(res) cb(res or { error = 'x' }) end)
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
    if GetResourceState('v-status') ~= 'started' then cb({ error = 'off' }) return end
    local st = exports['v-status']:Get() or {}
    cb({
        ok = true,
        hunger = st.hunger, thirst = st.thirst, stress = st.stress,
        bleed = st.bleed, sick = st.sick,
        armour = GetPedArmour(PlayerPedId()),
        health = GetEntityHealth(PlayerPedId()) - 100,   -- GTA floors a living ped at 100
    })
end)

RegisterNUICallback('photos', relay('v-phone:photo'))

--- The social apps. One relay with a whitelist, because the page names an operation and
--- the client decides which callbacks that can ever mean - the same shape as the SDK.
local SOCIAL_OPS = {
    me = true, setup = true, feed = true, post = true, like = true,
    hushMe = true, hushSetup = true, hushNext = true, hushChoice = true, hushMatches = true,
    -- The account system: SMS verification, sign-up, login, logout.
    requestCode = true, verifyCode = true, register = true, login = true, logout = true,
    -- People: a profile, the directory, following.
    profile = true, search = true, follow = true,
    -- What a post can carry beyond a like.
    comments = true, comment = true, uncomment = true, repost = true, delete = true,
    -- Stories, and the direct messages between two handles.
    stories = true, story = true, storySeen = true,
    dmList = true, dmThread = true, dmSend = true,
}

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
RegisterNUICallback('shoot', function(_, cb)
    local finished = false
    local focusReleased = false
    local captureRequest = openRequest

    -- screenshot-basic and the upload endpoint are both asynchronous. Whichever path
    -- finishes first owns the reply; late callbacks become harmless no-ops.
    local function finish(result)
        if finished then return end
        finished = true
        result = type(result) == 'table' and result or { error = 'x' }

        if focusReleased and isOpen and openRequest == captureRequest then
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

applyServerCall = function(nextCall, notifyUi)
    local previous = call
    if type(nextCall) ~= 'table' then
        if previous and previous.state == 'active' then leaveCallAudio() end
        call = nil
        stopRinging()
    else
        call = {
            id = tonumber(nextCall.id),
            state = tostring(nextCall.state or ''),
            number = nextCall.number,
        }
        if call.state == 'active'
            and (not previous or previous.id ~= call.id or previous.state ~= 'active') then
            stopRinging()
            joinCallAudio()
        elseif call.state == 'in' then
            startRinging()
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

RegisterNUICallback('call', function(data, cb)
    V.Request('v-phone:call', function(res)
        if not res or res.error then
            V.Notify(L('ph.err_' .. ((res and res.error) or 'x')), 'error')
        end
        cb(res or { error = 'x' })
    end, data)
end)

RegisterNUICallback('answer', function(_, cb)
    V.Request('v-phone:answer', function(res) cb(res or { error = 'x' }) end)
end)

RegisterNUICallback('hangup', function(_, cb)
    V.Request('v-phone:hangup', function(res) cb(res or { error = 'x' }) end)
end)

RegisterNetEvent('v-phone:client:callOut', function(data)
    call = { id = data.id, state = 'out', number = data.number }
    SendNUIMessage({ action = 'call', call = call })
end)

RegisterNetEvent('v-phone:client:callIn', function(data)
    call = { id = data.id, state = 'in', number = data.number }
    startRinging()
    -- An incoming call opens the phone if it is closed: a ringing phone the player cannot
    -- see is a missed call they never had the chance to take.
    SendNUIMessage({ action = 'call', call = call })
    if not isOpen then openPhone() end
end)

RegisterNetEvent('v-phone:client:callActive', function(data)
    call = { id = data.id, state = 'active', number = call and call.number or nil }
    stopRinging()
    joinCallAudio()
    refreshPose()
    SendNUIMessage({ action = 'call', call = call })
end)

RegisterNetEvent('v-phone:client:callEnd', function(reason)
    -- Leave the voice channel even if the UI never got the start: an end that does not
    -- release the channel leaves the player audible to strangers across the map.
    leaveCallAudio()
    stopRinging()
    call = nil
    refreshPose()
    SendNUIMessage({ action = 'call', call = nil })
    if reason and reason ~= 'hangup' then V.Notify(L('ph.call_' .. reason), 'info') end
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
            if not notificationMuted('banner', b) then buzz(false) end
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

RegisterNetEvent('v-phone:client:banner', function(b)
    if isOpen then
        SendNUIMessage({ action = 'banner', banner = b })
        if not notificationMuted('banner', b) then buzz(false) end
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
CreateThread(function()
    while true do
        if phoneTorch and isOpen then
            local ped = PlayerPedId()
            local c = GetEntityCoords(ped)
            local fwd = GetEntityForwardVector(ped)
            DrawLightWithRange(c.x + fwd.x, c.y + fwd.y, c.z + 0.2, 255, 255, 240, 6.0, 3.0)
            Wait(0)
        else
            Wait(300)
        end
    end
end)

CreateThread(function() Wait(4000); pushTheme() end)
