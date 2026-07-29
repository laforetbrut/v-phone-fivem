-- ══════════════════════════════════════════════════════════════
-- Home screen widgets: the server's half
-- ══════════════════════════════════════════════════════════════
-- A widget is a glance. Most of them do not need this file at all - the weather, the clock, the
-- battery, what is playing and what is downloading are all facts the page or the client already
-- holds, and they are drawn without asking anybody. **A phone showing only those never sends a
-- single request here.**
--
-- What is left is the handful that genuinely lives on the server: a balance, a reminder that is
-- due, an alert standing over the city. They share ONE round trip, and the rules below decide
-- what that round trip is allowed to contain.
--
-- ── The three gates, in order ──────────────────────────────────
--
--   1. **The enabled list is read from the SERVER's copy of the preferences.** Not from the
--      request. A page can ask to refresh a subset of what is already enabled; it can never
--      widen the set. This is the difference between "which of my widgets do you want redrawn"
--      and "tell me about the police queue".
--   2. **Intersected with the apps the character actually has.** A widget belongs to an app.
--      Uninstall the app, or never buy it, and its widget produces nothing - checked here
--      rather than trusted from a saved preference, because a preference outlives an uninstall.
--   3. **Intersected with `Config.Widgets`.** The operator's switch, same shape as an app being
--      turned off, and it wins over both of the above.
--
-- Only what survives all three has its builder called. A builder is never run "just in case".
--
-- ── Where the builders live ────────────────────────────────────
-- Next to the data they read. `WidgetSource(id, fn)` is how a file registers one, and it is
-- called from server/bank.lua, server/apps.lua and the rest - because the tables, the caches
-- and the entitlement checks those widgets need are file-locals there, and a copy of a query
-- in this file is a copy that goes stale the first time the real one is fixed.

local SOURCES = {}          -- [id] = builder(src, p) -> table|nil
local WIDGET_APP = {}       -- [id] = the app id it belongs to, or nil for "always"

--- Register a builder.
---
--- `app` names the app the widget belongs to, and an id with no app is available to everybody.
--- The builder is handed `(src, p)` and returns a plain table, or nil for "nothing to say" -
--- which is not an error: the page has an empty face for every widget precisely so a nil here
--- is a finished-looking tile rather than a hole.
function WidgetSource(id, app, fn)
    if type(id) ~= 'string' or type(fn) ~= 'function' then return end
    SOURCES[id] = fn
    WIDGET_APP[id] = (type(app) == 'string' and app ~= '') and app or nil
end

--- Is this widget turned on by the operator?
---
--- Absent from `Config.Widgets` means allowed. An operator who has not heard of a widget has not
--- decided to ban it, and a config that has to list every id to permit anything is a config that
--- silently drops the next one added.
local function allowed(id)
    local cfg = Config.Widgets
    if type(cfg) ~= 'table' then return true end
    if cfg.enabled == false then return false end
    local v = cfg[id]
    if v == nil then return true end
    return v ~= false
end

-- ── The one callback ───────────────────────────────────────────

--- A per-source memo, so the two renders that a single home paint can produce cost one build.
---
--- `renderHome()` runs twice in quick succession in more than one flow - the epoch guard on the
--- page exists for exactly that reason - and without this the second one repeats every builder.
local Memo = {}

local MEMO_MS = 4000

AddEventHandler('playerDropped', function()
    Memo[source] = nil
end)

V.Callback('v-phone:widgets', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve({ ok = false }) return end

    local now = GetGameTimer()
    local memo = Memo[src]
    -- A refresh naming specific widgets skips the memo: it was asked for because something
    -- changed, and answering it from a cache built before the change is answering the wrong
    -- question. The whole-strip paint, which is the frequent one, is what the memo is for.
    local only = {}
    local narrowed = false
    if type(data) == 'table' and type(data.only) == 'table' then
        for _, id in ipairs(data.only) do
            if type(id) == 'string' then only[id] = true; narrowed = true end
        end
    end
    if not narrowed and memo and (now - memo.at) < MEMO_MS then
        resolve(memo.res)
        return
    end

    -- Gate 1. The server's own copy, never the request's.
    -- `PhonePrefs`, not `prefsOf`: that one is a file-local inside server/main.lua and
    -- reads as a nil global from here, which is exactly what this used to call.
    local prefs = (PhonePrefs and PhonePrefs(p)) or {}
    local enabled = prefs.widgets
    if type(enabled) ~= 'table' then enabled = Config.Widgets and Config.Widgets.default or {} end

    local out = {}
    for _, id in ipairs(enabled) do
        local fn = SOURCES[id]
        -- Gate 1b: a narrowed request may only ever be a subset of what is enabled.
        if fn and (not narrowed or only[id]) and allowed(id) then
            local app = WIDGET_APP[id]
            -- Gate 2. Owning the app is what entitles you to the widget.
            if not app or PhoneHasApp(src, app) then
                -- A builder that throws takes its own tile down and nothing else. One widget
                -- reading a table another resource has renamed must not blank the strip.
                local ok, res = pcall(fn, src, p)
                if not ok then
                    print(('[v-phone] widget %s: %s'):format(id, tostring(res)))
                elseif type(res) == 'table' then
                    out[id] = res
                end
            end
        end
    end

    local res = { ok = true, at = os.time(), w = out }
    if not narrowed then Memo[src] = { at = now, res = res } end
    resolve(res)
end)

-- ── Helpers the builders share ─────────────────────────────────

--- Text on its way to a 160-pixel tile, cut to size HERE.
---
--- The page escapes everything it draws, so this is not about markup - it is about a reminder
--- whose body is five hundred characters being shipped in full to a tile that can show sixty of
--- them. Truncating on the page means the other four hundred and forty crossed the wire and sat
--- in the payload of a home screen anybody standing behind the player can see.
function WidgetText(s, n)
    s = tostring(s or ''):gsub('%c', ' '):gsub('%s+', ' ')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    n = n or 60
    if #s > n then s = s:sub(1, n) end
    return s
end

CreateThread(function()
    -- After every file that registers a builder has had its turn. The count is the whole
    -- point: a server showing "unavailable" on every widget is either missing this file or
    -- missing the builders, and those are different problems with different fixes.
    Wait(2000)
    local names = {}
    for id in pairs(SOURCES) do names[#names + 1] = id end
    table.sort(names)
    if #names == 0 then
        print('[v-phone] widgets: loaded, but NO builders registered. Every server-backed '
            .. 'widget will read as unavailable.')
    else
        print(('[v-phone] widgets: %d builder(s) - %s'):format(#names, table.concat(names, ', ')))
    end
end)
