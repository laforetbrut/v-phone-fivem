-- v-phone | server/doctor.lua
--
-- **The half of `/phonedebug doctor` that only the server can answer.**
--
-- Two questions, and both are worth asking at RUNTIME rather than by reading a file:
--
--   * **which callbacks are really registered.** A server file that failed to parse still
--     contains the text `V.Callback('x')`, so a file scan would report it as present while the
--     phone hangs on it. `V.Registered` knows what actually loaded.
--   * **what the app registry charges.** This is the exact shape of the bug that shipped:
--     `Config.Apps` said $250, `registerApp` dropped the field on the way in, and every step
--     afterwards behaved perfectly correctly for a free app. The config and the registry are two
--     different things and the whole point is to compare them.
--
-- Deliberately read-only and free of side effects: a diagnostic that changes something is a
-- diagnostic nobody dares run on a live server.

local ADMIN = Config.Admin or {}

--- Who may run it.
---
--- The same ace as every other staff route. It answers no personal data - a list of callback
--- names and a list of prices from a config file everybody's server owner can read - but it also
--- describes the shape of the resource, and there is no reason for that to be public.
local function allowed(src)
    local ace = tostring(ADMIN.ace or 'vphone.admin')
    return IsPlayerAceAllowed(src, ace) or IsPlayerAceAllowed(src, 'qbadmin.menu')
end

V.Callback('v-phone:doctor', function(src, resolve, data)
    if not allowed(src) then resolve({ error = 'denied' }) return end

    -- Which of the names the client asked about are live. Answered as a set of the ones that
    -- ARE registered rather than the ones that are not: the client has the full list already,
    -- and sending back what is present makes a missing answer read as "not registered" rather
    -- than as "the doctor did not check".
    local registered = {}
    if type(data) == 'table' and type(data.names) == 'table' then
        for _, name in ipairs(data.names) do
            name = tostring(name)
            if V.Registered and V.Registered(name) then registered[name] = true end
        end
    end

    -- What the registry believes each app costs. Taken from the same export the store reads, so
    -- a price that is right here and wrong in the store would mean the store is at fault - and
    -- one that is wrong here is the registry dropping it, which is what happened.
    local prices = {}
    local ok, apps = pcall(function() return exports['v-phone']:GetApps(src) end)
    if ok and type(apps) == 'table' then
        for _, a in ipairs(apps) do
            if a.id then prices[tostring(a.id)] = math.floor(tonumber(a.price) or 0) end
        end
    end

    resolve({ ok = true, registered = registered, prices = prices })
end)
