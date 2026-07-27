-- v-phone | bridge/shared/v.lua
--
-- **The `V` library, without v-core.**
--
-- Upstream, this phone is a module of the v-core framework and calls a shared library
-- called `V` for settings, callbacks, notifications and service lookup. This release runs
-- on qb-core, ox_core, ESX or nothing at all, so that library is reimplemented here on
-- plain FiveM primitives.
--
-- The API is deliberately IDENTICAL. Every call site in the phone is untouched, which is
-- what lets this build track upstream instead of drifting away from it.
--
--     V.Ready(fn)                     run once the framework is up
--     V.Callback(name, fn)            server: answer a client request
--     V.Request(name, cb, data)       client: ask the server
--     V.Setting(key, default)         a value from Config, or a convar override
--     V.SettingBool / V.SettingNumber typed readers
--     V.Notify(target, message, kind) the framework's own notification
--     V.Use(resource)                 an export proxy, or a bridge provider
--     V.Provide / V.Service           service names, kept as a no-op registry
--     V.Log / V.Module / V.Hook       kept so upstream code compiles unchanged

V = V or {}
V.name = GetCurrentResourceName()

local isServer = IsDuplicityVersion()

-- ══════════════════════════════════════════════════════════════
-- Readiness
-- ══════════════════════════════════════════════════════════════
-- Upstream waits for v-core. Here there is nothing to wait for on the client, and on the
-- server only the framework detection, which is instant once its resource has started.
local readyQueue, isReady = {}, false

function V.MarkReady()
    if isReady then return end
    isReady = true
    for _, fn in ipairs(readyQueue) do pcall(fn) end
    readyQueue = {}
end

