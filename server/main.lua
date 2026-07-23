-- v-phone | server
--
-- iFruit. Numbers, contacts, messages, calls and the app registry.
--
-- **The phone is a shell.** Messages and contacts are the only things it owns; every other
-- app is a view over the module that owns the data, and those calls are made by the client
-- straight to that module. Proxying them through here would put a second copy of the
-- bank's rules in the phone, and a second copy is a second answer.
--
-- **Server-authoritative in the two places it matters.** A message is stored and relayed
-- here, because a client that could write another player's history could forge it. A call
-- is routed here, because ringing somebody must not depend on the caller knowing where
-- they are.

V.Provide('phone')

local Core
local Numbers  = {}      -- [citizenid] = number, cached for the length of a session
local Online   = {}      -- [number]    = source
local Calls    = {}      -- [callId]    = { a, b, aNum, bNum, state, at }
local CallOf   = {}      -- [source]    = callId
local Apps     = {}      -- [id]        = registry row (config seed + RegisterApp)
local WorldApps = {}     -- [id]        = the operator's row from v-world
local callSeq  = 0
local MessageLastSend = {}
local MessageBusy = {}
local CipherUnlocked = {}
local CipherAttempts = {}
local CipherLastSend = {}

-- Forward declarations used by helpers defined before their implementation blocks.
-- Without these locals Lua resolves the earlier references as globals, even though a
-- same-named local is declared later in this file.
local Signal
local batteryOf
local requireItem
local phoneReachable
local speakerOff

local function num(v, d) return tonumber(v) or d or 0 end

local function L(src, k)
    local p = Core and Core.GetPlayer(src)
    local lang = (p and p.lang) or 'fr'
    return (Locales[lang] or Locales.fr or {})[k] or k
end

-- ══════════════════════════════════════════════════════════════
-- Settings
-- ══════════════════════════════════════════════════════════════
V.Module({
    label = 'Phone', category = 'gameplay',
    settings = {
        { key = 'enabled', label = 'Phone enabled', type = 'bool', default = true,
          hint = 'Off stops the phone opening. Numbers already minted are kept.' },

        { key = 'numberFormat', label = 'Number format', type = 'string', default = Config.NumberFormat,
          hint = 'Every # becomes a random digit; everything else is kept verbatim. Changing this only affects numbers minted afterwards, because an existing number is how other characters already reach that player.' },

        { key = 'requireItem', label = 'A phone item is required', type = 'bool', default = false,
          hint = 'On, the player must carry the `phone` item to open it. Off, everyone has one, which is the friendlier default for a young server.' },

        { key = 'maxLength', label = 'Message length limit', type = 'number', default = Config.Messages.maxLength,
          min = 20, max = 1000, step = 10 },

        { key = 'retentionDays', label = 'Keep messages for (days)', type = 'number', default = Config.Messages.retentionDays,
          min = 0, max = 365, step = 1,
          hint = 'Pruned once at boot. 0 keeps everything for ever, which is a growing table nobody trims.' },

        { key = 'ringSeconds', label = 'Ring for (s) before giving up', type = 'number', default = Config.Calls.ringSeconds,
          min = 5, max = 120, step = 1 },

        { key = 'maxMinutes', label = 'Longest call (min)', type = 'number', default = Config.Calls.maxMinutes,
          min = 1, max = 240, step = 1,
          hint = 'A ceiling so a call somebody walked away from does not hold a voice channel open all night.' },

        { key = 'battery', label = 'Battery drains', type = 'bool', default = true,
          hint = 'Off leaves every phone permanently charged. It only ever drains while the player is connected: coming back from a week away to a dead phone is a punishment for logging off, not a simulation.' },

        { key = 'hoursToEmpty', label = 'Hours from full to flat', type = 'number',
          default = Config.Battery.hoursToEmpty, min = 0.25, max = 72, step = 0.25,
          hint = 'Real hours, with the phone closed. The screen drains faster (see below).' },

        { key = 'screenDrain', label = 'Drain multiplier with the screen on', type = 'number',
          default = Config.Battery.screenMultiplier, min = 1, max = 20, step = 0.5 },

        { key = 'chargeMinutes', label = 'Minutes from flat to full', type = 'number',
          default = Config.Battery.chargeMinutes, min = 1, max = 600, step = 1,
          hint = 'At a charger. A vehicle and a property you hold a key to charge at the same rate.' },

        { key = 'powerbankCharge', label = 'Power bank charge (%)', type = 'number',
          default = 45, min = 5, max = 100, step = 5,
          hint = 'How much of the battery one power bank restores before it is used up.' },

        { key = 'autoDark', label = 'Automatic dark mode', type = 'bool', default = true,
          hint = 'Lets a player set the phone to follow the in-game clock. They still choose Light, Dark or Automatic; this only decides whether Automatic is offered at all.' },

        { key = 'darkFrom', label = 'Dark mode starts at (hour)', type = 'number', default = 20,
          min = 0, max = 23, step = 1,
          hint = 'In-game hour the screen turns dark when a player is on Automatic.' },

        { key = 'darkTo', label = 'Dark mode ends at (hour)', type = 'number', default = 6,
          min = 0, max = 23, step = 1,
          hint = 'In-game hour it goes light again. A start later than the end wraps over midnight, which is the normal case.' },

        { key = 'voicemail', label = 'Voicemail', type = 'bool', default = true,
          hint = 'A missed call lets the caller leave a written message. Off, a missed call is only a missed call.' },

        { key = 'voicemailMax', label = 'Voicemail length limit', type = 'number', default = 200,
          min = 40, max = 500, step = 10 },

        { key = 'anonymous', label = 'Allow withholding your number', type = 'bool', default = false,
          hint = 'On, a caller may hide their number. It is off by default because an anonymous call is a harassment tool before it is a roleplay tool.' },

        { key = 'wallpaperHosts', label = 'Wallpaper image hosts', type = 'string',
          default = table.concat(Config.WallpaperHosts, ', '),
          hint = 'Comma separated. A wallpaper link is a URL a client will fetch, so this is an operator decision. An open list is a way to make somebody load anything at all.' },

        { key = 'customWallpaper', label = 'Allow linked wallpapers', type = 'bool', default = true,
          hint = 'Off leaves only the built-in gradients, which cost nothing to load.' },

        { key = 'camera', label = 'Camera app enabled', type = 'bool', default = false,
          hint = 'The camera writes to a gallery. Uploading anywhere is an operator decision, so it has no default destination and stays off until one is set.' },

        { key = 'cameraUpload', label = 'Camera upload target (URL)', type = 'string', default = '',
          hint = 'Where a photo is posted. Empty means the photo never leaves the server. Add the returned CDN host to Wallpaper image hosts so saved photos can be shared or used as wallpaper.' },

        -- ── The social apps ────────────────────────────────────
        -- Bleeter, Snapmatic and Hush live in the phone rather than in a resource of
        -- their own, so their knobs live in the phone's settings too.
        { key = 'social', label = 'Social apps enabled', type = 'bool', default = Config.Social.enabled,
          hint = 'Off hides Bleeter, Snapmatic and Hush from every phone. Accounts and posts are kept.' },

        { key = 'socialMaxLength', label = 'Bleet length limit', type = 'number',
          default = Config.Social.postMax, min = 40, max = 1000, step = 10 },

        { key = 'socialFeedSize', label = 'Posts per feed', type = 'number',
          default = Config.Social.feedSize, min = 10, max = 200, step = 5,
          hint = 'How far back a feed reads. The one number to lower when a busy server starts feeling slow.' },

        { key = 'socialRetentionPosts', label = 'Keep posts for (days)', type = 'number',
          default = Config.Social.retention.posts, min = 0, max = 365, step = 1,
          hint = 'Swept at boot and then hourly. 0 keeps them for ever.' },

        { key = 'socialRetentionComments', label = 'Keep comments for (days)', type = 'number',
          default = Config.Social.retention.comments, min = 0, max = 365, step = 1,
          hint = 'A comment is also removed with the post it belongs to, whatever this says.' },

        { key = 'socialRetentionStories', label = 'Keep stories for (days)', type = 'number',
          default = Config.Social.retention.stories, min = 0, max = 30, step = 1,
          hint = 'One day is what a story is for. Longer turns it into a second feed.' },

        { key = 'socialRetentionMessages', label = 'Keep social messages for (days)', type = 'number',
          default = Config.Social.retention.messages, min = 0, max = 365, step = 1,
          hint = 'Direct messages inside Bleeter and Snapmatic. Phone SMS has its own limit above.' },

        { key = 'socialHush', label = 'Hush (dating) enabled', type = 'bool',
          default = Config.Social.hush.enabled },

        { key = 'socialDailyLikes', label = 'Hush likes per day', type = 'number',
          default = Config.Social.hush.dailyLikes, min = 1, max = 500, step = 1,
          hint = 'A ceiling, so liking absolutely everybody is not a strategy.' },

        { key = 'socialImageHosts', label = 'Social image hosts', type = 'string',
          default = table.concat(Config.Social.imageHosts, ', '),
          hint = 'Comma separated. Avatars and photos are URLs other clients will fetch, so this is an operator decision - the same rule as wallpapers.' },
    },
})

local function S(key, fallback) return V.Setting(key, fallback) end

-- ══════════════════════════════════════════════════════════════
-- Numbers
-- ══════════════════════════════════════════════════════════════
--- `#` becomes a digit; everything else is kept. The format is a setting rather than code
--- because "what a phone number looks like here" is a server's decision, not ours.
local function mintNumber(format)
    return (tostring(format):gsub('#', function() return tostring(math.random(0, 9)) end))
end

--- Retried rather than trusted: two characters created in the same second would otherwise
--- collide, and a duplicate number means two people share an inbox.
local function newNumber()
    local format = tostring(S('numberFormat', Config.NumberFormat))
    for _ = 1, 40 do
        local n = mintNumber(format)
        local taken = MySQL.scalar.await('SELECT 1 FROM vphone_characters WHERE phone = ? LIMIT 1', { n })
        if not taken then return n end
    end
    return nil
end

local function numberOfCid(cid)
    if Numbers[cid] then return Numbers[cid] end
    local n = MySQL.scalar.await('SELECT phone FROM vphone_characters WHERE citizenid = ?', { cid })
    if n and n ~= '' then Numbers[cid] = n end
    return Numbers[cid]
end

local function cidOfNumber(number)
    return MySQL.scalar.await('SELECT citizenid FROM vphone_characters WHERE phone = ?', { number })
end

local function ensureNumber(src, p)
    -- A character may already have a number the FRAMEWORK minted - qb writes one into
    -- charinfo when the character is created. Reusing it means every script that already
    -- knows how to reach this player still can.
    local fromFramework = Bridge.Numbers.Get(p.citizenid)
    if fromFramework and fromFramework ~= '' and not numberOfCid(p.citizenid) then
        MySQL.update.await('UPDATE vphone_characters SET phone = ? WHERE citizenid = ?',
            { fromFramework, p.citizenid })
        Numbers[p.citizenid] = fromFramework
    end

    local existing = numberOfCid(p.citizenid)
    if existing then
        Online[existing] = src
        return existing
    end
    local n = newNumber()
    if not n then
        print('[v-phone] could not mint a free number: the format has too few digits for the number of characters on this server')
        return nil
    end
    MySQL.update.await('UPDATE vphone_characters SET phone = ? WHERE citizenid = ?', { n, p.citizenid })
    -- And back into the framework, so a script that reads the character's number from
    -- qb or ox agrees with the phone rather than contradicting it.
    Bridge.Numbers.Set(p.citizenid, n)
    Numbers[p.citizenid] = n
    Online[n] = src
    return n
end

-- ══════════════════════════════════════════════════════════════
-- Apps
-- ══════════════════════════════════════════════════════════════
--- The same bet the module registry made: a script ships its own app without touching
--- v-phone. `page` is a URL the phone iframes; a Lua-only app just omits it and handles
--- its own NUI when opened.
-- Forward declaration: `local function` is only in scope AFTER its definition, and the
-- RegisterApp export below is written before it.
local loadWorldApps

local function registerApp(id, info, owner)
    id = tostring(id or '')
    if id == '' or not id:match('^[%w_-]+$') then
        print(('[v-phone] rejected invalid app id %q from %s'):format(id, tostring(owner or 'config')))
        return false
    end
    local permissions = {}
    local permissionSeen = {}
    for _, value in ipairs(type(info.permissions) == 'table' and info.permissions or {}) do
        local permission = tostring(value or ''):lower():gsub('[^%w_-]', ''):sub(1, 32)
        if permission ~= '' and not permissionSeen[permission] then
            permissionSeen[permission] = true
            permissions[#permissions + 1] = permission
        end
    end

    local features = {}
    for _, value in ipairs(type(info.features) == 'table' and info.features or {}) do
        local feature = tostring(value or ''):gsub('[%c]', ''):sub(1, 60)
        if feature ~= '' and #features < 8 then features[#features + 1] = feature end
    end

    local keywords = {}
    for _, value in ipairs(type(info.keywords) == 'table' and info.keywords or {}) do
        local keyword = tostring(value or ''):gsub('[%c]', ''):sub(1, 30)
        if keyword ~= '' and #keywords < 12 then keywords[#keywords + 1] = keyword end
    end

    Apps[id] = {
        id    = id,
        label = tostring(info.label or id),
        icon  = tostring(info.icon or 'dot'),
        page  = info.page,
        owner = owner or info.owner,
        slot  = num(info.slot, 99),
        -- Four apps sit in the dock rather than the paging grid: the ones a player
        -- reaches for without thinking should not move when the page does.
        dock  = info.dock == true,
        job   = info.job, jobGrade = info.jobGrade, gang = info.gang,
        -- A phone with no Phone app is a brick, so a few apps refuse to be removed.
        required = info.required == true,
        -- Not installed until it is downloaded. The store is the only way in.
        optional = info.optional == true,
        category = info.category and tostring(info.category) or 'utilities',
        version = info.version and tostring(info.version):sub(1, 16) or nil,
        developer = info.developer and tostring(info.developer):gsub('[%c]', ''):sub(1, 60) or nil,
        accent = info.accent and tostring(info.accent):match('^#%x%x%x%x%x%x$') or nil,
        permissions = permissions,
        features = features,
        keywords = keywords,
        -- One sentence for the store page. Optional, because forcing an empty string on
        -- every app would just fill the store with empty strings.
        desc  = info.desc and tostring(info.desc):sub(1, 300) or nil,
    }
    return true
end

exports('RegisterApp', function(id, info)
    -- A third-party app registers itself, and that is all it takes: it is governed by
    -- `Config.Apps` / `Config.Home` like a shipped one, with no database row to seed.
    return registerApp(id, info or {}, GetInvokingResource())
end)

exports('UnregisterApp', function(id) Apps[tostring(id or '')] = nil end)

-- Upstream read an admin-edited catalogue from v-world here. There is none in this build,
-- so this stays empty and the phone's catalogue is `Config.Apps` alone. Kept as a
-- function because the boot sequence and a couple of call sites still call it.
function loadWorldApps()  -- assigns the forward-declared local above
    WorldApps = {}
end

--- What this specific player may see. Three gates, and they are not interchangeable:
--- the operator's enable switch, the owning module actually running, and the job/gang the
--- operator set on that row.
local function appsFor(src, p)
    local out = {}
    for id, a in pairs(Apps) do
        local w = WorldApps[id]
        local ok = true

        if w and tonumber(w.enabled) == 0 then ok = false end
        -- An app that opens onto a stopped module is worse than an app that is not there.
        if ok and a.owner and a.owner ~= 'v-phone' and GetResourceState(a.owner) ~= 'started' then ok = false end
        -- The job gate can come from either place: the operator's row on v-world, or the
        -- app's own `job` in config (a police MDT is police-only even before an operator
        -- has ever touched it). The config value is the floor; the row can raise the grade.
        local gjob   = (w and w.job and w.job ~= '' and w.job) or a.job
        local ggrade = num(w and w.job_grade, 0)
        if a.jobGrade and a.jobGrade > ggrade then ggrade = a.jobGrade end
        if ok and gjob then
            ok = (p.job and p.job.name == gjob) and (num(p.job.grade, 0) >= ggrade)
        end
        if ok and w and w.gang and w.gang ~= '' then
            ok = (p.gang and p.gang.name == w.gang)
        end

        if ok then
            out[#out + 1] = {
                id = id, label = a.label, icon = a.icon, page = a.page, dock = a.dock or nil,
                slot = (w and num(w.slot, a.slot)) or a.slot,
                required = a.required or nil,
                optional = a.optional or nil, category = a.category,
                desc = a.desc, owner = a.owner, version = a.version,
                developer = a.developer, accent = a.accent,
                permissions = a.permissions, features = a.features, keywords = a.keywords,
            }
        end
    end
    table.sort(out, function(x, y)
        if x.slot ~= y.slot then return x.slot < y.slot end
        return x.id < y.id
    end)
    return out
