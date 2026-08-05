-- v-phone | server/creator.lua
--
-- **OnlyFruits: photographs somebody pays to see.**
--
-- A creator takes a picture with the phone's own camera, puts a price on it, and posts it.
-- Other people follow for free, subscribe for a month, buy one picture, or tip. The money is
-- real: it leaves a bank account and it arrives in a balance the creator withdraws.
--
-- The whole app rests on ONE property, and everything here is arranged around it:
--
--   **A locked picture's URL never leaves the server for somebody who has not paid.**
--
-- Not hidden behind a blur, not sent with a flag saying "do not show this" - not sent. A NUI
-- page is a browser: anything delivered to it can be read out of it, so a paywall that ships
-- the image and hides it with CSS is a paywall that does not exist. `postsFor` decides access
-- per row and strips `image` from every row the reader has not bought. That is the reason the
-- feed cannot simply select and return.
--
-- The money is deliberately paranoid, the same way server/bank.lua is:
--
--   * the price is the SELLER's, read from the row here - the buyer's client never sends one;
--   * the debit goes through `Bridge.RemoveMoney`, which fails closed, and nothing is granted
--     until it has confirmed;
--   * the seller is credited into the phone's own balance rather than straight into their bank,
--     so a payout that fails leaves the money owed rather than destroyed;
--   * buying the same picture twice is refused by the table, not by the button.

local CFG = Config.OnlyFruits or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

local function priceCap() return math.max(1, math.floor(num(CFG.maxPrice, 5000))) end
local function subCap() return math.max(1, math.floor(num(CFG.maxSubPrice, 10000))) end
local function tipCap() return math.max(1, math.floor(num(CFG.maxTip, 10000))) end
local function subDays() return math.max(1, math.floor(num(CFG.subDays, 30))) end
local function postDays() return math.max(0, math.floor(num(CFG.postDays, 0))) end
local function maxPosts() return math.max(0, math.floor(num(CFG.maxPosts, 100))) end
local function maxPerDay() return math.max(0, math.floor(num(CFG.maxPerDay, 20))) end
local function minHandle() return math.max(1, math.min(20, math.floor(num(CFG.minHandle, 3)))) end
local function payoutMin() return math.max(1, math.floor(num(CFG.payoutMin, 1))) end
local function subsOn() return CFG.subscriptions ~= false end
local function tipsOn() return CFG.tips ~= false end

--- The clause that hides a picture past its day.
---
--- Hidden, not deleted. A creator whose operator lowers `postDays` and raises it again gets
--- their back catalogue back rather than discovering it was burned - and an unlock somebody
--- paid for still points at a row that exists.
local function livePosts(alias)
    if postDays() <= 0 then return '' end
    return (' AND %s.at > NOW() - INTERVAL %d DAY'):format(alias, postDays())
end
local function feePercent()
    local pct = num(CFG.feePercent, 0)
    if pct < 0 then return 0 end
    return math.min(100, pct)
end

--- A whole amount inside the operator's bounds. Anything else is not a price, it is an attempt.
local function money(value, cap)
    local n = math.floor(num(value, 0))
    if n < 0 then return 0 end
    return math.min(n, cap)
end

--- **In-game photographs only. Not the social apps' host list.**
---
--- Bleeter and Snapmatic accept anything from an allowed host - imgur, Discord - because they
--- are places to share a picture. This is a place to SELL one, and the two are not the same
--- decision: a link box on a paid-content app is an invitation to sell somebody else's
--- photograph, and there is no way to tell from a URL who took what.
---
--- So the only acceptable picture is one this phone's own camera uploaded, which is exactly
--- what the media table records. A creator has to have gone somewhere and taken it.
---
--- The edit recipe is stripped first: the gallery appends `#filter,crop,...` to carry the
--- framing, and that is not part of the URL the upload recorded.
local function imageAllowed(url)
    local bare = tostring(url or ''):gsub('#.*$', '')
    if bare == '' then return false end
    if not Bridge.MediaHasUrl then return false end
    return Bridge.MediaHasUrl(bare) == true
