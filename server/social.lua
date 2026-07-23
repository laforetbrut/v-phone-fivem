-- v-phone | server/social.lua
--
-- **Bleeter, Snapmatic and Hush.** The one place player-SHARED data lives: handles,
-- posts, likes, follows, comments, stories, direct messages and matches.
--
-- This was a separate resource. It is not any more, and that is the point: a phone that
-- cannot show its own social apps unless a second resource happens to be running is half
-- a phone. Everything it needs is here, and every limit and expiry it applies comes from
-- `Config.Social` in the phone's own config file.
--
-- Three rules shape all of it:
--
--  1. **The author is always the server's idea of who called**, never a field in the
--     payload. A client that could name the author of a post could bleet as the mayor.
--
--  2. **Handles address people; citizen ids never leave the server.** A handle is the
--     public name an account chose. The citizen id is a database key, and every query
--     that answers a client resolves ids to handles before it resolves at all.
--
--  3. **A Hush match is the only place identity crosses over**, and it is the point:
--     both sides liked, so both sides get the other's NAME and NUMBER - and nothing else.

-- The phone already answers to `phone`; it answers to `social` as well now, so a module
-- that wants a handle or wants to post asks for the service rather than for a resource.
V.Provide('social')

local SOC = Config.Social

-- A separate file is a separate chunk, so the phone's own locals do not reach in here.
-- These three are the ones this file needs, and they are the same three.
local Core
local function num(v, d) return tonumber(v) or d or 0 end

local function L(src, k)
    local p = Core and Core.GetPlayer(src)
    local lang = (p and p.lang) or 'fr'
    return (Locales[lang] or Locales.fr or {})[k] or k
end

--- The social apps as a whole. Off hides all three and answers every call with `off`.
local function socOn()
    return Config.Social.enabled ~= false and V.SettingBool('social', true)
end

--- How many posts a feed carries. A setting rather than a constant because it is the one
--- number an operator tunes when a busy server starts feeling slow.
local function socFeedSize()
    return math.max(10, math.min(200, math.floor(tonumber(V.Setting('socialFeedSize', SOC.feedSize)) or SOC.feedSize)))
end

--- Days before a kind of row is swept. 0 means never.
local function socKeep(kind)
    local days = tonumber(V.Setting('socialRetention' .. kind:sub(1, 1):upper() .. kind:sub(2),
                                    SOC.retention[kind]))
    return math.max(0, math.floor(days or 0))
end