end

exports('GetApps', function(src)
    local p = Core.GetPlayer(src)
    return p and appsFor(src, p) or {}
end)

-- ══════════════════════════════════════════════════════════════
-- Preferences
-- ══════════════════════════════════════════════════════════════
-- Stored in the character's metadata rather than a table of their own: it is a handful of
-- per-character values that are already persisted with everything else about them.
--- A wallpaper link is a URL a client will fetch, so the host has to be one the operator
--- allowed. Rejected rather than sanitised: quietly rewriting somebody's link into one
--- that works is worse than telling them it is not permitted.
local function wallpaperAllowed(url)
    url = tostring(url or '')
    if url == '' then return true end                      -- clearing it is always fine
    local host = url:match('^https?://([^/]+)')
    if not host then return false end
    host = host:lower():gsub(':%d+$', '')
    local configured = V.Setting(
        'wallpaperHosts',
        table.concat(Config.WallpaperHosts or {}, ', ')
    )
    local allowedHosts = {}
    if type(configured) == 'table' then
        allowedHosts = configured
    else
        for allowed in tostring(configured or ''):gmatch('[^,%s]+') do
            allowedHosts[#allowedHosts + 1] = allowed:lower()
        end
    end
    for _, allowed in ipairs(allowedHosts) do
        allowed = tostring(allowed):lower():gsub('^%s+', ''):gsub('%s+$', '')
        if host == allowed or host:sub(-(#allowed + 1)) == '.' .. allowed then return true end
    end
    return false
end

local function wallpaperId(value)
    value = tostring(value or '')
    for _, id in ipairs(Config.Wallpapers or {}) do
        if value == tostring(id) then return value end
    end
    return nil
end

local function cleanAppId(value)
    local id = tostring(value or ''):sub(1, 40)
    return id ~= '' and id:match('^[%w_-]+$') and id or nil
end

local function stringIdList(value, limit)
    local out, seen = {}, {}
    if type(value) ~= 'table' then return out end
    for _, raw in ipairs(value) do
        local id = cleanAppId(raw)
        if id and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
            if #out >= (limit or 64) then break end
        end
    end
    return out
end

local function cleanLayout(value)
    if type(value) ~= 'table' or type(value.items) ~= 'table' then return nil end
    local items = {}
    for _, raw in ipairs(value.items) do
        if type(raw) == 'table' then
            if raw.t == 'folder' then
                local apps = stringIdList(raw.apps, 24)
                if #apps > 0 then
                    items[#items + 1] = {
                        t = 'folder',
                        name = tostring(raw.name or ''):sub(1, 40),
                        apps = apps,
                    }
                end
            else
                local id = cleanAppId(raw.id)
                if id then items[#items + 1] = { t = 'app', id = id } end
            end
        end
        if #items >= 100 then break end
    end
    return { items = items }
end

local function passcodeDigest(p, code)
    return tostring(MySQL.scalar.await('SELECT LOWER(SHA2(?, 256))', {
        ('v-phone|%s|iFruit|%s'):format(tostring(p.citizenid or ''), tostring(code or ''))
    }) or '')
end

local function prefsOf(p, includeSecrets)
    local m = p.GetMetadata('phone')
    if type(m) ~= 'table' then m = {} end
    -- `glass` is iOS 27's transparency slider: 0 is ultra clear, 100 is fully tinted.
    -- It is a real stored preference driving a CSS variable, not a decorative control.
    local glass = tonumber(m.glass)
    local deviceName = tostring(m.deviceName or 'iFruit'):gsub('[%c]', ''):sub(1, 32)
    -- Migrate names saved by the early setup draft, before the phone received its
    -- in-universe iFruit identity. Truly custom names remain unchanged.
    deviceName = deviceName:gsub('[iI][pP][hH][oO][nN][eE]', 'iFruit')
    local storedPasscode = tostring(m.passcodeHash or '')
    local securityEnabled = m.securityEnabled == true and storedPasscode ~= ''
    local prefs = {
        -- Activation belongs to the character, not the browser cache. Reinstalling or
        -- reconnecting therefore does not make an already configured phone forget itself.
        setupComplete = m.setupComplete == true,
        setupVersion = math.max(0, math.min(10, math.floor(tonumber(m.setupVersion) or 0))),
        ownerName = tostring(m.ownerName or ''):gsub('[%c]', ''):sub(1, 40),
        deviceName = deviceName,
        securityEnabled = securityEnabled,
        faceId = securityEnabled and m.faceId == true,
        wallpaper = wallpaperId(m.wallpaper) or Config.DefaultWallpaper,
        dnd       = m.dnd == true,
        -- Control centre toggles. Each one is real: airplane and cellular drive the
        -- signal the status bar draws, wifi and bluetooth their own glyphs, brightness a
        -- dimming layer. A control that changed nothing would be a lie about the phone.
        airplane  = m.airplane == true,
        cellular  = (m.cellular == nil) and true or (m.cellular == true),
        wifi      = (m.wifi == nil) and true or (m.wifi == true),
        bluetooth = m.bluetooth == true,
        brightness = math.max(0.35, math.min(1, tonumber(m.brightness) or 1)),
        -- Which apps the player has silenced. A muted app still exists; it just does not
        -- light up the island or land in the list.
        notifMuted = stringIdList(m.notifMuted, 64),
        -- Apps are light by default, as they are on iOS. This flips the six
        -- surface values and nothing else.
        dark      = m.dark == true,
        -- The first configured tone, not a name of its own: `default` was not one of
        -- the tones on offer, so a phone nobody had touched showed a bare locale key.
        ringtone  = tostring(m.ringtone or (Config.Sounds.ringtones or {})[1] or 'classic'),
        -- Light, dark, or follow the in-game clock. `dark` stays as the resolved value so
        -- an older client that only knows the boolean keeps working.
        darkMode  = (m.darkMode == 'dark' or m.darkMode == 'light' or m.darkMode == 'auto')
                    and m.darkMode or (m.dark == true and 'dark' or 'light'),
        vibrate   = (m.vibrate == nil) and true or (m.vibrate == true),
        ringVolume = math.max(0, math.min(1, tonumber(m.ringVolume) or 0.7)),
        -- The home screen grid, the way a real phone lets you pick one. Columns decide
        -- how big the icons are; rows decide how many fit before a new page starts.
        gridCols = math.max(3, math.min(6, math.floor(tonumber(m.gridCols) or 4))),
        gridRows = math.max(3, math.min(7, math.floor(tonumber(m.gridRows) or 4))),
        -- Which built-in tone, and the player's own link if they set one. The link wins
        -- when it is there, which is what choosing it means.
        alertTone = tostring(m.alertTone or (Config.Sounds.alerts or {})[1] or 'ping'),
        ringUrl   = m.ringUrl and tostring(m.ringUrl) or nil,
        alertUrl  = m.alertUrl and tostring(m.alertUrl) or nil,
        glass     = math.max(0, math.min(100, math.floor(glass or Config.DefaultGlass))),
        -- What the player REMOVED, not what they installed. Storing the removals
        -- means a new app an operator adds later is there without every existing
        -- character having to go and find it in the store.
        removed   = stringIdList(m.removed, 128),
        -- Optional apps are tracked by what was ADDED, not by what was left alone:
        -- absent is their starting state, so a missing entry has to mean "not yet".
        added     = stringIdList(m.added, 128),
        actionApp = m.actionApp and tostring(m.actionApp) or nil,
        -- A linked wallpaper, its fit, and the shape of the device itself.
        wallpaperUrl = V.SettingBool('customWallpaper', true)
                       and m.wallpaperUrl and tostring(m.wallpaperUrl) or nil,
        wallFit   = (m.wallFit == 'contain') and 'contain' or Config.WallpaperFit,
        size      = math.max(0.75, math.min(1.15, tonumber(m.size) or Config.DeviceSize)),
        side      = (m.side == 'left') and 'left' or 'right',
        -- The home screen: the player's own order, and any folders they made.
        layout    = cleanLayout(m.layout),
    }
    if includeSecrets then prefs.passcodeHash = storedPasscode end
    return prefs
end

local function contactsOf(p)
    local required, requiredNumbers = {}, {}
    for index, raw in ipairs(Config.RequiredContacts or {}) do
        if type(raw) == 'table' then
            local name = tostring(raw.name or ''):gsub('[%c]', ''):sub(1, 40)
            local number = tostring(raw.number or ''):gsub('[%c]', ''):sub(1, 20)
            if name ~= '' and number ~= '' and not requiredNumbers[number] then
                requiredNumbers[number] = true
                required[#required + 1] = {
                    id = 'required:' .. index,
                    name = name,
                    number = number,
                    favourite = raw.favourite == false and 0 or 1,
                    photo = tostring(raw.photo or ''):sub(1, 400),
                    email = tostring(raw.email or ''):sub(1, 64),
                    address = tostring(raw.address or ''):sub(1, 120),
                    birthday = tostring(raw.birthday or ''):sub(1, 20),
                    note = tostring(raw.note or ''):sub(1, 300),
                    system = true,
                    required = true,
                }
            end
        end
    end

    local personal = MySQL.query.await(
        [[SELECT id, name, number, favourite, photo, email, address, birthday, note
          FROM vphone_contacts WHERE citizenid = ? ORDER BY favourite DESC, name]],
        { p.citizenid }) or {}
    for _, contact in ipairs(personal) do
        -- The configured version wins, otherwise the same service would be shown twice
        -- and one of the duplicates would misleadingly appear editable.
        if not requiredNumbers[tostring(contact.number or '')] then
            required[#required + 1] = contact
        end
    end
    return required
end

--- Two lists, because they answer two different questions. `available` is what the
--- OPERATOR permits this player to have; `installed` is what the PLAYER has chosen to
--- keep. The store shows the first, the home screen shows the second.
local function appsFrom(src, p)
    local available = appsFor(src, p)
    local prefs = prefsOf(p)
    local removed, added = {}, {}
    for _, id in ipairs(prefs.removed or {}) do removed[id] = true end
    for _, id in ipairs(prefs.added or {}) do added[id] = true end

    local installed = {}
    for _, a in ipairs(available) do
        local on
        if a.required then on = true                 -- never leaves
        elseif a.optional then on = added[a.id]       -- absent until downloaded
        else on = not removed[a.id] end               -- there unless removed
        if on then installed[#installed + 1] = a end
    end
    return available, installed
end

-- ══════════════════════════════════════════════════════════════
-- Messages
-- ══════════════════════════════════════════════════════════════
--- Conversations, newest first: for each counterpart, the last message and how many are
--- unread. Filtered to this citizen id in SQL, so a client cannot ask for somebody else's.
local function conversations(cid)
    -- One grouped read fetches both the last message and the counterpart's number.
    -- This avoids the former N+1 pattern (one extra SELECT per conversation) while
    -- staying compatible with MariaDB versions that predate window functions.
    local last = MySQL.query.await([[
        SELECT m.id AS last_id, m.body, m.at,
               IF(m.from_cid = ?, m.to_cid, m.from_cid) AS other,
               c.phone AS number
        FROM vphone_messages m
        INNER JOIN (
            SELECT MAX(id) AS id
            FROM vphone_messages
            WHERE (from_cid = ? OR to_cid = ?) AND group_id IS NULL
            GROUP BY IF(from_cid = ?, to_cid, from_cid)
            ORDER BY id DESC
            LIMIT 100
        ) latest ON latest.id = m.id
        LEFT JOIN vphone_characters c
          ON c.citizenid = IF(m.from_cid = ?, m.to_cid, m.from_cid)
        ORDER BY m.id DESC
    ]], { cid, cid, cid, cid, cid }) or {}
    if #last == 0 then return {} end

    local unread = {}
    for _, r in ipairs(MySQL.query.await(
        'SELECT from_cid AS other, COUNT(*) AS n FROM vphone_messages WHERE to_cid = ? AND seen = 0 AND group_id IS NULL GROUP BY from_cid',
        { cid }) or {}) do
        unread[r.other] = num(r.n, 0)
    end

    local out = {}
    for _, r in ipairs(last) do
        if r.number and r.number ~= '' then Numbers[r.other] = r.number end
        out[#out + 1] = {
            other  = r.other,
            number = r.number or r.other,
            body   = r.body or '',
            at     = r.at,
            unread = unread[r.other] or 0,
            lastId = r.last_id,
        }
    end
    table.sort(out, function(a, b) return (a.lastId or 0) > (b.lastId or 0) end)
    return out
end

local function conversation(cid, otherCid, limit)
    local rows = MySQL.query.await([[
        SELECT id, from_cid, body, kind, attachment, at, seen FROM vphone_messages
        WHERE ((from_cid = ? AND to_cid = ?) OR (from_cid = ? AND to_cid = ?))
          AND group_id IS NULL
        ORDER BY at DESC, id DESC LIMIT ?
    ]], { cid, otherCid, otherCid, cid, limit }) or {}

    -- Read back in ascending order: the query takes the newest N, the reader wants them
    -- oldest first.
    local out = {}
    for i = #rows, 1, -1 do
        local r = rows[i]
        out[#out + 1] = { id = r.id, mine = (r.from_cid == cid), body = r.body,
            kind = r.kind, attachment = r.attachment, at = r.at }
    end
    MySQL.update('UPDATE vphone_messages SET seen = 1 WHERE to_cid = ? AND from_cid = ? AND seen = 0',
        { cid, otherCid })
    return out
end

--- Nothing leaves the phone without a signal. Checked here rather than in the client so
--- that standing in a tunnel actually means something.
local function hasBars(src)
    local p = Core and Core.GetPlayer(src)
    if not p then return false end
    local prefs = prefsOf(p)
    if prefs.airplane or prefs.cellular == false then return false end
    return (Signal[src] or 4) > 0
end

--- What a message may carry besides text. An image is a URL every reader's client will
--- fetch, so it goes through the same host gate as wallpapers; a location is two numbers
--- the sender chose to share. Returns body, attachment, errorKey.
local function checkContent(body, kind, attachment)
    body = tostring(body or ''):sub(1, math.max(1, math.floor(num(S('maxLength', Config.Messages.maxLength), 250))))
    attachment = tostring(attachment or ''):sub(1, 300)

    if kind == 'image' then
        if attachment == '' then return nil, nil, 'noimage' end
        if not wallpaperAllowed(attachment) then return nil, nil, 'badhost' end
    elseif kind == 'location' then
        if not attachment:match('^%-?%d+%.?%d*;%-?%d+%.?%d*$') then return nil, nil, 'x' end
    else
        if body:gsub('%s', '') == '' then return nil, nil, 'empty' end
        attachment = ''
    end
    return body, attachment, nil
end

--- The one write the phone owns. Returns ok plus the stored row, or an error key.
local function sendMessage(fromCid, toNumber, body, kind, attachment)
    kind = (kind == 'image' or kind == 'location') and kind or 'text'
    local err
    body, attachment, err = checkContent(body, kind, attachment)
    if err then return nil, err end

    local toCid = cidOfNumber(toNumber)
    if not toCid then return nil, 'nonumber' end
    if toCid == fromCid then return nil, 'self' end

    local id = MySQL.insert.await(
        'INSERT INTO vphone_messages (from_cid, to_cid, body, kind, attachment) VALUES (?,?,?,?,?)',
        { fromCid, toCid, body, kind, attachment })

    -- Delivered live only if they are on: an offline character reads it next time they
    -- open the app, which is what the table is for.
    local target = Online[numberOfCid(toCid) or '']
    if target and phoneReachable(target) then
        TriggerClientEvent('v-phone:client:message', target, {
            from = numberOfCid(fromCid), fromCid = fromCid, body = body, id = id,
            kind = kind, attachment = attachment, hasItem = requireItem(target),
        })
    end

    -- Announced for anything integrating with the phone: a dispatch mirror, a log, a
    -- bot. Citizen ids rather than sources, so a listener survives a reconnect.
    TriggerEvent('v-phone:messageSent', fromCid, toCid, body, kind)

    return { id = id, body = body, kind = kind, attachment = attachment }, nil
end

-- ── Groups ─────────────────────────────────────────────────────
local function isMember(groupId, cid)
    return MySQL.scalar.await(
        'SELECT 1 FROM vphone_group_members WHERE group_id = ? AND citizenid = ?',
        { groupId, cid }) ~= nil
end

--- A group message is one row, delivered to every member who is on. The sender is the
--- server's idea of who called, exactly as in a DM.
local function sendGroup(p, groupId, body, kind, attachment)
    kind = (kind == 'image' or kind == 'location') and kind or 'text'
    local err
    body, attachment, err = checkContent(body, kind, attachment)
    if err then return nil, err end
    if not isMember(groupId, p.citizenid) then return nil, 'x' end

    local id = MySQL.insert.await(
        'INSERT INTO vphone_messages (from_cid, to_cid, group_id, body, kind, attachment) VALUES (?,"",?,?,?,?)',
        { p.citizenid, groupId, body, kind, attachment })

    local gname = MySQL.scalar.await('SELECT name FROM vphone_groups WHERE id = ?', { groupId })
    local fromNumber = numberOfCid(p.citizenid)
    for _, m in ipairs(MySQL.query.await(
        'SELECT citizenid FROM vphone_group_members WHERE group_id = ?', { groupId }) or {}) do
        if m.citizenid ~= p.citizenid then
            local target = Online[numberOfCid(m.citizenid) or '']
            if target and phoneReachable(target) then
                TriggerClientEvent('v-phone:client:message', target, {
                    from = fromNumber, fromCid = p.citizenid, body = body, id = id,
                    kind = kind, attachment = attachment,
                    group = groupId, groupName = gname, hasItem = requireItem(target),
                })
            end
        end
    end
    return { id = id, body = body, kind = kind, attachment = attachment }, nil
end

exports('SendMessage', function(fromCid, toNumber, body)
    local row, err = sendMessage(tostring(fromCid or ''), tostring(toNumber or ''), body)
    return row ~= nil, err
end)

-- ══════════════════════════════════════════════════════════════
-- Calls
-- ══════════════════════════════════════════════════════════════
-- The phone does no audio. It decides who is on a call and tells both clients to hand
-- themselves to v-voice; v-voice owns the Mumble channel.
-- A call log entry per participant: each sees it from their own side (in/out) with the
-- other party's number, and whether it was answered. Missed calls are just inbound rows
-- that were never answered - the app colours them, the table does not need to.
local function logCall(c, answered)
    local rows = {
        { cid = cidOfNumber(c.aNum), other = c.bNum, dir = 'out' },
        { cid = cidOfNumber(c.bNum), other = c.anonymous and '' or c.aNum, dir = 'in' },
    }
    for _, r in ipairs(rows) do
        if r.cid then
            MySQL.insert('INSERT INTO vphone_calls (citizenid, other_num, direction, answered) VALUES (?,?,?,?)',
                { r.cid, r.other or '', r.dir, answered and 1 or 0 })
        end
    end
end

local function endCall(id, reason)
    local c = Calls[id]
    if not c then return end
    speakerOff(id)
    -- Log it once, as it ends, from the state it reached: active means it connected.
    logCall(c, c.state == 'active')
    -- Nobody picked up: offer the caller the voicemail, which is the whole point of one.
    if c.state ~= 'active' and reason == 'noanswer' and c.a and V.SettingBool('voicemail', true) then
        TriggerClientEvent('v-phone:client:voicemailOffer', c.a, { number = c.bNum })
    end
    Calls[id] = nil
    for _, s in ipairs({ c.a, c.b }) do
        if s and CallOf[s] == id then
            CallOf[s] = nil
            TriggerClientEvent('v-phone:client:callEnd', s, reason)
        end
    end
end

local function allocateCallId()
    -- v-voice maps phone calls over 24 dedicated Mumble channels. Never hand two live
    -- conversations the same modulo slot.
    for _ = 1, 24 do
        callSeq = (callSeq % 24) + 1
        if not Calls[callSeq] then return callSeq end
    end
    return nil
end

local function startCall(src, p, toNumber, anonymous, video)
    if CallOf[src] then return nil, 'busy' end
    if not requireItem(src) then return nil, 'nophone' end
    if V.SettingBool('battery', true) and batteryOf(src) <= 0 then return nil, 'flat' end
    if not hasBars(src) then return nil, 'nosignal' end
    -- And the person being called has to be reachable too, or a call would ring somebody
    -- standing in a tunnel.
    local target0 = Online[toNumber]
    if target0 and not phoneReachable(target0) then return nil, 'unreachable' end

    local toCid = cidOfNumber(toNumber)
    if not toCid then return nil, 'nonumber' end
    if toCid == p.citizenid then return nil, 'self' end

    local target = Online[toNumber]
    if not target then return nil, 'offline' end
    if not requireItem(target) then return nil, 'unreachable' end
    if CallOf[target] then return nil, 'busy_them' end

    local tp = Core.GetPlayer(target)
    if tp and prefsOf(tp).dnd then return nil, 'dnd' end

    local id = allocateCallId()
    if not id then return nil, 'capacity' end
    local callRecord = {
        a = src, b = target, state = 'ringing', at = os.time(),
        aNum = numberOfCid(p.citizenid), bNum = toNumber,
        anonymous = anonymous and V.SettingBool('anonymous', false) or false,
        -- FaceTime: a normal voice call, presented as a video call on both phones. The
        -- game cannot stream a live face, so there is no video stream - the flag only
        -- changes how the call is drawn. Both ends see it, so it reads as a real call.
        video = video == true,
    }
    Calls[id] = callRecord
    CallOf[src], CallOf[target] = id, id

    TriggerClientEvent('v-phone:client:callOut', src, { id = id, number = toNumber, video = callRecord.video })
    TriggerClientEvent('v-phone:client:callIn', target, {
        id = id,
        number = Calls[id].anonymous and '' or Calls[id].aNum,
        video = callRecord.video,
    })

    -- Give up rather than ring for ever: an unanswered call that never clears leaves both
    -- phones stuck reporting they are busy.
    local ring = math.floor(num(S('ringSeconds', Config.Calls.ringSeconds), 30))
    SetTimeout(ring * 1000, function()
        local c = Calls[id]
        if c == callRecord and c.state == 'ringing' then endCall(id, 'noanswer') end
    end)
    return id, nil
end

local function answerCall(src)
    local id = CallOf[src]
    local c = id and Calls[id]
    if not c or c.state ~= 'ringing' or c.b ~= src then return false end
    c.state, c.at = 'active', os.time()

    TriggerClientEvent('v-phone:client:callActive', c.a, { id = id })
    TriggerClientEvent('v-phone:client:callActive', c.b, { id = id })

    local cap = math.floor(num(S('maxMinutes', Config.Calls.maxMinutes), 30))
    SetTimeout(cap * 60000, function()
        if Calls[id] == c then endCall(id, 'timeout') end
    end)
    return true
end

-- ══════════════════════════════════════════════════════════════
-- Battery and signal
-- ══════════════════════════════════════════════════════════════
-- Both are decided here, from the player's real position, for the same reason calls are:
-- a client that reported its own signal would report five bars from inside a tunnel.

local Battery = {}       -- [source] = level 0..100
Signal = {}             -- [source] = bars 0..4
local Charging = {}      -- [source] = true while in reach of something that charges
-- [source] = rate, set by another resource through the SetCharging export: an electric
-- car, a solar pack, a wall socket prop. Global so server/api.lua can write it. Read by
-- chargeRateAt below, cleared when the player drops.
ExternalCharge = {}

batteryOf = function(src)
    return math.max(0, math.min(100, math.floor(Battery[src] or 100)))
end

local function currentCallFor(src)
    local id = CallOf[src]
    local c = id and Calls[id]
    if not c then return nil end
    local mineIsCaller = c.a == src
    return {
        id = id,
        state = c.state == 'active' and 'active' or (mineIsCaller and 'out' or 'in'),
        number = mineIsCaller and c.bNum or (c.anonymous and '' or c.aNum),
    }
end

local function pushPower(src)
    TriggerClientEvent('v-phone:client:power', src, {
        battery = batteryOf(src),
        charging = Charging[src] or false,
        signal = Signal[src] or 4,
    })
end

local function setBattery(src, level)
    level = math.max(0, math.min(100, level))
    local was = batteryOf(src)
    Battery[src] = level
    if math.floor(level) ~= was then
        pushPower(src)
    end
    return level
end

exports('GetBattery', function(src) return batteryOf(src) end)
exports('AddBattery', function(src, delta) return setBattery(src, batteryOf(src) + (tonumber(delta) or 0)) end)
exports('GetSignal',  function(src) return Signal[src] or 4 end)
exports('HasSignal',  function(src) return hasBars(src) end)

--- The ceiling from any dead zone the player is standing in. Zones overlap on purpose:
--- the WORST one wins, so a tunnel inside a weak-signal desert is still a tunnel.
local function signalAt(coords)
    if GetResourceState('v-world') ~= 'started' then return 4 end
    local bars = 4
    for _, z in ipairs(V.Use('v-world').GetDeadZones() or {}) do
        if z.enabled ~= false and z.enabled ~= 0 then
            local d = #(coords - vector3(z.x + 0.0, z.y + 0.0, z.z + 0.0))
            if d <= (z.radius or 60.0) then
                bars = math.min(bars, math.floor(tonumber(z.bars) or 0))
            end
        end
    end
    return bars
end

--- Anywhere that charges: a public charger, any vehicle, or a property this character
--- holds a key to. The last two follow the player rather than a coordinate, which is
--- why they are code and not rows.
local function chargeRateAt(src, ped, coords)
    -- Another resource driving the charge wins over everything: an electric car it put
    -- you in, a socket you plugged into. It named the rate; trust it, within the ceiling.
    local ext = ExternalCharge[src]
    if ext and ext > 0 then return ext end

    if IsPedInAnyVehicle(ped) then return 1.0 end

    -- Inside a property is decided on the CLIENT, because only the housing script knows,
    -- and reported up a replicated state bag. See bridge/client/charging.lua, which knows
    -- how to ask qs-housing, ps-housing, qb-houses and the rest.
    local state = Player(src) and Player(src).state
    if state and state.phoneAtHome == true then return 1.0 end

    -- Public chargers, from Config.Chargers.
    for _, c in ipairs(Config.Chargers or {}) do
        if c.enabled ~= false and c.enabled ~= 0 then
            if #(coords - vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0)) <= (c.radius or 3.0) then
                return math.max(0.1, (tonumber(c.rate) or 20) / 20.0)
            end
        end
    end
    return 0.0
end

-- One tick for everybody, every 20 seconds. Per-player timers for a value that changes
-- this slowly would be sixty threads doing arithmetic.
local TICK = 20
local Open = {}          -- [source] = true while the screen is on

CreateThread(function()
    while true do
        Wait(TICK * 1000)
        if Core then
            local batteryEnabled = V.SettingBool('battery', true)
            local hours = math.max(0.25, tonumber(V.Setting('hoursToEmpty', Config.Battery.hoursToEmpty)) or 8.0)
            local mult  = math.max(1.0, tonumber(V.Setting('screenDrain', Config.Battery.screenMultiplier)) or 3.0)
            local full  = math.max(1.0, tonumber(V.Setting('chargeMinutes', Config.Battery.chargeMinutes)) or 45.0)

            local drainPerTick  = 100.0 / (hours * 3600.0) * TICK
            local chargePerTick = 100.0 / (full * 60.0) * TICK

            for _, src in ipairs(GetPlayers()) do
                src = tonumber(src)
                local p = Core.GetPlayer(src)
                if p then
                    local ped = GetPlayerPed(src)
                    local coords = GetEntityCoords(ped)
                    local oldSignal, oldCharging = Signal[src], Charging[src]
                    local oldBattery = batteryOf(src)
                    Signal[src] = signalAt(coords)

                    local rate = chargeRateAt(src, ped, coords)
                    Charging[src] = rate > 0
                    if not batteryEnabled then
                        setBattery(src, 100)
                    elseif rate > 0 then
                        setBattery(src, batteryOf(src) + chargePerTick * rate)
                    else
                        setBattery(src, batteryOf(src) - drainPerTick * (Open[src] and mult or 1.0))
                    end
                    if batteryOf(src) == oldBattery
                        and (Signal[src] ~= oldSignal or Charging[src] ~= oldCharging) then
                        pushPower(src)
                    end
                    if CallOf[src] and (batteryOf(src) <= 0 or not hasBars(src)) then
                        endCall(CallOf[src], batteryOf(src) <= 0 and 'flat' or 'nosignal')
                    end
                end
            end
        end
    end
end)

exports('SetScreenOn', function(src, on) Open[src] = on and true or nil end)

-- ══════════════════════════════════════════════════════════════
-- Callbacks
-- ══════════════════════════════════════════════════════════════
-- Either handset counts. Shipping a setting that only accepts one of the two phone items
-- in the catalogue would look like the other one is broken.
local PHONE_ITEMS = { 'phone', 'iphone' }

requireItem = function(src)
    if not V.SettingBool('requireItem', false) then return true end
    local inv = V.Use('v-inventory')
    for _, item in ipairs(PHONE_ITEMS) do
        if num(inv.GetItemCount(src, item), 0) > 0 then return true end
    end
    return false
end

phoneReachable = function(src)
    if not Core.GetPlayer(src) or not requireItem(src) then return false end
    if V.SettingBool('battery', true) and batteryOf(src) <= 0 then return false end
    return hasBars(src)
end

-- ══ Cipher ═════════════════════════════════════════════════════
-- Cipher deliberately keeps cryptography out of Lua. The NUI generates an ECDH key pair,
-- keeps the encrypted private key in the player's local CEF storage and sends only its
-- public half here. This server can route an envelope, but it has no material with which
-- to open it.

-- ── Lawful intercept (opt-in) ──────────────────────────────────
-- When Config.Police.cipher.intercept is on, the phone also sends the plaintext, and the
-- server keeps a WRAPPED copy so the warrant terminal can crack it. The wrap is a keyed
-- stream over a per-message salt: its job is "not plaintext at rest, only the terminal
-- recovers it", not military secrecy. The key is a server secret, stable across restarts
-- so an old message stays recoverable.
--
-- This is the ONE place the server holds anything readable, and only when an operator
-- deliberately turned E2E's promise off. Left off, none of this runs.
local function interceptKey()
    local k = GetConvar('phone_intercept_key', '')
    if k ~= '' then return k end
    -- No key set: derive a stable one from the server's own license, so it survives a
    -- restart without the operator having to manage a secret. A server that wants to
    -- rotate it sets `phone_intercept_key`.
    return 'vphone-intercept-' .. (GetConvar('sv_licenseKey', 'nolicense'))
end

local function xorStream(text, salt)
    local key = interceptKey() .. ':' .. salt
    local out, klen = {}, #key
    for i = 1, #text do
        local kb = string.byte(key, ((i - 1) % klen) + 1)
        out[i] = string.char((string.byte(text, i) ~ kb) % 256)
    end
    return table.concat(out)
end

--- Plaintext -> a stored blob `salt$base64(xored)`. Global so a future module could use
--- it; police.lua reads it back through CipherRecover.
function CipherWrap(plain)
    plain = tostring(plain or '')
    if plain == '' then return nil end
    local salt = tostring(math.random(100000, 999999))
    local wrapped = xorStream(plain, salt)
    -- Hex-encode so the blob is printable and passes through JSON and TEXT unharmed.
    local hex = wrapped:gsub('.', function(c) return string.format('%02x', string.byte(c)) end)
    return salt .. '$' .. hex
end

--- The stored blob -> plaintext. Returns nil if the blob is malformed.
function CipherRecover(blob)
    blob = tostring(blob or '')
    local salt, hex = blob:match('^(%d+)%$(%x+)$')
    if not salt then return nil end
    local raw = hex:gsub('%x%x', function(h) return string.char(tonumber(h, 16)) end)
    return xorStream(raw, salt)
end

local function cipherHasApp(src, p)
    local _, installed = appsFrom(src, p)
    for _, app in ipairs(installed) do
        if app.id == 'cipher' then return true end
    end
    return false
end

local function cipherProfile(cid)
    local row = MySQL.single.await([[SELECT handle, displayname, public_key, fingerprint, created_at
        FROM vphone_cipher_profiles WHERE citizenid = ?]], { cid })
    if not row then return nil end
    return {
        handle = row.handle,
        displayName = row.displayname,
        publicKey = row.public_key,
        fingerprint = row.fingerprint,
        createdAt = row.created_at,
    }
end

local function cipherUnreadOf(cid)
    return tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM vphone_cipher_messages m
        LEFT JOIN vphone_cipher_clears c
          ON c.citizenid = ? AND c.other_cid = m.from_cid
        WHERE m.to_cid = ? AND m.seen = 0
          AND (m.expires_at IS NULL OR m.expires_at > NOW())
          AND m.id > COALESCE(c.before_id, 0)]], { cid, cid })) or 0
end

local function cipherPinHash(cid, pin)
    return MySQL.scalar.await("SELECT SHA2(CONCAT(?, ':cipher:', ?), 256)", { cid, pin })
end

local function cipherCleanHandle(raw)
    return tostring(raw or ''):lower():gsub('^@', ''):sub(1, 20)
end

local function cipherPublicMaterial(data)
    local publicKey = tostring((data and data.publicKey) or '')
    local fingerprint = tostring((data and data.fingerprint) or ''):upper()
    if #publicKey < 80 or #publicKey > 1800 or #fingerprint < 20 or #fingerprint > 95 then
        return nil
    end
    local ok, key = pcall(json.decode, publicKey)
    if not ok or type(key) ~= 'table' or key.kty ~= 'EC' or key.crv ~= 'P-256'
        or type(key.x) ~= 'string' or type(key.y) ~= 'string' then
        return nil
    end
    if not fingerprint:match('^[A-F0-9:]+$') then return nil end
    return publicKey, fingerprint
end

local function cipherUnlocked(src, p)
    return CipherUnlocked[src] == p.citizenid
end

local function cipherRequireSession(src, p, resolve)
    if not cipherHasApp(src, p) then resolve({ error = 'notinstalled' }) return false end
    if not cipherUnlocked(src, p) then resolve({ error = 'locked' }) return false end
    return true
end

local function cipherVerifyPin(src, p, pin)
    local attempt = CipherAttempts[src]
    local now = GetGameTimer()
    if attempt and attempt.untilAt and now < attempt.untilAt then
        return false, 'lockedout', math.ceil((attempt.untilAt - now) / 1000)
    end
    pin = tostring(pin or '')
    if not pin:match('^%d%d%d%d%d%d$') then return false, 'badpin', 0 end
    local stored = MySQL.scalar.await(
        'SELECT pin_hash FROM vphone_cipher_profiles WHERE citizenid = ?', { p.citizenid })
    if stored and stored == cipherPinHash(p.citizenid, pin) then
        CipherAttempts[src] = nil
        CipherUnlocked[src] = p.citizenid
        return true
    end
    local tries = (attempt and attempt.tries or 0) + 1
    local maximum = math.max(3, math.floor(num((Config.Cipher or {}).pinAttempts, 5)))
    if tries >= maximum then
        CipherAttempts[src] = { tries = 0, untilAt = now + 30000 }
        return false, 'lockedout', 30
    end
    CipherAttempts[src] = { tries = tries }
    return false, 'badpin', maximum - tries
end

local function cipherResolvePeer(handle, selfCid)
    handle = cipherCleanHandle(handle)
    if not handle:match('^[a-z0-9_][a-z0-9_][a-z0-9_]+$') then return nil end
    return MySQL.single.await([[SELECT citizenid, handle, displayname, public_key, fingerprint
        FROM vphone_cipher_profiles WHERE handle = ? AND citizenid <> ?]], { handle, selfCid })
end

local function cipherPeerPayload(row)
    if not row then return nil end
    return {
        handle = row.handle,
        displayName = row.displayname,
        publicKey = row.public_key,
        fingerprint = row.fingerprint,
    }
end

local function cipherAllowedBurn(raw)
    local value = math.max(0, math.floor(num(raw, 0)))
    for _, seconds in ipairs((Config.Cipher or {}).burnSeconds or { 0, 300, 3600, 86400 }) do
        if value == math.floor(num(seconds, 0)) then return value end
    end
    return 0
end

V.Callback('v-phone:open', function(src, resolve)
    if not V.SettingBool('enabled', true) then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'x' }) return end
    if not requireItem(src) then resolve({ error = 'nophone' }) return end
    -- A flat phone does not open. It is the one refusal players understand immediately.
    if V.SettingBool('battery', true) and batteryOf(src) <= 0 then resolve({ error = 'flat' }) return end

    local number = ensureNumber(src, p)
    local available, installed = appsFrom(src, p)
    resolve({
        ok       = true,
        playerName = tostring(p.name or ''):sub(1, 40),
        number   = number,
        battery  = batteryOf(src),
        charging = Charging[src] or false,
        signal   = Signal[src] or 4,
        apps      = installed,
        available = available,
        prefs    = prefsOf(p),
        contacts = contactsOf(p),
        conversations = conversations(p.citizenid),
        cipherUnread = cipherUnreadOf(p.citizenid),
        groups = MySQL.query.await([[SELECT g.id, g.name FROM vphone_groups g
            JOIN vphone_group_members m ON m.group_id = g.id
            WHERE m.citizenid = ? ORDER BY g.id DESC]], { p.citizenid }) or {},
        wallpapers = Config.Wallpapers,
        sounds = Config.Sounds,
        -- Whether the page should reach for the shipped WAV files or synthesise. It
        -- falls back on its own if a file will not load, so this is a preference and
        -- not a promise.
        soundFiles = Config.Sounds.files ~= false,
        -- Whether Cipher should hand a plaintext copy to the server for lawful intercept.
        -- Off unless the operator turned it on, so E2E stays E2E by default.
        cipherIntercept = (Config.Police and Config.Police.cipher and Config.Police.cipher.intercept) == true,
        -- Media hosting: whether the camera uploads to a CDN, and whether video recording
        -- is offered, and the clip length cap the record UI should honour.
        media = Bridge.MediaEnabled and Bridge.MediaEnabled() or false,
        mediaVideo = Bridge.MediaVideoEnabled and Bridge.MediaVideoEnabled() or false,
        mediaVideoMax = math.max(1, math.min(30, tonumber(Config.Media and Config.Media.video
            and Config.Media.video.maxSeconds) or 15)),
        -- The operator's automatic-dark policy, so the page can resolve 'auto' itself
        -- against the in-game clock rather than asking on every tick.
        theme = {
            auto = V.SettingBool('autoDark', true),
            from = math.floor(num(S('darkFrom', 20), 20)),
            to   = math.floor(num(S('darkTo', 6), 6)),
        },
        voicemail = V.SettingBool('voicemail', true),
        -- Unread voicemail, so the Phone icon can carry a badge like Messages does.
        vmUnread = tonumber(MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_voicemail WHERE citizenid = ? AND seen = 0', { p.citizenid })) or 0,
        photos     = (function()
            local ph = p.GetMetadata('photos')
            return (type(ph) == 'table') and ph or {}
        end)(),
        camera     = V.SettingBool('camera', false)
                     and (tostring(V.Setting('cameraUpload', '')) ~= '') or false,
        customWallpaper = V.SettingBool('customWallpaper', true),
        call = currentCallFor(src) or false,
    })
end)

V.Callback('v-phone:cipher', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'x' }) return end
    if not cipherHasApp(src, p) then resolve({ error = 'notinstalled' }) return end
    local op = tostring((data and data.op) or 'me')

    if op == 'me' then
        local profile = cipherProfile(p.citizenid)
        resolve({
            ok = true,
            exists = profile ~= nil,
            unlocked = cipherUnlocked(src, p),
            profile = profile,
        })
        return
    end

    if op == 'create' then
        if cipherProfile(p.citizenid) then resolve({ error = 'exists' }) return end
        local handle = cipherCleanHandle(data and data.handle)
        local displayName = tostring((data and data.displayName) or ''):gsub('[%c]', ''):sub(1, 32)
        local pin = tostring((data and data.pin) or '')
        local publicKey, fingerprint = cipherPublicMaterial(data)
        if not handle:match('^[a-z0-9_][a-z0-9_][a-z0-9_]+$') then
            resolve({ error = 'handle' }) return
        end
        if displayName == '' then displayName = handle end
        if not pin:match('^%d%d%d%d%d%d$') then resolve({ error = 'pin' }) return end
        if not publicKey then resolve({ error = 'key' }) return end
        if MySQL.scalar.await('SELECT 1 FROM vphone_cipher_profiles WHERE handle = ?', { handle }) then
            resolve({ error = 'taken' }) return
        end
        local id = MySQL.insert.await([[INSERT INTO vphone_cipher_profiles
            (citizenid, handle, displayname, public_key, fingerprint, pin_hash)
            VALUES (?,?,?,?,?,?)]], {
            p.citizenid, handle, displayName, publicKey, fingerprint,
            cipherPinHash(p.citizenid, pin),
        })
        if not id then resolve({ error = 'x' }) return end
        CipherUnlocked[src] = p.citizenid
        resolve({ ok = true, profile = cipherProfile(p.citizenid) })
        return
    end

    if op == 'unlock' then
        local ok, err, remaining = cipherVerifyPin(src, p, data and data.pin)
        if not ok then
            resolve({ error = err, remaining = remaining })
            return
        end
        resolve({ ok = true, profile = cipherProfile(p.citizenid) })
        return
    end

    if op == 'rotate' then
        local ok, err, remaining = cipherVerifyPin(src, p, data and data.pin)
        if not ok then resolve({ error = err, remaining = remaining }) return end
        local publicKey, fingerprint = cipherPublicMaterial(data)
        if not publicKey then resolve({ error = 'key' }) return end
        -- A replaced private key cannot open old envelopes. Purging them is safer than
        -- presenting undecryptable history as if it were still recoverable.
        MySQL.update.await([[DELETE FROM vphone_cipher_messages
            WHERE from_cid = ? OR to_cid = ?]], { p.citizenid, p.citizenid })
        MySQL.update.await([[UPDATE vphone_cipher_profiles SET public_key = ?, fingerprint = ?
            WHERE citizenid = ?]], { publicKey, fingerprint, p.citizenid })
        resolve({ ok = true, profile = cipherProfile(p.citizenid) })
        return
    end

    if not cipherRequireSession(src, p, resolve) then return end

    if op == 'list' then
        MySQL.update.await([[DELETE FROM vphone_cipher_messages
            WHERE expires_at IS NOT NULL AND expires_at <= NOW()]])
        local clearRows = MySQL.query.await([[SELECT other_cid, before_id
            FROM vphone_cipher_clears WHERE citizenid = ?]], { p.citizenid }) or {}
        local clears = {}
        for _, row in ipairs(clearRows) do clears[row.other_cid] = tonumber(row.before_id) or 0 end
        local rows = MySQL.query.await([[SELECT id, from_cid, to_cid, envelope, burn, seen, at
            FROM vphone_cipher_messages
            WHERE from_cid = ? OR to_cid = ?
            ORDER BY id DESC LIMIT 240]], { p.citizenid, p.citizenid }) or {}
        local conversationsByCid, order = {}, {}
        for _, row in ipairs(rows) do
            local other = row.from_cid == p.citizenid and row.to_cid or row.from_cid
            if tonumber(row.id) > (clears[other] or 0) then
                local conv = conversationsByCid[other]
                if not conv then
                    conv = {
                        otherCid = other,
                        envelope = row.envelope,
                        at = row.at,
                        burn = tonumber(row.burn) or 0,
                        unread = 0,
                    }
                    conversationsByCid[other] = conv
                    order[#order + 1] = other
                end
                if row.to_cid == p.citizenid and tonumber(row.seen) == 0 then
                    conv.unread = conv.unread + 1
                end
            end
        end
        -- Fetch every peer profile in one bounded read. The previous loop issued one
        -- query per conversation, which became noticeably expensive on active servers.
        local peers = {}
        if #order > 0 then
            local placeholders = {}
            for index, cid in ipairs(order) do
                placeholders[index] = '?'
                peers[index] = cid
            end
            local peerRows = MySQL.query.await(
                ('SELECT citizenid, handle, displayname, public_key, fingerprint ' ..
                 'FROM vphone_cipher_profiles WHERE citizenid IN (%s)'):format(
                    table.concat(placeholders, ',')),
                peers) or {}
            peers = {}
            for _, row in ipairs(peerRows) do peers[row.citizenid] = row end
        end
        local out = {}
        for _, cid in ipairs(order) do
            local conv = conversationsByCid[cid]
            local peer = peers[cid]
            if peer then
                conv.peer = cipherPeerPayload(peer)
                conv.otherCid = nil
                out[#out + 1] = conv
            end
        end
        resolve({ ok = true, conversations = out, unread = cipherUnreadOf(p.citizenid) })
        return
    end

    if op == 'lookup' then
        local query = cipherCleanHandle(data and data.query)
        if #query < 2 then resolve({ ok = true, results = {} }) return end
        local rows = MySQL.query.await([[SELECT handle, displayname, public_key, fingerprint
            FROM vphone_cipher_profiles
            WHERE citizenid <> ? AND handle LIKE CONCAT(?, '%')
            ORDER BY handle LIMIT 10]], { p.citizenid, query }) or {}
        local out = {}
        for _, row in ipairs(rows) do out[#out + 1] = cipherPeerPayload(row) end
        resolve({ ok = true, results = out })
        return
    end

    local peer = cipherResolvePeer(data and data.handle, p.citizenid)
    if (op == 'thread' or op == 'send' or op == 'clear') and not peer then
        resolve({ error = 'nouser' })
        return
    end

    if op == 'thread' then
        MySQL.update.await([[DELETE FROM vphone_cipher_messages
            WHERE expires_at IS NOT NULL AND expires_at <= NOW()]])
        local before = tonumber(MySQL.scalar.await([[SELECT before_id FROM vphone_cipher_clears
            WHERE citizenid = ? AND other_cid = ?]], { p.citizenid, peer.citizenid })) or 0
        local rows = MySQL.query.await([[SELECT id, from_cid, envelope, burn, seen, at, expires_at
            FROM vphone_cipher_messages
            WHERE ((from_cid = ? AND to_cid = ?) OR (from_cid = ? AND to_cid = ?))
              AND id > ? AND (expires_at IS NULL OR expires_at > NOW())
            ORDER BY id DESC LIMIT ?]], {
            p.citizenid, peer.citizenid, peer.citizenid, p.citizenid,
            before, math.max(20, math.floor(num((Config.Cipher or {}).pageSize, 80))),
        }) or {}
        local out = {}
        for index = #rows, 1, -1 do
            local row = rows[index]
            out[#out + 1] = {
                id = row.id,
                mine = row.from_cid == p.citizenid,
                envelope = row.envelope,
                burn = tonumber(row.burn) or 0,
                at = row.at,
                expiresAt = row.expires_at,
            }
        end
        MySQL.update.await([[UPDATE vphone_cipher_messages SET seen = 1
            WHERE from_cid = ? AND to_cid = ? AND seen = 0]], { peer.citizenid, p.citizenid })
        resolve({
            ok = true,
            peer = cipherPeerPayload(peer),
            messages = out,
            unread = cipherUnreadOf(p.citizenid),
        })
        return
    end

    if op == 'send' then
        if not requireItem(src) then resolve({ error = 'nophone' }) return end
        if V.SettingBool('battery', true) and batteryOf(src) <= 0 then
            resolve({ error = 'flat' }) return
        end
        if not hasBars(src) then resolve({ error = 'nosignal' }) return end
        local now = GetGameTimer()
        if CipherLastSend[src] and now - CipherLastSend[src] < 650 then
            resolve({ error = 'rate' }) return
        end
        CipherLastSend[src] = now
        local envelope = tostring((data and data.envelope) or '')
        if #envelope < 32 or #envelope > 6000 then resolve({ error = 'length' }) return end
        local ok, decoded = pcall(json.decode, envelope)
        if not ok or type(decoded) ~= 'table' or tonumber(decoded.v) ~= 1
            or type(decoded.iv) ~= 'string' or type(decoded.data) ~= 'string' then
            resolve({ error = 'key' }) return
        end
        local burn = cipherAllowedBurn(data and data.burn)
        local expires = burn > 0 and (os.time() + burn) or 0

        -- Lawful intercept: only when the operator turned it on, and only if the phone
        -- sent the plaintext for it. Wrapped, never stored in the clear. Off by default,
        -- so this is nil and Cipher stays a true end-to-end secret.
        local intercept = nil
        if Config.Police and Config.Police.cipher and Config.Police.cipher.intercept then
            local plain = tostring((data and data.intercept_plain) or '')
            if plain ~= '' then intercept = CipherWrap(plain:sub(1, 700)) end
        end

        local id = MySQL.insert.await([[INSERT INTO vphone_cipher_messages
            (from_cid, to_cid, envelope, burn, expires_at, intercept)
            VALUES (?,?,?,?,IF(? > 0, FROM_UNIXTIME(?), NULL),?)]], {
            p.citizenid, peer.citizenid, envelope, burn, expires, expires, intercept,
        })
        local message = {
            id = id,
            mine = true,
            envelope = envelope,
            burn = burn,
            at = os.date('%Y-%m-%d %H:%M:%S'),
            peer = cipherPeerPayload(peer),
        }
        local targetNumber = numberOfCid(peer.citizenid)
        local target = targetNumber and Online[targetNumber]
        if target then
            TriggerClientEvent('v-phone:client:cipher', target, {
                id = id,
                from = cipherProfile(p.citizenid),
                envelope = envelope,
                burn = burn,
                at = message.at,
            })
        end
        resolve({ ok = true, message = message })
        return
    end

    if op == 'clear' then
        local last = tonumber(MySQL.scalar.await([[SELECT MAX(id) FROM vphone_cipher_messages
            WHERE (from_cid = ? AND to_cid = ?) OR (from_cid = ? AND to_cid = ?)]], {
            p.citizenid, peer.citizenid, peer.citizenid, p.citizenid,
        })) or 0
        MySQL.query.await([[INSERT INTO vphone_cipher_clears (citizenid, other_cid, before_id)
            VALUES (?,?,?) ON DUPLICATE KEY UPDATE before_id = GREATEST(before_id, VALUES(before_id))]],
            { p.citizenid, peer.citizenid, last })
        resolve({ ok = true })
        return
    end

    if op == 'profile' then
        local displayName = tostring((data and data.displayName) or ''):gsub('[%c]', ''):sub(1, 32)
        if displayName == '' then resolve({ error = 'fields' }) return end
        MySQL.update.await('UPDATE vphone_cipher_profiles SET displayname = ? WHERE citizenid = ?',
            { displayName, p.citizenid })
        resolve({ ok = true, profile = cipherProfile(p.citizenid) })
        return
    end

    if op == 'logout' then
        CipherUnlocked[src] = nil
        resolve({ ok = true })
        return
    end

    if op == 'destroy' then
        local pin = tostring((data and data.pin) or '')
        local stored = MySQL.scalar.await(
            'SELECT pin_hash FROM vphone_cipher_profiles WHERE citizenid = ?', { p.citizenid })
        if not stored or stored ~= cipherPinHash(p.citizenid, pin) then
            resolve({ error = 'badpin' }) return
        end
        MySQL.update.await('DELETE FROM vphone_cipher_messages WHERE from_cid = ? OR to_cid = ?',
            { p.citizenid, p.citizenid })
        MySQL.update.await('DELETE FROM vphone_cipher_clears WHERE citizenid = ? OR other_cid = ?',
            { p.citizenid, p.citizenid })
        MySQL.update.await('DELETE FROM vphone_cipher_profiles WHERE citizenid = ?', { p.citizenid })
        CipherUnlocked[src], CipherAttempts[src] = nil, nil
        resolve({ ok = true })
        return
    end

    resolve({ error = 'forbidden' })
end)

V.Callback('v-phone:conversation', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local groupId = tonumber(data and data.group)
    if groupId then
        groupId = math.floor(groupId)
        if not isMember(groupId, p.citizenid) then resolve({ error = 'x' }) return end
        local rows = MySQL.query.await([[
            SELECT m.id, m.from_cid, m.body, m.kind, m.attachment, m.at,
                   c.phone AS from_num
            FROM vphone_messages m
            LEFT JOIN vphone_characters c ON c.citizenid = m.from_cid
            WHERE m.group_id = ? ORDER BY m.at DESC, m.id DESC LIMIT ?
        ]], { groupId, Config.Messages.pageSize }) or {}
        local out = {}
        for i = #rows, 1, -1 do
            local r = rows[i]
            out[#out + 1] = {
                id = r.id, mine = (r.from_cid == p.citizenid), body = r.body,
                kind = r.kind, attachment = r.attachment, at = r.at,
                from = r.from_num or r.from_cid,
            }
            if r.from_num and r.from_num ~= '' then Numbers[r.from_cid] = r.from_num end
        end
        resolve({ ok = true, messages = out })
        return
    end

    local other = cidOfNumber(tostring((data and data.number) or ''))
    if not other then resolve({ error = 'nonumber' }) return end
    resolve({ ok = true, messages = conversation(p.citizenid, other, Config.Messages.pageSize) })
end)

V.Callback('v-phone:send', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    if not requireItem(src) then resolve({ error = 'nophone' }) return end
    if V.SettingBool('battery', true) and batteryOf(src) <= 0 then
        resolve({ error = 'flat' }) return
    end
    if not hasBars(src) then resolve({ error = 'nosignal' }) return end
    local now = GetGameTimer()
    if MessageBusy[src] or (MessageLastSend[src] and now - MessageLastSend[src] < 400) then
        resolve({ error = 'rate' }) return
    end
    MessageLastSend[src] = now
    MessageBusy[src] = true
    local row, err
    local groupId = tonumber(data and data.group)
    if groupId then
        row, err = sendGroup(p, math.floor(groupId), data and data.body,
            data and data.kind, data and data.attachment)
    else
        row, err = sendMessage(p.citizenid, tostring((data and data.number) or ''),
            data and data.body, data and data.kind, data and data.attachment)
    end
    MessageBusy[src] = nil
    if not row then resolve({ error = err }) return end
    resolve({ ok = true, id = row.id, body = row.body, kind = row.kind, attachment = row.attachment })
end)

--- Create a group from contact numbers. The creator is a member by construction; every
--- number must resolve to a real character, because a group with ghosts in it is a bug
--- report waiting to be typed.
V.Callback('v-phone:groupCreate', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local name = tostring((data and data.name) or ''):sub(1, 40)
    if name:gsub('%s', '') == '' then resolve({ error = 'fields' }) return end

    local members, seen = { p.citizenid }, { [p.citizenid] = true }
    for _, n in ipairs((data and data.numbers) or {}) do
        local cid = cidOfNumber(tostring(n))
        if cid and not seen[cid] then
            seen[cid] = true
            members[#members + 1] = cid
        end
        if #members >= 16 then break end
    end
    if #members < 2 then resolve({ error = 'fields' }) return end

    local id = MySQL.insert.await(
        'INSERT INTO vphone_groups (name, owner_cid) VALUES (?,?)', { name, p.citizenid })
    for _, cid in ipairs(members) do
        MySQL.insert.await(
            'INSERT IGNORE INTO vphone_group_members (group_id, citizenid) VALUES (?,?)', { id, cid })
    end
    resolve({ ok = true, id = id, name = name })
end)

V.Callback('v-phone:contactSave', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    if type(data and data.id) == 'string' and data.id:match('^required:') then
        resolve({ error = 'required' })
        return
    end
    local name   = tostring((data and data.name) or ''):sub(1, 40)
    local number = tostring((data and data.number) or ''):sub(1, 20)
    if name == '' or number == '' then resolve({ error = 'fields' }) return end
    local fav = (data and data.favourite) and 1 or 0
    -- The rest of the card. A photo is a URL other clients will fetch, so it goes through
    -- the same host gate as a wallpaper.
    local photo = tostring((data and data.photo) or ''):sub(1, 400)
    if photo ~= '' and not wallpaperAllowed(photo) then resolve({ error = 'badhost' }) return end
    local email = tostring((data and data.email) or ''):sub(1, 64)
    local address = tostring((data and data.address) or ''):sub(1, 120)
    local birthday = tostring((data and data.birthday) or ''):sub(1, 20)
    local note = tostring((data and data.note) or ''):sub(1, 300)

    local id = tonumber(data and data.id)
    if id then
        -- Scoped to the owner in SQL, not checked afterwards: an UPDATE that trusted the
        -- id alone would let a client rewrite somebody else's contact list.
        MySQL.update.await([[UPDATE vphone_contacts SET name = ?, number = ?, favourite = ?,
            photo = ?, email = ?, address = ?, birthday = ?, note = ?
            WHERE id = ? AND citizenid = ?]],
            { name, number, fav, photo, email, address, birthday, note, id, p.citizenid })
    else
        id = MySQL.insert.await([[INSERT INTO vphone_contacts
            (citizenid, name, number, favourite, photo, email, address, birthday, note)
            VALUES (?,?,?,?,?,?,?,?,?)]],
            { p.citizenid, name, number, fav, photo, email, address, birthday, note })
    end
    resolve({ ok = true, id = id })
end)

V.Callback('v-phone:contactDelete', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    if type(data and data.id) == 'string' and data.id:match('^required:') then
        resolve({ error = 'required' })
        return
    end
    MySQL.update.await('DELETE FROM vphone_contacts WHERE id = ? AND citizenid = ?',
        { tonumber(data and data.id) or 0, p.citizenid })
    resolve({ ok = true })
end)

V.Callback('v-phone:prefs', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local prefs = prefsOf(p, true)
    local networkWasOn = not prefs.airplane and prefs.cellular ~= false
    if data then
        if data.setupComplete ~= nil then prefs.setupComplete = data.setupComplete == true end
        if data.setupVersion ~= nil then
            prefs.setupVersion = math.max(0, math.min(10, math.floor(num(data.setupVersion, 0))))
        end
        if data.ownerName ~= nil then
            prefs.ownerName = tostring(data.ownerName):gsub('[%c]', ''):sub(1, 40)
        end
        if data.deviceName ~= nil then
            local name = tostring(data.deviceName):gsub('[%c]', ''):sub(1, 32)
            name = name:gsub('[iI][pP][hH][oO][nN][eE]', 'iFruit')
            prefs.deviceName = (name:gsub('%s', '') ~= '') and name or 'iFruit'
        end
        if data.passcode ~= nil then
            local code = tostring(data.passcode)
            if not code:match('^%d%d%d%d%d%d$') then resolve({ error = 'passcode' }) return end
            -- The clear six digits exist only for this callback. Metadata receives a
            -- character-salted SHA-256 digest, never the code the player entered.
            prefs.passcodeHash = passcodeDigest(p, code)
            prefs.securityEnabled = prefs.passcodeHash ~= ''
        end
        if data.securityEnabled ~= nil and data.securityEnabled == true then
            prefs.securityEnabled = tostring(prefs.passcodeHash or '') ~= ''
        end
        if data.faceId ~= nil then
            prefs.faceId = prefs.securityEnabled and data.faceId == true
        end
        if data.wallpaper then
            local selected = wallpaperId(data.wallpaper)
            if not selected then resolve({ error = 'x' }) return end
            prefs.wallpaper = selected
        end
        if data.ringtone  then prefs.ringtone  = tostring(data.ringtone) end
        if data.gridCols ~= nil then prefs.gridCols = math.max(3, math.min(6, math.floor(num(data.gridCols, 4)))) end
        if data.gridRows ~= nil then prefs.gridRows = math.max(3, math.min(7, math.floor(num(data.gridRows, 4)))) end
        if data.alertTone then prefs.alertTone = tostring(data.alertTone) end
        -- A tone link is a URL a client will fetch, so it goes through the same host gate
        -- as a wallpaper. An empty string clears it back to the built-in.
        for _, k in ipairs({ 'ringUrl', 'alertUrl' }) do
            if data[k] ~= nil then
                local url = tostring(data[k]):sub(1, 400)
                if url ~= '' then
                    if not (Config.Sounds and Config.Sounds.allowCustom) then resolve({ error = 'off' }) return end
                    local host = url:match('^https?://([^/]+)')
                    local ok = false
                    for _, h in ipairs(Config.Sounds.hosts or {}) do
                        if host and (host == h or host:sub(-(#h + 1)) == '.' .. h) then ok = true break end
                    end
                    if not ok then resolve({ error = 'badhost' }) return end
                end
                prefs[k] = (url ~= '') and url or nil
            end
        end
        if data.darkMode ~= nil then
            local m = tostring(data.darkMode)
            prefs.darkMode = (m == 'dark' or m == 'light' or m == 'auto') and m or 'light'
            -- Keep the boolean in step so nothing that reads `dark` goes stale.
            if prefs.darkMode ~= 'auto' then prefs.dark = (prefs.darkMode == 'dark') end
        end
        if data.vibrate ~= nil then prefs.vibrate = data.vibrate == true end
        if data.ringVolume ~= nil then prefs.ringVolume = math.max(0, math.min(1, num(data.ringVolume, 0.7))) end
        if data.dnd ~= nil then prefs.dnd = data.dnd == true end
        if data.airplane  ~= nil then prefs.airplane  = data.airplane == true end
        if data.cellular  ~= nil then prefs.cellular  = data.cellular == true end
        if data.wifi      ~= nil then prefs.wifi      = data.wifi == true end
        if data.bluetooth ~= nil then prefs.bluetooth = data.bluetooth == true end
        if data.brightness ~= nil then prefs.brightness = math.max(0.35, math.min(1, num(data.brightness, 1))) end
        if type(data.notifMuted) == 'table' then
            prefs.notifMuted = stringIdList(data.notifMuted, 64)
        end
        if data.dark ~= nil then prefs.dark = data.dark == true end
        if data.wallpaperUrl ~= nil then
            local url = tostring(data.wallpaperUrl):sub(1, 400)
            if url ~= '' and not V.SettingBool('customWallpaper', true) then
                resolve({ error = 'off' }) return
            end
            if url ~= '' and not wallpaperAllowed(url) then resolve({ error = 'badhost' }) return end
            prefs.wallpaperUrl = (url ~= '') and url or nil
        end
        if data.wallFit ~= nil then prefs.wallFit = (data.wallFit == 'contain') and 'contain' or 'cover' end
        if data.size ~= nil then prefs.size = math.max(0.75, math.min(1.15, num(data.size, 1.0))) end
        if data.side ~= nil then prefs.side = (data.side == 'left') and 'left' or 'right' end
        if data.layout ~= nil then
            prefs.layout = cleanLayout(data.layout)
        end
        if data.actionApp ~= nil then
            prefs.actionApp = (data.actionApp ~= '') and tostring(data.actionApp) or nil
        end
        if data.glass ~= nil then
            prefs.glass = math.max(0, math.min(100, math.floor(num(data.glass, Config.DefaultGlass))))
        end
    end
    p.SetMetadata('phone', prefs)
    if networkWasOn and (prefs.airplane or prefs.cellular == false) then
        local id = CallOf[src]
        if id then endCall(id, 'nosignal') end
    end
    local publicPrefs = {}
    for key, value in pairs(prefs) do
        if key ~= 'passcodeHash' then publicPrefs[key] = value end
    end
    resolve({ ok = true, prefs = publicPrefs })
end)

local UnlockAttempts = {}

V.Callback('v-phone:unlock', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local prefs = prefsOf(p, true)
    if not prefs.securityEnabled then resolve({ ok = true }) return end

    local now = os.time()
    local guard = UnlockAttempts[src] or { failures = 0, blockedUntil = 0 }
    if guard.blockedUntil > now then
        resolve({ error = 'locked', retryAfter = guard.blockedUntil - now })
        return
    end

    -- Face ID represents the character already authenticated by the FiveM session.
    -- The passcode remains the fallback and is compared only on the server.
    if data and data.faceId == true and prefs.faceId == true then
        UnlockAttempts[src] = nil
        resolve({ ok = true, method = 'faceId' })
        return
    end

    local code = tostring((data and data.passcode) or '')
    local valid = code:match('^%d%d%d%d%d%d$')
        and passcodeDigest(p, code) == tostring(prefs.passcodeHash or '')
    if valid then
        UnlockAttempts[src] = nil
        resolve({ ok = true, method = 'passcode' })
        return
    end

    guard.failures = guard.failures + 1
    if guard.failures >= 5 then
        guard.failures = 0
        guard.blockedUntil = now + 30
    end
    UnlockAttempts[src] = guard
    resolve({
        error = guard.blockedUntil > now and 'locked' or 'badcode',
        retryAfter = math.max(0, guard.blockedUntil - now),
        attemptsRemaining = math.max(0, 5 - guard.failures),
    })
end)

V.Callback('v-phone:lookup', function(src, resolve, data)
    -- Who a number belongs to, answered only as a name the caller could have learned
    -- anyway. It never returns a citizen id.
    local cid = cidOfNumber(tostring((data and data.number) or ''))
    if not cid then resolve({ error = 'nonumber' }) return end
    local row = MySQL.single.await('SELECT firstname, lastname FROM vphone_characters WHERE citizenid = ?', { cid })
    resolve({ ok = true, name = row and (row.firstname .. ' ' .. row.lastname) or nil })
end)

--- The jobs app is read-only on purpose. `v-cityhall:take` is gated on standing at a
--- desk, and it should stay that way: browsing vacancies from a sofa is fine, signing on
--- from one is not. The list comes from v-cityhall so there is one definition of "open".
V.Callback('v-phone:jobs', function(src, resolve)
    if GetResourceState('v-cityhall') ~= 'started' then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    -- The employment card: not just the job's name, but where the player stands in it.
    -- v-world owns the ladder, so the grade names and pay come from there rather than
    -- from a copy kept here that could disagree with the payslip.
    local name = (p.job and p.job.name) or 'unemployed'
    local level = num(p.job and p.job.grade, 0)
    local me = { name = name, label = name, grade = level, gradeLabel = '', salary = 0, ranks = 0 }

    if exports['v-world']:IsReady() then
        for _, j in ipairs(exports['v-world']:GetJobs() or {}) do
            if j.name == name then
                me.label = j.label or name
                me.type = j.type or 'civ'
                me.ranks = #(j.grades or {})
                for _, g in ipairs(j.grades or {}) do
                    local gl = num(g.grade, g.level or 0)
                    if gl == level then
                        me.gradeLabel = g.name or ''
                        me.salary = num(g.salary, 0)
                    end
                end
                -- The rungs above and below, so a player can see where promotion leads.
                me.ladder = {}
                for _, g in ipairs(j.grades or {}) do
                    me.ladder[#me.ladder + 1] = {
                        grade = num(g.grade, g.level or 0),
                        name = g.name or '',
                        salary = num(g.salary, 0),
                    }
                end
                table.sort(me.ladder, function(a, b) return a.grade < b.grade end)
                break
            end
        end
    end

    resolve({
        ok = true,
        jobs = V.Use('v-cityhall').OpenPositions() or {},
        current = name,
        me = me,
    })
end)

--- Per app, per character. An app that wants to remember something needs no table, no
--- migration and no server file: it calls Phone.storage.set and the value is here next
--- session. Values are stored as text; anything structured is the app's own JSON,
--- because guessing at a schema for somebody else's data helps nobody.
V.Callback('v-phone:storage', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = tostring((data and data.app) or ''):gsub('[^%w_-]', ''):sub(1, 40)
    if app == '' then resolve({ error = 'forbidden' }) return end
    local op = tostring((data and data.op) or 'get')

    if op == 'all' then
        local out = {}
        for _, r in ipairs(MySQL.query.await(
            'SELECT k, v FROM vphone_app_data WHERE citizenid = ? AND app = ?',
            { p.citizenid, app }) or {}) do out[r.k] = r.v end
        resolve({ ok = true, values = out })
        return
    end

    if op == 'clear' then
        MySQL.update.await('DELETE FROM vphone_app_data WHERE citizenid = ? AND app = ?',
            { p.citizenid, app })
        resolve({ ok = true })
        return
    end

    local key = tostring((data and data.key) or ''):sub(1, 60)
    if key == '' then resolve({ error = 'key' }) return end

    if op == 'remove' then
        MySQL.update.await('DELETE FROM vphone_app_data WHERE citizenid = ? AND app = ? AND k = ?',
            { p.citizenid, app, key })
        resolve({ ok = true })
        return
    end

    if op == 'set' then
        local value = data.value
        if type(value) == 'table' then value = json.encode(value) end
        value = tostring(value == nil and '' or value):sub(1, 4000)
        MySQL.query.await([[INSERT INTO vphone_app_data (citizenid, app, k, v) VALUES (?,?,?,?)
            ON DUPLICATE KEY UPDATE v = VALUES(v)]], { p.citizenid, app, key, value })
        resolve({ ok = true })
        return
    end

    resolve({ ok = true, value = MySQL.scalar.await(
        'SELECT v FROM vphone_app_data WHERE citizenid = ? AND app = ? AND k = ?',
        { p.citizenid, app, key }) })
end)

--- Everywhere the map already shows. v-world owns every one of these lists, and each is
--- public information: these are places with blips on them, not secrets. The app turns a
--- row into a waypoint, which is the one thing a phone map is actually for.
local PLACE_SOURCES = {
    { key = 'garage',   getter = 'GetGarages',       icon = 'garage' },
    { key = 'shop',     getter = 'GetShopLocations', icon = 'cart' },
    { key = 'station',  getter = 'GetStations',      icon = 'fuel' },
    { key = 'mechanic', getter = 'GetMechShops',     icon = 'wrench' },
    { key = 'cityhall', getter = 'GetCityHalls',     icon = 'jobs' },
    { key = 'dealer',   getter = 'GetDealers',       icon = 'garage' },
}

--- Install or remove an app for THIS character. It cannot make an app appear that the
--- operator has not permitted, and it cannot remove one the phone needs to work: those
--- are the operator's decision and the phone's, not the player's.
--- The camera's gallery. Only ever URLs: the upload target the operator configured
--- returns one, and a data URI would be megabytes of base64 in a metadata column.
-- ══════════════════════════════════════════════════════════════
-- Notes
-- ══════════════════════════════════════════════════════════════
-- Native now rather than a sample resource: notes are the one thing on a phone people
-- expect to survive everything else, so they live with the phone's own data.
V.Callback('v-phone:notes', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local op = tostring((data and data.op) or 'list')

    if op == 'list' then
        resolve({ ok = true, notes = MySQL.query.await(
            'SELECT id, title, body, at FROM vphone_notes WHERE citizenid = ? ORDER BY id DESC LIMIT 100',
            { p.citizenid }) or {} })
        return
    end
    if op == 'save' then
        local title = tostring((data and data.title) or ''):sub(1, 80)
        local bodyTxt = tostring((data and data.body) or ''):sub(1, 4000)
        if title == '' and bodyTxt == '' then resolve({ error = 'empty' }) return end
        if title == '' then title = bodyTxt:sub(1, 40) end
        local id = math.floor(num(data and data.id, 0))
        if id > 0 then
            MySQL.update.await('UPDATE vphone_notes SET title = ?, body = ? WHERE id = ? AND citizenid = ?',
                { title, bodyTxt, id, p.citizenid })
        else
            id = MySQL.insert.await('INSERT INTO vphone_notes (citizenid, title, body) VALUES (?,?,?)',
                { p.citizenid, title, bodyTxt })
        end
        resolve({ ok = true, id = id })
        return
    end
    if op == 'del' then
        MySQL.update('DELETE FROM vphone_notes WHERE id = ? AND citizenid = ?',
            { math.floor(num(data and data.id, 0)), p.citizenid })
        resolve({ ok = true })
        return
    end
    resolve({ error = 'x' })
end)

V.Callback('v-phone:photo', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local op = tostring((data and data.op) or 'list')
    if op == 'add' and not V.SettingBool('camera', false) then
        resolve({ error = 'off' }) return
    end

    local shots = p.GetMetadata('photos')
    if type(shots) ~= 'table' then shots = {} end

    -- A photo used to be a bare URL. It is a row now - url, album, filter - and old
    -- string entries are lifted into one as they are read, so nobody loses a picture.
    local changed = false
    for i, v in ipairs(shots) do
        if type(v) == 'string' then shots[i] = { url = v, album = '', filter = '' } changed = true end
    end

    if op == 'add' then
        local url = tostring((data and data.url) or ''):sub(1, 400)
        if url == '' then resolve({ error = 'x' }) return end
        if not wallpaperAllowed(url) then resolve({ error = 'badhost' }) return end
        table.insert(shots, 1, { url = url, album = '', filter = '' })
        while #shots > 60 do table.remove(shots) end     -- a gallery, not an archive
        changed = true
    elseif op == 'del' then
        local i = math.floor(num(data and data.index, 0))
        if shots[i] then table.remove(shots, i) changed = true end
    elseif op == 'edit' then
        -- Retouching is a stored filter name, not a re-encoded image: the phone never
        -- holds pixels, only the link and how to draw it.
        local i = math.floor(num(data and data.index, 0))
        if shots[i] then
            if data.album ~= nil then shots[i].album = tostring(data.album):sub(1, 40) end
            if data.filter ~= nil then shots[i].filter = tostring(data.filter):sub(1, 20) end
            changed = true
        end
    elseif op == 'album' then
        -- Renaming or emptying an album, across every photo that carries it.
        local from = tostring((data and data.from) or '')
        local to = tostring((data and data.to) or ''):sub(1, 40)
        for _, sh in ipairs(shots) do
            if sh.album == from then sh.album = to changed = true end
        end
    end
    if changed then p.SetMetadata('photos', shots) end

    -- The albums that actually exist, worked out from the photos rather than kept in a
    -- second list that could disagree with them.
    local albums, seen = {}, {}
    for _, sh in ipairs(shots) do
        if sh.album and sh.album ~= '' and not seen[sh.album] then
            seen[sh.album] = true
            albums[#albums + 1] = sh.album
        end
    end
    table.sort(albums)
    resolve({ ok = true, photos = shots, albums = albums })
end)

local function ownsPhoto(p, url)
    local shots = p and p.GetMetadata('photos')
    if type(shots) ~= 'table' then return false end
    for _, shot in ipairs(shots) do
        local stored = type(shot) == 'table' and shot.url or shot
        if tostring(stored or '') == url then return true end
    end
    return false
end

-- ══════════════════════════════════════════════════════════════
-- AirDrop
-- Send a contact, a number or a photo to a nearby phone. Both ends need Bluetooth on and
-- to be within range - the two conditions the real feature needs to see a device at all.
-- Every offer is a handshake: the sender proposes, the receiver accepts, and only then
-- does anything land. Nothing is written to a phone that did not say yes.
-- ══════════════════════════════════════════════════════════════
local AirOffers = {}     -- [offerId] = { from, to, kind, payload, at }
local AirLastSend = {}
local airSeq = 0

local function btOn(pl)
    if not pl then return false end
    local m = pl.GetMetadata('phone')
    return type(m) == 'table' and m.bluetooth == true
end

local function coordsOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function airRange()
    return (Config.Airdrop and Config.Airdrop.range) or 12.0
end

local function airOfferTtl()
    return math.max(1, tonumber(Config.Airdrop and Config.Airdrop.offerTtl) or 30)
end

-- Who this player could AirDrop to right now: online, Bluetooth on, and close enough.
V.Callback('v-phone:airdropScan', function(src, resolve)
    local me = Core.GetPlayer(src)
    if not me then resolve(false) return end
    if not phoneReachable(src) then resolve({ error = 'gone' }) return end
    if not btOn(me) then resolve({ error = 'bt' }) return end
    local c0 = coordsOf(src)
    if not c0 then resolve({ ok = true, devices = {} }) return end

    local out = {}
    for _, sid in ipairs(GetPlayers()) do
        local tid = tonumber(sid)
        if tid and tid ~= src then
            local tp = Core.GetPlayer(tid)
            if tp and phoneReachable(tid) and btOn(tp) then
                local c = coordsOf(tid)
                if c and #(c0 - c) <= airRange() then
                    out[#out + 1] = {
                        id = tid,
                        name = prefsOf(tp).deviceName or tp.name or 'iFruit',
                    }
                end
            end
        end
    end
    resolve({ ok = true, devices = out })
end)

-- Propose a transfer. Validated at BOTH ends: the receiver has to still be discoverable
-- and in range, so a stale device list cannot push anything onto a phone that walked off.
V.Callback('v-phone:airdropSend', function(src, resolve, data)
    local me = Core.GetPlayer(src)
    if not me then resolve(false) return end
    if not phoneReachable(src) then resolve({ error = 'gone' }) return end
    if not btOn(me) then resolve({ error = 'bt' }) return end

    local to = tonumber(data and data.to)
    local tp = to and Core.GetPlayer(to)
    if to == src or not tp or not phoneReachable(to) or not btOn(tp) then
        resolve({ error = 'gone' }) return
    end

    local c0, c1 = coordsOf(src), coordsOf(to)
    if not c0 or not c1 or #(c0 - c1) > airRange() then resolve({ error = 'range' }) return end

    local kind = tostring((data and data.kind) or '')
    local pin = (data and data.payload) or {}
    local payload
    if kind == 'contact' or kind == 'number' then
        payload = { name = tostring(pin.name or ''):sub(1, 40), number = tostring(pin.number or ''):sub(1, 20) }
        if payload.number == '' then resolve({ error = 'x' }) return end
    elseif kind == 'photo' then
        payload = { url = tostring(pin.url or ''):sub(1, 400) }
        if payload.url == '' or not wallpaperAllowed(payload.url) or not ownsPhoto(me, payload.url) then
            resolve({ error = 'x' }) return
        end
    else
        resolve({ error = 'x' }) return
    end

    local now = GetGameTimer()
    local last = AirLastSend[src]
    local outstanding = 0
    for _, pending in pairs(AirOffers) do
        if pending.from == src then outstanding = outstanding + 1 end
    end
    if (last and now - last < 800) or outstanding >= 3 then
        resolve({ error = 'busy' }) return
    end
    AirLastSend[src] = now

    airSeq = airSeq + 1
    local offerId = airSeq
    local offer = { from = src, to = to, kind = kind, payload = payload, at = os.time() }
    AirOffers[offerId] = offer

    -- A receiver may ignore the prompt or disconnect. Retire the exact offer object so
    -- abandoned handshakes cannot accumulate for the lifetime of the resource.
    SetTimeout(math.floor(airOfferTtl() * 1000), function()
        if AirOffers[offerId] == offer then AirOffers[offerId] = nil end
    end)

    local preview = (kind == 'photo') and payload.url
        or (payload.name ~= '' and (payload.name .. ' - ' .. payload.number) or payload.number)
    TriggerClientEvent('v-phone:client:airdrop', to,
        {
            offerId = offerId, from = me.name or 'iFruit', kind = kind, preview = preview,
            ttlMs = math.floor(airOfferTtl() * 1000),
        })
    resolve({ ok = true })
end)

-- Accept or decline. On accept the payload is applied to the RECEIVER, never the sender's
-- word for it: a contact/number becomes a row in their book, a photo enters their gallery.
V.Callback('v-phone:airdropRespond', function(src, resolve, data)
    local id = tonumber(data and data.offerId)
    local o = id and AirOffers[id]
    if not o or o.to ~= src then resolve({ error = 'gone' }) return end
    AirOffers[id] = nil

    -- Expired offers are simply dropped.
    if (os.time() - o.at) > airOfferTtl() then
        resolve({ error = 'gone' }) return
    end

    if not (data and data.accept) then
        if o.from and GetPlayerName(o.from) then
            TriggerClientEvent('v-phone:client:airdropResult', o.from, { ok = false })
        end
        resolve({ ok = true, declined = true }) return
    end

    local rp = Core.GetPlayer(src)
    local sp = Core.GetPlayer(o.from)
    if not rp or not sp or not phoneReachable(src) or not phoneReachable(o.from)
        or not btOn(rp) or not btOn(sp) then
        resolve({ error = 'gone' }) return
    end
    local senderCoords, receiverCoords = coordsOf(o.from), coordsOf(src)
    if not senderCoords or not receiverCoords or #(senderCoords - receiverCoords) > airRange() then
        resolve({ error = 'range' }) return
    end

    if o.kind == 'photo' then
        local shots = rp.GetMetadata('photos')
        if type(shots) ~= 'table' then shots = {} end
        table.insert(shots, 1, { url = o.payload.url, album = '', filter = '' })
        while #shots > 60 do table.remove(shots) end
        rp.SetMetadata('photos', shots)
    else
        local nm = o.payload.name ~= '' and o.payload.name or o.payload.number
        MySQL.insert.await(
            'INSERT INTO vphone_contacts (citizenid, name, number, favourite) VALUES (?, ?, ?, 0)',
            { rp.citizenid, nm, o.payload.number })
    end

    if o.from and GetPlayerName(o.from) then
        TriggerClientEvent('v-phone:client:airdropResult', o.from, { ok = true, name = rp.name or '' })
    end
    resolve({ ok = true })
end)

V.Callback('v-phone:install', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id = tostring((data and data.app) or '')
    local want = data and data.install == true

    local available = appsFor(src, p)
    local found
    for _, a in ipairs(available) do if a.id == id then found = a break end end
    if not found then resolve({ error = 'unavailable' }) return end
    if found.required and not want then resolve({ error = 'required' }) return end

    local prefs = prefsOf(p)
    -- Two lists because the two kinds start from opposite defaults: a stock app is
    -- recorded when it LEAVES, an optional one when it ARRIVES.
    local key = found.optional and 'added' or 'removed'
    local keep = found.optional and want or (not want)

    local out = {}
    for _, rid in ipairs(prefs[key] or {}) do
        if rid ~= id then out[#out + 1] = rid end
    end
    if keep then out[#out + 1] = id end
    prefs[key] = out
    p.SetMetadata('phone', prefs)
    resolve({ ok = true })
end)

V.Callback('v-phone:places', function(src, resolve)
    if GetResourceState('v-world') ~= 'started' then resolve({ error = 'off' }) return end
    local world = V.Use('v-world')
    local out = {}
    for _, src2 in ipairs(PLACE_SOURCES) do
        for _, r in ipairs(world[src2.getter]() or {}) do
            -- A disabled row is one the operator switched off; it should not be on a map
            -- either, or the phone contradicts the world.
            if r.enabled ~= 0 and r.enabled ~= false and r.x then
                out[#out + 1] = {
                    kind = src2.key, icon = src2.icon,
                    label = r.label or r.id or src2.key,
                    x = r.x, y = r.y, z = r.z or 0.0,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return tostring(a.label) < tostring(b.label)
    end)
    resolve({ ok = true, places = out })
end)

-- The player's recent calls, newest first, capped. The number comes back raw; the app
-- resolves it to a contact name the same way every other screen does.
-- ══════════════════════════════════════════════════════════════
-- Mail
-- ══════════════════════════════════════════════════════════════
-- An address is chosen once and belongs to the character, like the number. Everything
-- else is a mailbox row: one per copy of a message, so the sender's Sent, each
-- recipient's Inbox and a draft are the same mail seen from different sides. Deleting
-- your copy never touches anybody else's.
local function mailAddressOf(cid)
    return MySQL.scalar.await('SELECT address FROM vphone_mail_accounts WHERE citizenid = ?', { cid })
end

local function cidOfAddress(addr)
    return MySQL.scalar.await('SELECT citizenid FROM vphone_mail_accounts WHERE address = ?', { addr })
end

--- Rows in a folder, newest first, with the mail they point at.
local function mailbox(addr, folder)
    return MySQL.query.await([[SELECT b.id AS box_id, b.folder, b.seen, b.saved,
               m.id AS mail_id, m.from_addr, m.to_addr, m.subject, m.body, m.at, m.reply_to
        FROM vphone_mail_box b JOIN vphone_mail m ON m.id = b.mail_id
        WHERE b.address = ? AND b.folder = ? ORDER BY b.id DESC LIMIT 60]], { addr, folder }) or {}
end

V.Callback('v-phone:mail', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local op = tostring((data and data.op) or 'me')
    local mine = mailAddressOf(p.citizenid)

    if op == 'me' then
        resolve({ ok = true, address = mine, domains = Config.Mail.domains })
        return
    end

    -- One address, chosen once. It is the account other people will write to, which is
    -- exactly why it cannot be edited away afterwards.
    if op == 'create' then
        if mine then resolve({ error = 'exists' }) return end
        local localpart = tostring((data and data.localpart) or ''):lower():gsub('[^%w%._-]', '')
        if #localpart < Config.Mail.localMin or #localpart > Config.Mail.localMax then
            resolve({ error = 'address' }) return
        end
        local domain = tostring((data and data.domain) or '')
        local okDomain = false
        for _, d in ipairs(Config.Mail.domains) do if d == domain then okDomain = true break end end
        if not okDomain then resolve({ error = 'domain' }) return end

        local addr = localpart .. '@' .. domain
        if MySQL.scalar.await('SELECT 1 FROM vphone_mail_accounts WHERE address = ?', { addr }) then
            resolve({ error = 'taken' }) return
        end
        MySQL.insert.await('INSERT INTO vphone_mail_accounts (citizenid, address) VALUES (?,?)',
            { p.citizenid, addr })
        resolve({ ok = true, address = addr })
        return
    end

    if not mine then resolve({ error = 'noaccount' }) return end

    if op == 'list' then
        local folder = tostring((data and data.folder) or 'inbox')
        if folder ~= 'inbox' and folder ~= 'sent' and folder ~= 'draft' then folder = 'inbox' end
        resolve({ ok = true, mail = mailbox(mine, folder),
                  unread = tonumber(MySQL.scalar.await(
                      'SELECT COUNT(*) FROM vphone_mail_box WHERE address = ? AND folder = ? AND seen = 0',
                      { mine, 'inbox' })) or 0 })
        return
    end

    -- Everything the player keeps, whatever folder it came from.
    if op == 'saved' then
        resolve({ ok = true, mail = MySQL.query.await([[SELECT b.id AS box_id, b.folder, b.seen, b.saved,
                   m.id AS mail_id, m.from_addr, m.to_addr, m.subject, m.body, m.at, m.reply_to
            FROM vphone_mail_box b JOIN vphone_mail m ON m.id = b.mail_id
            WHERE b.address = ? AND b.saved = 1 ORDER BY b.id DESC LIMIT 60]], { mine }) or {} })
        return
    end

    if op == 'seen' then
        MySQL.update('UPDATE vphone_mail_box SET seen = 1 WHERE id = ? AND address = ?',
            { math.floor(num(data and data.boxId, 0)), mine })
        resolve({ ok = true })
        return
    end

    if op == 'save' then
        MySQL.update('UPDATE vphone_mail_box SET saved = ? WHERE id = ? AND address = ?',
            { (data and data.saved) and 1 or 0, math.floor(num(data and data.boxId, 0)), mine })
        resolve({ ok = true })
        return
    end

    -- Only ever your own copy. The mail row itself stays for whoever else holds it.
    if op == 'del' then
        MySQL.update('DELETE FROM vphone_mail_box WHERE id = ? AND address = ?',
            { math.floor(num(data and data.boxId, 0)), mine })
        resolve({ ok = true })
        return
    end

    if op == 'send' or op == 'draft' then
        local subject = tostring((data and data.subject) or ''):sub(1, Config.Mail.maxSubject)
        local bodyTxt = tostring((data and data.body) or ''):sub(1, Config.Mail.maxBody)
        local replyTo = math.floor(num(data and data.replyTo, 0))

        -- Recipients arrive as one field; a group mail is simply more than one of them.
        local raw = tostring((data and data.to) or '')
        local to, seen = {}, {}
        for tok in raw:gmatch('[^,;%s]+') do
            local a = tok:lower()
            if not seen[a] and #to < Config.Mail.maxTo then seen[a] = true to[#to + 1] = a end
        end

        -- A draft is yours alone: it needs neither a recipient nor a subject yet.
        if op == 'draft' then
            if bodyTxt == '' and subject == '' and #to == 0 then resolve({ error = 'empty' }) return end
            local prev = math.floor(num(data and data.boxId, 0))
            if prev > 0 then
                -- Replacing the draft you were editing rather than stacking a new one.
                local mid = MySQL.scalar.await(
                    'SELECT mail_id FROM vphone_mail_box WHERE id = ? AND address = ? AND folder = ?',
                    { prev, mine, 'draft' })
                if mid then
                    MySQL.update.await('UPDATE vphone_mail SET to_addr = ?, subject = ?, body = ? WHERE id = ?',
                        { table.concat(to, ', '), subject, bodyTxt, mid })
                    resolve({ ok = true }) return
                end
            end
            local mid = MySQL.insert.await(
                'INSERT INTO vphone_mail (from_addr, to_addr, subject, body, reply_to) VALUES (?,?,?,?,?)',
                { mine, table.concat(to, ', '), subject, bodyTxt, replyTo > 0 and replyTo or nil })
            MySQL.insert.await(
                'INSERT INTO vphone_mail_box (mail_id, address, folder, seen) VALUES (?,?,?,1)',
                { mid, mine, 'draft' })
            resolve({ ok = true })
            return
        end

        if #to == 0 then resolve({ error = 'noto' }) return end
        if bodyTxt == '' and subject == '' then resolve({ error = 'empty' }) return end

        -- Every address has to exist. Half-delivering a group mail and saying nothing
        -- would be worse than refusing it.
        local targets = {}
        for _, a in ipairs(to) do
            local cid = cidOfAddress(a)
            if not cid then resolve({ error = 'noaddr', address = a }) return end
            targets[#targets + 1] = { addr = a, cid = cid }
        end

        local mid = MySQL.insert.await(
            'INSERT INTO vphone_mail (from_addr, to_addr, subject, body, reply_to) VALUES (?,?,?,?,?)',
            { mine, table.concat(to, ', '), subject, bodyTxt, replyTo > 0 and replyTo or nil })

        MySQL.insert.await('INSERT INTO vphone_mail_box (mail_id, address, folder, seen) VALUES (?,?,?,1)',
            { mid, mine, 'sent' })
        for _, t in ipairs(targets) do
            MySQL.insert.await('INSERT INTO vphone_mail_box (mail_id, address, folder, seen) VALUES (?,?,?,0)',
                { mid, t.addr, 'inbox' })
            local tnum = numberOfCid(t.cid)
            local online = tnum and Online[tnum]
            if online then
                TriggerClientEvent('v-phone:client:banner', online, {
                    app = 'mail', title = subject ~= '' and subject or L(online, 'ph.mail_new'),
                    body = mine, hasItem = requireItem(online),
                })
            end
        end

        -- The draft it grew out of has served its purpose.
        local prev = math.floor(num(data and data.boxId, 0))
        if prev > 0 then
            MySQL.update('DELETE FROM vphone_mail_box WHERE id = ? AND address = ? AND folder = ?',
                { prev, mine, 'draft' })
        end
        resolve({ ok = true })
        return
    end

    resolve({ error = 'x' })
end)

-- ══════════════════════════════════════════════════════════════
-- Voicemail
-- ══════════════════════════════════════════════════════════════
-- A missed call is an invitation to leave a message. It is written rather than recorded,
-- which is the only honest way to do it here: nothing on the server can hold audio, and a
-- note the other person can actually read beats a fake tape.
V.Callback('v-phone:voicemail', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local op = tostring((data and data.op) or 'list')

    if op == 'list' then
        local rows = MySQL.query.await([[SELECT id, from_num AS number, body, seen, at
            FROM vphone_voicemail WHERE citizenid = ? ORDER BY id DESC LIMIT 40]], { p.citizenid }) or {}
        resolve({ ok = true, voicemail = rows })
        return
    end

    if op == 'seen' then
        MySQL.update('UPDATE vphone_voicemail SET seen = 1 WHERE citizenid = ? AND seen = 0', { p.citizenid })
        resolve({ ok = true })
        return
    end

    if op == 'del' then
        MySQL.update('DELETE FROM vphone_voicemail WHERE id = ? AND citizenid = ?',
            { math.floor(num(data and data.id, 0)), p.citizenid })
        resolve({ ok = true })
        return
    end

    if op == 'leave' then
        if not V.SettingBool('voicemail', true) then resolve({ error = 'off' }) return end
        local toNumber = tostring((data and data.number) or '')
        local toCid = cidOfNumber(toNumber)
        if not toCid then resolve({ error = 'nonumber' }) return end
        local body = tostring((data and data.body) or ''):sub(1, math.floor(num(S('voicemailMax', 200), 200)))
        if body == '' then resolve({ error = 'empty' }) return end

        MySQL.insert.await('INSERT INTO vphone_voicemail (citizenid, from_num, body) VALUES (?,?,?)',
            { toCid, numberOfCid(p.citizenid) or '', body })

        -- Tell them now if they are on; otherwise it is waiting when they next look.
        local target = Online[toNumber]
        if target then
            TriggerClientEvent('v-phone:client:banner', target, {
                app = 'phone', title = L(target, 'ph.vm_new'),
                body = (numberOfCid(p.citizenid) or ''), hasItem = requireItem(target),
            })
        end
        resolve({ ok = true })
        return
    end

    resolve({ error = 'x' })
end)

-- ══════════════════════════════════════════════════════════════
-- Health record
-- ══════════════════════════════════════════════════════════════
-- What a real Health app keeps and the game cannot work out for itself: blood type,
-- allergies, conditions, an emergency contact. Stored on the character, so it is the same
-- record whatever happens to the handset. Steps come from the client, which is the only
-- side that knows how far somebody actually walked.
V.Callback('v-phone:health', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local rec = p.GetMetadata('healthrec')
    if type(rec) ~= 'table' then rec = {} end

    local op = tostring((data and data.op) or 'get')
    if op == 'set' then
        if data.blood    ~= nil then rec.blood    = tostring(data.blood):sub(1, 6) end
        if data.allergies ~= nil then rec.allergies = tostring(data.allergies):sub(1, 300) end
        if data.conditions ~= nil then rec.conditions = tostring(data.conditions):sub(1, 300) end
        if data.meds     ~= nil then rec.meds     = tostring(data.meds):sub(1, 300) end
        if data.donor    ~= nil then rec.donor    = data.donor == true end
        if data.ice      ~= nil then rec.ice      = tostring(data.ice):sub(1, 60) end
        p.SetMetadata('healthrec', rec)
    elseif op == 'steps' then
        -- The client reports distance walked; the record keeps the day's total.
        local add = math.max(0, math.floor(num(data and data.steps, 0)))
        local day = os.date('%Y-%m-%d')
        if rec.stepDay ~= day then rec.stepDay = day rec.steps = 0 end
        rec.steps = math.min(200000, (tonumber(rec.steps) or 0) + add)
        p.SetMetadata('healthrec', rec)
    end

    local day = os.date('%Y-%m-%d')
    if rec.stepDay ~= day then rec.steps = 0 end
    resolve({ ok = true, record = rec })
end)

-- ══════════════════════════════════════════════════════════════
-- Speaker
-- ══════════════════════════════════════════════════════════════
-- The phone is on speaker, so the people standing next to you hear the call. Each call has
-- its own voice channel, so putting one on speaker never leaks any other conversation.
local Speaker = {}      -- [callId] = { on = true, heard = { [src] = true } }

local function speakerRange()
    return num(Config.Calls.speakerRange, 8.0)
end

--- Re-work out who is close enough, and add or drop them.
local function speakerSync(id)
    local st = Speaker[id]
    local c = Calls[id]
    if not st or not c or c.state ~= 'active' then return end

    local near = {}
    for _, holder in ipairs({ c.a, c.b }) do
        local ped = holder and GetPlayerPed(holder)
        local at = ped and ped ~= 0 and GetEntityCoords(ped) or nil
        if at then
            for _, sid in ipairs(GetPlayers()) do
                local t = tonumber(sid)
                if t and t ~= c.a and t ~= c.b then
                    local tp = GetPlayerPed(t)
                    if tp and tp ~= 0 and #(GetEntityCoords(tp) - at) <= speakerRange() then
                        near[t] = true
                    end
                end
            end
        end
    end

    for t in pairs(near) do
        if not st.heard[t] then
            st.heard[t] = true
            TriggerClientEvent('v-phone:client:speaker', t, { id = id, on = true })
        end
    end
    for t in pairs(st.heard) do
        if not near[t] then
            st.heard[t] = nil
            TriggerClientEvent('v-phone:client:speaker', t, { id = id, on = false })
        end
    end
end

speakerOff = function(id)
    local st = Speaker[id]
    if not st then return end
    for t in pairs(st.heard) do
        TriggerClientEvent('v-phone:client:speaker', t, { id = id, on = false })
    end
    Speaker[id] = nil
end

V.Callback('v-phone:speaker', function(src, resolve, data)
    local id = CallOf[src]
    local c = id and Calls[id]
    if not c or c.state ~= 'active' then resolve({ error = 'nocall' }) return end
    local on = data and data.on == true

    if not on then speakerOff(id) resolve({ ok = true, on = false }) return end

    if Speaker[id] then
        speakerSync(id)
        resolve({ ok = true, on = true })
        return
    end
    local speakerState = { heard = {} }
    local callRecord = c
    Speaker[id] = speakerState
    speakerSync(id)
    -- People walk. Re-checked while it is on, so somebody who wanders over hears it and
    -- somebody who wanders off stops.
    CreateThread(function()
        while Speaker[id] == speakerState and Calls[id] == callRecord
            and callRecord.state == 'active' do
            speakerSync(id)
            Wait(2500)
        end
        if Speaker[id] == speakerState then speakerOff(id) end
    end)
    resolve({ ok = true, on = true })
end)

V.Callback('v-phone:calls', function(src, resolve)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local rows = MySQL.query.await([[SELECT other_num AS number, direction, answered, at
        FROM vphone_calls WHERE citizenid = ? ORDER BY id DESC LIMIT 60]], { p.citizenid }) or {}
    resolve({ ok = true, calls = rows })
end)

V.Callback('v-phone:call', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id, err = startCall(src, p, tostring((data and data.number) or ''),
        data and data.anonymous, data and data.video == true)
    if not id then resolve({ error = err }) return end
    resolve({ ok = true, id = id })
end)

V.Callback('v-phone:answer', function(src, resolve)
    resolve({ ok = answerCall(src) })
end)

V.Callback('v-phone:hangup', function(src, resolve)
    local id = CallOf[src]
    if id then endCall(id, 'hangup') end
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Exports for other modules
-- ══════════════════════════════════════════════════════════════
exports('GetNumber',     function(cid) return numberOfCid(tostring(cid or '')) end)
exports('NumberOf',      function(src)
    local p = Core.GetPlayer(src)
    return p and numberOfCid(p.citizenid) or nil
end)
exports('FindByNumber',  function(number) return cidOfNumber(tostring(number or '')) end)
exports('IsOnline',      function(number) return Online[tostring(number or '')] ~= nil end)
exports('IsOnCall',      function(src) return CallOf[src] ~= nil end)

--- A notification banner on somebody's phone. The one thing another module usually wants
--- from a phone, and the reason it is an export rather than an event: the caller gets a
--- yes/no back instead of shouting into the void.
exports('Notify', function(src, app, title, body)
    if not Core.GetPlayer(src) then return false end
    TriggerClientEvent('v-phone:client:banner', src, {
        app = tostring(app or ''), title = tostring(title or ''), body = tostring(body or ''),
        hasItem = requireItem(src),
    })
    return true
end)

-- ══════════════════════════════════════════════════════════════
-- Lifecycle
-- ══════════════════════════════════════════════════════════════
-- A power bank is one charge, and then it is gone. Registered only if the item exists,
-- so a server that removed it from the catalogue does not get a usable item pointing at
-- nothing.
CreateThread(function()
    while GetResourceState('v-inventory') ~= 'started' do Wait(200) end
    Wait(1500)
    V.Use('v-inventory').RegisterUsableItem('powerbank', function(src)
        local amount = math.floor(tonumber(V.Setting('powerbankCharge', 45)) or 45)
        if batteryOf(src) >= 100 then
            Core.Notify(src, L(src, 'ph.battery_full'), 'info')
            return
        end
        if not V.Use('v-inventory').RemoveItem(src, 'powerbank', 1) then return end
        setBattery(src, batteryOf(src) + amount)
        Core.Notify(src, (L(src, 'ph.powerbank_used')):format(amount), 'success')
    end)
end)

RegisterNetEvent('v-phone:server:screen', function(on)
    local src = source
    Open[src] = on and true or nil
    if not on then CipherUnlocked[src] = nil end

    -- Replicated, so another RESOURCE can ask whether the phone is up without going
    -- through an export and a round trip. `IsPhoneOpen` in api.lua reads this.
    local state = Player(src) and Player(src).state
    if state then state:set('phoneOpen', on and true or false, true) end

    -- And announced, so a script can react rather than poll.
    local p = Core.GetPlayer(src)
    TriggerEvent(on and 'v-phone:phoneOpened' or 'v-phone:phoneClosed', src, p and p.citizenid or nil)
end)

V.Callback('v-phone:callState', function(src, resolve)
    if not Core.GetPlayer(src) then resolve(false) return end
    resolve({ ok = true, call = currentCallFor(src) or false })
end)

local function hydratePlayer(src, player)
    if not player then return end
    ensureNumber(src, player)
    local saved = player.GetMetadata('battery')
    Battery[src] = V.SettingBool('battery', true)
        and ((type(saved) == 'number') and math.max(0, math.min(100, saved)) or 100)
        or 100
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local coords = GetEntityCoords(ped)
        Signal[src] = signalAt(coords)
        Charging[src] = chargeRateAt(src, ped, coords) > 0
    else
        Signal[src], Charging[src] = 4, false
    end
    TriggerClientEvent('v-phone:client:prefsSync', src, prefsOf(player))
    pushPower(src)
end

AddEventHandler('v-core:server:onPlayerLoaded', function(src, player)
    if Core then hydratePlayer(src, player) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local p = Core.GetPlayer(src)
    if p and Battery[src] then p.SetMetadata('battery', math.floor(Battery[src])) end
    Battery[src], Signal[src], Charging[src], Open[src] = nil, nil, nil, nil
    ExternalCharge[src] = nil
    MessageLastSend[src], MessageBusy[src] = nil, nil
    CipherUnlocked[src], CipherAttempts[src], CipherLastSend[src] = nil, nil, nil
    AirLastSend[src] = nil
    UnlockAttempts[src] = nil
    for offerId, offer in pairs(AirOffers) do
        if offer.from == src or offer.to == src then AirOffers[offerId] = nil end
    end
    local id = CallOf[src]
    if id then endCall(id, 'dropped') end
    for n, s in pairs(Online) do if s == src then Online[n] = nil end end
end)

AddEventHandler('v-world:server:changed', function(domain)
    if domain == 'apps' or not domain then loadWorldApps() end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() or not Core then return end
    for _, raw in ipairs(GetPlayers()) do
        local src = tonumber(raw)
        local player = src and Core.GetPlayer(src)
        if player and Battery[src] then
            player.SetMetadata('battery', math.floor(Battery[src]))
        end
    end
end)

CreateThread(function()
    -- The bridge decides which framework is running and publishes `Core`. There is
    -- nothing else to wait for: no core resource, no module registry.
    local ready = false
    V.Ready(function() ready = true end)
    while not ready do Wait(50) end
    Core = _G.Core

    -- Before a single table is created: move an earlier build's tables to the vphone_
    -- prefix, so an existing server keeps its data and a fresh one does nothing.
    Bridge.MigrateTables()

    -- The two tables the bridge owns: per-character storage, and the projection of
    -- whoever the framework says these characters are.
    Bridge.KvBoot()
    Bridge.CharactersBoot()
    -- Media hosting (photos/video on a CDN) with its own expiry sweep. A no-op table
    -- and no sweep when Config.Media is off, so it costs nothing unused.
    if Bridge.MediaBoot then Bridge.MediaBoot() end

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_contacts` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(16)  NOT NULL,
        `name`      VARCHAR(40)  NOT NULL,
        `number`    VARCHAR(20)  NOT NULL,
        `favourite` TINYINT(1)   NOT NULL DEFAULT 0,
        PRIMARY KEY (`id`),
        KEY `citizenid` (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_messages` (
        `id`       INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `from_cid` VARCHAR(16)  NOT NULL,
        `to_cid`   VARCHAR(16)  NOT NULL,
        `body`     VARCHAR(1000) NOT NULL,
        `seen`     TINYINT(1)   NOT NULL DEFAULT 0,
        `at`       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `from_cid` (`from_cid`),
        KEY `to_cid` (`to_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_app_data` (
        `citizenid` VARCHAR(16) NOT NULL,
        `app`       VARCHAR(40) NOT NULL,
        `k`         VARCHAR(60) NOT NULL,
        `v`         TEXT,
        PRIMARY KEY (`citizenid`, `app`, `k`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_cipher_profiles` (
        `citizenid`  VARCHAR(16)  NOT NULL,
        `handle`     VARCHAR(20)  NOT NULL,
        `displayname` VARCHAR(32) NOT NULL,
        `public_key` TEXT         NOT NULL,
        `fingerprint` VARCHAR(95) NOT NULL,
        `pin_hash`   CHAR(64)     NOT NULL,
        `created_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`citizenid`),
        UNIQUE KEY `handle` (`handle`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_cipher_messages` (
        `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        `from_cid`   VARCHAR(16) NOT NULL,
        `to_cid`     VARCHAR(16) NOT NULL,
        `envelope`   TEXT        NOT NULL,
        `burn`       INT UNSIGNED NOT NULL DEFAULT 0,
        `seen`       TINYINT(1)  NOT NULL DEFAULT 0,
        `at`         TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
        `expires_at` TIMESTAMP   NULL DEFAULT NULL,
        -- Only ever filled when Config.Police.cipher.intercept is on: a server-wrapped
        -- copy of the plaintext, so the warrant terminal can crack the content. NULL, and
        -- content is truly unrecoverable, on a server that leaves intercept off.
        `intercept`  TEXT        NULL DEFAULT NULL,
        PRIMARY KEY (`id`),
        KEY `cipher_from` (`from_cid`, `id`),
        KEY `cipher_to` (`to_cid`, `seen`, `id`),
        KEY `cipher_expiry` (`expires_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_cipher_clears` (
        `citizenid` VARCHAR(16) NOT NULL,
        `other_cid` VARCHAR(16) NOT NULL,
        `before_id` BIGINT UNSIGNED NOT NULL DEFAULT 0,
        PRIMARY KEY (`citizenid`, `other_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_groups` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `name`      VARCHAR(40) NOT NULL,
        `owner_cid` VARCHAR(16) NOT NULL,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_group_members` (
        `group_id`  INT UNSIGNED NOT NULL,
        `citizenid` VARCHAR(16) NOT NULL,
        PRIMARY KEY (`group_id`, `citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- The contact card grew. Added idempotently so an existing database upgrades without
    -- a migration step nobody would run.
    for col, ddl in pairs({
        photo    = "ADD COLUMN `photo` VARCHAR(400) NOT NULL DEFAULT ''",
        email    = "ADD COLUMN `email` VARCHAR(64) NOT NULL DEFAULT ''",
        address  = "ADD COLUMN `address` VARCHAR(120) NOT NULL DEFAULT ''",
        birthday = "ADD COLUMN `birthday` VARCHAR(20) NOT NULL DEFAULT ''",
        note     = "ADD COLUMN `note` VARCHAR(300) NOT NULL DEFAULT ''",
    }) do
        local has = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_contacts'
              AND COLUMN_NAME = ? LIMIT 1]], { col })
        if not has then MySQL.query.await('ALTER TABLE `vphone_contacts` ' .. ddl) end
    end

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_notes` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(16) NOT NULL,
        `title`     VARCHAR(120) NOT NULL DEFAULT '',
        `body`      TEXT,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `owner_idx` (`citizenid`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_mail_accounts` (
        `citizenid` VARCHAR(16) NOT NULL,
        `address`   VARCHAR(64) NOT NULL,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`citizenid`), UNIQUE KEY `address` (`address`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_mail` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `from_addr` VARCHAR(64) NOT NULL,
        `to_addr`   VARCHAR(400) NOT NULL DEFAULT '',
        `subject`   VARCHAR(120) NOT NULL DEFAULT '',
        `body`      TEXT,
        `reply_to`  INT UNSIGNED NULL DEFAULT NULL,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- One row per copy: the sender's Sent, each recipient's Inbox, and drafts. Deleting
    -- your copy leaves everyone else's alone, which is what a mailbox means.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_mail_box` (
        `id`      INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `mail_id` INT UNSIGNED NOT NULL,
        `address` VARCHAR(64) NOT NULL,
        `folder`  VARCHAR(8) NOT NULL DEFAULT 'inbox',
        `seen`    TINYINT(1) NOT NULL DEFAULT 0,
        `saved`   TINYINT(1) NOT NULL DEFAULT 0,
        PRIMARY KEY (`id`), KEY `box_idx` (`address`, `folder`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_voicemail` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(16) NOT NULL,
        `from_num`  VARCHAR(20) NOT NULL DEFAULT '',
        `body`      VARCHAR(500) NOT NULL DEFAULT '',
        `seen`      TINYINT(1) NOT NULL DEFAULT 0,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `owner_idx` (`citizenid`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_calls` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(16) NOT NULL,
        `other_num` VARCHAR(20) NOT NULL DEFAULT '',
        `direction` VARCHAR(4)  NOT NULL DEFAULT 'out',
        `answered`  TINYINT(1)  NOT NULL DEFAULT 0,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `owner_idx` (`citizenid`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    -- Messages grew a kind, an attachment and a group. Idempotent, so an existing
    -- database upgrades without a migration step nobody would run.
    local hasKind = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_messages'
          AND COLUMN_NAME = 'kind' LIMIT 1]])
    if not hasKind then
        MySQL.query.await("ALTER TABLE `vphone_messages` ADD COLUMN `kind` VARCHAR(10) NOT NULL DEFAULT 'text'")
        MySQL.query.await("ALTER TABLE `vphone_messages` ADD COLUMN `attachment` VARCHAR(300) NOT NULL DEFAULT ''")
        MySQL.query.await("ALTER TABLE `vphone_messages` ADD COLUMN `group_id` INT UNSIGNED NULL DEFAULT NULL")
        MySQL.query.await("ALTER TABLE `vphone_messages` ADD KEY `group_idx` (`group_id`, `id`)")
        print('[v-phone] messages migrated: kind, attachment, groups')
    end

    -- The lawful-intercept column on cipher messages, for a server upgrading from before
    -- it existed. A fresh install already has it from the CREATE.
    local hasIntercept = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_cipher_messages'
          AND COLUMN_NAME = 'intercept' LIMIT 1]])
    if not hasIntercept then
        MySQL.query.await("ALTER TABLE `vphone_cipher_messages` ADD COLUMN `intercept` TEXT NULL DEFAULT NULL")
    end

    -- Composite indexes mirror the actual hot paths: inbox unread counts, two-person
    -- threads, group membership, saved mail and retention cleanup. Existing servers
    -- receive them once; later boots only perform the inexpensive metadata checks.
    local function ensureIndex(tableName, indexName, columns)
        local has = MySQL.scalar.await([[SELECT 1 FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
              AND INDEX_NAME = ? LIMIT 1]], { tableName, indexName })
        if has then return end
        MySQL.query.await(('ALTER TABLE `%s` ADD KEY `%s` (%s)'):format(
            tableName, indexName, columns))
    end
    ensureIndex('vphone_messages', 'msg_inbox_idx',
        '`to_cid`,`seen`,`group_id`,`from_cid`,`id`')
    ensureIndex('vphone_messages', 'msg_from_idx',
        '`from_cid`,`to_cid`,`group_id`,`id`')
    ensureIndex('vphone_group_members', 'member_cid_idx',
        '`citizenid`,`group_id`')
    ensureIndex('vphone_mail_box', 'mail_saved_idx',
        '`address`,`saved`,`id`')
    ensureIndex('vphone_voicemail', 'voicemail_unread_idx',
        '`citizenid`,`seen`,`id`')
    ensureIndex('vphone_calls', 'calls_at_idx', '`at`')

    -- A call log is history, not an archive: keep the last while, then let it go.
    MySQL.query('DELETE FROM vphone_calls WHERE at < DATE_SUB(NOW(), INTERVAL 30 DAY)')

    -- The number lives on the character, not in a table of its own: it identifies the
    -- character the same way their name does. Added idempotently so an existing database
    -- upgrades without a migration step nobody would run.
    local hasCol = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_characters' AND COLUMN_NAME = 'phone' LIMIT 1]])
    if not hasCol then
        MySQL.query.await('ALTER TABLE `vphone_characters` ADD COLUMN `phone` VARCHAR(20) DEFAULT NULL')
        MySQL.query.await('ALTER TABLE `vphone_characters` ADD UNIQUE KEY `phone` (`phone`)')
    end

    for _, a in ipairs(Config.Apps) do registerApp(a.id, a, a.owner) end

    -- Upstream seeded chargers, dead zones and the app list into v-world's editable
    -- tables here. There is no editor and no v-world in this build: the config lists ARE
    -- the content, read straight from Config wherever they are needed. Nothing to seed.
    loadWorldApps()

    -- Drop-in apps: whatever an `apps/<id>/app.lua` declared. They go through the same
    -- registration a third-party resource uses, so from here on the phone cannot tell an
    -- app folder from an app resource - which is the whole point.
    for _, def in ipairs(PhoneApps or {}) do
        if registerApp(def.id, def, 'v-phone') then
            print(('[v-phone] app folder loaded: %s'):format(def.id))
        end
    end
    loadWorldApps()

    -- Upstream kept an editable app catalogue in v-world's `world_apps` table, so an admin
    -- could reorder or gate apps from an in-game panel. There is no panel here and no
    -- v-world: `Config.Apps` and `Config.Home` ARE the catalogue, read fresh every boot.
    -- So there is nothing to seed and nothing to re-seed - the two loops that did are
    -- gone, along with the one table this resource did not own.

    -- A resource restart does not replay the framework's player-loaded event. Rebuild
    -- every online index and persisted power state before accepting calls/messages.
    for _, raw in ipairs(GetPlayers()) do
        local src = tonumber(raw)
        if src then hydratePlayer(src, Core.GetPlayer(src)) end
    end

    -- Retention, once at boot. A prune on a timer would be a second thing to reason about
    -- for a table that only grows while people are talking.
    local days = math.floor(num(S('retentionDays', Config.Messages.retentionDays), 30))
    if days > 0 then
        local n = MySQL.update.await('DELETE FROM vphone_messages WHERE at < DATE_SUB(NOW(), INTERVAL ? DAY)', { days })
        if n and n > 0 then print(('[v-phone] pruned %d message(s) older than %d days'):format(n, days)) end
    end
    MySQL.update.await([[DELETE FROM vphone_cipher_messages
        WHERE expires_at IS NOT NULL AND expires_at <= NOW()]])

    -- The social apps are part of this resource now, so they wait for the same boot
    -- rather than for one of their own. `Core` is passed rather than fetched again: a
    -- second GetCore would be a second answer to a question already asked.
    if SocialBoot then SocialBoot(Core) end
end)