end

local function clean(text, max)
    text = tostring(text or ''):gsub('[%c]', ' '):gsub('%s+', ' ')
    return text:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, max)
end

--- A handle: lowercase, letters, digits and underscores, and never empty.
local function cleanHandle(raw)
    return tostring(raw or ''):lower():gsub('^@', ''):gsub('[^%a%d_]', ''):sub(1, 20)
end

-- ══════════════════════════════════════════════════════════════
-- Tables
-- ══════════════════════════════════════════════════════════════
CreateThread(function()
    if not enabled() then return end

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fan_profiles` (
        `citizenid` VARCHAR(64) NOT NULL,
        `handle`    VARCHAR(20) NOT NULL,
        `name`      VARCHAR(40) NOT NULL DEFAULT '',
        `bio`       VARCHAR(200) NOT NULL DEFAULT '',
        `avatar`    VARCHAR(300) NOT NULL DEFAULT '',
        `cover`     VARCHAR(300) NOT NULL DEFAULT '',
        `sub_price` INT UNSIGNED NOT NULL DEFAULT 0,
        `balance`   BIGINT NOT NULL DEFAULT 0,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`citizenid`),
        UNIQUE KEY `handle` (`handle`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fan_posts` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(64) NOT NULL,
        `image`     VARCHAR(300) NOT NULL,
        `caption`   VARCHAR(200) NOT NULL DEFAULT '',
        `price`     INT UNSIGNED NOT NULL DEFAULT 0,
        `subs_only` TINYINT(1) NOT NULL DEFAULT 0,
        `sold`      INT UNSIGNED NOT NULL DEFAULT 0,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `citizenid` (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fan_follows` (
        `citizenid` VARCHAR(64) NOT NULL,
        `creator`   VARCHAR(64) NOT NULL,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`citizenid`, `creator`),
        KEY `creator` (`creator`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- A subscription is a DATE, not a flag: it lapses on its own, and re-subscribing extends
    -- rather than restarts, so paying twice by accident is not paying for nothing.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fan_subs` (
        `citizenid` VARCHAR(64) NOT NULL,
        `creator`   VARCHAR(64) NOT NULL,
        `until_at`  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`citizenid`, `creator`),
        KEY `creator` (`creator`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- One row per picture somebody bought. The PRIMARY KEY is what makes buying twice
    -- impossible - a check in Lua would be a check across a query, and two taps are faster
    -- than a round trip.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fan_unlocks` (
        `citizenid` VARCHAR(64) NOT NULL,
        `post_id`   INT UNSIGNED NOT NULL,
        `paid`      INT UNSIGNED NOT NULL DEFAULT 0,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`citizenid`, `post_id`),
        KEY `post_id` (`post_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fan_tx` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `creator`   VARCHAR(64) NOT NULL,
        `buyer`     VARCHAR(64) NOT NULL DEFAULT '',
        `kind`      VARCHAR(12) NOT NULL DEFAULT 'sale',
        `amount`    INT NOT NULL DEFAULT 0,
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `creator` (`creator`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

-- ══════════════════════════════════════════════════════════════
-- Reading
-- ══════════════════════════════════════════════════════════════
local function profileOf(cid)
    if cid == '' then return nil end
    return MySQL.single.await(
        'SELECT citizenid, handle, name, bio, avatar, cover, sub_price, balance FROM vphone_fan_profiles WHERE citizenid = ?',
        { cid })
end

local function profileByHandle(handle)
    handle = cleanHandle(handle)
    if handle == '' then return nil end
    return MySQL.single.await(
        'SELECT citizenid, handle, name, bio, avatar, cover, sub_price, balance FROM vphone_fan_profiles WHERE handle = ?',
        { handle })
end

local function counts(cid)
    return {
        followers = num(MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_fan_follows WHERE creator = ?', { cid }), 0),
        subscribers = num(MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_fan_subs WHERE creator = ? AND until_at > NOW()', { cid }), 0),
        posts = num(MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_fan_posts p WHERE p.citizenid = ?' .. livePosts('p'),
            { cid }), 0),
    }
end

--- **May this reader see this picture?** The one place that decides.
---
--- It was decided twice - once for a creator's page and once for the feed - and the two copies
--- disagreed. The feed's said a subscription opens every PRICED picture; the page's said it does
--- only when the operator asked for that with `subsUnlockPaid`, which is off by default. So a
--- subscriber scrolling their feed saw everything they had not bought, and the paywall held on
--- one screen and not the other.
---
--- A rule written twice is a rule that will differ. There is one of it now, and both readers ask
--- it the same question.
local function postOpen(mine, price, subsOnly, bought, isSub)
    if mine or bought then return true end
    -- Held back for subscribers: the subscription IS the key, whatever else is set.
    if subsOnly then return isSub end
    -- Free to everybody.
    if price <= 0 then return true end
    -- Priced. A subscription only covers it if the operator said subscriptions cover everything.
    return isSub and CFG.subsUnlockPaid == true
end

local function subscribed(cid, creator)
    if cid == creator then return true end
    return MySQL.scalar.await(
        'SELECT 1 FROM vphone_fan_subs WHERE citizenid = ? AND creator = ? AND until_at > NOW()',
        { cid, creator }) ~= nil
end

--- The posts of one creator, as THIS reader is allowed to see them.
---
--- **This is the paywall.** A row the reader has not paid for comes back with `locked = true`
--- and NO `image` field at all: the URL is dropped here, on the server, so there is nothing in
--- the page to find. Everything else about the row - the price, the caption, when it was posted -
--- is public, because that is what somebody decides to buy from.
local function postsFor(readerCid, creatorCid, limit)
    limit = math.max(1, math.min(100, math.floor(num(limit, 30))))
    local rows = MySQL.query.await([[
        SELECT p.id, p.image, p.caption, p.price, p.subs_only, p.sold, UNIX_TIMESTAMP(p.at) AS ts,
               (u.post_id IS NOT NULL) AS bought
        FROM vphone_fan_posts p
        LEFT JOIN vphone_fan_unlocks u ON u.post_id = p.id AND u.citizenid = ?
        WHERE p.citizenid = ?]] .. livePosts('p') .. [[
        ORDER BY p.id DESC LIMIT ?]],
        { readerCid, creatorCid, limit }) or {}

    local isSub = subscribed(readerCid, creatorCid)
    local mine = readerCid == creatorCid

    local out = {}
    for _, r in ipairs(rows) do
        local price = math.floor(num(r.price, 0))
        local subsOnly = num(r.subs_only, 0) == 1
        -- Free to everybody, or already bought, or covered by a subscription, or your own.
        local open = postOpen(mine, price, subsOnly, num(r.bought, 0) == 1, isSub)

        out[#out + 1] = {
            id = r.id,
            caption = r.caption,
            price = price,
            subsOnly = subsOnly or nil,
            sold = math.floor(num(r.sold, 0)),
            ts = math.floor(num(r.ts, 0)),
            locked = (not open) or nil,
            -- The one line the whole app is built around.
            image = open and r.image or nil,
        }
    end
    return out
end

--- A creator card, without anything private on it.
local function cardOf(row, readerCid)
    local c = counts(row.citizenid)
    return {
        handle = row.handle,
        name = row.name ~= '' and row.name or row.handle,
        bio = row.bio,
        avatar = row.avatar ~= '' and row.avatar or nil,
        cover = row.cover ~= '' and row.cover or nil,
        subPrice = math.floor(num(row.sub_price, 0)),
        followers = c.followers,
        subscribers = c.subscribers,
        posts = c.posts,
        me = readerCid == row.citizenid or nil,
        following = readerCid ~= row.citizenid and MySQL.scalar.await(
            'SELECT 1 FROM vphone_fan_follows WHERE citizenid = ? AND creator = ?',
            { readerCid, row.citizenid }) ~= nil or nil,
        subscribed = readerCid ~= row.citizenid and subscribed(readerCid, row.citizenid) or nil,
    }
end

-- ══════════════════════════════════════════════════════════════
-- The app
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:fan:open', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local mine = profileOf(cid)

    -- Who you follow, newest post first. A feed of people you chose beats a feed of everybody.
    local feed = {}
    for _, r in ipairs(MySQL.query.await([[
        SELECT pr.citizenid, pr.handle, pr.name, pr.avatar, po.id, po.caption, po.price,
               po.subs_only, po.image, UNIX_TIMESTAMP(po.at) AS ts,
               (u.post_id IS NOT NULL) AS bought
        FROM vphone_fan_posts po
        INNER JOIN vphone_fan_profiles pr ON pr.citizenid = po.citizenid
        INNER JOIN vphone_fan_follows f ON f.creator = po.citizenid AND f.citizenid = ?
        LEFT JOIN vphone_fan_unlocks u ON u.post_id = po.id AND u.citizenid = ?
        WHERE 1 = 1]] .. livePosts('po') .. [[
        ORDER BY po.id DESC LIMIT 40]], { cid, cid }) or {}) do
        local price = math.floor(num(r.price, 0))
        local subsOnly = num(r.subs_only, 0) == 1
        local open = postOpen(false, price, subsOnly, num(r.bought, 0) == 1,
                              subscribed(cid, r.citizenid))
        feed[#feed + 1] = {
            id = r.id, handle = r.handle, name = r.name ~= '' and r.name or r.handle,
            avatar = r.avatar ~= '' and r.avatar or nil,
            caption = r.caption, price = price, subsOnly = subsOnly or nil,
            ts = math.floor(num(r.ts, 0)),
            locked = (not open) or nil,
            image = open and r.image or nil,
        }
    end

    -- Discover: the most followed, so a new player has somewhere to start.
    local discover = {}
    for _, r in ipairs(MySQL.query.await([[
        SELECT pr.citizenid, pr.handle, pr.name, pr.avatar, pr.cover, pr.bio, pr.sub_price,
               (SELECT COUNT(*) FROM vphone_fan_follows f WHERE f.creator = pr.citizenid) AS followers
        FROM vphone_fan_profiles pr
        WHERE pr.citizenid <> ?
        ORDER BY followers DESC, pr.at DESC LIMIT 20]], { cid }) or {}) do
        discover[#discover + 1] = {
            handle = r.handle, name = r.name ~= '' and r.name or r.handle,
            avatar = r.avatar ~= '' and r.avatar or nil,
            -- The banner, which the tile leads with. It was stored, drawn on the creator's own
            -- page, and never SENT to Discover - so the one screen whose whole job is to make
            -- somebody want to open a page was a grid of blank rectangles.
            cover = r.cover ~= '' and r.cover or nil,
            bio = r.bio,
            subPrice = math.floor(num(r.sub_price, 0)),
            followers = math.floor(num(r.followers, 0)),
        }
    end

    local out = {
        ok = true,
        feed = feed,
        discover = discover,
        -- The page draws itself from these rather than from its own idea of the rules. A
        -- ceiling the server enforces and the page does not know about is a form that lets
        -- somebody type a number and then refuses it, which reads as a bug.
        limits = {
            maxPrice = priceCap(), maxSubPrice = subCap(), maxTip = tipCap(),
            subDays = subDays(), fee = feePercent(),
            tax = math.max(0, math.min(100, num((CFG.tax or {}).percent, 0))),
            postDays = postDays(), maxPosts = maxPosts(), maxPerDay = maxPerDay(),
            minHandle = minHandle(), payoutMin = payoutMin(),
            subscriptions = subsOn(), tips = tipsOn(),
        },
    }

    if mine then
        out.me = cardOf(mine, cid)
        out.balance = math.floor(num(mine.balance, 0))
        out.posts = postsFor(cid, cid, 60)
        local tx = {}
        for _, r in ipairs(MySQL.query.await([[
            SELECT kind, amount, UNIX_TIMESTAMP(at) AS ts FROM vphone_fan_tx
            WHERE creator = ? ORDER BY id DESC LIMIT 30]], { cid }) or {}) do
            tx[#tx + 1] = { kind = r.kind, amount = math.floor(num(r.amount, 0)),
                            ts = math.floor(num(r.ts, 0)) }
        end
        out.earnings = tx
    end

    resolve(out)
end)

--- Create or edit your own page.
V.Callback('v-phone:fan:setup', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local handle = cleanHandle(data and data.handle)
    if #handle < minHandle() then resolve({ error = 'handle' }) return end

    local name = clean(data and data.name, 40)
    local bio = clean(data and data.bio, 200)
    local avatar = tostring((data and data.avatar) or ''):sub(1, 300)
    local cover = tostring((data and data.cover) or ''):sub(1, 300)
    if avatar ~= '' and not imageAllowed(avatar) then resolve({ error = 'badhost' }) return end
    if cover ~= '' and not imageAllowed(cover) then resolve({ error = 'badhost' }) return end

    local subPrice = money(data and data.subPrice, subCap())

    -- The handle belongs to whoever took it. Checked before the write so the answer is a
    -- sentence rather than a duplicate-key error.
    local taken = MySQL.scalar.await(
        'SELECT citizenid FROM vphone_fan_profiles WHERE handle = ? AND citizenid <> ?',
        { handle, cid })
    if taken then resolve({ error = 'taken' }) return end

    -- Every column is written from a value decided above, so there is no partial-write problem
    -- of the kind that erased the Hush profile: the form sends all of them and all of them are
    -- validated here.
    MySQL.query.await([[
        INSERT INTO vphone_fan_profiles (citizenid, handle, name, bio, avatar, cover, sub_price)
        VALUES (?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE handle=VALUES(handle), name=VALUES(name), bio=VALUES(bio),
            avatar=VALUES(avatar), cover=VALUES(cover), sub_price=VALUES(sub_price)]],
        { cid, handle, name, bio, avatar, cover, subPrice })

    resolve({ ok = true })
end)

--- Is this handle available?
---
--- Asked while somebody is typing, so the sign-up can say "taken" beside the field instead of
--- refusing the whole form at the end. It answers about availability and NOTHING else: it never
--- says who holds a taken handle, because "is @mara somebody" is not a question a stranger gets
--- to ask a server about.
V.Callback('v-phone:fan:handle', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local handle = cleanHandle(data and data.handle)
    if #handle < minHandle() then
        resolve({ ok = true, handle = handle, free = false, why = 'short' })
        return
    end
    local taken = MySQL.scalar.await(
        'SELECT 1 FROM vphone_fan_profiles WHERE handle = ? AND citizenid <> ?',
        { handle, p.citizenid })
    resolve({ ok = true, handle = handle, free = not taken, why = taken and 'taken' or nil })
end)

--- Publish a photograph.
V.Callback('v-phone:fan:post', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid
    if not profileOf(cid) then resolve({ error = 'noprofile' }) return end

    local image = tostring((data and data.image) or ''):sub(1, 300)
    if image == '' then resolve({ error = 'noimage' }) return end
    if not imageAllowed(image) then resolve({ error = 'badhost' }) return end

    local caption = clean(data and data.caption, 200)
    local price = money(data and data.price, priceCap())
    local subsOnly = (data and data.subsOnly) == true and subsOn()

    -- The operator's ceilings, checked here because the page cannot be trusted to have drawn
    -- them. `maxPosts` counts what is LISTED, so a creator whose older pictures have aged out
    -- has room again - which is the point of a lifetime rather than a hard cap.
    if maxPosts() > 0 then
        local live = num(MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_fan_posts p WHERE p.citizenid = ?' .. livePosts('p'),
            { cid }), 0)
        if live >= maxPosts() then resolve({ error = 'toomany' }) return end
    end
    if maxPerDay() > 0 then
        local today = num(MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_fan_posts WHERE citizenid = ? AND at > NOW() - INTERVAL 1 DAY',
            { cid }), 0)
        if today >= maxPerDay() then resolve({ error = 'dailycap' }) return end
    end

    local id = MySQL.insert.await(
        'INSERT INTO vphone_fan_posts (citizenid, image, caption, price, subs_only) VALUES (?,?,?,?,?)',
        { cid, image, caption, price, subsOnly and 1 or 0 })

    -- Everybody who follows is told, because a post nobody hears about is a post nobody buys.
    -- Through the phone's own notification, so it obeys mute, Do Not Disturb and the app's tone.
    local who = MySQL.query.await('SELECT citizenid FROM vphone_fan_follows WHERE creator = ?', { cid }) or {}
    local me = profileOf(cid)
    for _, f in ipairs(who) do
        pcall(function()
            exports[GetCurrentResourceName()]:NotifyCitizen(f.citizenid, 'onlyfruits',
                (me and me.name ~= '' and me.name) or (me and me.handle) or '',
                LP(src, 'ph.fan_notif_post'))
        end)
    end

    resolve({ ok = true, id = id })
end)

V.Callback('v-phone:fan:delete', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve({ error = 'args' }) return end

    -- Yours, checked in the statement rather than read-then-write: two queries is a window.
    local n = MySQL.update.await('DELETE FROM vphone_fan_posts WHERE id = ? AND citizenid = ?',
        { id, p.citizenid }) or 0
    if n <= 0 then resolve({ error = 'notyours' }) return end

    -- The unlocks go with it. Somebody who paid for a picture the creator then deleted keeps
    -- nothing to point at, and a row referring to a post that is gone is a row that will
    -- confuse the next person to read this table.
    MySQL.update.await('DELETE FROM vphone_fan_unlocks WHERE post_id = ?', { id })
    resolve({ ok = true })
end)

--- One creator's page.
V.Callback('v-phone:fan:creator', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local row = profileByHandle(data and data.handle)
    if not row then resolve({ error = 'nocreator' }) return end

    resolve({ ok = true, creator = cardOf(row, p.citizenid),
              posts = postsFor(p.citizenid, row.citizenid, 60) })
end)

V.Callback('v-phone:fan:follow', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local row = profileByHandle(data and data.handle)
    if not row then resolve({ error = 'nocreator' }) return end
    if row.citizenid == p.citizenid then resolve({ error = 'self' }) return end

    if (data and data.on) == false then
        MySQL.update.await('DELETE FROM vphone_fan_follows WHERE citizenid = ? AND creator = ?',
            { p.citizenid, row.citizenid })
        resolve({ ok = true, following = false })
        return
    end

    MySQL.query.await(
        'INSERT IGNORE INTO vphone_fan_follows (citizenid, creator) VALUES (?,?)',
        { p.citizenid, row.citizenid })
    resolve({ ok = true, following = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Money
-- ══════════════════════════════════════════════════════════════
-- One function takes money from a buyer and credits a seller, because there are three ways to
-- pay in this app and all three have to be equally careful. The order is the only order that
-- cannot lose money: debit first, and only credit what the debit confirmed.

local function pay(src, buyerCid, creatorCid, amount, kind)
    amount = math.floor(num(amount, 0))
    if amount <= 0 then return false, 'amount' end
    if buyerCid == creatorCid then return false, 'self' end

    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not Bridge.RemoveMoney(acting, amount, 'bank', 'v-phone: OnlyFruits') then
        return false, 'nomoney'
    end

    -- The house's cut, if the operator takes one. Rounded DOWN, so the house never rounds up.
    local fee = math.floor(amount * feePercent() / 100)

    -- And the tax, taken from the SAME gross amount rather than from what is left after the
    -- fee. Two percentages that compound are two percentages nobody can predict from reading
    -- the config: with both at 10, the creator loses exactly 20 and not 19.
    --
    -- A credit that fails leaves the money with the CREATOR rather than destroying it. Unpaid
    -- tax is something an operator can chase; money that went nowhere is gone.
    local tax = 0
    pcall(function()
        tax = Bridge.Revenue(CFG.tax, amount, 'v-phone: OnlyFruits tax') or 0
    end)

    local net = math.max(0, amount - fee - tax)

    -- Into the phone's own balance rather than the creator's bank. A creator who is offline
    -- has no source id to credit, and money that has left one account and arrived nowhere is
    -- the one outcome worth engineering against.
    MySQL.update.await('UPDATE vphone_fan_profiles SET balance = balance + ? WHERE citizenid = ?',
        { net, creatorCid })
    MySQL.insert('INSERT INTO vphone_fan_tx (creator, buyer, kind, amount) VALUES (?,?,?,?)',
        { creatorCid, buyerCid, kind, net })

    return true, net
end

V.Callback('v-phone:fan:unlock', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve({ error = 'args' }) return end

    -- The PRICE comes from the row, never from the buyer. This is the whole reason the client
    -- sends an id and nothing else.
    local post = MySQL.single.await(
        'SELECT citizenid, price, subs_only, image FROM vphone_fan_posts WHERE id = ?', { id })
    if not post then resolve({ error = 'gone' }) return end

    -- **Nothing is charged for a picture that is no longer there.**
    --
    -- A row outlives its file: media expires on its own clock, and a paid post whose photograph
    -- has gone still had a price, still took the money, still said "Unlocked", and showed an
    -- empty card. Buying again answered `already`, so there was no way back and no refund.
    --
    -- `MediaHasUrl` is the phone's own record of what it uploaded, and the cheapest honest test
    -- available here - a request to the host would put a network round trip in front of every
    -- purchase.
    -- **Without the edit recipe.** A photograph the player cropped or filtered carries
    -- `#vp=...` on the end, `MediaHasUrl` is an exact match, and so every post made from an
    -- edited picture would read as expired for ever and could never be sold. `imageAllowed`
    -- above strips it for the same reason.
    local img = tostring(post.image or ''):gsub('#.*$', '')
    if img ~= '' and Bridge.MediaHasUrl and not Bridge.MediaHasUrl(img) then
        resolve({ error = 'postgone' }) return
    end
    if post.citizenid == cid then resolve({ error = 'self' }) return end
    if num(post.subs_only, 0) == 1 then resolve({ error = 'subsonly' }) return end

    local price = math.floor(num(post.price, 0))
    if price <= 0 then resolve({ error = 'free' }) return end

    -- Claim it BEFORE paying. The primary key is what makes a double tap harmless: the second
    -- insert affects no rows, so the second payment never happens.
    local claimed = MySQL.update.await(
        'INSERT IGNORE INTO vphone_fan_unlocks (citizenid, post_id, paid) VALUES (?,?,?)',
        { cid, id, price }) or 0
    if claimed <= 0 then resolve({ error = 'already' }) return end

    local ok, err = pay(src, cid, post.citizenid, price, 'sale')
    if not ok then
        -- Paid for nothing is worse than bought nothing: the claim goes back.
        MySQL.update.await('DELETE FROM vphone_fan_unlocks WHERE citizenid = ? AND post_id = ?',
            { cid, id })
        resolve({ error = err })
        return
    end

    MySQL.update('UPDATE vphone_fan_posts SET sold = sold + 1 WHERE id = ?', { id })
    pcall(function()
        exports[GetCurrentResourceName()]:NotifyCitizen(post.citizenid, 'onlyfruits',
            LP(src, 'ph.fan_notif_sale'), tostring(price))
    end)

    -- And the picture, now that it is theirs.
    local image = MySQL.scalar.await('SELECT image FROM vphone_fan_posts WHERE id = ?', { id })
    resolve({ ok = true, image = image })
end)

V.Callback('v-phone:fan:subscribe', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local row = profileByHandle(data and data.handle)
    if not row then resolve({ error = 'nocreator' }) return end
    if row.citizenid == cid then resolve({ error = 'self' }) return end

    if not subsOn() then resolve({ error = 'nosub' }) return end
    local price = math.floor(num(row.sub_price, 0))
    if price <= 0 then resolve({ error = 'nosub' }) return end

    local ok, err = pay(src, cid, row.citizenid, price, 'sub')
    if not ok then resolve({ error = err }) return end

    -- Extends rather than restarts: subscribing again a week early adds a month to what is
    -- left instead of throwing it away.
    MySQL.query.await([[
        INSERT INTO vphone_fan_subs (citizenid, creator, until_at)
        VALUES (?, ?, DATE_ADD(NOW(), INTERVAL ? DAY))
        ON DUPLICATE KEY UPDATE until_at = DATE_ADD(
            GREATEST(until_at, NOW()), INTERVAL ? DAY)]],
        { cid, row.citizenid, subDays(), subDays() })

    pcall(function()
        exports[GetCurrentResourceName()]:NotifyCitizen(row.citizenid, 'onlyfruits',
            LP(src, 'ph.fan_notif_sub'), tostring(price))
    end)
    resolve({ ok = true })
end)

V.Callback('v-phone:fan:tip', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    if not tipsOn() then resolve({ error = 'notips' }) return end
    local row = profileByHandle(data and data.handle)
    if not row then resolve({ error = 'nocreator' }) return end

    local amount = money(data and data.amount, tipCap())
    if amount <= 0 then resolve({ error = 'amount' }) return end

    local ok, err = pay(src, p.citizenid, row.citizenid, amount, 'tip')
    if not ok then resolve({ error = err }) return end

    pcall(function()
        exports[GetCurrentResourceName()]:NotifyCitizen(row.citizenid, 'onlyfruits',
            LP(src, 'ph.fan_notif_tip'), tostring(amount))
    end)
    resolve({ ok = true })
end)

--- Take the earnings out.
---
--- The balance is decremented FIRST and put back if the credit fails, which is the same shape
--- as the unlock above and for the same reason: between the two statements is a window, and the
--- direction that survives it is the one where a failure owes money rather than invents it.
V.Callback('v-phone:fan:payout', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local balance = math.floor(num(MySQL.scalar.await(
        'SELECT balance FROM vphone_fan_profiles WHERE citizenid = ?', { cid }), 0))
    if balance <= 0 then resolve({ error = 'empty' }) return end
    if balance < payoutMin() then
        resolve({ error = 'payoutmin', min = payoutMin() }) return
    end

    local taken = MySQL.update.await(
        'UPDATE vphone_fan_profiles SET balance = balance - ? WHERE citizenid = ? AND balance >= ?',
        { balance, cid, balance }) or 0
    if taken <= 0 then resolve({ error = 'empty' }) return end

    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not Bridge.AddMoney(acting, balance, 'bank', 'v-phone: OnlyFruits payout') then
        MySQL.update.await('UPDATE vphone_fan_profiles SET balance = balance + ? WHERE citizenid = ?',
            { balance, cid })
        resolve({ error = 'nobank' })
        return
    end

    MySQL.insert('INSERT INTO vphone_fan_tx (creator, buyer, kind, amount) VALUES (?,?,?,?)',
        { cid, '', 'payout', -balance })
    resolve({ ok = true, amount = balance })
end)