function V.Ready(fn)
    if type(fn) ~= 'function' then return end
    if isReady then pcall(fn) return end
    readyQueue[#readyQueue + 1] = fn
end

-- ══════════════════════════════════════════════════════════════
-- Settings
-- ══════════════════════════════════════════════════════════════
-- Upstream reads these from v-core's admin panel, which stores them in a database and
-- lets a staff member change them in game. There is no admin panel here, so a setting is
-- **the config file, with a convar able to override it** - which is how a server operator
-- expects to configure a standalone resource, and which still allows a live change with
-- `set phone_battery false` in the console.
--
-- The key is the same key upstream uses; the convar is that key prefixed, so
-- `V.Setting('battery')` reads `phone_battery`.
local SETTING_PREFIX = 'phone_'

--- Where a key that is not in `Config.Settings` falls back to. Kept as a function so a
--- server can point the whole system at its own store by replacing one thing.
local function configSetting(key, default)
    local settings = (Config and Config.Settings) or {}
    local value = settings[key]
    if value ~= nil then return value end
    return default
end

function V.Setting(key, default)
    local raw = GetConvar(SETTING_PREFIX .. key, '__unset__')
    if raw ~= '__unset__' and raw ~= '' then
        if raw == 'true' then return true end
        if raw == 'false' then return false end
        return tonumber(raw) or raw
    end
    return configSetting(key, default)
end

function V.SettingNumber(key, default)
    return tonumber(V.Setting(key, default)) or default
end

function V.SettingBool(key, default)
    local value = V.Setting(key, default)
    if type(value) == 'boolean' then return value end
    if value == 'true' or value == 1 or value == '1' then return true end
    if value == 'false' or value == 0 or value == '0' then return false end
    return default and true or false
end

--- Upstream notifies modules when an admin changes a setting. Nothing changes settings
--- here at runtime except a convar, so this is a no-op that keeps call sites valid.
function V.OnSetting(_) end

--- Upstream registers the module with the admin panel. Here it only records the label,
--- so `/phone:info` and the docs have something truthful to print.
function V.Module(info)
    V.moduleInfo = info
end

-- ══════════════════════════════════════════════════════════════
-- Callbacks
-- ══════════════════════════════════════════════════════════════
-- A request/response pair over net events, with the ticket kept on the caller's side.
-- The server never trusts the ticket for anything but routing the answer back.
local CB_REQUEST = 'v-phone:bridge:request'
local CB_ANSWER = 'v-phone:bridge:answer'

if isServer then
    local handlers = {}

    function V.Callback(name, fn)
        handlers[name] = fn
    end

    --- Is this callback registered? Used by /phonediag to tell "the server file did not
    --- load" apart from "the handler ran and failed", which look identical from the phone.
    function V.Registered(name) return handlers[tostring(name)] ~= nil end

    RegisterNetEvent(CB_REQUEST, function(ticket, name, data)
        local src = source
        local fn = handlers[name]
        if not fn then
            -- Named, not nil. A nil answer used to become the app's generic "something went
            -- wrong", which is the same four words for a callback that does not exist, a
            -- query that threw, and a server that never replied. Three different problems
            -- and one useless message: it cost two rounds of guessing to tell them apart,
            -- because the real reason was only ever printed on the SERVER console while the
            -- console anybody actually reads is F8.
            print(('[v-phone] no callback registered for %s - is its server file loading?')
                :format(tostring(name)))
            TriggerClientEvent(CB_ANSWER, src, ticket, { error = 'nohandler', name = name })
            return
        end
        -- One answer per ticket, whatever the handler does. A handler that resolves twice
        -- would otherwise leave the client's callback table holding a stale entry.
        local answered = false
        local ok, err = pcall(fn, src, function(result)
            if answered then return end
            answered = true
            TriggerClientEvent(CB_ANSWER, src, ticket, result)
        end, data)
        if not ok then
            print(('[v-phone] callback %s failed: %s'):format(name, err))
            -- The detail travels to the client so it reaches F8 as well. It is a Lua error
            -- message about this resource's own code, not anything about the player or the
            -- server's configuration, so there is nothing here worth withholding.
            if not answered then
                TriggerClientEvent(CB_ANSWER, src, ticket,
                    { error = 'server', name = name, detail = tostring(err) })
            end
        end
    end)
else
    local pending, ticketSeq = {}, 0

    --- Whatever came back, plus a line in F8 when it came back broken.
    ---
    --- Every app turns a failed request into one short sentence on screen, which is right for
    --- a player and useless for anybody fixing it. The reason is printed here instead, once,
    --- in the console people actually paste - so a report arrives with its own diagnosis.
    local function report(name, result)
        if type(result) ~= 'table' then return end
        if result.error == 'nohandler' then
            print(('[v-phone] %s: no server callback registered. The server file that should '
                .. 'register it is not loading - check the server console at startup.')
                :format(tostring(name)))
        elseif result.error == 'server' then
            print(('[v-phone] %s failed on the server: %s')
                :format(tostring(name), tostring(result.detail or '?')))
        end
    end

    function V.Request(name, cb, data)
        ticketSeq = ticketSeq + 1
        local ticket = ticketSeq
        pending[ticket] = function(result)
            report(name, result)
            cb(result)
        end
        TriggerServerEvent(CB_REQUEST, ticket, name, data)
        -- A server that never answers must not leak a callback for the session. Ten
        -- seconds is far past any query this phone makes.
        SetTimeout(10000, function()
            local waiting = pending[ticket]
            if not waiting then return end
            pending[ticket] = nil
            -- The third silent failure, named like the other two: no answer at all. A handler
            -- that returns without ever calling `resolve` ends up here, and used to be
            -- indistinguishable from one that threw.
            print(('[v-phone] %s: no answer from the server after 10s - a handler that '
                .. 'returned without resolving, or the server event never arrived.')
                :format(tostring(name)))
            pcall(waiting, { error = 'timeout', name = name })
        end)
    end

    RegisterNetEvent(CB_ANSWER, function(ticket, result)
        local cb = pending[ticket]
        if not cb then return end
        pending[ticket] = nil
        pcall(cb, result)
    end)
end

-- ══════════════════════════════════════════════════════════════
-- Services and resources
-- ══════════════════════════════════════════════════════════════
-- Upstream resolves a SERVICE name (`phone`, `social`) to whichever resource provides it.
-- Here the phone provides both and nothing else is looked up, so the registry is a table.
local services = {}

function V.Provide(service)
    services[service] = V.name
    return true
end

function V.HasService(service) return services[service] ~= nil end

--- An export proxy: `V.Use('some-resource').Fn(a, b)` calls `exports['some-resource']:Fn(a, b)`.
--- The bridge registers PROVIDERS under the names the phone expects, so a call written
--- for `v-banking` reaches whatever this server actually runs.
local providers = {}

--- Providers MERGE rather than replace. Two files legitimately fill parts of the same
--- name - the compatibility stubs know how to register a usable item, the integrations
--- know how to read an inventory - and whichever loaded second must not erase the other.
function V.RegisterProvider(name, tbl)
    providers[name] = providers[name] or {}
    for key, value in pairs(tbl or {}) do providers[name][key] = value end
end
function V.GetProvider(name) return providers[name] end

local missing = setmetatable({}, {
    __index = function() return function() return nil end end,
})

function V.Use(resource)
    if providers[resource] then return providers[resource] end
    if GetResourceState(resource) ~= 'started' then return missing end
    return setmetatable({}, {
        __index = function(_, key)
            return function(...) return exports[resource][key](exports[resource], ...) end
        end,
    })
end

function V.Service(service)
    local resource = services[service]
    return resource and V.Use(resource) or missing
end

function V.Has(resource)
    return providers[resource] ~= nil or GetResourceState(resource) == 'started'
end

function V.Require(resource)
    return V.Has(resource)
end

function V.Version(resource)
    return GetResourceMetadata(resource, 'version', 0)
end

-- ══════════════════════════════════════════════════════════════
-- The rest of the surface
-- ══════════════════════════════════════════════════════════════
--- The framework's own notification, or the one the server chose. Server side it goes
--- through the bridge, which knows which framework is running; client side it is the
--- same decision made locally.
function V.Notify(target, message, kind)
    if isServer then
        if Bridge and Bridge.Notify then Bridge.Notify(target, message, kind) end
        return
    end
    -- On the client the first argument is the message: there is only one target.
    message, kind = target, message
    if GetResourceState('ox_lib') == 'started' then
        exports.ox_lib:notify({ title = 'iFruit', description = message, type = kind or 'inform' })
    elseif GetResourceState('qb-core') == 'started' or GetResourceState('qbx_core') == 'started' then
        TriggerEvent('QBCore:Notify', message, kind == 'error' and 'error' or 'primary')
    elseif GetResourceState('es_extended') == 'started' then
        TriggerEvent('esx:showNotification', message)
    else
        TriggerEvent('chat:addMessage', { args = { 'iFruit', message } })
    end
end

function V.Player(src)
    if isServer then return Core and Core.GetPlayer(src) or nil end
    return nil
end

function V.Log(...)
    print(('[%s]'):format(V.name), ...)
end

--- Boot chatter: what was detected, what is on, what a module decided.
---
--- Silent by default. The resource used to print about twenty lines at every start - the
--- framework, each app group, the bank, the payphones, the admin command, every app folder -
--- which is exactly the kind of output an operator learns to scroll past, and then misses the
--- one line that mattered. A problem still prints unconditionally through `print`; this is
--- only for the things that are merely true.
---
--- Turned on by `Config.Log.boot = true`, or without touching the config by
--- `set phone_verbose true` in server.cfg, which also works on a live server via `sets`.
function V.Info(...)
    local cfg = rawget(_G, 'Config')
    local on = cfg and cfg.Log and cfg.Log.boot
    if not on and GetConvar('phone_verbose', '') ~= 'true' then return end
    print(('[%s]'):format(V.name), ...)
end

function V.On(event, fn) AddEventHandler(event, fn) end
function V.OnNet(event, fn) RegisterNetEvent(event, fn) end
function V.Emit(event, ...) TriggerEvent(event, ...) end

--- Upstream's hook system. Nothing in the phone runs hooks on this build, but the
--- functions exist so a server that added its own does not crash on load.
local hooks = {}
function V.Hook(hook, fn, priority)
    hooks[hook] = hooks[hook] or {}
    table.insert(hooks[hook], { fn = fn, priority = priority or 50 })
    table.sort(hooks[hook], function(a, b) return a.priority < b.priority end)
end

function V.RunHook(hook, payload)
    for _, entry in ipairs(hooks[hook] or {}) do
        local ok, result = pcall(entry.fn, payload)
        if ok and result ~= nil then payload = result end
    end
    return payload
end

function V.Enabled(_) return true end
function V.SetEnabled(_, _) end
function V.Registry() return { module = V.moduleInfo, services = services } end

function V.Interval(ms, fn)
    CreateThread(function()
        while true do
            Wait(ms)
            fn()
        end
    end)
end

function V.Timeout(ms, fn) SetTimeout(ms, fn) end

function V.State(key, value, replicated)
    if value == nil then return GlobalState[key] end
    GlobalState:set(key, value, replicated ~= false)
end

function V.Command(name, opts, fn)
    RegisterCommand(name, fn, (opts and opts.restricted) or false)
end

-- ══════════════════════════════════════════════════════════════
-- Three commands, and everything under one of them
-- ══════════════════════════════════════════════════════════════
-- `phone` for players, `phonedebug` for diagnostics, `phoneadmin` for staff. A player who learns
-- one word can find the rest by typing it, and a server owner reading their console can tell at a
-- glance which of the three a line came from.
--
-- The registry lives here because the subcommands do not: `phone refresh` is in client/main.lua
-- and `phonedebug charge` is in bridge/client/charging.lua, each next to the code it reports on.
-- Registering the group command in both places would mean the second one silently replacing the
-- first, which is how half a command set disappears.

local Groups = {}       -- [group] = { order = { name, ... }, subs = { [name] = { help, fn } } }

local function runGroup(group, src, args)
    local g = Groups[group]
    if not g then return end
    local want = tostring(args and args[1] or ''):lower()

    local function say(text)
        if IsDuplicityVersion() then
            print('[v-phone] ' .. text)
        else
            print('[v-phone] ' .. text)
        end
    end

    if want == '' or want == 'help' then
        -- No subcommand is not an error. `phone` on its own is the phone, which is what somebody
        -- typing it wants; every other group lists what it can do.
        if g.bare then g.bare(src, args) return end
        say(group .. ': ' .. table.concat(g.order, ' | '))
        for _, name in ipairs(g.order) do
            say(('  %-10s %s'):format(name, g.subs[name].help or ''))
        end
        return
    end

    local sub = g.subs[want]
    if not sub then
        say(('%s: no such subcommand "%s". Try: %s')
            :format(group, want, table.concat(g.order, ' | ')))
        return
    end
    -- The subcommand's own arguments start after its name, so a handler never has to know it was
    -- reached through a group.
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end
    sub.fn(src, rest)
end

--- Add one subcommand to one group, registering the group the first time it is used.
---
--- `bare` is what the group does with no subcommand at all. Only `phone` has one.
function V.Sub(group, name, help, fn, bare)
    group, name = tostring(group), tostring(name):lower()
    local g = Groups[group]
    if not g then
        g = { order = {}, subs = {} }
        Groups[group] = g
        RegisterCommand(group, function(src, args) runGroup(group, src, args) end, false)
    end
    if bare then g.bare = bare end
    if g.subs[name] then return end
    g.subs[name] = { help = help, fn = fn }
    g.order[#g.order + 1] = name
end

--- What a group can do, for a chat suggestion or a help screen.
function V.SubList(group)
    local g = Groups[tostring(group)]
    if not g then return {} end
    local out = {}
    for i, name in ipairs(g.order) do
        out[i] = { name = name, help = g.subs[name].help }
    end
    return out
end
