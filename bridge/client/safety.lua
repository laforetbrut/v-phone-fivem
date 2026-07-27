-- v-phone | bridge/client/safety.lua
--
-- **The nets under the phone.**
--
-- Players report being "stuck in the phone": no cursor, no way out, reconnect. Every report is
-- some version of one of three things, and this file answers all three in one place rather
-- than asking every future feature to remember.
--
--   1. A NUI callback that throws never answers, so the page waits for ever. The spinner in
--      the middle of an app is a promise that was never settled.
--   2. Focus is held with nothing on screen that wants it.
--   3. Something happened to the player - they died, they respawned - and the phone did not
--      notice.
--
-- Loaded FIRST among the client scripts, because the wrapper below has to be in place before
-- anything registers a callback through it.

-- ══════════════════════════════════════════════════════════════
-- 1. A callback always answers
-- ══════════════════════════════════════════════════════════════
-- `RegisterNUICallback(name, fn)` hands the page a `cb`. If `fn` raises before calling it, the
-- page's `fetch` never settles - and a `fetch` that never settles is an `await` that never
-- returns, which is a loading screen with no end. Nothing in FiveM notices: the error is
-- printed and the request is simply abandoned.
--
-- So every handler is wrapped once, here. A raise answers `{ error = 'x' }`, which every
-- caller in the page already knows how to draw, and the reason is printed with the callback's
-- name so a report arrives with its own diagnosis.
--
-- Handlers that answer LATER - most of them, through `V.Request` - are unaffected: `answer` is
-- just held until they call it, and it only ever fires once whichever path gets there first.
local realRegisterNUICallback = RegisterNUICallback

function RegisterNUICallback(name, handler)
    realRegisterNUICallback(name, function(data, cb)
        local answered = false
        local function answer(result)
            if answered then return end
            answered = true
            -- The page is waiting on this. A raise HERE would be the same bug one layer down.
            pcall(cb, result)
        end

        local ok, err = pcall(handler, data, answer)
        if not ok then
            print(('[v-phone] NUI callback %s raised: %s'):format(tostring(name), tostring(err)))
            answer({ error = 'x' })
        end
    end)
end

-- ══════════════════════════════════════════════════════════════
-- 2. Focus is never held by nothing
-- ══════════════════════════════════════════════════════════════
-- Each surface says whether it wants the cursor. The phone, the payphone panel and the
-- forensics terminal each answer for themselves; a surface that has not loaded yet answers
-- no, which is the safe direction.

--- **Does THIS resource hold the cursor?**
---
--- `IsNuiFocused()` answers for the whole game, not for us. Every other resource's menu, shop
--- and inventory sets it, and the first version of this watchdog read it - so opening anybody
--- else's UI looked exactly like a stuck phone. It fired every two seconds, printed a line,
--- and ran a full phone reset that clears the ped's secondary task, which is somebody else's
--- animation. A guard that misfires into other resources is worse than the bug it guards.
---
--- `SetNuiFocus` is per-resource, so wrapping our own calls is the whole answer: what we set
--- is what we own. Wrapped here for the same reason as `RegisterNUICallback` - this file loads
--- first, so every call in the resource goes through it.
local weHoldFocus = false
local realSetNuiFocus = SetNuiFocus

function SetNuiFocus(on, cursor)
    weHoldFocus = (on == true)
    return realSetNuiFocus(on, cursor)
end

--- For anything that needs to know. Read by the respawn guard below.
function PhoneOwnsFocus() return weHoldFocus end

local function wants()
    local ok, v = pcall(function()
        return (PhoneFocusWanted and PhoneFocusWanted())
            or (BoothFocusWanted and BoothFocusWanted())
            or (ForensicFocusWanted and ForensicFocusWanted())
    end)
    return ok and v == true
end

local function watchdogOn()
    local cfg = Config.Watchdog or {}
    return cfg.enabled ~= false
end

CreateThread(function()
    local strikes = 0
    while true do
        Wait(1000)
        if watchdogOn() then
            -- Only focus WE took. Another resource's menu is not this phone's business, and
            -- treating it as one is how this printed ten lines a minute into somebody's F8.
            if weHoldFocus and not wants() then
                -- Two seconds, not one. Opening and closing both pass through a frame where
                -- focus is set and the flag is not, and a watchdog that fired on that would
                -- close the phone as it opened.
                strikes = strikes + 1
                if strikes >= 2 then
                    strikes = 0
                    print('[v-phone] watchdog: the cursor was held with nothing open. Released.')
                    SetNuiFocus(false, false)
                    SetNuiFocusKeepInput(false)
                    if PhoneForceReset then pcall(PhoneForceReset) end
                end
            else
                strikes = 0
            end
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- 3. What happens to the player happens to the phone
-- ══════════════════════════════════════════════════════════════
-- Dying with the phone open used to leave it open: the handset on screen, the cursor caught,
-- and a death screen behind it that cannot be clicked through. Respawning is the same story
-- from the other end - the ped is replaced and the pose and prop belong to the old one.

CreateThread(function()
    local wasDead = false
    while true do
        Wait(500)
        local cfg = Config.Watchdog or {}
        if cfg.closeOnDeath ~= false then
            local ped = PlayerPedId()
            local dead = ped ~= 0 and IsEntityDead(ped)
            if dead and not wasDead then
                if PhoneForceReset and PhoneFocusWanted and PhoneFocusWanted() then
                    pcall(PhoneForceReset)
                end
            end
            wasDead = dead
        end
    end
end)

--- A respawn replaces the ped. Anything attached to the old one is gone, and anything the
--- phone thought it was doing to it is now about a ped that does not exist.
---
--- **Only when there is something to reset.** `playerSpawned` fires several times during
--- character selection and loading, and a reset that runs then tears down nothing, tells the
--- server the screen closed, and - until this guard - printed a line each time. A phone
--- talking to somebody who has not chosen a character yet is pure noise.
AddEventHandler('playerSpawned', function()
    if not PhoneForceReset then return end
    local busy = (PhoneFocusWanted and PhoneFocusWanted()) or weHoldFocus
    if busy then pcall(PhoneForceReset) end
end)

-- baseevents, when a server runs it. Its death event fires earlier than the poll above.
AddEventHandler('baseevents:onPlayerDied', function()
    local cfg = Config.Watchdog or {}
    if cfg.closeOnDeath == false then return end
    if PhoneForceReset then pcall(PhoneForceReset) end
end)
AddEventHandler('baseevents:onPlayerKilled', function()
    local cfg = Config.Watchdog or {}
    if cfg.closeOnDeath == false then return end
    if PhoneForceReset then pcall(PhoneForceReset) end
end)
