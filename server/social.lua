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

--- A stored TINYINT(1), as a boolean.
---
--- **oxmysql hands a TINYINT(1) column back as a Lua boolean, not as 0 or 1.** Its type cast
--- reads `case "TINY": return field.length === 1 ? field.string() === "1" : next()`, so the
--- driver has already decided. `tonumber(true)` is nil, which made every one of the twenty-one
--- `num(column, 0)` comparisons in this file false on every server: an account could be
--- verified in the database and in the staff command's own listing, and the badge still could
--- not appear anywhere.
---
--- All three shapes are accepted. A column that a computed expression produced - `EXISTS(...)`,
--- `(a.citizenid = ?)` - comes back as a number, and a schema created wider than TINYINT(1) by
--- an older build comes back as a number too.
local function truthy(v)
    if v == nil then return false end
    if type(v) == 'boolean' then return v end
    return (tonumber(v) or 0) ~= 0
end

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
--- A photo's URL may carry the phone's own edit recipe in its fragment. Stripped before the
--- host is read: a fragment never reaches the host, so it cannot bear on whether the host is
--- allowed, and on a URL with no path it would otherwise be read as part of the host itself.
local function withoutRecipe(url) return (tostring(url or ''):gsub('#.*$', '')) end

local function imageAllowed(url)
    url = withoutRecipe(url)
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

    -- A photograph this phone took. Without this, picking one out of the gallery for an avatar,
    -- a cover or a post was refused as `badhost` - the phone rejecting its own photograph
    -- because the operator had not listed the CDN the phone itself uploads to.
    if Bridge.MediaHasUrl and Bridge.MediaHasUrl(url) then return true end

    return false
end

--- The same gate, for the other apps that accept a picture.
---
--- Published rather than copied: a server that widens `socialImageHosts` widens it everywhere at
--- once. A second copy of this function is a second list to forget to update, and the symptom
--- would be one app refusing a photograph the app beside it accepts.
function PhoneImageAllowed(url)
    return imageAllowed(url)
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
        'SELECT citizenid, handle, displayname, avatar, cover, bio, phone, verified FROM vphone_social_accounts WHERE citizenid = ? AND app = ?',
        { cid, app })
end

--- The stored hash, fetched on its own.
---
--- `accountOf` deliberately does not select it, which is right - an account row is read on
--- nearly every screen and the hash has no business travelling with it. But `soc:login`
--- called `checkPw(a.password, ...)` against that row, and `a.password` was therefore always
--- nil, so `checkPw` returned false before it compared anything. Every sign-in failed,
--- including with the correct password, and the only way back into an account was a reset
--- that did not exist yet.
local function passwordOf(cid, app)
    return MySQL.scalar.await(
        'SELECT password FROM vphone_social_accounts WHERE citizenid = ? AND app = ?',
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
local Authed  = {}       -- [src] = { [app] = true }, this session's warm copy
local ResetTry = {}      -- [src] = { [app] = { n, at } }, the password-reset attempt counter.
                         -- Declared here rather than beside the reset code below, because
                         -- playerDropped clears it and that handler is above it - as a later
                         -- local it was a nil global there, and every disconnect raised.

-- Signing in USED to be session-only, so every script restart and every server reboot threw
-- the player back to a password prompt on a phone they had never left. It is their own
-- handset and their own account: the answer belongs with the character, not the session.
--
-- Kept in the phone's own KV table rather than in a new column, so there is nothing to
-- migrate and an operator can clear it by hand.
local AUTH_KEY = 'soc_auth'

local function authRecord(citizenid)
    local rec = Bridge.KvGet(citizenid, AUTH_KEY)
    return type(rec) == 'table' and rec or {}
end

local function isAuthed(src, citizenid, app)
    if Authed[src] and Authed[src][app] ~= nil then return Authed[src][app] == true end
    local on = authRecord(citizenid)[app] == true
    Authed[src] = Authed[src] or {}
    Authed[src][app] = on
    return on
end

local function setAuthed(src, citizenid, app, on)
    Authed[src] = Authed[src] or {}
    Authed[src][app] = on and true or false
    local rec = authRecord(citizenid)
    rec[app] = on and true or nil
    Bridge.KvSet(citizenid, AUTH_KEY, rec)
end

AddEventHandler('playerDropped', function()
    local src = source
    Pending[src] = nil
    Authed[src] = nil
    ResetTry[src] = nil
end)

local function phoneNumberOf(src)
    if GetResourceState('v-phone') ~= 'started' then return nil end
    local ok, n = pcall(function() return exports['v-phone']:NumberOf(src) end)
    return ok and n or nil
end

local function smsCode(src, app, code)
    if GetResourceState('v-phone') ~= 'started' then return end
    local name = APP_NAME[app] or 'iFruit'
    local text = (LP(src, 'ph.soc_code_sms')):format(code)

    -- A real message, in Messages, from the service that sent it. A banner disappears the
    -- moment you look away and the code goes with it; a text is still there when you come
    -- back to type it in, which is what anyone does with a verification code.
    pcall(function()
        local p = Core and Core.GetPlayer and Core.GetPlayer(src)
        if p and p.citizenid then
            exports['v-phone']:SendServiceMessage(p.citizenid, name:sub(1, 12), text)
        end
    end)

    -- And the banner as well, because the code is wanted immediately and the player is
    -- already looking at the sign-up screen rather than at Messages.
    pcall(function()
        exports['v-phone']:Notify(src, app, name, text)
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
    local authed = (a ~= nil) and isAuthed(src, p.citizenid, app) or false
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
    -- The cover banner. Same host gate as the avatar: it faces every visitor to the profile,
    -- so it is exactly as public as a post's image and gets the same check.
    local cover = tostring((data and data.cover) or ''):sub(1, 300)
    if cover ~= '' and not imageAllowed(cover) then resolve({ error = 'badhost' }) return end
    local bio = tostring((data and data.bio) or ''):sub(1, 160)

    if accountOf(p.citizenid, app) then resolve({ error = 'exists' }) return end
    local taken = MySQL.scalar.await(
        'SELECT 1 FROM vphone_social_accounts WHERE app = ? AND handle = ? LIMIT 1', { app, handle })
    if taken then resolve({ error = 'taken' }) return end

    -- **`verified` is 0, and the literal 1 that used to be here is the bug.**
    --
    -- Two different things share that word. Signing up VERIFIES YOUR NUMBER - the code texted
    -- to the phone, which is `pend.verified` a few lines above and is the gate on reaching this
    -- statement at all. The `verified` COLUMN is the blue tick, granted by staff with
    -- `/phoneadmin verify @handle` and by nothing else. Writing the first into the column of the
    -- second gave every account that ever registered a badge, which is the same as no badge:
    -- the one thing it is for is telling accounts apart.
    MySQL.query.await([[INSERT INTO vphone_social_accounts
        (citizenid, app, handle, displayname, avatar, bio, phone, password, verified)
        VALUES (?,?,?,?,?,?,?,?,0)]],
        { p.citizenid, app, handle, displayname, avatar, bio, pend.number, hashPw(pw) })

    Pending[src][app] = nil
    -- Registering signs you in, and that has to persist like any other sign-in.
    setAuthed(src, p.citizenid, app, true)
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
    if not checkPw(passwordOf(p.citizenid, app), tostring((data and data.password) or '')) then
        resolve({ error = 'badpass' }) return
    end
    setAuthed(src, p.citizenid, app, true)
    resolve({ ok = true, account = publicAccount(a) })
end)

-- ── Forgetting the password ────────────────────────────────────
-- The account is tied to this character's phone line, and the code goes to that line. So
-- "forgot my password" is answered the same way the account was created in the first place:
-- prove you hold the handset, then set a new one.
--
-- Rate limited per source. Without it this is a way to spam a player's own Messages, and -
-- more to the point - an attempt counter is what stops a four-digit code from being walked
-- through at leisure.
local function resetGate(src, app)
    ResetTry[src] = ResetTry[src] or {}
    local t = ResetTry[src][app]
    if not t or (os.time() - t.at) > 600 then
        t = { n = 0, at = os.time() }
        ResetTry[src][app] = t
    end
    t.n = t.n + 1
    return t.n <= 5
end

V.Callback('v-phone:soc:resetCode', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = tostring((data and data.app) or '')
    if not APPS[app] then resolve(false) return end
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end
    if not resetGate(src, app) then resolve({ error = 'toomany' }) return end

    local number = phoneNumberOf(src)
    if not number or number == '' then resolve({ error = 'nonumber' }) return end

    local code = genCode()
    Pending[src] = Pending[src] or {}
    Pending[src][app] = { code = code, number = number, at = os.time(), reset = true }
    smsCode(src, app, code)
    resolve({ ok = true, number = number })
end)

--- The code, and the password to put in its place. One call, so a verified code cannot be
--- left lying around between "it was right" and "here is the new one".
V.Callback('v-phone:soc:resetPassword', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = tostring((data and data.app) or '')
    if not APPS[app] then resolve(false) return end

    local pend = Pending[src] and Pending[src][app]
    if not pend or not pend.reset then resolve({ error = 'nocode' }) return end
    if (os.time() - pend.at) > 300 then
        Pending[src][app] = nil
        resolve({ error = 'expired' }) return
    end
    if not resetGate(src, app) then resolve({ error = 'toomany' }) return end

    local code = tostring((data and data.code) or ''):gsub('%s', '')
    if code ~= pend.code then resolve({ error = 'badcode' }) return end

    local pw = tostring((data and data.password) or '')
    if #pw < 4 then resolve({ error = 'password' }) return end

    local a = accountOf(p.citizenid, app)
    if not a then resolve({ error = 'noaccount' }) return end

    MySQL.query.await('UPDATE vphone_social_accounts SET password = ? WHERE citizenid = ? AND app = ?',
        { hashPw(pw), p.citizenid, app })

    -- The code is spent, the attempt counter is cleared, and the new password signs them in:
    -- making somebody type what they just chose is ceremony, not security.
    Pending[src][app] = nil
    ResetTry[src] = nil
    setAuthed(src, p.citizenid, app, true)
    resolve({ ok = true, account = publicAccount(a) })
end)

V.Callback('v-phone:soc:logout', function(src, resolve, data)
    local app = tostring((data and data.app) or '')
    local p = Core.GetPlayer(src)
    if p then setAuthed(src, p.citizenid, app, false) end
    resolve({ ok = true })
end)

V.Callback('v-phone:soc:setup', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local app = tostring((data and data.app) or 'bleeter')
    if not APPS[app] then resolve(false) return end
    -- Editing an existing profile, so it needs a logged-in account, not the sign-up path.
    if not isAuthed(src, p.citizenid, app) then resolve({ error = 'unverified' }) return end
    local a = accountOf(p.citizenid, app)
    if not a then resolve({ error = 'noaccount' }) return end

    local displayname = tostring((data and data.displayname) or a.displayname or ''):sub(1, 40)
    if displayname == '' then displayname = a.handle end
    local avatar = tostring((data and data.avatar) or ''):sub(1, 300)
    if avatar ~= '' and not imageAllowed(avatar) then resolve({ error = 'badhost' }) return end
    -- The cover banner. This declaration was missing and the UPDATE below read `cover` as a
    -- nil GLOBAL, so every profile save failed with "Column 'cover' cannot be null" - a hard
    -- error, on a column that had only just been added.
    --
    -- Same host gate as the avatar: it faces every visitor to the profile, so it is exactly as
    -- public as a post's image.
    local cover = tostring((data and data.cover) or ''):sub(1, 300)
    if cover ~= '' and not imageAllowed(cover) then resolve({ error = 'badhost' }) return end
    local bio = tostring((data and data.bio) or ''):sub(1, 160)

    -- The handle is the account's name on the server and does not change here; only the
    -- display name, avatar, cover and bio do.
    MySQL.query.await([[UPDATE vphone_social_accounts
        SET displayname = ?, avatar = ?, cover = ?, bio = ? WHERE citizenid = ? AND app = ?]],
        { displayname, avatar, cover, bio, p.citizenid, app })
    resolve({ ok = true, account = { handle = a.handle, displayname = displayname,
                                     avatar = avatar, cover = cover, bio = bio } })
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
    -- Whether THIS reader saved it. There is deliberately no count beside it: how many people
    -- bookmarked something is not information a save is supposed to leak.
    EXISTS(SELECT 1 FROM vphone_social_saves sv WHERE sv.post_id = s.id AND sv.citizenid = ?) AS saved,
    EXISTS(SELECT 1 FROM vphone_social_follows f WHERE f.app = a.app AND f.from_cid = ? AND f.to_cid = s.citizenid) AS following,
    (s.citizenid = ?) AS mine
]]

