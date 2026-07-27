-- v-phone | client/doctor.lua
--
-- **`/phonedebug doctor` - is everything actually wired to everything else?**
--
-- Written after four bugs in one week that were all the same bug wearing different clothes:
--
--   * `registerApp` dropped `price`, so an app configured at $250 was silently free;
--   * `hushChat` was missing from the client's op whitelist, so a finished feature was
--     unreachable;
--   * `threadDelete` compared a phone NUMBER against a citizen id column, so it matched nothing
--     and answered `ok`;
--   * `Config.Export.categories` holds locale KEYS and they went to the page unresolved, so
--     `ph.export_c_metal` was printed on screen.
--
-- Not one of them raised an error. Every one was configured in one place and never joined up in
-- another, which is the failure this resource is most prone to: it is five languages deep - a
-- config table, a Lua server, a Lua client, a NUI bridge and a page - and every seam between two
-- of them is a place where a name can be spelt right on one side and not exist on the other.
--
-- **This is a static check that runs from inside the game.** `LoadResourceFile` can read the
-- resource's own shipped files at runtime, so the seams can be checked by reading both sides and
-- comparing - no build step, no external tool, and it checks what is actually installed on the
-- server rather than what is in somebody's editor.
--
-- Where a runtime answer exists it is preferred over reading a file: `V.Registered` on the
-- server knows which callbacks really loaded, which is a stronger fact than finding the text
-- `V.Callback('x')` in a file that may have failed to parse.
--
-- **A noisy doctor is a doctor nobody runs.** Every check below is written to be quiet when
-- things are right, and each one names the fix rather than only the symptom.

local RES = GetCurrentResourceName()

local function read(path)
    local text = LoadResourceFile(RES, path)
    return type(text) == 'string' and text or nil
end

--- Is this a callback THIS resource is responsible for?
---
--- Two kinds of name are asked for and neither is a fault, so both are skipped rather than
--- reported. The first run of this check found five things, all of them fine, which is exactly
--- how a check gets learned and then scrolled past:
---
---   * **another resource's namespace.** `v-housing:payRent` and `v-police:lookup` go to other
---     modules through the compatibility layer, and every call site already refuses when that
---     resource is not started. Nothing here should register them.
---   * **a concatenation stem.** `V.Request('v-phone:soc:' .. op, ...)` leaves the literal
---     `v-phone:soc:` in the file, and there is nothing to look up under the stem itself - the
---     same reason locale keys ending in `_` are skipped below.
local function ours(name)
    if name:sub(1, 8) ~= 'v-phone:' then return false end
    return name:sub(-1) ~= ':'
end