--- Same shape as the phone's wallpaper gate, for the same reason. Rejected rather than
--- rewritten: silently fixing somebody's link is worse than telling them it is refused.
local function imageAllowed(url)
    url = tostring(url or '')
    if url == '' then return true end
    local host = url:match('^https?://([^/]+)')
    if not host then return false end
    host = host:lower():gsub(':%d+$', '')
    local hosts = V.Setting('socialImageHosts', SOC.imageHosts)
    if type(hosts) == 'string' then
        local out = {}
        for h in hosts:gmatch('[^,%s]+') do out[#out + 1] = h end
        hosts = out
    end
    for _, allowed in ipairs(hosts or SOC.imageHosts) do
        if host == allowed or host:sub(-(#allowed + 1)) == '.' .. allowed then return true end
    end
    return false
end

-- ══════════════════════════════════════════════════════════════
-- Accounts
-- ══════════════════════════════════════════════════════════════
-- 'bleeter' posts text, 'snap' posts photos. The app an account belongs to is part of
-- its key: your Bleeter handle is not your Snapmatic handle unless you choose it twice.
local APPS = { bleeter = true, snap = true, hush = true }
local APP_NAME = { bleeter = 'Bleeter', snap = 'Snapmatic', hush = 'Hush' }

local function appOfKind(kind) return kind == 'photo' and 'snap' or 'bleeter' end

local function accountOf(cid, app)
    return MySQL.single.await(
        'SELECT citizenid, handle, displayname, avatar, bio, phone, verified FROM vphone_social_accounts WHERE citizenid = ? AND app = ?',
        { cid, app })
end

-- ── Credentials ────────────────────────────────────────────────
-- A roleplay password, not a real one: FNV-1a with a per-account salt is enough to keep
-- it out of the database in the clear and to make one account's hash useless against
-- another. It is never reused for anything with real stakes.
local function randHex(n)
    local t = {}
    for i = 1, n do t[i] = string.format('%x', math.random(0, 15)) end
    return table.concat(t)
end

local function fnv1a(str)
    local h = 2166136261
    for i = 1, #str do
        h = h ~ string.byte(str, i)
        h = (h * 16777619) % 4294967296
    end
    return h
end

local function hashPw(pw)
    local salt = randHex(8)
    return salt .. ':' .. string.format('%08x', fnv1a(salt .. pw))
end

local function checkPw(stored, pw)
    if type(stored) ~= 'string' then return false end
    local salt, hash = stored:match('^(%x+):(%x+)$')
    if not salt then return false end
    return string.format('%08x', fnv1a(salt .. pw)) == hash
end

local function genCode() return string.format('%04d', math.random(0, 9999)) end

-- Per-session state, cleared when the player drops: the code we texted them, and which
-- apps they are logged into on this device.
local Pending = {}       -- [src] = { [app] = { code, number, at } }
local Authed  = {}       -- [src] = { [app] = true }

AddEventHandler('playerDropped', function()
    local src = source
    Pending[src] = nil
    Authed[src] = nil
end)

local function phoneNumberOf(src)
    if GetResourceState('v-phone') ~= 'started' then return nil end
    local ok, n = pcall(function() return exports['v-phone']:NumberOf(src) end)
    return ok and n or nil
end

local function smsCode(src, app, code)
    if GetResourceState('v-phone') ~= 'started' then return end
    pcall(function()
        exports['v-phone']:Notify(src, app, APP_NAME[app] or 'iFruit',
            ('Code de verification : %s'):format(code))
    end)
end

local function publicAccount(a)
    -- The citizen id stops here.
    return a and { handle = a.handle, displayname = a.displayname, avatar = a.avatar, bio = a.bio } or nil
end

-- exists: an account is on file. authed: this session has logged into it. The app draws
-- a sign-up wizard, a login screen, or the feed from exactly these two bits.
V.Callback('v-phone:soc:me', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = tostring((data and data.app) or 'bleeter')
    if not APPS[app] then resolve(false) return end
    local a = accountOf(p.citizenid, app)
    local authed = a and Authed[src] and Authed[src][app] == true or false
    resolve({ ok = true, exists = a ~= nil, authed = authed,
              account = authed and publicAccount(a) or nil })
end)

-- Step one of sign-up: text a code to the phone's own number. The number is not the
-- client's to choose - it is whatever v-phone says this player's line is, so an account
-- cannot be verified against someone else's phone.
V.Callback('v-phone:soc:requestCode', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = tostring((data and data.app) or '')
    if not APPS[app] then resolve(false) return end
    local number = phoneNumberOf(src)
    if not number or number == '' then resolve({ error = 'nonumber' }) return end

    local code = genCode()
    Pending[src] = Pending[src] or {}
    Pending[src][app] = { code = code, number = number, at = os.time() }
    smsCode(src, app, code)
    resolve({ ok = true, number = number })
end)

-- Step two: the code they were texted. A five-minute window, one guess-free check.
V.Callback('v-phone:soc:verifyCode', function(src, resolve, data)
    local app = tostring((data and data.app) or '')
    local code = tostring((data and data.code) or ''):gsub('%s', '')
    local pend = Pending[src] and Pending[src][app]
    if not pend then resolve({ error = 'nocode' }) return end
    if (os.time() - pend.at) > 300 then Pending[src][app] = nil resolve({ error = 'expired' }) return end
    if code ~= pend.code then resolve({ error = 'badcode' }) return end
    pend.verified = true
    resolve({ ok = true })
end)

-- Step three: pick a username, a display name and a password. Only allowed once the code
-- for this app has been verified this session.
V.Callback('v-phone:soc:register', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = tostring((data and data.app) or '')
    if not APPS[app] then resolve(false) return end
    local pend = Pending[src] and Pending[src][app]
    if not (pend and pend.verified) then resolve({ error = 'unverified' }) return end

    local handle = tostring((data and data.handle) or ''):gsub('[^%w_]', ''):sub(1, SOC.handleMax)
    if #handle < SOC.handleMin then resolve({ error = 'handle' }) return end
    local displayname = tostring((data and data.displayname) or ''):sub(1, 40)
    if displayname == '' then resolve({ error = 'displayname' }) return end
    local pw = tostring((data and data.password) or '')
    if #pw < 4 then resolve({ error = 'password' }) return end
    local avatar = tostring((data and data.avatar) or ''):sub(1, 300)
    if avatar ~= '' and not imageAllowed(avatar) then resolve({ error = 'badhost' }) return end
    local bio = tostring((data and data.bio) or ''):sub(1, 160)

    if accountOf(p.citizenid, app) then resolve({ error = 'exists' }) return end
    local taken = MySQL.scalar.await(
        'SELECT 1 FROM vphone_social_accounts WHERE app = ? AND handle = ? LIMIT 1', { app, handle })
    if taken then resolve({ error = 'taken' }) return end

    MySQL.query.await([[INSERT INTO vphone_social_accounts
        (citizenid, app, handle, displayname, avatar, bio, phone, password, verified)
        VALUES (?,?,?,?,?,?,?,?,1)]],
        { p.citizenid, app, handle, displayname, avatar, bio, pend.number, hashPw(pw) })

    Pending[src][app] = nil
    Authed[src] = Authed[src] or {}
    Authed[src][app] = true
    resolve({ ok = true, account = { handle = handle, displayname = displayname, avatar = avatar, bio = bio } })
end)

-- Returning to a registered account on a fresh session: the password unlocks it.
V.Callback('v-phone:soc:login', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = tostring((data and data.app) or '')
    if not APPS[app] then resolve(false) return end
    local a = accountOf(p.citizenid, app)
    if not a then resolve({ error = 'noaccount' }) return end
    if not checkPw(a.password, tostring((data and data.password) or '')) then
        resolve({ error = 'badpass' }) return
    end
    Authed[src] = Authed[src] or {}
    Authed[src][app] = true
    resolve({ ok = true, account = publicAccount(a) })
end)

V.Callback('v-phone:soc:logout', function(src, resolve, data)
    local app = tostring((data and data.app) or '')
    if Authed[src] then Authed[src][app] = nil end
    resolve({ ok = true })
end)

V.Callback('v-phone:soc:setup', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local app = tostring((data and data.app) or 'bleeter')
    if not APPS[app] then resolve(false) return end
    -- Editing an existing profile, so it needs a logged-in account, not the sign-up path.
    if not (Authed[src] and Authed[src][app]) then resolve({ error = 'unverified' }) return end
    local a = accountOf(p.citizenid, app)
    if not a then resolve({ error = 'noaccount' }) return end

    local displayname = tostring((data and data.displayname) or a.displayname or ''):sub(1, 40)
    if displayname == '' then displayname = a.handle end
    local avatar = tostring((data and data.avatar) or ''):sub(1, 300)
    if avatar ~= '' and not imageAllowed(avatar) then resolve({ error = 'badhost' }) return end
    local bio = tostring((data and data.bio) or ''):sub(1, 160)

    -- The handle is the account's name on the server and does not change here; only the
    -- display name, avatar and bio do.
    MySQL.query.await(
        'UPDATE vphone_social_accounts SET displayname = ?, avatar = ?, bio = ? WHERE citizenid = ? AND app = ?',
        { displayname, avatar, bio, p.citizenid, app })
    resolve({ ok = true, account = { handle = a.handle, displayname = displayname, avatar = avatar, bio = bio } })
end)

-- ══════════════════════════════════════════════════════════════
-- Shared reading helpers
-- ══════════════════════════════════════════════════════════════
local function cidOfHandle(app, handle)
    handle = tostring(handle or ''):gsub('^@', ''):sub(1, 20)
    if handle == '' then return nil end
    return MySQL.scalar.await(
        'SELECT citizenid FROM vphone_social_accounts WHERE app = ? AND handle = ?', { app, handle })
end

local function appOf(data)
    local app = tostring((data and data.app) or 'bleeter')
    return APPS[app] and app or 'bleeter'
end

--- The columns every feed draws. One query per count would be one query per post; these
--- are subselects, so a feed stays a single round trip however long it is. The four
--- placeholders are the caller's own citizen id, in order.
local POST_COLUMNS = [[
    s.id, s.kind, s.body, s.image, s.at,
    a.handle, a.displayname, a.avatar, a.verified,
    (SELECT COUNT(*) FROM vphone_social_likes l WHERE l.post_id = s.id) AS likes,
    (SELECT COUNT(*) FROM vphone_social_comments c WHERE c.post_id = s.id) AS comments,
    (SELECT COUNT(*) FROM vphone_social_reposts r WHERE r.post_id = s.id) AS reposts,
    EXISTS(SELECT 1 FROM vphone_social_likes l2 WHERE l2.post_id = s.id AND l2.citizenid = ?) AS liked,
    EXISTS(SELECT 1 FROM vphone_social_reposts r2 WHERE r2.post_id = s.id AND r2.citizenid = ?) AS reposted,
    EXISTS(SELECT 1 FROM vphone_social_follows f WHERE f.app = a.app AND f.from_cid = ? AND f.to_cid = s.citizenid) AS following,
    (s.citizenid = ?) AS mine
]]

--- MySQL answers booleans as 0/1 and counts as strings. The page should receive the
--- types it is going to render, not the types the driver happened to return.
local function cleanPosts(rows)
    for _, r in ipairs(rows or {}) do
        r.likes = num(r.likes, 0)
        r.comments = num(r.comments, 0)
        r.reposts = num(r.reposts, 0)
        r.liked = num(r.liked, 0) == 1
        r.reposted = num(r.reposted, 0) == 1
        r.following = num(r.following, 0) == 1
        r.verified = num(r.verified, 0) == 1
        r.mine = num(r.mine, 0) == 1
    end
    return rows or {}
end

-- ══════════════════════════════════════════════════════════════
-- The feed
-- ══════════════════════════════════════════════════════════════
-- One table, two kinds. Bleeter shows 'text', Snapmatic shows 'photo': the same feed with
-- different content types and different chrome, which is all those two apps ever were.
V.Callback('v-phone:soc:feed', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local photo = (data and data.kind == 'photo')
    local app = appOfKind(photo and 'photo' or 'text')

    -- The photo feed (Snapmatic) shows photos AND videos; the text feed (Bleeter) shows
    -- text. A clip lives with the pictures.
    local kindWhere = photo and 's.kind IN (?, ?)' or 's.kind = ?'

    -- Two feeds, one query: everything, or only the accounts you follow plus your own.
    -- A "following" tab that quietly showed strangers would not be worth having.
    local following = (data and data.scope) == 'following'
    local where = following
        and [[ AND (s.citizenid = ? OR EXISTS(
                 SELECT 1 FROM vphone_social_follows f WHERE f.app = a.app
                   AND f.from_cid = ? AND f.to_cid = s.citizenid))]]
        or ''

    local args = { p.citizenid, p.citizenid, p.citizenid, p.citizenid, app }
    if photo then args[#args + 1] = 'photo'; args[#args + 1] = 'video'
    else args[#args + 1] = 'text' end
    if following then
        args[#args + 1] = p.citizenid
        args[#args + 1] = p.citizenid
    end
    args[#args + 1] = socFeedSize()

    local rows = MySQL.query.await(([[
        SELECT %s
        FROM vphone_social_posts s
        JOIN vphone_social_accounts a ON a.citizenid = s.citizenid AND a.app = ?
        WHERE %s%s
        ORDER BY s.id DESC LIMIT ?
    ]]):format(POST_COLUMNS, kindWhere, where), args) or {}

    resolve({ ok = true, posts = cleanPosts(rows) })
end)

V.Callback('v-phone:soc:post', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    -- text -> Bleeter, photo/video -> the app the client named (Bleeter or Snapmatic), or
    -- Snapmatic by default for media. A clip is a photo that moves; it shares the account,
    -- the host gate and the feed, with its media URL in `image`.
    local raw = (data and data.kind) or 'text'
    local kind = (raw == 'photo' or raw == 'video') and raw or 'text'
    local wantApp = tostring((data and data.app) or '')
    local mediaApp = (kind == 'text') and 'bleeter'
        or ((wantApp == 'bleeter' or wantApp == 'snap') and wantApp)
        or appOfKind('photo')
    if not accountOf(p.citizenid, mediaApp) then resolve({ error = 'noaccount' }) return end
    local body = tostring((data and data.body) or '')
        :sub(1, math.floor(num(V.Setting('socialMaxLength', SOC.postMax), 280)))
    local image = tostring((data and data.image) or ''):sub(1, 300)

    if kind == 'photo' or kind == 'video' then
        -- The media is the post; a caption is optional. The URL faces every client that
        -- opens the feed, so it goes through the host gate.
        if image == '' then resolve({ error = 'noimage' }) return end
        if not imageAllowed(image) then resolve({ error = 'badhost' }) return end
    else
        if body:gsub('%s', '') == '' then resolve({ error = 'empty' }) return end
        image = ''
    end

    local id = MySQL.insert.await(
        'INSERT INTO vphone_social_posts (citizenid, kind, body, image) VALUES (?,?,?,?)',
        { p.citizenid, kind, body, image })
    Core.Log('social', ('%s posted %s #%d'):format(p.citizenid, kind, id), nil, p.citizenid)
    resolve({ ok = true, id = id })
end)

V.Callback('v-phone:soc:like', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end

    -- A like is a toggle. INSERT IGNORE + DELETE keyed on the pair means double-clicking
    -- can never count twice, whatever order the packets land in.
    local liked
    local exists = MySQL.scalar.await(
        'SELECT 1 FROM vphone_social_likes WHERE post_id = ? AND citizenid = ?', { id, p.citizenid })
    if exists then
        MySQL.query.await('DELETE FROM vphone_social_likes WHERE post_id = ? AND citizenid = ?', { id, p.citizenid })
        liked = false
    else
        MySQL.insert.await('INSERT IGNORE INTO vphone_social_likes (post_id, citizenid) VALUES (?,?)', { id, p.citizenid })
        liked = true
    end
    local count = num(MySQL.scalar.await(
        'SELECT COUNT(*) FROM vphone_social_likes WHERE post_id = ?', { id }), 0)
    resolve({ ok = true, liked = liked, likes = count })
end)

-- ══════════════════════════════════════════════════════════════
-- Hush
-- ══════════════════════════════════════════════════════════════
local function hushOn() return socOn() and V.SettingBool('socialHush', SOC.hush.enabled) end

--- A date of birth becomes an age and nothing else: the card shows how old somebody is,
--- never the day they were born.
local function ageFrom(dob)
    local year = tostring(dob or ''):match('^(%d%d%d%d)')
    return year and math.max(18, 2026 - tonumber(year)) or nil
end

V.Callback('v-phone:soc:hushMe', function(src, resolve)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local row = MySQL.single.await(
        'SELECT bio, photo, active FROM vphone_hush_profiles WHERE citizenid = ?', { p.citizenid })
    resolve({ ok = true, profile = row and { bio = row.bio, photo = row.photo, active = num(row.active, 0) == 1 } or nil })
end)

V.Callback('v-phone:soc:hushSetup', function(src, resolve, data)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local bio = tostring((data and data.bio) or ''):sub(1, SOC.bioMax)
    local photo = tostring((data and data.photo) or ''):sub(1, 300)
    if photo ~= '' and not imageAllowed(photo) then resolve({ error = 'badhost' }) return end
    local active = (data and data.active == false) and 0 or 1

    MySQL.query.await([[INSERT INTO vphone_hush_profiles (citizenid, bio, photo, active)
        VALUES (?,?,?,?)
        ON DUPLICATE KEY UPDATE bio=VALUES(bio), photo=VALUES(photo), active=VALUES(active)]],
        { p.citizenid, bio, photo, active })
    resolve({ ok = true })
end)

--- The next profile this player has not judged yet. The citizen id travels as an opaque
--- `ref` the client hands straight back - it is never displayed, and the visible fields
--- are the first name and an age derived from the date of birth, which is how a dating
--- profile introduces somebody.
V.Callback('v-phone:soc:hushNext', function(src, resolve)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    -- A pass comes round again after `Config.Social.hush.passDays`, because a deck you
    -- can empty for ever is a deck that ends. A LIKE never does: that one is a decision.
    local passDays = math.max(0, math.floor(num(SOC.hush.passDays, 7)))
    local row = MySQL.single.await(([[
        SELECT h.citizenid, h.bio, h.photo, c.firstname, c.dob
        FROM vphone_hush_profiles h
        JOIN vphone_characters c ON c.citizenid = h.citizenid
        WHERE h.active = 1 AND h.citizenid <> ?
          AND NOT EXISTS (SELECT 1 FROM vphone_hush_likes l
                          WHERE l.from_cid = ? AND l.to_cid = h.citizenid
                            AND (l.liked = 1%s))
        ORDER BY RAND() LIMIT 1
    ]]):format(passDays > 0
        and (' OR l.at > DATE_SUB(NOW(), INTERVAL %d DAY)'):format(passDays)
        or ' OR 1 = 1'), { p.citizenid, p.citizenid })
    if not row then resolve({ ok = true, profile = nil }) return end

    resolve({ ok = true, profile = {
        ref = row.citizenid, name = row.firstname, age = ageFrom(row.dob),
        bio = row.bio, photo = row.photo,
    } })
end)

V.Callback('v-phone:soc:hushChoice', function(src, resolve, data)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local target = tostring((data and data.ref) or '')
    if target == '' or target == p.citizenid then resolve(false) return end

    local liked = data and data.like == true
    -- A pass is recorded too, or the same face comes back every time the app opens. It
    -- is an UPDATE rather than an IGNORE because a pass expires: seeing somebody again
    -- has to restart their clock, otherwise the second pass never sticks.
    MySQL.insert.await([[INSERT INTO vphone_hush_likes (from_cid, to_cid, liked) VALUES (?,?,?)
        ON DUPLICATE KEY UPDATE liked = VALUES(liked), at = CURRENT_TIMESTAMP]],
        { p.citizenid, target, liked and 1 or 0 })

    if not liked then resolve({ ok = true, match = false }) return end

    -- The daily ceiling counts LIKES, not passes: saying no is free.
    local today = num(MySQL.scalar.await([[SELECT COUNT(*) FROM vphone_hush_likes
        WHERE from_cid = ? AND liked = 1 AND at > DATE_SUB(NOW(), INTERVAL 1 DAY)]],
        { p.citizenid }), 0)
    if today > math.floor(num(V.Setting('socialDailyLikes', SOC.hush.dailyLikes), 30)) then
        MySQL.query.await('DELETE FROM vphone_hush_likes WHERE from_cid = ? AND to_cid = ?', { p.citizenid, target })
        resolve({ error = 'limit' }) return
    end

    local mutual = MySQL.scalar.await(
        'SELECT 1 FROM vphone_hush_likes WHERE from_cid = ? AND to_cid = ? AND liked = 1',
        { target, p.citizenid })
    if not mutual then resolve({ ok = true, match = false }) return end

    -- The match: the one moment identity crosses, because both sides asked for it. Names
    -- and numbers travel through v-phone, which owns numbers; each side gets a message
    -- from the other, so the conversation already exists when they open it.
    local phone = V.Use('v-phone')
    local myNumber = phone.GetNumber(p.citizenid)
    local theirNumber = phone.GetNumber(target)
    local them = MySQL.single.await('SELECT firstname FROM vphone_characters WHERE citizenid = ?', { target })

    if myNumber and theirNumber then
        phone.SendMessage(p.citizenid, theirNumber, L(src, 'soc.match_line'))
        phone.SendMessage(target, myNumber, L(src, 'soc.match_line'))
    end
    Core.Log('social', ('hush match %s <-> %s'):format(p.citizenid, target), nil, p.citizenid)
    resolve({ ok = true, match = true, name = them and them.firstname or '?', number = theirNumber })
end)

--- Everyone who liked you back. A dating app whose matches you can only ever see once,
--- in a banner that fades, is a dating app that loses your matches.
V.Callback('v-phone:soc:hushMatches', function(src, resolve)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local rows = MySQL.query.await([[
        SELECT mine.to_cid AS cid, mine.at,
               c.firstname, c.dob, h.bio, h.photo
        FROM vphone_hush_likes mine
        JOIN vphone_hush_likes theirs
          ON theirs.from_cid = mine.to_cid AND theirs.to_cid = mine.from_cid AND theirs.liked = 1
        LEFT JOIN vphone_characters c ON c.citizenid = mine.to_cid
        LEFT JOIN vphone_hush_profiles h ON h.citizenid = mine.to_cid
        WHERE mine.from_cid = ? AND mine.liked = 1
        ORDER BY mine.at DESC LIMIT 50
    ]], { p.citizenid }) or {}

    local phone = GetResourceState('v-phone') == 'started' and V.Use('v-phone') or nil
    local out = {}
    for _, r in ipairs(rows) do
        -- A match already exchanged numbers, so the number is theirs to have. Nothing
        -- else about the citizen behind it travels.
        out[#out + 1] = {
            name = r.firstname or '?',
            age = ageFrom(r.dob),
            bio = r.bio or '',
            photo = r.photo or '',
            at = r.at,
            number = phone and phone.GetNumber(r.cid) or nil,
        }
    end
    resolve({ ok = true, matches = out })
end)

-- ══════════════════════════════════════════════════════════════
-- People: profiles, search, following
-- ══════════════════════════════════════════════════════════════
-- Everything below addresses people by HANDLE. A citizen id is resolved on the way in
-- and dropped on the way out, so a client can follow, message or open a profile without
-- ever learning who is behind it.

V.Callback('v-phone:soc:profile', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    local kind = app == 'snap' and 'photo' or 'text'

    -- No handle means "me". A profile you cannot reach from your own account is a
    -- profile you can only see by guessing a name.
    local handle = tostring((data and data.handle) or '')
    local cid = handle ~= '' and cidOfHandle(app, handle) or p.citizenid
    if not cid then resolve({ error = 'nouser' }) return end

    local a = accountOf(cid, app)
    if not a then resolve({ error = 'nouser' }) return end

    local counts = MySQL.single.await([[
        SELECT (SELECT COUNT(*) FROM vphone_social_posts s WHERE s.citizenid = ? AND s.kind = ?) AS posts,
               (SELECT COUNT(*) FROM vphone_social_follows f WHERE f.app = ? AND f.to_cid = ?) AS followers,
               (SELECT COUNT(*) FROM vphone_social_follows f2 WHERE f2.app = ? AND f2.from_cid = ?) AS following
    ]], { cid, kind, app, cid, app, cid }) or {}

    local posts = MySQL.query.await(([[
        SELECT %s FROM vphone_social_posts s
        JOIN vphone_social_accounts a ON a.citizenid = s.citizenid AND a.app = ?
        WHERE s.citizenid = ? AND s.kind = ?
        ORDER BY s.id DESC LIMIT ?
    ]]):format(POST_COLUMNS), {
        p.citizenid, p.citizenid, p.citizenid, p.citizenid,
        app, cid, kind, socFeedSize(),
    }) or {}

    resolve({
        ok = true,
        me = cid == p.citizenid,
        account = {
            handle = a.handle, displayname = a.displayname, avatar = a.avatar,
            bio = a.bio, verified = num(a.verified, 0) == 1,
        },
        counts = {
            posts = num(counts.posts, 0),
            followers = num(counts.followers, 0),
            following = num(counts.following, 0),
        },
        followed = cid ~= p.citizenid and MySQL.scalar.await(
            'SELECT 1 FROM vphone_social_follows WHERE app = ? AND from_cid = ? AND to_cid = ?',
            { app, p.citizenid, cid }) ~= nil or false,
        posts = cleanPosts(posts),
    })
end)

V.Callback('v-phone:soc:search', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    local q = tostring((data and data.q) or ''):gsub('^@', ''):sub(1, 20)

    -- An empty search is not an error, it is the suggestion list: the accounts with the
    -- most followers, which is what a directory with nothing typed into it should show.
    local rows
    if q:gsub('%s', '') == '' then
        rows = MySQL.query.await([[
            SELECT a.handle, a.displayname, a.avatar, a.bio, a.verified,
                   (SELECT COUNT(*) FROM vphone_social_follows f WHERE f.app = a.app AND f.to_cid = a.citizenid) AS followers,
                   EXISTS(SELECT 1 FROM vphone_social_follows f2 WHERE f2.app = a.app AND f2.from_cid = ? AND f2.to_cid = a.citizenid) AS followed,
                   (a.citizenid = ?) AS me
            FROM vphone_social_accounts a WHERE a.app = ?
            ORDER BY followers DESC, a.handle ASC LIMIT 30
        ]], { p.citizenid, p.citizenid, app }) or {}
    else
        local like = '%' .. q .. '%'
        rows = MySQL.query.await([[
            SELECT a.handle, a.displayname, a.avatar, a.bio, a.verified,
                   (SELECT COUNT(*) FROM vphone_social_follows f WHERE f.app = a.app AND f.to_cid = a.citizenid) AS followers,
                   EXISTS(SELECT 1 FROM vphone_social_follows f2 WHERE f2.app = a.app AND f2.from_cid = ? AND f2.to_cid = a.citizenid) AS followed,
                   (a.citizenid = ?) AS me
            FROM vphone_social_accounts a
            WHERE a.app = ? AND (a.handle LIKE ? OR a.displayname LIKE ?)
            ORDER BY (a.handle = ?) DESC, followers DESC LIMIT 30
        ]], { p.citizenid, p.citizenid, app, like, like, q }) or {}
    end

    for _, r in ipairs(rows) do
        r.followers = num(r.followers, 0)
        r.followed = num(r.followed, 0) == 1
        r.verified = num(r.verified, 0) == 1
        r.me = num(r.me, 0) == 1
    end
    resolve({ ok = true, accounts = rows })
end)

V.Callback('v-phone:soc:follow', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    local cid = cidOfHandle(app, data and data.handle)
    if not cid then resolve({ error = 'nouser' }) return end
    -- Following yourself is not a feature, it is a bug report waiting to happen.
    if cid == p.citizenid then resolve({ error = 'self' }) return end

    local exists = MySQL.scalar.await(
        'SELECT 1 FROM vphone_social_follows WHERE app = ? AND from_cid = ? AND to_cid = ?',
        { app, p.citizenid, cid })
    if exists then
        MySQL.query.await('DELETE FROM vphone_social_follows WHERE app = ? AND from_cid = ? AND to_cid = ?',
            { app, p.citizenid, cid })
    else
        MySQL.insert.await('INSERT IGNORE INTO vphone_social_follows (app, from_cid, to_cid) VALUES (?,?,?)',
            { app, p.citizenid, cid })
    end
    resolve({
        ok = true, followed = not exists,
        followers = num(MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_social_follows WHERE app = ? AND to_cid = ?', { app, cid }), 0),
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Comments and reposts
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:soc:comments', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end
    local app = appOf(data)

    local rows = MySQL.query.await([[
        SELECT c.id, c.body, c.at, a.handle, a.displayname, a.avatar, a.verified,
               (c.citizenid = ?) AS mine
        FROM vphone_social_comments c
        JOIN vphone_social_accounts a ON a.citizenid = c.citizenid AND a.app = ?
        WHERE c.post_id = ? ORDER BY c.id ASC LIMIT 200
    ]], { p.citizenid, app, id }) or {}
    for _, r in ipairs(rows) do
        r.mine = num(r.mine, 0) == 1
        r.verified = num(r.verified, 0) == 1
    end
    resolve({ ok = true, comments = rows })
end)

V.Callback('v-phone:soc:comment', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end
    local id = math.floor(num(data and data.id, 0))
    local body = tostring((data and data.body) or ''):sub(1, 280)
    if id <= 0 or body:gsub('%s', '') == '' then resolve({ error = 'empty' }) return end
    if not MySQL.scalar.await('SELECT 1 FROM vphone_social_posts WHERE id = ?', { id }) then
        resolve({ error = 'gone' }) return
    end

    MySQL.insert.await('INSERT INTO vphone_social_comments (post_id, citizenid, body) VALUES (?,?,?)',
        { id, p.citizenid, body })
    resolve({ ok = true, comments = num(MySQL.scalar.await(
        'SELECT COUNT(*) FROM vphone_social_comments WHERE post_id = ?', { id }), 0) })
end)

V.Callback('v-phone:soc:uncomment', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end
    -- Your own comment only. The author check is the WHERE clause, not a branch.
    MySQL.query.await('DELETE FROM vphone_social_comments WHERE id = ? AND citizenid = ?', { id, p.citizenid })
    resolve({ ok = true })
end)

V.Callback('v-phone:soc:repost', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end

    local exists = MySQL.scalar.await(
        'SELECT 1 FROM vphone_social_reposts WHERE post_id = ? AND citizenid = ?', { id, p.citizenid })
    if exists then
        MySQL.query.await('DELETE FROM vphone_social_reposts WHERE post_id = ? AND citizenid = ?', { id, p.citizenid })
    else
        MySQL.insert.await('INSERT IGNORE INTO vphone_social_reposts (post_id, citizenid) VALUES (?,?)',
            { id, p.citizenid })
    end
    resolve({
        ok = true, reposted = not exists,
        reposts = num(MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_social_reposts WHERE post_id = ?', { id }), 0),
    })
end)

V.Callback('v-phone:soc:delete', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end
    local n = MySQL.update.await('DELETE FROM vphone_social_posts WHERE id = ? AND citizenid = ?',
        { id, p.citizenid })
    if not n or n == 0 then resolve({ error = 'notyours' }) return end
    -- The post is gone, so its likes, comments and reposts are noise. Clear them rather
    -- than leaving rows pointing at nothing.
    MySQL.query.await('DELETE FROM vphone_social_likes WHERE post_id = ?', { id })
    MySQL.query.await('DELETE FROM vphone_social_comments WHERE post_id = ?', { id })
    MySQL.query.await('DELETE FROM vphone_social_reposts WHERE post_id = ?', { id })
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Stories
-- ══════════════════════════════════════════════════════════════
-- A story is a post with an expiry. It is a separate table because it has different
-- rules - it disappears, and being seen is part of its state - not to keep two feeds.
local STORY_HOURS = 24

V.Callback('v-phone:soc:stories', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)

    local rows = MySQL.query.await([[
        SELECT t.id, t.citizenid, t.image, t.body, t.at,
               a.handle, a.displayname, a.avatar,
               EXISTS(SELECT 1 FROM vphone_social_story_seen v WHERE v.story_id = t.id AND v.citizenid = ?) AS seen,
               (t.citizenid = ?) AS mine
        FROM vphone_social_stories t
        JOIN vphone_social_accounts a ON a.citizenid = t.citizenid AND a.app = t.app
        WHERE t.app = ? AND t.at > DATE_SUB(NOW(), INTERVAL ? HOUR)
          AND (t.citizenid = ? OR EXISTS(
                SELECT 1 FROM vphone_social_follows f
                WHERE f.app = t.app AND f.from_cid = ? AND f.to_cid = t.citizenid))
        ORDER BY t.id ASC
    ]], { p.citizenid, p.citizenid, app, STORY_HOURS, p.citizenid, p.citizenid }) or {}

    -- Grouped by author, in the order the ring is drawn: yourself first, then anyone
    -- with something unseen, then the rest.
    local byAuthor, order = {}, {}
    for _, r in ipairs(rows) do
        local key = r.handle
        if not byAuthor[key] then
            byAuthor[key] = {
                handle = r.handle, displayname = r.displayname, avatar = r.avatar,
                mine = num(r.mine, 0) == 1, unseen = false, items = {},
            }
            order[#order + 1] = byAuthor[key]
        end
        local group = byAuthor[key]
        local seen = num(r.seen, 0) == 1
        if not seen then group.unseen = true end
        group.items[#group.items + 1] = { id = r.id, image = r.image, body = r.body, at = r.at, seen = seen }
    end
    table.sort(order, function(x, y)
        if x.mine ~= y.mine then return x.mine end
        if x.unseen ~= y.unseen then return x.unseen end
        return (x.handle or '') < (y.handle or '')
    end)
    resolve({ ok = true, stories = order })
end)

V.Callback('v-phone:soc:story', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end
    local image = tostring((data and data.image) or ''):sub(1, 300)
    if image == '' then resolve({ error = 'noimage' }) return end
    if not imageAllowed(image) then resolve({ error = 'badhost' }) return end

    MySQL.insert.await('INSERT INTO vphone_social_stories (app, citizenid, image, body) VALUES (?,?,?,?)',
        { app, p.citizenid, image, tostring((data and data.body) or ''):sub(1, 160) })
    resolve({ ok = true })
end)

V.Callback('v-phone:soc:storySeen', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end
    MySQL.insert.await('INSERT IGNORE INTO vphone_social_story_seen (story_id, citizenid) VALUES (?,?)',
        { id, p.citizenid })
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Direct messages
-- ══════════════════════════════════════════════════════════════
-- Separate from the phone's SMS on purpose: these are between two HANDLES, and neither
-- side learns the other's number by writing one.
V.Callback('v-phone:soc:dmList', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)

    local rows = MySQL.query.await([[
        SELECT a.handle, a.displayname, a.avatar,
               m.body, m.image, m.at, (m.from_cid = ?) AS mine,
               (SELECT COUNT(*) FROM vphone_social_dm u
                 WHERE u.app = m.app AND u.to_cid = ? AND u.seen = 0
                   AND u.from_cid = IF(m.from_cid = ?, m.to_cid, m.from_cid)) AS unread
        FROM vphone_social_dm m
        JOIN vphone_social_accounts a
          ON a.app = m.app AND a.citizenid = IF(m.from_cid = ?, m.to_cid, m.from_cid)
        WHERE m.app = ? AND (m.from_cid = ? OR m.to_cid = ?)
          AND m.id = (
            SELECT MAX(m2.id) FROM vphone_social_dm m2
            WHERE m2.app = m.app
              AND ((m2.from_cid = m.from_cid AND m2.to_cid = m.to_cid)
                OR (m2.from_cid = m.to_cid AND m2.to_cid = m.from_cid)))
        ORDER BY m.id DESC LIMIT 50
    ]], { p.citizenid, p.citizenid, p.citizenid, p.citizenid, app, p.citizenid, p.citizenid }) or {}

    for _, r in ipairs(rows) do
        r.mine = num(r.mine, 0) == 1
        r.unread = num(r.unread, 0)
    end
    resolve({ ok = true, threads = rows })
end)

V.Callback('v-phone:soc:dmThread', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    local cid = cidOfHandle(app, data and data.handle)
    if not cid then resolve({ error = 'nouser' }) return end

    local rows = MySQL.query.await([[
        SELECT id, body, image, at, (from_cid = ?) AS mine FROM vphone_social_dm
        WHERE app = ? AND ((from_cid = ? AND to_cid = ?) OR (from_cid = ? AND to_cid = ?))
        ORDER BY id ASC LIMIT 200
    ]], { p.citizenid, app, p.citizenid, cid, cid, p.citizenid }) or {}
    for _, r in ipairs(rows) do r.mine = num(r.mine, 0) == 1 end

    -- Opening the thread is reading it.
    MySQL.query.await('UPDATE vphone_social_dm SET seen = 1 WHERE app = ? AND from_cid = ? AND to_cid = ?',
        { app, cid, p.citizenid })

    local a = accountOf(cid, app)
    resolve({
        ok = true, messages = rows,
        account = a and { handle = a.handle, displayname = a.displayname, avatar = a.avatar } or nil,
    })
end)

V.Callback('v-phone:soc:dmSend', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end
    local cid = cidOfHandle(app, data and data.handle)
    if not cid then resolve({ error = 'nouser' }) return end
    if cid == p.citizenid then resolve({ error = 'self' }) return end

    local body = tostring((data and data.body) or ''):sub(1, 500)
    local image = tostring((data and data.image) or ''):sub(1, 300)
    if image ~= '' and not imageAllowed(image) then resolve({ error = 'badhost' }) return end
    if body:gsub('%s', '') == '' and image == '' then resolve({ error = 'empty' }) return end

    MySQL.insert.await('INSERT INTO vphone_social_dm (app, from_cid, to_cid, body, image) VALUES (?,?,?,?,?)',
        { app, p.citizenid, cid, body, image })

    -- A message they cannot see until they happen to open the app is a message that does
    -- not arrive. Tell the phone, which knows how to put it on their screen.
    local me = accountOf(p.citizenid, app)
    local target = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(cid)
    if target and target.source and GetResourceState('v-phone') == 'started' then
        pcall(function()
            exports['v-phone']:Notify(target.source, app, '@' .. (me and me.handle or '?'),
                body ~= '' and body or (Locales.fr or {})['soc.dm_photo'] or 'Photo')
        end)
    end
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Exports for other modules
-- ══════════════════════════════════════════════════════════════
exports('SocialHandle', function(cid, app)
    local a = accountOf(tostring(cid or ''), APPS[tostring(app or '')] and app or 'bleeter')
    return a and a.handle or nil
end)

--- Post as the system/an event, for modules that want to put something on Bleeter (a
--- news module, a race result). `handle` must be an account that exists.
exports('SocialPostAs', function(cid, kind, body, image)
    cid = tostring(cid or '')
    if not accountOf(cid, appOfKind(kind == 'photo' and 'photo' or 'text')) then return false end
    return MySQL.insert.await(
        'INSERT INTO vphone_social_posts (citizenid, kind, body, image) VALUES (?,?,?,?)',
        { cid, kind == 'photo' and 'photo' or 'text', tostring(body or ''):sub(1, 280),
          tostring(image or ''):sub(1, 300) }) ~= nil
end)

-- ══════════════════════════════════════════════════════════════
-- Lifecycle
-- ══════════════════════════════════════════════════════════════
-- ══════════════════════════════════════════════════════════════
-- Expiry
-- ══════════════════════════════════════════════════════════════
-- Every kind of row has its own clock, set in `Config.Social.retention` and overridable
-- per server in the admin panel. A throwaway story and a conversation are not the same
-- thing, so they are not swept on the same schedule - and 0 anywhere means "keep it".
local SWEEPS = {
    { kind = 'stories',  table = 'vphone_social_stories', label = 'story',   hours = true },
    { kind = 'posts',    table = 'vphone_social_posts',   label = 'post' },
    { kind = 'comments', table = 'vphone_social_comments', label = 'comment' },
    { kind = 'messages', table = 'vphone_social_dm',      label = 'message' },
}

function socialSweep(loud)
    for _, s in ipairs(SWEEPS) do
        local days = socKeep(s.kind)
        if days > 0 then
            -- Stories are measured in hours because a day is the whole of their life:
            -- rounding one to "yesterday" would keep it on screen for twice as long.
            local n = s.hours
                and MySQL.update.await(('DELETE FROM %s WHERE at < DATE_SUB(NOW(), INTERVAL ? HOUR)'):format(s.table),
                                       { math.max(1, math.floor(days * 24)) })
                or MySQL.update.await(('DELETE FROM %s WHERE at < DATE_SUB(NOW(), INTERVAL ? DAY)'):format(s.table),
                                      { days })
            if loud and n and n > 0 then
                print(('[v-phone] social: pruned %d %s(s) older than %d day(s)'):format(n, s.label, days))
            end
        end
    end

    -- Rows that only exist to point at something else. A like on a post that has been
    -- swept is not a like, it is a dangling key.
    MySQL.query.await('DELETE FROM vphone_social_likes WHERE post_id NOT IN (SELECT id FROM vphone_social_posts)')
    MySQL.query.await('DELETE FROM vphone_social_reposts WHERE post_id NOT IN (SELECT id FROM vphone_social_posts)')
    MySQL.query.await('DELETE FROM vphone_social_comments WHERE post_id NOT IN (SELECT id FROM vphone_social_posts)')
    MySQL.query.await('DELETE FROM vphone_social_story_seen WHERE story_id NOT IN (SELECT id FROM vphone_social_stories)')
end

--- Called by the phone once v-core is up and `Core` is known, because the phone is the
--- resource now and there is only one boot to wait for.
function SocialBoot(core)
    Core = core

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_accounts` (
        `citizenid` VARCHAR(16) NOT NULL,
        `app`       VARCHAR(12) NOT NULL DEFAULT 'bleeter',
        `handle`      VARCHAR(20) NOT NULL,
        `displayname` VARCHAR(40) NOT NULL DEFAULT '',
        `avatar`    VARCHAR(300) NOT NULL DEFAULT '',
        `bio`       VARCHAR(160) NOT NULL DEFAULT '',
        `phone`     VARCHAR(20) NOT NULL DEFAULT '',
        `password`  VARCHAR(80) NOT NULL DEFAULT '',
        `verified`  TINYINT(1) NOT NULL DEFAULT 0,
        PRIMARY KEY (`citizenid`, `app`),
        UNIQUE KEY `handle` (`app`, `handle`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- Accounts made before credentials existed keep working: they are marked verified and
    -- given the handle as a display name, so nobody is locked out by the upgrade.
    for col, ddl in pairs({
        displayname = "ADD COLUMN `displayname` VARCHAR(40) NOT NULL DEFAULT ''",
        phone       = "ADD COLUMN `phone` VARCHAR(20) NOT NULL DEFAULT ''",
        password    = "ADD COLUMN `password` VARCHAR(80) NOT NULL DEFAULT ''",
        verified    = "ADD COLUMN `verified` TINYINT(1) NOT NULL DEFAULT 0",
    }) do
        local has = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_social_accounts'
              AND COLUMN_NAME = ? LIMIT 1]], { col })
        if not has then MySQL.query.await('ALTER TABLE `vphone_social_accounts` ' .. ddl) end
    end
    MySQL.query.await("UPDATE `vphone_social_accounts` SET `verified` = 1 WHERE `verified` = 0 AND `password` = ''")
    MySQL.query.await("UPDATE `vphone_social_accounts` SET `displayname` = `handle` WHERE `displayname` = ''")

    -- A database created before accounts were per-app is migrated in place: existing
    -- rows become Bleeter accounts, which is what they were in spirit.
    local hasApp = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_social_accounts'
          AND COLUMN_NAME = 'app' LIMIT 1]])
    if not hasApp then
        MySQL.query.await("ALTER TABLE `vphone_social_accounts` ADD COLUMN `app` VARCHAR(12) NOT NULL DEFAULT 'bleeter'")
        MySQL.query.await("ALTER TABLE `vphone_social_accounts` DROP PRIMARY KEY, ADD PRIMARY KEY (`citizenid`, `app`)")
        MySQL.query.await("ALTER TABLE `vphone_social_accounts` DROP INDEX `handle`")
        MySQL.query.await("ALTER TABLE `vphone_social_accounts` ADD UNIQUE KEY `handle` (`app`, `handle`)")
        print('[v-social] accounts migrated to one per app')
    end

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_posts` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(16) NOT NULL,
        `kind`      VARCHAR(8)  NOT NULL DEFAULT 'text',
        `body`      VARCHAR(1000) NOT NULL DEFAULT '',
        `image`     VARCHAR(300) NOT NULL DEFAULT '',
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `kind_idx` (`kind`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_likes` (
        `post_id`   INT UNSIGNED NOT NULL,
        `citizenid` VARCHAR(16) NOT NULL,
        PRIMARY KEY (`post_id`, `citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_hush_profiles` (
        `citizenid` VARCHAR(16) NOT NULL,
        `bio`       VARCHAR(160) NOT NULL DEFAULT '',
        `photo`     VARCHAR(300) NOT NULL DEFAULT '',
        `active`    TINYINT(1) NOT NULL DEFAULT 1,
        PRIMARY KEY (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_hush_likes` (
        `from_cid` VARCHAR(16) NOT NULL,
        `to_cid`   VARCHAR(16) NOT NULL,
        `liked`    TINYINT(1) NOT NULL DEFAULT 0,
        `at`       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`from_cid`, `to_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_follows` (
        `app`      VARCHAR(12) NOT NULL DEFAULT 'bleeter',
        `from_cid` VARCHAR(16) NOT NULL,
        `to_cid`   VARCHAR(16) NOT NULL,
        `at`       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`app`, `from_cid`, `to_cid`), KEY `to_idx` (`app`, `to_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_comments` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `post_id`   INT UNSIGNED NOT NULL,
        `citizenid` VARCHAR(16) NOT NULL,
        `body`      VARCHAR(280) NOT NULL DEFAULT '',
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `post_idx` (`post_id`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_reposts` (
        `post_id`   INT UNSIGNED NOT NULL,
        `citizenid` VARCHAR(16) NOT NULL,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`post_id`, `citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_stories` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `app`       VARCHAR(12) NOT NULL DEFAULT 'snap',
        `citizenid` VARCHAR(16) NOT NULL,
        `image`     VARCHAR(300) NOT NULL DEFAULT '',
        `body`      VARCHAR(160) NOT NULL DEFAULT '',
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `live_idx` (`app`, `at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_story_seen` (
        `story_id`  INT UNSIGNED NOT NULL,
        `citizenid` VARCHAR(16) NOT NULL,
        PRIMARY KEY (`story_id`, `citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_dm` (
        `id`       INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `app`      VARCHAR(12) NOT NULL DEFAULT 'bleeter',
        `from_cid` VARCHAR(16) NOT NULL,
        `to_cid`   VARCHAR(16) NOT NULL,
        `body`     VARCHAR(500) NOT NULL DEFAULT '',
        `image`    VARCHAR(300) NOT NULL DEFAULT '',
        `seen`     TINYINT(1) NOT NULL DEFAULT 0,
        `at`       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `pair_idx` (`app`, `from_cid`, `to_cid`, `id`),
        KEY `inbox_idx` (`app`, `to_cid`, `seen`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    socialSweep(true)

    -- Once at boot is not enough for a server that stays up for weeks: a story is meant
    -- to be gone tomorrow, not gone at the next restart. The sweep runs hourly, which is
    -- often enough for a day-long expiry and cheap enough to ignore.
    CreateThread(function()
        while true do
            Wait(60 * 60 * 1000)
            socialSweep(false)
        end
    end)
end