-- ══════════════════════════════════════════════════════════════
-- Being told about it
-- ══════════════════════════════════════════════════════════════
--- Who wrote a post, and which app it belongs to.
local function postAuthor(id)
    local row = MySQL.single.await('SELECT citizenid, app, kind FROM vphone_social_posts WHERE id = ?', { id })
    if not row then return nil end
    -- `app` on the row, with the old rule as the fallback for a row written before the
    -- column existed and somehow missed by the backfill.
    return row.citizenid, (row.app ~= '' and row.app) or appOfKind(row.kind)
end

--- File a notification, unless it is somebody being told about their own action.
---
--- Liking your own post, replying to yourself, following yourself: all legal, none of them
--- worth a badge on your own icon. The check is here rather than at each of the five call
--- sites so it cannot be forgotten at one of them.
local function notify(app, toCid, fromCid, kind, postId)
    toCid, fromCid = tostring(toCid or ''), tostring(fromCid or '')
    if toCid == '' or fromCid == '' or toCid == fromCid then return end
    MySQL.insert('INSERT INTO vphone_social_notifs (app, to_cid, from_cid, kind, post_id) VALUES (?,?,?,?,?)',
        { app, toCid, fromCid, tostring(kind), postId })
end

--- Lowercase the ASCII letters and nothing else.
---
--- `string.lower` is byte-wise and locale-dependent, and that is not a detail: on a Latin-1
--- locale it maps 0xC3 to 0xE3, and 0xC3 is the LEAD BYTE of every accented Latin character in
--- UTF-8. So `('#soirée'):lower()` does not return a lowercase tag, it returns a corrupt one -
--- which then goes into the database and comes back as a broken glyph.
---
--- Restricting the match to the byte range A-Z cannot touch anything above 0x7F. The trade is
--- that an accented capital stays capital, so #SOIRÉE and #soirée are two tags. That is a
--- visible imperfection rather than a silent corruption, which is the right way round.
local function lowerAscii(str)
    return (tostring(str):gsub('[A-Z]', string.lower))
end