--- Every distinct capture of one pattern, as a set and in the order first seen.
---
--- Order matters only so the report reads the same way twice; the set is what the comparisons
--- use. Both from one pass, because these files are large and two passes over 700KB to build
--- two shapes of the same thing is work nobody sees.
local function findAll(text, pattern)
    local set, order = {}, {}
    if not text then return set, order end
    for name in text:gmatch(pattern) do
        if not set[name] then
            set[name] = true
            order[#order + 1] = name
        end
    end
    return set, order
end

-- ══════════════════════════════════════════════════════════════
-- What to read
-- ══════════════════════════════════════════════════════════════

--- The client files, taken from the manifest rather than listed here.
---
--- A hardcoded list is a list that goes stale, and a doctor that silently stopped checking a file
--- somebody added last month is worse than no doctor: it reports "all clear" about code it never
--- looked at.
local function clientFiles()
    local manifest = read('fxmanifest.lua')
    local _, order = findAll(manifest, "'(client/[%w_]+%.lua)'")
    local _, bridge = findAll(manifest, "'(bridge/client/[%w_]+%.lua)'")
    for _, f in ipairs(bridge) do order[#order + 1] = f end
    return order
end

local function serverFileNames()
    local manifest = read('fxmanifest.lua')
    local _, order = findAll(manifest, "'(server/[%w_]+%.lua)'")
    return order
end

-- ══════════════════════════════════════════════════════════════
-- The report
-- ══════════════════════════════════════════════════════════════

local Problems = 0

local function head(title)
    print(('^5[doctor]^7 %s'):format(title))
end

--- One finding. `fix` is the sentence somebody acts on - a doctor that says "3 problems" and
--- nothing else has moved the work rather than done it.
local function bad(what, fix)
    Problems = Problems + 1
    print(('  ^1x^7 %s'):format(what))
    if fix then print(('     ^3-> %s^7'):format(fix)) end
end

local function good(what)
    print(('  ^2ok^7 %s'):format(what))
end

-- ══════════════════════════════════════════════════════════════
-- The checks
-- ══════════════════════════════════════════════════════════════

--- 1. The page asks for things the client must answer.
---
--- `post('x')` on the page becomes `RegisterNUICallback('x')` on the client. A name that exists
--- on one side only is a button that does nothing at all, silently - the page waits, the
--- callback never fires, and nothing is printed anywhere. This is the seam that hid the Hush
--- thread for a whole release.
local function checkNui(app, clients)
    head('page -> client (NUI callbacks)')

    local registered = {}
    for _, path in ipairs(clients) do
        local text = read(path)
        if text then
            for name in text:gmatch("RegisterNUICallback%('([%w_]+)'") do registered[name] = true end
        end
    end

    -- The page's own `post` helper is defined with the same shape it calls, so its definition
    -- would match. Skipped by name rather than by position: a definition that moved would
    -- otherwise start being reported as a missing callback.
    local skip = { post = true }

    local missing = 0
    local _, wanted = findAll(app, "post%('([%w_]+)'")
    for _, name in ipairs(wanted) do
        if not skip[name] and not registered[name] then
            bad(("the page posts '%s' and no client file answers it"):format(name),
                ("add RegisterNUICallback('%s', ...) - the app will hang silently without it")
                    :format(name))
            missing = missing + 1
        end
    end
    if missing == 0 then good(('%d page requests, all answered'):format(#wanted)) end
end

--- (The client -> server check lives in the command at the bottom: it is the only one that has
--- to wait for an answer, so it runs last and prints after everything else has.)

--- 3. Every app can actually be drawn.
---
--- An id in `Config.Apps` with no `RENDER` opens onto a blank screen. Apps that declare a `page`
--- are drawn in an iframe by the app itself and are meant to have none.
local function checkApps(app)
    head('apps')

    local renders = findAll(app, "RENDER%.([%w_]+)%s*=")
    local missing = 0
    local count = 0

    for _, a in ipairs(Config.Apps or {}) do
        local id = tostring(a.id or '')
        if id ~= '' then
            count = count + 1
            if not a.page and not renders[id] then
                bad(("the app '%s' has no RENDER on the page"):format(id),
                    ("add RENDER.%s in html/app.js, or give the app a `page`"):format(id))
                missing = missing + 1
            end
        end
    end
    if missing == 0 then good(('%d apps, all drawable'):format(count)) end
end

--- 4. Every phrase the page asks for exists, in every language.
---
--- `L('ph.x')` with no `ph.x` prints the key. That is what put `ph.export_c_metal` on screen,
--- and it is invisible to anybody testing in the language that happens to be complete.
---
--- Keys ending in `_` are prefixes built by concatenation - `L('ph.err_' + code)` - and there is
--- nothing to look up under the stem itself.
local function checkLocales(app)
    head('phrases')

    local en = read('locales/en.lua')
    local fr = read('locales/fr.lua')
    if not en or not fr then
        bad('a locale file could not be read', 'locales/en.lua and locales/fr.lua must both ship')
        return
    end

    local haveEn = findAll(en, "%['([%w_%.]+)'%]")
    local haveFr = findAll(fr, "%['([%w_%.]+)'%]")

    local missing = 0
    local checked = 0
    -- Lua patterns have no alternation, so the two prefixes are gathered separately.
    local _, usedPh = findAll(app, "'(ph%.[%w_]+)'")
    local _, usedApp = findAll(app, "'(app%.[%w_]+)'")
    local used = {}
    for _, k in ipairs(usedPh) do used[#used + 1] = k end
    for _, k in ipairs(usedApp) do used[#used + 1] = k end

    for _, key in ipairs(used) do
        if key:sub(-1) ~= '_' then
            checked = checked + 1
            if not haveEn[key] then
                bad(("'%s' is used by the page and missing from locales/en.lua"):format(key),
                    'the key prints itself on screen when it is missing')
                missing = missing + 1
            elseif not haveFr[key] then
                bad(("'%s' is in English and missing from locales/fr.lua"):format(key),
                    'a French player sees the raw key where everybody else sees a sentence')
                missing = missing + 1
            end
        end
    end
    if missing == 0 then good(('%d phrases, present in both languages'):format(checked)) end
end

--- 5. Every icon an app names exists.
---
--- A missing icon falls back to a dot, which looks like a design choice rather than a mistake -
--- so nobody reports it and it stays.
local function checkIcons()
    head('icons')

    local sdk = read('html/sdk.js')
    if not sdk then
        bad('html/sdk.js could not be read', 'it holds the icon set')
        return
    end

    -- Two tables in that file: the stroke paths, and the app tiles. An app icon may be in
    -- either, so both are gathered.
    local icons = findAll(sdk, "\n%s*([%w_]+):%s*'M")
    for name in sdk:gmatch("\n%s*([%w_]+):%s*{%s*bg:") do icons[name] = true end
    for name in sdk:gmatch("\n%s*([%w_]+):%s*'M") do icons[name] = true end

    local missing = 0
    local count = 0
    for _, a in ipairs(Config.Apps or {}) do
        local icon = tostring(a.icon or '')
        if icon ~= '' then
            count = count + 1
            if not icons[icon] then
                bad(("the app '%s' names an icon '%s' that does not exist")
                    :format(tostring(a.id), icon),
                    'add it to ICONS or TILES in html/sdk.js - a missing one draws a dot')
                missing = missing + 1
            end
        end
    end
    if missing == 0 then good(('%d app icons, all present'):format(count)) end
end

--- 6. A paid app is actually paid for.
---
--- The exact bug that shipped: `Config.Apps` said $250, the registry dropped the field, and every
--- step after that behaved correctly for a free app. Asked of the SERVER, because the registry is
--- the thing that was wrong and only the server holds it.
local function checkPrices(res)
    head('prices')

    local want = {}
    local count = 0
    for _, a in ipairs(Config.Apps or {}) do
        local price = math.floor(tonumber(a.price) or 0)
        if price > 0 then
            count = count + 1
            want[tostring(a.id)] = price
        end
    end

    if count == 0 then good('no paid apps configured') return end
    if type(res) ~= 'table' or type(res.prices) ~= 'table' then
        bad('the server could not be asked what the registry charges', nil)
        return
    end

    local wrong = 0
    for id, price in pairs(want) do
        local got = math.floor(tonumber(res.prices[id]) or 0)
        if got ~= price then
            bad(("'%s' costs %d in the config and %d in the registry"):format(id, price, got),
                got == 0 and 'the price is being dropped on the way in - it will be free'
                         or 'two sources disagree about what this costs')
            wrong = wrong + 1
        end
    end
    if wrong == 0 then good(('%d paid apps, all charging what the config says'):format(count)) end
end

--- 7. What is answering, and what is not.
---
--- Not a fault, just the ground truth an operator needs before reading anything above: an app
--- with no provider running is meant to fall back, and knowing which fell back explains half the
--- surprises on a server.
local function checkProviders()
    head('providers')
    for _, res in ipairs({
        'doc-shops', 'doc-mechanicmdt', 'doc-civilalerte', 'doc-lottery',
        'doc-taxijob', 'doc-restaurant', 'doc-banking',
        'pma-voice', 'qb-core', 'es_extended', 'ox_core',
    }) do
        local state = GetResourceState(res)
        if state == 'started' then
            print(('  ^2..^7 %s'):format(res))
        end
    end
end

-- ══════════════════════════════════════════════════════════════
-- The command
-- ══════════════════════════════════════════════════════════════

V.Sub('phonedebug', 'doctor', 'check that everything is wired to everything else', function()
    Problems = 0

    local app = read('html/app.js')
    if not app then
        print('^1[doctor] html/app.js could not be read. Nothing else can be checked.^7')
        return
    end
    local clients = clientFiles()

    print('^5[doctor]^7 v-phone, checking ' .. #clients .. ' client file(s) and ' ..
          #serverFileNames() .. ' server file(s)')

    checkNui(app, clients)
    checkApps(app)
    checkLocales(app)
    checkIcons()

    -- The two that need the server go last, because they are the only ones that have to wait
    -- for an answer - everything above has already printed by the time this returns.
    V.Request('v-phone:doctor', function(res)
        checkPrices(res)
        checkProviders()

        head('client -> server (callbacks)')
        if type(res) ~= 'table' or not res.ok then
            bad('the server side of the doctor did not answer',
                'server/doctor.lua did not load - look for a Lua error at startup')
        else
            local parts = {}
            for _, path in ipairs(clients) do parts[#parts + 1] = read(path) or '' end
            local _, wanted = findAll(table.concat(parts, '\n'), "V%.Request%('([%w%-_:%.]+)'")

            local missing, checked = 0, 0
            for _, name in ipairs(wanted) do
                -- Silently, and on purpose: see `ours` at the top of this file.
                if ours(name) then
                    checked = checked + 1
                    if not (res.registered and res.registered[name]) then
                        bad(("the client asks for '%s' and the server registers nothing")
                            :format(name),
                            'the server file that registers it did not load, or the name differs')
                        missing = missing + 1
                    end
                end
            end
            if missing == 0 then
                -- The number CHECKED, not the number found in the files: reporting the second
                -- would claim credit for the other resources' names it deliberately skipped.
                good(('%d server callbacks, all registered'):format(checked))
            end
        end

        print(Problems == 0
            and '^2[doctor] nothing to report.^7'
            or ('^1[doctor] %d problem(s). Each one above names the fix.^7'):format(Problems))
    end, { names = (function()
        local parts = {}
        for _, path in ipairs(clients) do parts[#parts + 1] = read(path) or '' end
        local _, wanted = findAll(table.concat(parts, '\n'), "V%.Request%('([%w%-_:%.]+)'")
        -- Only what this resource answers for. Asking the server to look up another module's
        -- names would have it report every one of them as missing, correctly and uselessly.
        local mine = {}
        for _, name in ipairs(wanted) do
            if ours(name) then mine[#mine + 1] = name end
        end
        return mine
    end)() })
end)