--- Cut a string to a byte budget without leaving half a character behind.
---
--- Lua strings are bytes and the tag column counts characters, so a plain `sub(1, 40)` on
--- `#soirée` can stop between the two bytes of the é and store a broken sequence. This walks
--- back to the start of the character the boundary landed inside.
local function cutBytes(str, maxBytes)
    if #str <= maxBytes then return str end
    local nextByte = str:byte(maxBytes + 1)
    local cut = str:sub(1, maxBytes)
    -- 0x80..0xBF is a UTF-8 continuation byte: the boundary is mid-character.
    if nextByte and nextByte >= 0x80 and nextByte < 0xC0 then
        while #cut > 0 do
            local b = cut:byte(#cut)
            cut = cut:sub(1, #cut - 1)
            if b >= 0xC0 then break end   -- that was the lead byte; the character is gone
        end
    end
    return cut
end

--- Every #hashtag in a body, lowercased and de-duplicated.
---
--- Lowercased because #Ballas and #ballas are the same conversation, and a tag list that
--- disagrees with itself is worse than no tag list.
---
--- The pattern takes anything that is not whitespace and not another # or @, then trims
--- trailing punctuation, rather than allowing only `[%w_]`. `%w` is ASCII here, so the narrow
--- version cut `#soirée` into `soir` plus a stray byte - fine for an English server and wrong
--- for every other one. `lower()` leaves accented characters alone, which is the honest
--- outcome: it means #Soirée and #soirée are two tags, and mangling the bytes to avoid that
--- would be worse.
local function tagsIn(body)
    local seen, out = {}, {}
    -- The match is not reassigned: a generic-for control variable is const in Lua 5.5, and
    -- writing to it is a hard error there even though 5.4 allows it.
    for raw in tostring(body or ''):gmatch('#([^%s#@]+)') do
        -- A tag at the end of a sentence must not swallow the full stop.
        --
        -- The set is written out rather than using `%p`, and it is a Lua long string so no
        -- character in it needs escaping. Lua patterns work on BYTES and `ispunct` is true for
        -- 0xA9 - the second byte of an e-acute - so `%p` stripped that byte and left its lead
        -- byte dangling, which is an invalid UTF-8 sequence in the database. Every character
        -- listed here is ASCII, so no multi-byte sequence can be touched.
        local trimmed = raw:gsub([=[[%.,;:!%?%)%]}>"']+$]=], '')
        local tag = cutBytes(lowerAscii(trimmed), 40)
        if #tag >= 2 and not seen[tag] then
            seen[tag] = true
            out[#out + 1] = tag
            if #out >= 10 then break end   -- a post is not a tag dump
        end
    end
    return out
end

--- Every @handle in a body, lowercased and de-duplicated.
---
--- Deliberately narrower than the tag pattern: registration strips a handle to `[%w_]`, so a
--- wider pattern here could only ever match text that is not an account.
local function handlesIn(body)
    local seen, out = {}, {}
    for raw in tostring(body or ''):gmatch('@([%w_]+)') do
        -- Same treatment, for the same reason: registration filters a handle with `%w`, which
        -- is also byte-wise, so a handle can in principle hold a byte that `lower` would ruin.
        local handle = lowerAscii(raw):sub(1, 20)
        if #handle >= 2 and not seen[handle] then
            seen[handle] = true
            out[#out + 1] = handle
            if #out >= 10 then break end
        end
    end
    return out
end

--- Index a new post's tags, and tell everybody it mentioned.
local function indexPost(id, app, body, authorCid)
    for _, tag in ipairs(tagsIn(body)) do
        MySQL.insert('INSERT IGNORE INTO vphone_social_tags (post_id, app, tag) VALUES (?,?,?)',
            { id, app, tag })
    end
    for _, handle in ipairs(handlesIn(body)) do
        local cid = cidOfHandle(app, handle)
        if cid then notify(app, cid, authorCid, 'mention', id) end
    end
end

--- MySQL answers booleans as 0/1 and counts as strings. The page should receive the
--- types it is going to render, not the types the driver happened to return.
local function cleanPosts(rows)
    for _, r in ipairs(rows or {}) do
        r.likes = num(r.likes, 0)
        r.comments = num(r.comments, 0)
        r.reposts = num(r.reposts, 0)
        r.liked = truthy(r.liked)
        r.reposted = truthy(r.reposted)
        r.saved = truthy(r.saved)
        r.following = truthy(r.following)
        r.verified = truthy(r.verified)
        r.mine = truthy(r.mine)
    end
    return rows or {}
end

-- ══════════════════════════════════════════════════════════════
-- The feed
-- ══════════════════════════════════════════════════════════════
-- One table, two apps. The same feed with different chrome, filtered on `s.app` - which is
-- what the post was actually filed under, rather than on its content type. Bleeter carries
-- text AND pictures, like the thing it is modelled on; Snapmatic carries pictures only,
-- because it is a photo app.
V.Callback('v-phone:soc:feed', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    -- The client still says which feed it wants by content type, because that is how the two
    -- apps are told apart on screen; the server turns it into an app name once, here.
    local photo = (data and data.kind == 'photo')
    -- `appOf` already falls back to 'bleeter', so this is the client's app when it named one
    -- and the content type's app otherwise - which keeps an older page working.
    local app = (data and data.app) and appOf(data) or appOfKind(photo and 'photo' or 'text')

    local kindWhere = 's.app = ?'

    -- Two feeds, one query: everything, or only the accounts you follow plus your own.
    -- A "following" tab that quietly showed strangers would not be worth having.
    local following = (data and data.scope) == 'following'
    local where = following
        and [[ AND (s.citizenid = ? OR EXISTS(
                 SELECT 1 FROM vphone_social_follows f WHERE f.app = a.app
                   AND f.from_cid = ? AND f.to_cid = s.citizenid))]]
        or ''

    -- Five, not four: POST_COLUMNS gained `saved`. Miscounting these silently shifts every
    -- later placeholder along by one, which is the kind of bug that answers with somebody
    -- else's rows rather than with an error.
    local args = { p.citizenid, p.citizenid, p.citizenid, p.citizenid, p.citizenid, app }
    -- One placeholder now, for `s.app = ?`. It used to be one or two depending on the feed,
    -- and a miscount here shifts every later binding silently.
    args[#args + 1] = app
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
    -- The app the client named, and it is now recorded on the row rather than inferred back
    -- out of `kind` later. A clip is a photo that moves: it shares the account, the host
    -- gate and the feed, with its media URL in `image`.
    --
    -- Snapmatic is a photo app, so a text post addressed to it is filed on Bleeter instead -
    -- that is the only case where the client's choice is overruled, and it is overruled
    -- towards the app that can actually show the thing.
    local raw = (data and data.kind) or 'text'
    local kind = (raw == 'photo' or raw == 'video') and raw or 'text'
    local wantApp = tostring((data and data.app) or '')
    local mediaApp = (wantApp == 'bleeter' or wantApp == 'snap') and wantApp or appOfKind(kind)
    if kind == 'text' then mediaApp = 'bleeter' end
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
        'INSERT INTO vphone_social_posts (citizenid, app, kind, body, image) VALUES (?,?,?,?,?)',
        { p.citizenid, mediaApp, kind, body, image })
    Core.Log('social', ('%s posted %s #%d'):format(p.citizenid, kind, id), nil, p.citizenid)
    -- Hashtags into their own table, and anybody the post named gets told. Both read the
    -- body that was actually stored, not the one that arrived, so a truncated post cannot
    -- index a tag the reader will never see.
    -- `mediaApp`, which is what this post was actually filed under. `appOfKind(kind)` would
    -- say 'snap' for every photo, so a photo posted to Bleeter would have its tags indexed
    -- against the wrong app and never appear under them.
    if id then indexPost(id, mediaApp, body, p.citizenid) end
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
        -- Only on the way up. Somebody who likes, unlikes and likes again has not done
        -- three things worth being told about.
        local author, app = postAuthor(id)
        if author then notify(app, author, p.citizenid, 'like', id) end
    end
    local count = num(MySQL.scalar.await(
        'SELECT COUNT(*) FROM vphone_social_likes WHERE post_id = ?', { id }), 0)
    resolve({ ok = true, liked = liked, likes = count })
end)

-- ══════════════════════════════════════════════════════════════
-- Hush
-- ══════════════════════════════════════════════════════════════
local function hushOn() return socOn() and V.SettingBool('socialHush', SOC.hush.enabled) end

--- What a profile may say about itself, as closed sets.
---
--- **Every one of these is drawn on a stranger's screen.** Free text there is free text in
--- somebody else's markup, and it is also untranslatable - the page turns `hobby_cars` into
--- whatever the reader's language calls it, which a typed string could never do. A key that is
--- not in the set is dropped rather than refused: an older page sending an option this build
--- removed should lose that one field, not fail to save a profile.
local HUSH_LOOKING = { serious = true, casual = true, friends = true, unsure = true }
local HUSH_INTERESTS = {
    cars = true, music = true, food = true, gym = true, films = true, games = true,
    nights = true, beach = true, hiking = true, art = true, animals = true, travel = true,
    fishing = true, bikes = true, coffee = true, dancing = true, cooking = true, guns = true,
}
--- The conversation starters. The KEY is the question and the player writes the answer, which
--- is the one piece of free text on a Hush card - capped, stripped, and escaped by the page.
local HUSH_PROMPTS = {
    perfect_night = true, never_again = true, order_at_bar = true, worst_habit = true,
    find_me = true, deal_breaker = true, sunday = true, brag = true,
}

--- A stored `interests` column back into a list, dropping anything not in the set.
---
--- Filtered on the way OUT as well as on the way in. A row written by an older build, by hand,
--- or by an operator's own migration can hold a key this build does not know, and the page turns
--- a key into a translated chip - so an unknown one would draw a locale key on a stranger's
--- profile.
local function hushSplit(csv)
    local out = {}
    for key in tostring(csv or ''):gmatch('([^,]+)') do
        if HUSH_INTERESTS[key] and #out < 6 then out[#out + 1] = key end
    end
    return out
end

--- The keys of a closed set, sorted, so the page's picker is in the same order every time it
--- is drawn. `pairs` has no order, and a picker whose rows move between visits is a picker
--- nobody can build a habit with.
local function hushKeys(set)
    local out = {}
    for key in pairs(set) do out[#out + 1] = key end
    table.sort(out)
    return out
end

--- How much a day of Hush Premium costs, and what it buys. Read through `V.Setting` so an
--- operator can move the price with a convar on a live server.
local function hushPass()
    local cfg = (SOC.hush and SOC.hush.premium) or {}
    return {
        on = cfg.enabled ~= false,
        price = math.max(0, math.floor(num(V.Setting('socialHushPrice', cfg.price), 50))),
        account = (cfg.account == 'cash') and 'cash' or 'bank',
        hours = math.max(1, math.floor(num(cfg.hours, 24))),
        likes = math.max(1, math.floor(num(cfg.likes, 25))),
        supers = math.max(0, math.floor(num(cfg.superLikes, 5))),
        seeLikes = cfg.seeLikes ~= false,
        rewindLikes = cfg.rewindLikes ~= false,
    }
end

--- Characters with a pass purchase in flight, so a second tap cannot start another.
---
--- Keyed by citizen id rather than by source: a staff member holding somebody's phone acts as
--- that character, and it is the CHARACTER who may only be buying one pass at a time.
local HushBuying = {}

--- Likes and super likes this character has claimed but not yet written.
---
--- **The cap is counted from rows, and the row is written last.** `hushLikeCaps`, `hushSpent`
--- and the "already judged?" read are three awaits before the INSERT, so every request issued
--- in the same tick read the same count and every one of them passed - which on the free tier
--- turns three likes a day into as many as the page cares to fire, and the cap is precisely
--- what the premium pass is sold to raise.
---
--- A lock would have closed it and refused a legitimate second swipe while the first was still
--- in flight, which on a swipe deck IS the feature breaking. Counting the writes in flight
--- refuses nothing extra: the count is read and the claim taken with no yield between them, and
--- Lua only interleaves coroutines at a yield, so those two lines are atomic.
local HushFlight = {}

AddEventHandler('playerDropped', function()
    local p = Core.GetPlayer(source)
    if p and p.citizenid then HushFlight[p.citizenid] = nil end
end)

--- Is this character's pass still running, and until when?
---
--- Read from the database on every call rather than cached. A cache here would have to be
--- invalidated by a purchase, by the clock, and by a character switch, and the read is a scalar
--- on the primary key.
local function hushPremiumUntil(cid)
    local until_ = MySQL.scalar.await(
        'SELECT premium_until FROM vphone_hush_profiles WHERE citizenid = ?', { cid })
    until_ = math.floor(num(until_, 0))
    return (until_ > os.time()) and until_ or 0
end

--- The like ceiling for this character today: the free one, or the pass's.
local function hushLikeCaps(cid)
    local pass = hushPass()
    local premium = pass.on and hushPremiumUntil(cid) > 0
    if premium then return pass.likes, pass.supers, true end
    return math.max(0, math.floor(num(V.Setting('socialDailyLikes', SOC.hush.dailyLikes), 3))),
           math.max(0, math.floor(num(SOC.hush.dailySuper, 1))), false
end

--- How many likes and super likes this character has spent in the last day.
local function hushSpent(cid)
    local row = MySQL.single.await([[SELECT
            SUM(liked = 1) AS likes,
            SUM(liked = 1 AND super = 1) AS supers
        FROM vphone_hush_likes
        WHERE from_cid = ? AND at > DATE_SUB(NOW(), INTERVAL 1 DAY)]], { cid }) or {}
    return math.floor(num(row.likes, 0)), math.floor(num(row.supers, 0))
end

--- The current year, for the age arithmetic in SQL. Read once: it is a constant for any
--- session short enough to matter, and calling os.date per row would be silly.
local THIS_YEAR = tonumber(os.date('%Y')) or 2026

--- How far away another character is, in metres, or nil when they are not connected.
---
--- Rounded to ten metres before it leaves the server. A dating app has no business handing one
--- player another's exact position, and "260 m" is as useful as "263.4 m" while being useless
--- for finding somebody who has not agreed to be found.
local function hushDistance(src, targetCid)
    local target = Core.GetPlayerByCitizenId(targetCid)
    if not target or not target.source then return nil end
    local ok, metres = pcall(function()
        -- Hush measures the distance from the phone's OWNER, so a staff member holding one
        -- does not put the deck around themselves.
        local a = GetEntityCoords(GetPlayerPed(PhoneActingSource
            and PhoneActingSource(src) or src))
        local b = GetEntityCoords(GetPlayerPed(target.source))
        return #(a - b)
    end)
    if not ok or not metres then return nil end
    return math.floor(metres / 10) * 10
end

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
    local row = MySQL.single.await([[SELECT bio, photo, photo2, photo3, gender, seeking,
        min_age, max_age, active, job, looking, interests, prompt, prompt_answer,
        premium_until FROM vphone_hush_profiles WHERE citizenid = ?]], { p.citizenid })

    local pass = hushPass()
    local until_ = math.floor(num(row and row.premium_until, 0))
    if until_ <= os.time() then until_ = 0 end
    local likeCap, superCap, premium = hushLikeCaps(p.citizenid)
    local likesUsed, supersUsed = hushSpent(p.citizenid)

    resolve({
        ok = true,
        profile = row and {
            bio = row.bio, photo = row.photo, photo2 = row.photo2, photo3 = row.photo3,
            gender = row.gender, seeking = row.seeking,
            minAge = num(row.min_age, 18), maxAge = num(row.max_age, 99),
            active = truthy(row.active),
            job = row.job, looking = row.looking, prompt = row.prompt,
            promptAnswer = row.prompt_answer,
            interests = hushSplit(row.interests),
        } or nil,
        -- What this player may still do today, so the page can say "2 likes left" instead of
        -- letting them find out by being refused.
        limits = {
            likes = likeCap, likesUsed = likesUsed,
            supers = superCap, supersUsed = supersUsed,
            premium = premium, until_ = until_,
        },
        -- The shop window for the pass. Sent whether or not they have one: the page draws the
        -- price on the buy button and the renewal date on the badge from the same fields.
        pass = pass.on and {
            price = pass.price, account = pass.account, hours = pass.hours,
            likes = pass.likes, supers = pass.supers,
            seeLikes = pass.seeLikes, rewindLikes = pass.rewindLikes,
        } or nil,
        -- The closed sets, so the page builds its pickers from what the server will accept
        -- rather than from a copy that drifts.
        options = { looking = hushKeys(HUSH_LOOKING), interests = hushKeys(HUSH_INTERESTS),
                    prompts = hushKeys(HUSH_PROMPTS) },
    })
end)

--- Buy a day of Hush Premium.
---
--- **The money moves before the pass is granted, and a debit that cannot be confirmed grants
--- nothing.** `Bridge.RemoveMoney` answers false on every framework it supports when the
--- balance will not cover it, and the operator's own hook is asked first - so this works on
--- qb-core, qbx_core, ox_core, ESX and anything wired through `Config.Compat.hooks.removeMoney`
--- without a branch here per framework.
V.Callback('v-phone:soc:hushPass', function(src, resolve)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local pass = hushPass()
    if not pass.on then resolve({ error = 'off' }) return end

    -- A profile has to exist first: the pass is a column on it, and buying a pass for a
    -- profile nobody can be shown is spending money on nothing.
    local has = MySQL.scalar.await(
        'SELECT 1 FROM vphone_hush_profiles WHERE citizenid = ?', { p.citizenid })
    if not has then resolve({ error = 'noprofile' }) return end

    -- **One purchase at a time per character.**
    --
    -- Everything below yields: the debit, the update, the read back. Two taps on the buy
    -- button in the same second both got past the checks, both were charged, and both wrote
    -- the same expiry - so the player paid twice for one day. The flag is cleared on every
    -- exit path below, including the refusal.
    if HushBuying[p.citizenid] then resolve({ error = 'busy' }) return end
    HushBuying[p.citizenid] = true

    -- **The money comes off the phone's OWNER, not off whoever is holding it.**
    --
    -- Under a staff phone-view session `Core.GetPlayer(src)` answers with the held character -
    -- that is the whole point of admin view - but `src` is still the staff member. So the
    -- purchase was granted to the character on screen and paid for out of the wallet of the
    -- person looking at it. Every other paying path in this resource resolves the actor
    -- through `PhoneActingSource` first, and this one did not.
    local acting = PhoneActingSource and PhoneActingSource(src) or src

    if pass.price > 0 then
        local paid = Bridge.RemoveMoney(acting, pass.price, pass.account, 'Hush Premium')
        if paid ~= true then
            HushBuying[p.citizenid] = nil
            resolve({ error = 'nomoney' })
            return
        end
    end

    -- **The extension is computed in SQL, against the stored value.**
    --
    -- Reading the expiry into Lua, adding a day and writing the result back is a check-then-act
    -- across three awaits. `GREATEST` does the same arithmetic inside the statement, where
    -- nothing can interleave.
    MySQL.query.await([[UPDATE vphone_hush_profiles
        SET premium_until = GREATEST(COALESCE(premium_until, 0), UNIX_TIMESTAMP()) + ?
        WHERE citizenid = ?]], { pass.hours * 3600, p.citizenid })
    HushBuying[p.citizenid] = nil
    local until_ = hushPremiumUntil(p.citizenid)
    Core.Log('social', ('hush premium %s for %dh (%d)')
        :format(p.citizenid, pass.hours, pass.price), nil, p.citizenid)

    local likeCap, superCap = hushLikeCaps(p.citizenid)
    local likesUsed, supersUsed = hushSpent(p.citizenid)
    resolve({ ok = true, until_ = until_,
              limits = { likes = likeCap, likesUsed = likesUsed, supers = superCap,
                         supersUsed = supersUsed, premium = true, until_ = until_ } })
end)

--- Who has liked you and is waiting for an answer. **The pass buys this.**
---
--- Without it the page is told how many there are and nothing else, which is the honest version
--- of the tease every dating app runs: the count is real, and paying reveals the faces rather
--- than inventing them.
V.Callback('v-phone:soc:hushLikedMe', function(src, resolve)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    -- Only people I have not already judged. Somebody I passed on is not waiting for me.
    local rows = MySQL.query.await([[SELECT h.citizenid, h.photo, h.job, h.bio, l.super,
               c.firstname, c.dob
        FROM vphone_hush_likes l
        JOIN vphone_hush_profiles h ON h.citizenid = l.from_cid AND h.active = 1
        JOIN vphone_characters c ON c.citizenid = l.from_cid
        WHERE l.to_cid = ? AND l.liked = 1
          AND NOT EXISTS (SELECT 1 FROM vphone_hush_likes m
                          WHERE m.from_cid = ? AND m.to_cid = l.from_cid)
        ORDER BY l.super DESC, l.at DESC LIMIT 30]], { p.citizenid, p.citizenid }) or {}

    local pass = hushPass()
    local premium = pass.on and pass.seeLikes and hushPremiumUntil(p.citizenid) > 0
    if not premium then
        -- The COUNT and nothing else. No name, no photograph, no citizen id - a payload that
        -- carries them and a page that blurs them is a payload anybody can read.
        resolve({ ok = true, locked = true, count = #rows })
        return
    end

    local out = {}
    for i, r in ipairs(rows) do
        out[i] = { ref = r.citizenid, name = r.firstname, age = ageFrom(r.dob),
                   photo = r.photo, job = r.job, bio = r.bio, super = truthy(r.super) }
    end
    resolve({ ok = true, locked = false, count = #out, people = out })
end)

V.Callback('v-phone:soc:hushSetup', function(src, resolve, data)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local bio = tostring((data and data.bio) or ''):sub(1, SOC.bioMax)
    -- Three photographs, each through the host gate: they face every profile this one is
    -- shown to, so they are as public as a post's image.
    local photos = {}
    for i, key in ipairs({ 'photo', 'photo2', 'photo3' }) do
        local url = tostring((data and data[key]) or ''):sub(1, 300)
        if url ~= '' and not imageAllowed(url) then resolve({ error = 'badhost' }) return end
        photos[i] = url
    end
    local active = (data and data.active == false) and 0 or 1

    -- Who this profile is, and who it wants to see. Self-declared on both counts: the
    -- framework's idea of a character's sex is a different question from who they are looking
    -- for, and a dating app that decides the second one for somebody is not a dating app.
    local gender = tostring((data and data.gender) or '')
    gender = (gender == 'm' or gender == 'f') and gender or ''
    local seeking = tostring((data and data.seeking) or 'all')
    if seeking ~= 'm' and seeking ~= 'f' then seeking = 'all' end

    -- The age range, bounded and ordered. 18 is the floor because everybody on this app is an
    -- adult, and swapping a reversed pair is kinder than refusing it.
    local minAge = math.max(18, math.min(99, math.floor(num(data and data.minAge, 18))))
    local maxAge = math.max(18, math.min(99, math.floor(num(data and data.maxAge, 99))))
    if minAge > maxAge then minAge, maxAge = maxAge, minAge end

    -- What they do. The one free-text field besides the bio and the prompt answer, and it is
    -- a job title rather than a sentence - forty characters, stripped of control codes.
    local job = tostring((data and data.job) or ''):gsub('%c', ' '):gsub('%s+', ' ')
    job = job:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 40)

    -- Closed sets from here down. An unknown key is DROPPED rather than refused, so a page a
    -- build behind loses one field instead of failing to save the profile at all.
    local looking = tostring((data and data.looking) or '')
    if not HUSH_LOOKING[looking] then looking = '' end

    local interests = {}
    local seenTag = {}
    for _, key in ipairs((data and type(data.interests) == 'table' and data.interests) or {}) do
        key = tostring(key or '')
        if HUSH_INTERESTS[key] and not seenTag[key] and #interests < 6 then
            seenTag[key] = true
            interests[#interests + 1] = key
        end
    end

    local prompt = tostring((data and data.prompt) or '')
    if not HUSH_PROMPTS[prompt] then prompt = '' end
    local answer = tostring((data and data.promptAnswer) or ''):gsub('%c', ' '):gsub('%s+', ' ')
    answer = answer:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 140)
    -- An answer with no question is a line of text nothing introduces, and a question with no
    -- answer is a blank on the card. Neither is kept.
    if prompt == '' or answer == '' then prompt, answer = '', '' end

    MySQL.query.await([[INSERT INTO vphone_hush_profiles
            (citizenid, bio, photo, photo2, photo3, gender, seeking, min_age, max_age, active,
             job, looking, interests, prompt, prompt_answer)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE bio=VALUES(bio), photo=VALUES(photo), photo2=VALUES(photo2),
            photo3=VALUES(photo3), gender=VALUES(gender), seeking=VALUES(seeking),
            min_age=VALUES(min_age), max_age=VALUES(max_age), active=VALUES(active),
            job=VALUES(job), looking=VALUES(looking), interests=VALUES(interests),
            prompt=VALUES(prompt), prompt_answer=VALUES(prompt_answer)]],
        { p.citizenid, bio, photos[1], photos[2], photos[3], gender, seeking,
          minAge, maxAge, active, job, looking, table.concat(interests, ','), prompt, answer })
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
    local me = MySQL.single.await(
        'SELECT gender, seeking, min_age, max_age FROM vphone_hush_profiles WHERE citizenid = ?',
        { p.citizenid }) or {}

    -- **Both** preferences, not one.
    --
    -- Showing somebody a profile that would never want them back is how a dating app wastes
    -- everybody's time: a card that cannot become a match is a card that should not be dealt.
    -- So the deck filters on what THIS player is looking for and on whether the other profile
    -- is looking for them. `seeking = 'all'` and a blank gender both mean "no opinion", which
    -- has to pass rather than exclude - most profiles will not have filled this in.
    local wants = tostring(me.seeking or 'all')
    local myGender = tostring(me.gender or '')
    local minAge = math.max(18, math.floor(num(me.min_age, 18)))
    local maxAge = math.max(minAge, math.floor(num(me.max_age, 99)))

    local row = MySQL.single.await(([[
        SELECT h.citizenid, h.bio, h.photo, h.photo2, h.photo3, h.gender,
               h.job, h.looking, h.interests, h.prompt, h.prompt_answer,
               c.firstname, c.dob
        FROM vphone_hush_profiles h
        JOIN vphone_characters c ON c.citizenid = h.citizenid
        WHERE h.active = 1 AND h.citizenid <> ?
          AND NOT EXISTS (SELECT 1 FROM vphone_hush_likes l
                          WHERE l.from_cid = ? AND l.to_cid = h.citizenid
                            AND (l.liked = 1%s))
          -- What I am looking for.
          AND (? = 'all' OR h.gender = '' OR h.gender = ?)
          -- And what they are looking for, when either of us has said.
          AND (h.seeking = 'all' OR ? = '' OR h.seeking = ?)
          -- Age, both ways: mine of them, and theirs of me.
          AND (c.dob IS NULL OR c.dob = ''
               OR (%d - CAST(LEFT(c.dob, 4) AS UNSIGNED)) BETWEEN ? AND ?)
        ORDER BY RAND() LIMIT 1
    ]]):format(passDays > 0
        and (' OR l.at > DATE_SUB(NOW(), INTERVAL %d DAY)'):format(passDays)
        or ' OR 1 = 1', THIS_YEAR),
        { p.citizenid, p.citizenid, wants, wants, myGender, myGender, minAge, maxAge })
    if not row then resolve({ ok = true, profile = nil }) return end

    local photos = {}
    for _, url in ipairs({ row.photo, row.photo2, row.photo3 }) do
        if url and url ~= '' then photos[#photos + 1] = tostring(url) end
    end

    -- What the two of them have in common, worked out here rather than on the page: the page
    -- does not hold the reader's own profile while a card is on screen, and a shared interest
    -- is the single most useful thing a dating card can say.
    local mineTags = {}
    for _, key in ipairs(hushSplit(MySQL.scalar.await(
        'SELECT interests FROM vphone_hush_profiles WHERE citizenid = ?', { p.citizenid }))) do
        mineTags[key] = true
    end
    local theirTags, shared = hushSplit(row.interests), {}
    for _, key in ipairs(theirTags) do
        if mineTags[key] then shared[#shared + 1] = key end
    end

    local likeCap, superCap, premium = hushLikeCaps(p.citizenid)
    local likesUsed, supersUsed = hushSpent(p.citizenid)

    resolve({ ok = true,
      limits = { likes = likeCap, likesUsed = likesUsed, supers = superCap,
                 supersUsed = supersUsed, premium = premium },
      profile = {
        ref = row.citizenid, name = row.firstname, age = ageFrom(row.dob),
        bio = row.bio, photo = row.photo, photos = photos,
        job = row.job, looking = row.looking,
        interests = theirTags, shared = shared,
        prompt = row.prompt, promptAnswer = row.prompt_answer,
        -- How far away, in metres, when they are connected. A dating app without distance is a
        -- pen-pal service, and on a server the answer is genuinely useful.
        distance = hushDistance(src, row.citizenid),
        -- Did they already super like me? Tinder shows this before the swipe, and it is the
        -- whole point of a super like.
        superOnMe = MySQL.scalar.await([[SELECT 1 FROM vphone_hush_likes
            WHERE from_cid = ? AND to_cid = ? AND liked = 1 AND super = 1]],
            { row.citizenid, p.citizenid }) ~= nil,
    } })
end)

V.Callback('v-phone:soc:hushChoice', function(src, resolve, data)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local target = tostring((data and data.ref) or '')
    if target == '' or target == p.citizenid then resolve(false) return end

    local liked = data and data.like == true
    local super = liked and (data and data.super == true) or false

    -- Set when a like is claimed against the in-flight count below, and given back the moment
    -- the row it was claiming for has been written - or the request has failed.
    local claimed = false
    local function unclaim()
        if not claimed then return end
        claimed = false
        local held = HushFlight[p.citizenid]
        if not held then return end
        held.likes = held.likes - 1
        held.supers = held.supers - (super and 1 or 0)
        if held.likes <= 0 and held.supers <= 0 then HushFlight[p.citizenid] = nil end
    end

    -- A super like is capped hard and separately from ordinary likes. That cap IS the feature:
    -- a signal everybody can send at will says nothing.
    -- **Both ceilings are read BEFORE the row is written**, not after.
    --
    -- The like ceiling used to be checked by inserting the row and counting afterwards, then
    -- deleting it again when the count came out too high. That is a write, a read and a write
    -- to answer a question the first read could have answered - and it left a window in which
    -- a second request saw the row that was about to be removed. The pass moves both numbers,
    -- so this is also where the pass earns its money.
    local likeCap, superCap = hushLikeCaps(p.citizenid)
    if liked then
        local likesUsed, supersUsed = hushSpent(p.citizenid)
        -- Already judged? Then this is a change of mind on a card that came round again, and
        -- it does not spend a second like.
        local already = MySQL.scalar.await([[SELECT liked FROM vphone_hush_likes
            WHERE from_cid = ? AND to_cid = ?]], { p.citizenid, target })
        local spends = num(already, 0) ~= 1

        -- **No yield from here to the claim below**, which is what makes this hold.
        local flight = HushFlight[p.citizenid] or { likes = 0, supers = 0 }
        if spends and (likesUsed + flight.likes) >= likeCap then
            resolve({ error = 'limit', cap = likeCap, premium = false }) return
        end
        if super and (supersUsed + flight.supers) >= superCap then
            resolve({ error = 'superlimit', cap = superCap }) return
        end
        if spends then
            HushFlight[p.citizenid] = {
                likes = flight.likes + 1,
                supers = flight.supers + (super and 1 or 0),
            }
            claimed = true
        end
    end

    -- A pass is recorded too, or the same face comes back every time the app opens. It
    -- is an UPDATE rather than an IGNORE because a pass expires: seeing somebody again
    -- has to restart their clock, otherwise the second pass never sticks.
    MySQL.insert.await([[INSERT INTO vphone_hush_likes (from_cid, to_cid, liked, super)
            VALUES (?,?,?,?)
        ON DUPLICATE KEY UPDATE liked = VALUES(liked), super = VALUES(super),
            at = CURRENT_TIMESTAMP]],
        { p.citizenid, target, liked and 1 or 0, super and 1 or 0 })

    -- The row exists, so the claim is redundant: `hushSpent` counts it from here on.
    unclaim()

    -- What is left, so the page can count down without asking again.
    local likesLeft, supersLeft = hushSpent(p.citizenid)
    likesLeft = math.max(0, likeCap - likesLeft)
    supersLeft = math.max(0, superCap - supersLeft)

    if not liked then
        resolve({ ok = true, match = false, left = likesLeft, supersLeft = supersLeft })
        return
    end

    local mutual = MySQL.scalar.await(
        'SELECT 1 FROM vphone_hush_likes WHERE from_cid = ? AND to_cid = ? AND liked = 1',
        { target, p.citizenid })
    if not mutual then resolve({ ok = true, match = false }) return end

    -- The match: a first name, and nothing else.
    --
    -- **No phone number, and no SMS.** This used to look each side's number up and text both of
    -- them, which handed each person the other's number at the moment of matching - the one
    -- thing Hush is not supposed to do, and it survived the change that took the number out of
    -- the match LIST because the number left by a different door. The conversation Hush needs
    -- is its own: `hushChat` addresses by the match and never learns who is on the other end.
    local them = MySQL.single.await('SELECT firstname FROM vphone_characters WHERE citizenid = ?', { target })

    Core.Log('social', ('hush match %s <-> %s'):format(p.citizenid, target), nil, p.citizenid)
    resolve({ ok = true, match = true, name = them and them.firstname or '?', super = super,
              left = likesLeft, supersLeft = supersLeft })
end)

--- Undo the last pass.
---
--- Only a PASS. Undoing a like would let somebody take back a match after seeing who it was,
--- and a match is the one thing on this app that both sides agreed to - it is not a decision
--- one of them gets to reverse quietly.
V.Callback('v-phone:soc:hushRewind', function(src, resolve)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local row = MySQL.single.await([[SELECT to_cid FROM vphone_hush_likes
        WHERE from_cid = ? AND liked = 0 ORDER BY at DESC LIMIT 1]], { p.citizenid })
    if not row then resolve({ error = 'nothing' }) return end

    MySQL.query.await('DELETE FROM vphone_hush_likes WHERE from_cid = ? AND to_cid = ?',
        { p.citizenid, row.to_cid })
    resolve({ ok = true })
end)

--- Undo a match, from either side.
---
--- Both rows go. Leaving the other half behind would put the person straight back in the deck
--- as somebody who already liked you, so the next swipe would re-match you with somebody you
--- had just walked away from.
V.Callback('v-phone:soc:hushUnmatch', function(src, resolve, data)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local target = tostring((data and data.ref) or '')
    if target == '' then resolve(false) return end

    MySQL.query.await([[DELETE FROM vphone_hush_likes
        WHERE (from_cid = ? AND to_cid = ?) OR (from_cid = ? AND to_cid = ?)]],
        { p.citizenid, target, target, p.citizenid })
    Core.Log('social', ('hush unmatch %s <-> %s'):format(p.citizenid, target), nil, p.citizenid)
    resolve({ ok = true })
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

    -- Every unread count in one grouped read, instead of one query per match inside the loop
    -- below. Same predicates, same key - `inbox_idx (app, to_cid, seen)` serves this directly,
    -- where the per-row form probed an index that does not carry `seen`.
    --
    -- It counts unread from ANYBODY, not only from matches; the extra keys are simply never
    -- looked up, because the only reader is `unread[r.cid]` and `r.cid` is always a match.
    local unread = {}
    for _, u in ipairs(MySQL.query.await([[
        SELECT from_cid AS other, COUNT(*) AS n FROM vphone_social_dm
        WHERE app = 'hush' AND to_cid = ? AND seen = 0
        GROUP BY from_cid]], { p.citizenid }) or {}) do
        unread[u.other] = num(u.n, 0)
    end

    local out = {}
    for _, r in ipairs(rows) do
        -- **No phone number.** A match is two people who liked a first name and a photograph;
        -- handing over the number behind it makes a dating app a directory, and the number is
        -- the one thing a player cannot take back once somebody has it. They talk inside Hush,
        -- and they give out their number themselves if they decide to.
        --
        -- `ref` is the citizen id, and it is opaque: the client hands it straight back and it is
        -- never displayed. Everything shown is the first name, an age from the date of birth,
        -- and what they wrote about themselves.
        out[#out + 1] = {
            ref = r.cid,
            name = r.firstname or '?',
            age = ageFrom(r.dob),
            bio = r.bio or '',
            photo = r.photo or '',
            at = r.at,
            unread = math.floor(unread[r.cid] or 0),
        }
    end
    resolve({ ok = true, matches = out })
end)

-- ══════════════════════════════════════════════════════════════
-- Hush: its own conversations
-- ══════════════════════════════════════════════════════════════
-- **Matches talk inside Hush, not by text message.**
--
-- Opening a match used to hand over their phone NUMBER and push the player into the Messages app.
-- Two things wrong with that. A number cannot be taken back: one swipe and a stranger has the way
-- to reach you everywhere, for ever, whatever you decide about them ten minutes later. And a
-- conversation that leaves the app leaves its context - unmatching stops nothing, because the
-- thread is in Messages now.
--
-- So Hush carries its own thread. It reuses `vphone_social_dm` - the table Bleeter and Snapmatic
-- already use - under `app = 'hush'`, because a second messages table would be a second set of
-- bugs. What differs is ADDRESSING: the other two address by handle, and a Hush profile has no
-- handle, so these two address by the match itself and check the match on every call.
--
-- Unmatching deletes the like rows, so `hushMatched` goes false and the thread becomes
-- unreachable from both sides at once. That is the point of talking here rather than by SMS.

--- Are these two matched? Both directions, both liked. The gate on every call below.
local function hushMatched(a, b)
    if a == '' or b == '' or a == b then return false end
    return MySQL.scalar.await([[SELECT 1 FROM vphone_hush_likes mine
        JOIN vphone_hush_likes theirs
          ON theirs.from_cid = mine.to_cid AND theirs.to_cid = mine.from_cid AND theirs.liked = 1
        WHERE mine.from_cid = ? AND mine.to_cid = ? AND mine.liked = 1 LIMIT 1]], { a, b }) ~= nil
end

--- One conversation. Marks what arrived as seen, because opening it is reading it.
--- Delete one direct message - Bleeter, Snapmatic or Hush.
---
--- **The same two meanings behind one word as SMS**, because a phone that deletes differently
--- depending which app you are in is a phone nobody trusts:
---
---   * a message you SENT is unsent, so the row goes and it leaves both phones;
---   * a message you RECEIVED comes off YOUR copy only, because deleting somebody else's record
---     of what they said is not yours to do.
---
--- One handler for all three apps: they share `vphone_social_dm`, so a second implementation
--- would only be a second set of bugs. The `app` is read from the row, never from the page -
--- passing it in would let a Bleeter call reach into a Hush thread.
V.Callback('v-phone:soc:dmDelete', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve({ error = 'args' }) return end

    local row = MySQL.single.await(
        'SELECT app, from_cid, to_cid FROM vphone_social_dm WHERE id = ?', { id })
    if not row then resolve({ error = 'gone' }) return end
    if row.from_cid ~= p.citizenid and row.to_cid ~= p.citizenid then
        resolve({ error = 'notyours' })
        return
    end

    if row.from_cid == p.citizenid then
        MySQL.update.await('DELETE FROM vphone_social_dm WHERE id = ?', { id })
        MySQL.update.await('DELETE FROM vphone_dm_hidden WHERE message_id = ?', { id })
        resolve({ ok = true, both = true })
        return
    end

    MySQL.query.await(
        'INSERT IGNORE INTO vphone_dm_hidden (message_id, citizenid) VALUES (?,?)',
        { id, p.citizenid })
    resolve({ ok = true, both = false })
end)

V.Callback('v-phone:soc:hushChat', function(src, resolve, data)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local other = tostring((data and data.ref) or '')
    if not hushMatched(p.citizenid, other) then resolve({ error = 'nomatch' }) return end

    local rows = MySQL.query.await([[SELECT id, from_cid, body, image, at
        FROM vphone_social_dm
        WHERE app = 'hush' AND ((from_cid = ? AND to_cid = ?) OR (from_cid = ? AND to_cid = ?))
          AND id NOT IN (SELECT message_id FROM vphone_dm_hidden WHERE citizenid = ?)
        ORDER BY id ASC LIMIT 200]],
        { p.citizenid, other, other, p.citizenid, p.citizenid }) or {}

    MySQL.update.await([[UPDATE vphone_social_dm SET seen = 1
        WHERE app = 'hush' AND from_cid = ? AND to_cid = ?]], { other, p.citizenid })

    local out = {}
    for i, r in ipairs(rows) do
        -- `mine` rather than a citizen id: the page needs to know which side a line is on and
        -- nothing else. No name, no number, no citizen id - the row id travels only because
        -- deleting a line has to be able to name which one.
        out[i] = { id = r.id, mine = r.from_cid == p.citizenid,
                   body = r.body or '', image = r.image or '', at = r.at }
    end

    -- Who they are, from the profile, so the thread has a face at the top of it.
    local who = MySQL.single.await([[SELECT c.firstname, c.dob, h.photo
        FROM vphone_hush_profiles h LEFT JOIN vphone_characters c ON c.citizenid = h.citizenid
        WHERE h.citizenid = ?]], { other })

    resolve({ ok = true, messages = out, name = who and who.firstname or '?',
              age = who and ageFrom(who.dob) or nil, photo = who and who.photo or '' })
end)

--- Say something to a match.
V.Callback('v-phone:soc:hushSay', function(src, resolve, data)
    if not hushOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local other = tostring((data and data.ref) or '')
    if not hushMatched(p.citizenid, other) then resolve({ error = 'nomatch' }) return end

    local body = tostring((data and data.body) or ''):sub(1, 500)
    local image = tostring((data and data.image) or ''):sub(1, 300)
    if image ~= '' and not imageAllowed(image) then resolve({ error = 'badhost' }) return end
    if body:gsub('%s', '') == '' and image == '' then resolve({ error = 'empty' }) return end

    MySQL.insert.await(
        'INSERT INTO vphone_social_dm (app, from_cid, to_cid, body, image) VALUES (?,?,?,?,?)',
        { 'hush', p.citizenid, other, body, image })

    -- The notification carries the FIRST NAME, which is all Hush ever shows of anybody. Not a
    -- handle - there is none - and certainly not a number.
    local target = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(other)
    if target and target.source and GetResourceState('v-phone') == 'started' then
        local me = MySQL.single.await(
            'SELECT firstname FROM vphone_characters WHERE citizenid = ?', { p.citizenid })
        pcall(function()
            exports['v-phone']:Notify(target.source, 'hush', me and me.firstname or '?',
                body ~= '' and body or (Locales.fr or {})['soc.dm_photo'] or 'Photo')
        end)
    end
    resolve({ ok = true })
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
        SELECT (SELECT COUNT(*) FROM vphone_social_posts s WHERE s.citizenid = ? AND s.app = ?) AS posts,
               (SELECT COUNT(*) FROM vphone_social_follows f WHERE f.app = ? AND f.to_cid = ?) AS followers,
               (SELECT COUNT(*) FROM vphone_social_follows f2 WHERE f2.app = ? AND f2.from_cid = ?) AS following
    ]], { cid, app, app, cid, app, cid }) or {}

    local posts = MySQL.query.await(([[
        SELECT %s FROM vphone_social_posts s
        JOIN vphone_social_accounts a ON a.citizenid = s.citizenid AND a.app = ?
        WHERE s.citizenid = ? AND s.app = ?
        ORDER BY s.id DESC LIMIT ?
    ]]):format(POST_COLUMNS), {
        -- Five: POST_COLUMNS binds the reader's own id once per EXISTS - liked, reposted,
        -- saved, following - plus once for `mine`.
        p.citizenid, p.citizenid, p.citizenid, p.citizenid, p.citizenid,
        app, cid, app, socFeedSize(),
    }) or {}

    resolve({
        ok = true,
        me = cid == p.citizenid,
        account = {
            handle = a.handle, displayname = a.displayname, avatar = a.avatar,
            bio = a.bio, cover = a.cover, verified = truthy(a.verified),
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
            SELECT a.handle, a.displayname, a.avatar, a.cover, a.bio, a.verified,
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
        r.followed = truthy(r.followed)
        r.verified = truthy(r.verified)
        r.me = truthy(r.me)
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
        notify(app, cid, p.citizenid, 'follow', nil)
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
        r.mine = truthy(r.mine)
        r.verified = truthy(r.verified)
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
    -- `postApp`, not `app`: shadowing the request's app with the post's would work here and
    -- quietly mislead whoever edits the lines after it.
    local author, postApp = postAuthor(id)
    if author then notify(postApp, author, p.citizenid, 'comment', id) end
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
    -- Same rule as a like: the notification belongs to the act of reposting, not to
    -- toggling it off again. `exists` was the state BEFORE this call, so a fresh repost is
    -- `not exists` - there is no `reposted` local here, and reading one as a global would
    -- have been nil and silently notified nobody.
    if not exists then
        local author, postApp = postAuthor(id)
        if author then notify(postApp, author, p.citizenid, 'repost', id) end
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
    -- And its tags, and every notification that points at it. A notification whose post is
    -- gone is a tap that leads nowhere.
    MySQL.query.await('DELETE FROM vphone_social_saves WHERE post_id = ?', { id })
    MySQL.query.await('DELETE FROM vphone_social_tags WHERE post_id = ?', { id })
    MySQL.query.await('DELETE FROM vphone_social_notifs WHERE post_id = ?', { id })
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Stories
-- ══════════════════════════════════════════════════════════════
-- A story is a post with an expiry. It is a separate table because it has different
-- rules - it disappears, and being seen is part of its state - not to keep two feeds.
local STORY_HOURS = 24

-- ══════════════════════════════════════════════════════════════
-- Notifications, hashtags and trending
-- ══════════════════════════════════════════════════════════════
--- What happened to you. Newest first, with the handle behind it resolved here so the page
--- never has to make a second call per row.
V.Callback('v-phone:soc:notifs', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end

    local rows = MySQL.query.await([[SELECT n.id, n.kind, n.post_id, n.seen,
            UNIX_TIMESTAMP(n.at) AS ts,
            a.handle, a.displayname, a.avatar, a.verified,
            (SELECT LEFT(s.body, 80) FROM vphone_social_posts s WHERE s.id = n.post_id) AS excerpt
        FROM vphone_social_notifs n
        JOIN vphone_social_accounts a ON a.citizenid = n.from_cid AND a.app = n.app
        WHERE n.app = ? AND n.to_cid = ?
        ORDER BY n.id DESC LIMIT 60]], { app, p.citizenid }) or {}

    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            id = math.floor(num(r.id, 0)),
            kind = tostring(r.kind or ''),
            postId = r.post_id and math.floor(num(r.post_id, 0)) or nil,
            seen = truthy(r.seen),
            ts = math.floor(num(r.ts, 0)),
            handle = tostring(r.handle or ''),
            displayname = r.displayname and tostring(r.displayname) or nil,
            avatar = r.avatar and tostring(r.avatar) or nil,
            verified = truthy(r.verified),
            excerpt = r.excerpt and tostring(r.excerpt) or nil,
        }
    end
    resolve({ ok = true, notifs = out })
end)

--- How many are unread. Its own call because the tab bar wants the number on every screen,
--- not just on the notifications tab, and a count is one indexed read rather than sixty rows.
V.Callback('v-phone:soc:notifCount', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    resolve({ ok = true, unread = num(MySQL.scalar.await(
        'SELECT COUNT(*) FROM vphone_social_notifs WHERE app = ? AND to_cid = ? AND seen = 0',
        { app, p.citizenid }), 0) })
end)

--- Mark them read. All of them: opening the tab IS reading them, and per-row seen state on a
--- list somebody just looked at is bookkeeping nobody asked for.
V.Callback('v-phone:soc:notifSeen', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    MySQL.update.await(
        'UPDATE vphone_social_notifs SET seen = 1 WHERE app = ? AND to_cid = ? AND seen = 0',
        { app, p.citizenid })
    resolve({ ok = true })
end)

--- Every post carrying one tag, newest first. The tag table is indexed on (app, tag, post_id),
--- so this is a range read rather than a scan of every body ever written.
V.Callback('v-phone:soc:tag', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    local tag = cutBytes(lowerAscii(tostring((data and data.tag) or ''):gsub('^#', '')), 40)
    if tag == '' then resolve({ error = 'notag' }) return end

    local rows = MySQL.query.await(([[
        SELECT %s
        FROM vphone_social_posts s
        JOIN vphone_social_accounts a ON a.citizenid = s.citizenid AND a.app = ?
        JOIN vphone_social_tags t ON t.post_id = s.id AND t.app = ?
        WHERE t.tag = ? AND s.app = ?
        ORDER BY s.id DESC LIMIT ?
    ]]):format(POST_COLUMNS),
        { p.citizenid, p.citizenid, p.citizenid, p.citizenid, p.citizenid,
          app, app, tag, app, socFeedSize() }) or {}

    resolve({ ok = true, tag = tag, posts = cleanPosts(rows) })
end)

--- What people are talking about: the most used tags in a recent window, with how many posts
--- carry each. A window rather than all time, because "trending" that never changes is just a
--- list of the tags somebody used most in the first week the server ran.
V.Callback('v-phone:soc:trending', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    local hours = math.max(1, math.min(168, math.floor(num(SOC.trendingHours, 48))))

    local rows = MySQL.query.await([[SELECT tag, COUNT(*) AS posts
        FROM vphone_social_tags
        WHERE app = ? AND at >= (NOW() - INTERVAL ? HOUR)
        GROUP BY tag ORDER BY posts DESC, tag ASC LIMIT 10]], { app, hours }) or {}

    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = { tag = tostring(r.tag), posts = math.floor(num(r.posts, 0)) }
    end
    resolve({ ok = true, trending = out, hours = hours })
end)

-- ══════════════════════════════════════════════════════════════
-- Saving a post
-- ══════════════════════════════════════════════════════════════
--- Save or unsave. A toggle, keyed on the pair, so a double tap cannot count twice.
V.Callback('v-phone:soc:save', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end

    local exists = MySQL.scalar.await(
        'SELECT 1 FROM vphone_social_saves WHERE post_id = ? AND citizenid = ?', { id, p.citizenid })
    if exists then
        MySQL.query.await('DELETE FROM vphone_social_saves WHERE post_id = ? AND citizenid = ?',
            { id, p.citizenid })
    else
        MySQL.insert.await('INSERT IGNORE INTO vphone_social_saves (post_id, citizenid) VALUES (?,?)',
            { id, p.citizenid })
    end
    -- Nobody is notified. A save is private, and telling the author would make it public.
    resolve({ ok = true, saved = not exists })
end)

--- Everything this reader saved, newest save first - not newest post. Somebody looking at
--- their saves is looking for the thing they kept, and they remember when they kept it.
V.Callback('v-phone:soc:saved', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end

    local rows = MySQL.query.await(([[
        SELECT %s
        FROM vphone_social_saves sv
        JOIN vphone_social_posts s ON s.id = sv.post_id
        JOIN vphone_social_accounts a ON a.citizenid = s.citizenid AND a.app = ?
        -- The POST's app, not just the author's account. Somebody with an account on both
        -- would otherwise see their saved Bleeter posts inside Snapmatic.
        WHERE sv.citizenid = ? AND s.app = ?
        ORDER BY sv.at DESC, sv.post_id DESC LIMIT ?
    ]]):format(POST_COLUMNS),
        { p.citizenid, p.citizenid, p.citizenid, p.citizenid, p.citizenid,
          app, p.citizenid, app, socFeedSize() }) or {}

    resolve({ ok = true, posts = cleanPosts(rows) })
end)

-- ══════════════════════════════════════════════════════════════
-- Explore
-- ══════════════════════════════════════════════════════════════
--- Photographs from accounts this reader does not already follow.
---
--- The point of an explore grid is to show something the feed cannot, so it deliberately
--- EXCLUDES the people already followed and the reader themselves. Ordered by likes over a
--- recent window rather than all time: a grid that never changes is a hall of fame, not a
--- place to discover anybody.
V.Callback('v-phone:soc:explore', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end
    local hours = math.max(1, math.min(720, math.floor(num(SOC.exploreHours, 168))))

    local rows = MySQL.query.await(([[
        SELECT %s
        FROM vphone_social_posts s
        JOIN vphone_social_accounts a ON a.citizenid = s.citizenid AND a.app = ?
        -- Both: the app it was posted to, and that it is actually a picture. Explore is a
        -- grid, so a text post on the same app has nothing to show in it.
        WHERE s.app = ? AND s.kind IN ('photo', 'video')
          AND s.citizenid <> ?
          AND NOT EXISTS(SELECT 1 FROM vphone_social_follows f
                         WHERE f.app = ? AND f.from_cid = ? AND f.to_cid = s.citizenid)
          AND s.at >= (NOW() - INTERVAL ? HOUR)
        ORDER BY likes DESC, s.id DESC LIMIT ?
    ]]):format(POST_COLUMNS),
        -- a.app, s.app, s.citizenid, f.app, f.from_cid, hours, limit - in that order.
        { p.citizenid, p.citizenid, p.citizenid, p.citizenid, p.citizenid,
          app, app, p.citizenid, app, p.citizenid, hours, socFeedSize() }) or {}

    resolve({ ok = true, posts = cleanPosts(rows) })
end)

-- ══════════════════════════════════════════════════════════════
-- Who watched a story
-- ══════════════════════════════════════════════════════════════
--- The viewers of one story, for its author and nobody else.
---
--- The seen table has existed since stories shipped and only ever drove the unseen ring. This
--- reads the other direction, which is what the author actually wants to know.
V.Callback('v-phone:soc:storyViewers', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end

    -- Only the author. Who watched somebody else's story is their business, and asking for a
    -- story id that is not yours must answer nothing rather than a list.
    local owner = MySQL.scalar.await(
        'SELECT citizenid FROM vphone_social_stories WHERE id = ? AND app = ?', { id, app })
    if not owner then resolve({ error = 'gone' }) return end
    if owner ~= p.citizenid then resolve({ error = 'notyours' }) return end

    local rows = MySQL.query.await([[SELECT a.handle, a.displayname, a.avatar, a.verified
        FROM vphone_social_story_seen v
        JOIN vphone_social_accounts a ON a.citizenid = v.citizenid AND a.app = ?
        WHERE v.story_id = ?
        ORDER BY a.handle LIMIT 100]], { app, id }) or {}

    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            handle = tostring(r.handle), displayname = r.displayname and tostring(r.displayname) or nil,
            avatar = r.avatar and tostring(r.avatar) or nil,
            verified = truthy(r.verified),
        }
    end
    resolve({ ok = true, viewers = out })
end)

-- ══════════════════════════════════════════════════════════════
-- People behind a number
-- ══════════════════════════════════════════════════════════════
-- Every count in this app was a dead end. A post said how many likes it had and there was no
-- way to find out whose; a profile said how many followers and the number was the whole
-- answer. On a roleplay server those lists ARE the app - who follows whom is the social map,
-- and a like is somebody telling you they were there.

--- One person, shaped the way every list in this app shapes a person.
---
--- Written once because there are now four lists - viewers, likers, followers, following - and
--- four copies of the same six fields is four chances for one of them to start including a
--- citizen id.
local function personRow(r)
    return {
        handle = tostring(r.handle),
        displayname = r.displayname and tostring(r.displayname) or nil,
        avatar = r.avatar and tostring(r.avatar) or nil,
        verified = truthy(r.verified),
    }
end

--- Who liked a post.
---
--- Public, deliberately. A like is a public act: the count is already on the card and the
--- author is already told who it was. Hiding the list while showing the number is the shape of
--- privacy without any of it.
V.Callback('v-phone:soc:likers', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end

    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve(false) return end
    -- The post has to exist AND belong to this app: a Bleeter id asked for as a Snapmatic post
    -- would otherwise answer with the likes of somebody else's post.
    local exists = MySQL.scalar.await(
        'SELECT 1 FROM vphone_social_posts WHERE id = ? AND app = ? LIMIT 1', { id, app })
    if not exists then resolve({ error = 'gone' }) return end

    local rows = MySQL.query.await([[SELECT a.handle, a.displayname, a.avatar, a.verified
        FROM vphone_social_likes l
        JOIN vphone_social_accounts a ON a.citizenid = l.citizenid AND a.app = ?
        WHERE l.post_id = ?
        ORDER BY l.citizenid = ? DESC, a.handle
        LIMIT 200]], { app, id, p.citizenid }) or {}

    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = personRow(r) end
    resolve({ ok = true, people = out })
end)

--- Who follows an account, or who it follows.
---
--- `which` is one of two words and is checked against both rather than pasted into the query:
--- the direction decides which COLUMN is joined, and a column name coming from the client is
--- how a list turns into a way to read the table.
V.Callback('v-phone:soc:follows', function(src, resolve, data)
    if not socOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local app = appOf(data)
    if not accountOf(p.citizenid, app) then resolve({ error = 'noaccount' }) return end

    local handle = tostring((data and data.handle) or '')
    local cid = handle ~= '' and cidOfHandle(app, handle) or p.citizenid
    if not cid then resolve({ error = 'nouser' }) return end

    local which = tostring((data and data.which) or 'followers')
    if which ~= 'followers' and which ~= 'following' then which = 'followers' end

    -- Two whole statements rather than one with a column pasted in. It is four more lines and
    -- it cannot be turned into a different query by anything the client sends.
    local rows
    if which == 'followers' then
        rows = MySQL.query.await([[SELECT a.handle, a.displayname, a.avatar, a.verified
            FROM vphone_social_follows f
            JOIN vphone_social_accounts a ON a.citizenid = f.from_cid AND a.app = ?
            WHERE f.app = ? AND f.to_cid = ?
            ORDER BY f.at DESC LIMIT 200]], { app, app, cid })
    else
        rows = MySQL.query.await([[SELECT a.handle, a.displayname, a.avatar, a.verified
            FROM vphone_social_follows f
            JOIN vphone_social_accounts a ON a.citizenid = f.to_cid AND a.app = ?
            WHERE f.app = ? AND f.from_cid = ?
            ORDER BY f.at DESC LIMIT 200]], { app, app, cid })
    end

    local out = {}
    for _, r in ipairs(rows or {}) do out[#out + 1] = personRow(r) end
    resolve({ ok = true, people = out, which = which })
end)

-- ══════════════════════════════════════════════════════════════
-- Verification
-- ══════════════════════════════════════════════════════════════
--- Grant or revoke the badge on one account.
---
--- The column and the badge have both existed since the app shipped - the badge is drawn
--- wherever a name appears - and nothing has ever set it, so no account could be verified by
--- anybody. This is the missing half.
---
--- Deliberately NOT a callback: a client must never be able to ask for this. It is an export,
--- and the only thing that calls it is the ace-gated staff command in server/admin.lua. A
--- server with its own admin menu calls the export from there.
---
---     exports['v-phone']:SetVerified('bleeter', 'somehandle', true)
---
--- Returns ok, and the handle as it is actually stored, so a caller can echo it back.
--- Take the badge off every account on one app, or on both.
---
--- **For the servers that ran a build where registering granted it.** Every account created
--- before that was fixed carries a tick, which makes the tick meaningless - the one thing it is
--- for is telling accounts apart. Undoing that one handle at a time is not realistic on a
--- server with two hundred characters.
---
---     exports['v-phone']:ClearVerified()          -- both apps
---     exports['v-phone']:ClearVerified('bleeter') -- one of them
---
--- Returns how many accounts it changed. Deliberately NOT run by an update: it is somebody
--- else's database and somebody else's decision, and a server that granted those badges on
--- purpose would lose them without being asked.
exports('ClearVerified', function(app)
    local one = tostring(app or ''):lower()
    one = (one == 'snap' or one == 'bleeter') and one or nil

    local changed
    if one then
        changed = MySQL.update.await(
            'UPDATE vphone_social_accounts SET verified = 0 WHERE app = ? AND verified <> 0', { one })
    else
        changed = MySQL.update.await(
            'UPDATE vphone_social_accounts SET verified = 0 WHERE verified <> 0')
    end
    changed = tonumber(changed) or 0

    -- Every phone that is open is showing the old badge until something makes it look again.
    for _, raw in ipairs(GetPlayers()) do
        local other = tonumber(raw)
        if other then
            TriggerClientEvent('v-phone:client:socialRefresh', other, one or 'bleeter')
            if not one then TriggerClientEvent('v-phone:client:socialRefresh', other, 'snap') end
        end
    end
    return changed
end)

exports('SetVerified', function(app, handle, on)
    app = (tostring(app or ''):lower() == 'snap') and 'snap' or 'bleeter'
    handle = tostring(handle or ''):gsub('^@', ''):gsub('%s', '')
    if handle == '' then return false, 'nohandle' end

    local cid = cidOfHandle(app, handle)
    if not cid then return false, 'nosuchhandle' end

    MySQL.update.await(
        'UPDATE vphone_social_accounts SET verified = ? WHERE citizenid = ? AND app = ?',
        { on and 1 or 0, cid, app })

    -- The badge is on every card that account has ever posted, so an open phone would keep
    -- showing the old state until something else made it refresh. Telling it costs one event.
    local target = Core.GetPlayerByCitizenId(cid)
    if target and target.source then
        TriggerClientEvent('v-phone:client:socialRefresh', target.source, app)
    end
    return true, handle
end)

--- Who is verified, for a staff command that wants to list them. Handles only: this is an
--- account list, not a character list, and it has no business carrying citizen ids.
exports('VerifiedHandles', function(app)
    app = (tostring(app or ''):lower() == 'snap') and 'snap' or 'bleeter'
    local rows = MySQL.query.await(
        'SELECT handle FROM vphone_social_accounts WHERE app = ? AND verified = 1 ORDER BY handle',
        { app }) or {}
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = tostring(r.handle) end
    return out
end)

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
                mine = truthy(r.mine), unseen = false, items = {},
            }
            order[#order + 1] = byAuthor[key]
        end
        local group = byAuthor[key]
        local seen = truthy(r.seen)
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
        SELECT a.handle, a.displayname, a.avatar, a.verified,
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
        r.mine = truthy(r.mine)
        r.verified = truthy(r.verified)
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
          AND id NOT IN (SELECT message_id FROM vphone_dm_hidden WHERE citizenid = ?)
        ORDER BY id ASC LIMIT 200
    ]], { p.citizenid, app, p.citizenid, cid, cid, p.citizenid, p.citizenid }) or {}
    for _, r in ipairs(rows) do r.mine = truthy(r.mine) end

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
--- `app` is optional and defaults to what the kind implies, so existing callers keep
--- working; pass 'bleeter' with a photo to put a picture on Bleeter.
exports('SocialPostAs', function(cid, kind, body, image, app)
    cid = tostring(cid or '')
    kind = (kind == 'photo') and 'photo' or 'text'
    app = (app == 'bleeter' or app == 'snap') and app or appOfKind(kind)
    if kind == 'text' then app = 'bleeter' end
    if not accountOf(cid, app) then return false end
    return MySQL.insert.await(
        'INSERT INTO vphone_social_posts (citizenid, app, kind, body, image) VALUES (?,?,?,?,?)',
        { cid, app, kind, tostring(body or ''):sub(1, 280),
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
        `cover`     VARCHAR(300) NOT NULL DEFAULT '',
        `bio`       VARCHAR(160) NOT NULL DEFAULT '',
        `phone`     VARCHAR(20) NOT NULL DEFAULT '',
        `password`  VARCHAR(80) NOT NULL DEFAULT '',
        `verified`  TINYINT(1) NOT NULL DEFAULT 0,
        PRIMARY KEY (`citizenid`, `app`),
        UNIQUE KEY `handle` (`app`, `handle`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- `CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists, so a column
    -- added after release has to be added on its own or it never appears - the bank app lost
    -- its whole statement to exactly this once already.
    local hasCover = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_social_accounts'
          AND COLUMN_NAME = 'cover' LIMIT 1]])
    if not hasCover then
        MySQL.query.await(
            "ALTER TABLE `vphone_social_accounts` ADD COLUMN `cover` VARCHAR(300) NOT NULL DEFAULT '' AFTER `avatar`")
        print('[v-phone] social: added vphone_social_accounts.cover')
    end

    -- Accounts made before credentials existed keep working: they are given the handle as a
    -- display name, so nobody is left with a blank one by the upgrade.
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
    -- **The blue tick is NOT handed out here, and the line that did it is gone.**
    --
    -- It read `SET verified = 1 WHERE verified = 0 AND password = ''`, and the comment above it
    -- called that "keeps working". Two different things share the word: signing up verifies
    -- your NUMBER, and the `verified` COLUMN is the badge staff grant with
    -- `/phoneadmin verify @handle`. The sign-up path has a long comment about exactly this
    -- confusion because the same mistake was made there once and fixed; this copy survived.
    --
    -- It was not a one-time migration either. It ran on EVERY boot, so any account with an
    -- empty password - one seeded by a script, imported from elsewhere, or created by another
    -- resource - was badged at the next restart, for ever. A badge everybody has is not a
    -- badge; telling accounts apart is the one thing it is for.
    --
    -- Nothing replaces it. An account with no password is not locked out: `resetGate` texts a
    -- code to the number on the account and lets a new password be set, which is the path that
    -- already existed and the one that actually solves being unable to sign in. `verified` was
    -- never consulted for authentication at all - it is drawn, and nothing else.
    --
    -- Badges already granted by this line are left alone: they are somebody else's database
    -- and taking them back is not an update's decision. `exports['v-phone']:ClearVerified()`
    -- is there for an operator who wants them gone.
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
        -- WHICH APP this post belongs to.
        --
        -- It used to be derived from `kind`: text meant Bleeter, photo meant Snapmatic. That
        -- worked exactly as long as the two apps carried different content types, and broke
        -- the moment Bleeter learnt to post pictures - every photograph, wherever it was
        -- written, appeared on Snapmatic and never on Bleeter. A post's app is a fact about
        -- the post, not something to infer from its media type, so it is stored.
        `app`       VARCHAR(8)  NOT NULL DEFAULT 'bleeter',
        `kind`      VARCHAR(8)  NOT NULL DEFAULT 'text',
        `body`      VARCHAR(1000) NOT NULL DEFAULT '',
        `image`     VARCHAR(300) NOT NULL DEFAULT '',
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), KEY `app_idx` (`app`, `id`), KEY `kind_idx` (`kind`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- `CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists, so the
    -- column is added on its own - and then BACKFILLED from what the old rule would have
    -- said. Every existing photo really was on Snapmatic and every existing text really was
    -- on Bleeter, because that was the only behaviour there had ever been, so this is a
    -- faithful record of where those posts already are rather than a guess.
    local hasApp = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_social_posts'
          AND COLUMN_NAME = 'app' LIMIT 1]])
    if not hasApp then
        MySQL.query.await("ALTER TABLE `vphone_social_posts` ADD COLUMN `app` VARCHAR(8) NOT NULL DEFAULT 'bleeter'")
        MySQL.query.await("UPDATE `vphone_social_posts` SET `app` = 'snap' WHERE `kind` IN ('photo', 'video')")
        MySQL.query.await('ALTER TABLE `vphone_social_posts` ADD INDEX `app_idx` (`app`, `id`)')
        print('[v-phone] social: added posts.app and backfilled it from kind')
    end

    -- What somebody did to your post, or to you. The one thing a social app cannot be
    -- without: a like nobody is told about may as well not have happened.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_notifs` (
        `id`       INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `app`      VARCHAR(8)  NOT NULL DEFAULT 'bleeter',
        `to_cid`   VARCHAR(16) NOT NULL,
        `from_cid` VARCHAR(16) NOT NULL,
        `kind`     VARCHAR(10) NOT NULL,
        `post_id`  INT UNSIGNED NULL DEFAULT NULL,
        `seen`     TINYINT(1)  NOT NULL DEFAULT 0,
        `at`       TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `inbox` (`app`, `to_cid`, `id`),
        KEY `unread` (`app`, `to_cid`, `seen`),
        KEY `post` (`post_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- Hashtags, extracted once when the post is written. The alternative is a LIKE '%#tag%'
    -- scan over every post ever made, every time somebody taps a tag, which is fine on a
    -- test server and hopeless on a real one.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_tags` (
        `post_id` INT UNSIGNED NOT NULL,
        `app`     VARCHAR(8)  NOT NULL DEFAULT 'bleeter',
        `tag`     VARCHAR(40) NOT NULL,
        `at`      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`post_id`, `tag`),
        KEY `bytag` (`app`, `tag`, `post_id`),
        KEY `trend` (`app`, `at`)
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
        `photo2`    VARCHAR(300) NOT NULL DEFAULT '',
        `photo3`    VARCHAR(300) NOT NULL DEFAULT '',
        -- Self-declared, which is how a dating app works: the framework's idea of a
        -- character's sex is not the same question as who they are looking for.
        `gender`    VARCHAR(1) NOT NULL DEFAULT '',
        `seeking`   VARCHAR(3) NOT NULL DEFAULT 'all',
        `min_age`   TINYINT UNSIGNED NOT NULL DEFAULT 18,
        `max_age`   TINYINT UNSIGNED NOT NULL DEFAULT 99,
        `active`    TINYINT(1) NOT NULL DEFAULT 1,
        PRIMARY KEY (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- Columns added after the table shipped, one at a time, because `CREATE TABLE IF NOT
    -- EXISTS` does nothing to a table that already exists. This is the third time that has
    -- caught something in this resource, so it is now the reflex.
    local function hushColumn(column, definition)
        local has = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_hush_profiles'
              AND COLUMN_NAME = ? LIMIT 1]], { column })
        if has then return end
        MySQL.query.await(('ALTER TABLE `vphone_hush_profiles` ADD COLUMN `%s` %s')
            :format(column, definition))
        print(('[v-phone] hush: added %s'):format(column))
    end
    hushColumn('photo2', "VARCHAR(300) NOT NULL DEFAULT ''")
    hushColumn('photo3', "VARCHAR(300) NOT NULL DEFAULT ''")
    hushColumn('gender', "VARCHAR(1) NOT NULL DEFAULT ''")
    hushColumn('seeking', "VARCHAR(3) NOT NULL DEFAULT 'all'")
    hushColumn('min_age', 'TINYINT UNSIGNED NOT NULL DEFAULT 18')
    hushColumn('max_age', 'TINYINT UNSIGNED NOT NULL DEFAULT 99')
    -- A profile that is a photograph and one line is a profile nobody can decide anything
    -- from. These five are what an actual dating app asks for, and every one of them is drawn
    -- on the card rather than stored and forgotten.
    hushColumn('job', "VARCHAR(40) NOT NULL DEFAULT ''")
    hushColumn('looking', "VARCHAR(8) NOT NULL DEFAULT ''")
    -- A comma-separated list of keys from a CLOSED set, never free text. Free text here would
    -- be a chip drawn on a stranger's screen, and a closed set also means the two sides of a
    -- match can be told they have something in common.
    hushColumn('interests', "VARCHAR(120) NOT NULL DEFAULT ''")
    hushColumn('prompt', "VARCHAR(16) NOT NULL DEFAULT ''")
    hushColumn('prompt_answer', "VARCHAR(140) NOT NULL DEFAULT ''")
    -- When the premium pass runs out, as a unix timestamp. NULL is "never had one".
    hushColumn('premium_until', 'INT UNSIGNED NULL DEFAULT NULL')

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_hush_likes` (
        `from_cid` VARCHAR(16) NOT NULL,
        `to_cid`   VARCHAR(16) NOT NULL,
        `liked`    TINYINT(1) NOT NULL DEFAULT 0,
        -- A super like is a like that says so. Its own table would buy nothing: it is the
        -- same row, the same uniqueness, and the same expiry rules.
        `super`    TINYINT(1) NOT NULL DEFAULT 0,
        `at`       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`from_cid`, `to_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    local hasSuper = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'vphone_hush_likes'
          AND COLUMN_NAME = 'super' LIMIT 1]])
    if not hasSuper then
        MySQL.query.await('ALTER TABLE `vphone_hush_likes` ADD COLUMN `super` TINYINT(1) NOT NULL DEFAULT 0')
        print('[v-phone] hush: added super')
    end

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

    -- Saved posts. The one thing on a social app that is nobody else's business: a like is
    -- public, a repost is public, a save is a private bookmark and its count is never shown.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_social_saves` (
        `post_id`   INT UNSIGNED NOT NULL,
        `citizenid` VARCHAR(16) NOT NULL,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`post_id`, `citizenid`),
        KEY `mine` (`citizenid`, `post_id`)
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

    -- One row per direct message a reader has taken off their own copy. A separate table
    -- rather than a column, for the same reason SMS uses one: a message has two readers and
    -- only one row, so "deleted" is not a property of the message.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_dm_hidden` (
        `message_id` INT UNSIGNED NOT NULL,
        `citizenid`  VARCHAR(16) NOT NULL,
        PRIMARY KEY (`message_id`, `citizenid`),
        KEY `citizenid` (`citizenid`)
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
