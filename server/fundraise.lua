-- v-phone | server/fundraise.lua
--
-- **Fruitee: a page you can give money to.**
--
-- Somebody opens a page - a name, a picture, a few lines about what the money is for, and a
-- target. Anybody else opens it and gives. The money is real: it leaves a bank account through
-- the same bridge every other app uses, so it works the same on qb-core, on ESX and with
-- doc-banking, and it arrives in a balance the owner withdraws.
--
-- It is deliberately NOT OnlyFruits with different words. The two apps look similar and the
-- one thing that matters is the opposite:
--
--   * OnlyFruits sells a thing at a price the SELLER set. The buyer's client never sends an
--     amount, because it has no business naming one.
--   * Fruitee takes a gift at an amount the GIVER chose. The amount has to come from the
--     client - that is what giving is - so every one of them is bounded here, by the
--     operator's floor and ceiling, and the page's suggested tiers are suggestions and
--     nothing more. A tier is never trusted as a price.
--
-- Two numbers, and they are not the same number:
--
--   * `raised` is what people GAVE. It is what the progress bar counts, because somebody who
--     gives 100 has given 100 towards the target whatever the server takes off it.
--   * `balance` is what the owner may WITHDRAW - the gift less the fee and the tax. Showing
--     the second as the first would make every goal on the server quietly unreachable.
--
-- The money is as paranoid as server/bank.lua:
--
--   * the debit goes through `Bridge.RemoveMoney`, which fails closed, and the gift is only
--     recorded once it has confirmed;
--   * the owner is credited into the page's own balance rather than into their bank, so a
--     payout to somebody offline is money owed rather than money destroyed;
--   * a failed tax credit leaves the money with the OWNER - unpaid tax can be chased, and
--     money that went nowhere cannot;
--   * a second click within a few seconds is refused, because unlike buying a picture there
--     is nothing about a gift that makes giving twice impossible.

local CFG = Config.Fundraise or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

local function minGift() return math.max(1, math.floor(num(CFG.minGift, 1))) end
local function maxGift() return math.max(minGift(), math.floor(num(CFG.maxGift, 100000))) end
local function goalMax() return math.max(0, math.floor(num(CFG.goalMax, 1000000))) end
local function maxTiers() return math.max(0, math.min(6, math.floor(num(CFG.maxTiers, 4)))) end
local function payoutMin() return math.max(1, math.floor(num(CFG.payoutMin, 1))) end
local function messagesOn() return CFG.messages ~= false end
local function anonOn() return CFG.anonymous ~= false end

--- How long a page stays listed, in real days.
---
--- Hidden, not deleted, exactly as OnlyFruits treats an old picture: an operator who lowers
--- this and raises it again gets the pages back rather than discovering they were burned. The
--- OWNER always sees their own, however old - a page that vanished from under its author with
--- no explanation is a support ticket.
local function pageDays() return math.max(0, math.floor(num(CFG.pageDays, 0))) end
local function liveClause(alias)
    if pageDays() <= 0 then return '' end
    return (' AND %s.at > NOW() - INTERVAL %d DAY'):format(alias, pageDays())
end

-- ══════════════════════════════════════════════════════════════
-- The two cuts
-- ══════════════════════════════════════════════════════════════
-- Every gift is split three ways, and the app names all three: the platform's cut, the
-- government's, and what is left for the page.
--
-- **The percentage is always taken. The account only decides where it lands.**
--
-- That is a deliberate choice and it is the opposite of what this file did first. The rate is
-- printed on the screen a player reads before giving, so it has to be true - and a rate that
-- silently did nothing because a field further down the config was blank is the app lying
-- about money. With no account named the cut is a sink: it leaves the economy, which is a
-- thing servers want on purpose. Set the percentage to 0 to not take it at all.
--
-- Both come off the SAME gross rather than one off what is left after the other. Two
-- percentages that compound are two nobody can predict from reading the config: at 5 and 30
-- the page loses exactly 35, not 33.5.

local function cutOf(key, fallback)
    local taxes = CFG.taxes
    local one = type(taxes) == 'table' and taxes[key] or nil
    if type(one) ~= 'table' then return { percent = fallback or 0, account = '' } end
    local pct = num(one.percent, fallback or 0)
    if pct < 0 then pct = 0 end
    return {
        percent = math.min(100, pct),
        account = tostring(one.account or ''):gsub('%s', ''),
    }
end

--- The cuts in the order the app shows them, largest concept first: whose app this is, then
--- whose city it is.
local function taxes()
    return {
        { key = 'platform', cut = cutOf('platform', 5) },
        { key = 'government', cut = cutOf('government', 30) },
    }
end

--- Take both cuts off one gross amount, and say what each one was.
---
--- A credit that fails still counts as taken, because the alternative is worse: money that was
--- announced as a 30 percent tax and then quietly handed back would make the number on the
--- page a lie in the other direction. A failed credit is a sink, and it prints once so an
--- operator can see the account name is wrong.
local function applyTaxes(amount)
    local total, lines = 0, {}
    for _, entry in ipairs(taxes()) do
        local pct = entry.cut.percent
        -- Rounded DOWN, so the house never rounds up.
        local cut = math.floor(amount * pct / 100)
        if cut > 0 then
            total = total + cut
            lines[#lines + 1] = { key = entry.key, percent = pct, amount = cut }
            if entry.cut.account ~= '' then
                local ok, paid = pcall(function()
                    return Bridge.AddSociety(entry.cut.account, cut,
                        'v-phone: Fruitee ' .. entry.key) and cut or 0
                end)
                if not ok or (paid or 0) <= 0 then
                    print(('[v-phone] Fruitee: %s tax of %d could not reach "%s"')
                        :format(entry.key, cut, entry.cut.account))
                end
            end
        end
    end
    return total, lines
end

--- A whole amount inside the operator's bounds. Anything else is not a gift, it is an attempt.
local function giftAmount(v)
    local n = math.floor(num(v, 0))
    if n < minGift() then return nil end
    if n > maxGift() then return nil end
    return n
end

local function clean(text, max)
    return tostring(text or ''):gsub('%c', ' '):sub(1, max or 200)
end

--- The same host gate every other picture in the phone goes through.
---
--- A cover faces everybody who opens the page, so it is exactly as public as a post's image
--- and gets exactly the same check. With `inGameOnly` on it has to be a photograph taken with
--- the phone's own camera, which is the setting for a server that does not want links to the
--- open internet on its pages at all.
local function imageAllowed(url)
    local bare = tostring(url or ''):gsub('#.*$', '')
    if bare == '' then return true end
    if CFG.inGameOnly == true then
        if not Bridge.MediaHasUrl then return false end
        return Bridge.MediaHasUrl(bare) == true
    end
    return PhoneImageAllowed == nil or PhoneImageAllowed(bare) == true
end

--- The page's address. Lower case, letters, digits and underscores, and unique on the server.
local function cleanSlug(raw)
    local s = tostring(raw or ''):lower():gsub('[^%w_]', '')
    return s:sub(1, 24)
end

local function categories()
    local list = CFG.categories
    if type(list) ~= 'table' or #list == 0 then
        return { 'community', 'medical', 'business', 'memorial', 'event', 'other' }
    end
    local out = {}
    for _, c in ipairs(list) do
        local one = tostring(c):lower():gsub('[^%a]', '')
        if one ~= '' then out[#out + 1] = one end
    end
    return #out > 0 and out or { 'other' }
end

local function knownCategory(c)
    c = tostring(c or ''):lower()
    for _, one in ipairs(categories()) do
        if one == c then return c end
    end
    return categories()[1]
end

-- ══════════════════════════════════════════════════════════════
-- Tiers
-- ══════════════════════════════════════════════════════════════
-- A suggested amount with a word beside it: "5 - a coffee", "50 - a week's rent". Stored as
-- JSON in one column because they are a short list that is only ever read whole, and a table
-- of four rows per page would be a join for nothing.
--
-- **A tier is a SUGGESTION and never a price.** `give` bounds whatever amount it is handed by
-- the operator's floor and ceiling and does not look at the tiers at all - so a page cannot
-- make somebody give more than the server allows by writing a big number into one.

local function encodeTiers(raw)
    if type(raw) ~= 'table' then return '[]' end
    local out = {}
    for _, t in ipairs(raw) do
        if #out >= maxTiers() then break end
        local amount = math.floor(num(type(t) == 'table' and t.amount or t, 0))
        if amount >= minGift() and amount <= maxGift() then
            out[#out + 1] = {
                amount = amount,
                label = clean(type(t) == 'table' and t.label or '', 32),
            }
        end
    end
    local ok, encoded = pcall(json.encode, out)
    return ok and encoded or '[]'
end

local function decodeTiers(raw)
    if type(raw) ~= 'string' or raw == '' then return {} end
    local ok, list = pcall(json.decode, raw)
    if not ok or type(list) ~= 'table' then return {} end
    local out = {}
    for _, t in ipairs(list) do
        if type(t) == 'table' and num(t.amount, 0) > 0 then
            out[#out + 1] = { amount = math.floor(num(t.amount, 0)), label = tostring(t.label or '') }
        end
    end
    return out
end

-- ══════════════════════════════════════════════════════════════
-- Schema
-- ══════════════════════════════════════════════════════════════

CreateThread(function()
    if not enabled() then return end
    Wait(600)

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fund_pages` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(64)  NOT NULL,
        `slug`      VARCHAR(24)  NOT NULL,
        `title`     VARCHAR(60)  NOT NULL DEFAULT '',
        `blurb`     VARCHAR(400) NOT NULL DEFAULT '',
        `cover`     VARCHAR(300) NOT NULL DEFAULT '',
        `avatar`    VARCHAR(300) NOT NULL DEFAULT '',
        `category`  VARCHAR(20)  NOT NULL DEFAULT 'other',
        -- 0 means no target: a page can simply collect.
        `goal`      INT UNSIGNED NOT NULL DEFAULT 0,
        -- What people gave, gross. This is the progress bar.
        `raised`    INT UNSIGNED NOT NULL DEFAULT 0,
        -- What the owner may withdraw, net of the fee and the tax.
        `balance`   INT UNSIGNED NOT NULL DEFAULT 0,
        `gifts`     INT UNSIGNED NOT NULL DEFAULT 0,
        `tiers`     VARCHAR(400) NOT NULL DEFAULT '[]',
        `anon`      TINYINT(1)   NOT NULL DEFAULT 1,
        `msgs`      TINYINT(1)   NOT NULL DEFAULT 1,
        `closed`    TINYINT(1)   NOT NULL DEFAULT 0,
        `at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        -- One page per character, and one owner per address.
        UNIQUE KEY `owner` (`citizenid`),
        UNIQUE KEY `slug` (`slug`),
        KEY `browse` (`closed`, `at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fund_gifts` (
        `id`      INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `page_id` INT UNSIGNED NOT NULL,
        `donor`   VARCHAR(16)  NOT NULL,
        `amount`  INT UNSIGNED NOT NULL DEFAULT 0,
        `net`     INT UNSIGNED NOT NULL DEFAULT 0,
        `body`    VARCHAR(200) NOT NULL DEFAULT '',
        -- Kept even when anonymous. The NAME is withheld from the page, not the record: an
        -- operator investigating where money went has to be able to find out, and a gift with
        -- no donor at all is a hole in the audit rather than privacy.
        `anon`    TINYINT(1)   NOT NULL DEFAULT 0,
        `at`      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `page` (`page_id`, `id`),
        KEY `donor` (`donor`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_fund_tx` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(64) NOT NULL,
        `kind`      VARCHAR(12) NOT NULL DEFAULT 'gift',
        `amount`    INT         NOT NULL DEFAULT 0,
        `at`        TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `mine` (`citizenid`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

-- ══════════════════════════════════════════════════════════════
-- Reading
-- ══════════════════════════════════════════════════════════════

local function pageOf(cid)
    return MySQL.single.await('SELECT * FROM vphone_fund_pages WHERE citizenid = ?', { cid })
end

local function pageBySlug(slug)
    return MySQL.single.await('SELECT * FROM vphone_fund_pages WHERE slug = ?', { slug })
end

--- What the owner is called, for a page nobody has met.
local function ownerName(cid)
    local ok, name = pcall(function()
        return Bridge.CharacterName and Bridge.CharacterName(cid) or nil
    end)
    if ok and type(name) == 'string' and name ~= '' then return name end
    return nil
end

--- One page, as everybody sees it.
---
--- `balance` is NOT in here and must not be: what an owner has left to withdraw is their
--- business, and it is a number the page has no reason to publish.
local function cardOf(row, viewerCid)
    if not row then return nil end
    return {
        id = math.floor(num(row.id, 0)),
        slug = tostring(row.slug or ''),
        title = tostring(row.title or ''),
        blurb = tostring(row.blurb or ''),
        cover = tostring(row.cover or ''),
        avatar = tostring(row.avatar or ''),
        category = tostring(row.category or 'other'),
        goal = math.floor(num(row.goal, 0)),
        raised = math.floor(num(row.raised, 0)),
        gifts = math.floor(num(row.gifts, 0)),
        tiers = decodeTiers(row.tiers),
        anon = num(row.anon, 1) == 1,
        msgs = num(row.msgs, 1) == 1,
        closed = num(row.closed, 0) == 1,
        owner = ownerName(row.citizenid),
        mine = viewerCid ~= nil and row.citizenid == viewerCid,
        ts = row.at,
    }
end

--- The supporters shown under a page.
---
--- An anonymous gift comes back with no name at all rather than with a name and a flag: a flag
--- is something a page can forget to honour, and this one only has to be honoured everywhere.
local function giftsFor(pageId, limit)
    local rows = MySQL.query.await([[SELECT id, donor, amount, body, anon, at
        FROM vphone_fund_gifts WHERE page_id = ? ORDER BY id DESC LIMIT ?]],
        { pageId, math.max(1, math.min(50, math.floor(num(limit, 20)))) }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local hidden = num(r.anon, 0) == 1
        out[#out + 1] = {
            id = math.floor(num(r.id, 0)),
            amount = math.floor(num(r.amount, 0)),
            body = tostring(r.body or ''),
            anon = hidden,
            -- **`hidden and nil or name` sends the name in both branches.** `nil` is
            -- falsy, so the `and` fails whatever `hidden` is and the `or` always wins.
            -- This function's own comment two lines up says an anonymous gift comes back
            -- with no name at all; for as long as it has existed it came back with one.
            -- The page draws "Anonymous" from the flag, so nothing looked wrong and the
            -- real name sat in the payload for anybody with a console open.
            name = (not hidden) and ownerName(r.donor) or nil,
            ts = r.at,
        }
    end
    return out
end

local function limits()
    local cuts, total = {}, 0
    for _, entry in ipairs(taxes()) do
        if entry.cut.percent > 0 then
            cuts[#cuts + 1] = { key = entry.key, percent = entry.cut.percent }
            total = total + entry.cut.percent
        end
    end
    return {
        minGift = minGift(), maxGift = maxGift(),
        goalMax = goalMax(), maxTiers = maxTiers(),
        payoutMin = payoutMin(),
        messages = messagesOn(), anonymous = anonOn(),
        categories = categories(),
        -- Named one by one, so the app can say WHOSE each cut is rather than printing one
        -- total nobody can account for.
        taxes = cuts,
        taxTotal = total,
    }
end

V.Callback('v-phone:fund:open', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local mine = pageOf(cid)

    -- What to browse. Closed pages are not listed - a page whose owner shut it is not asking
    -- for money any more - and a page past its day is hidden from the LIST but never from its
    -- own author, who still sees it under "My page".
    local rows = MySQL.query.await(([[SELECT * FROM vphone_fund_pages p
        WHERE p.closed = 0 %s
        ORDER BY p.raised DESC, p.id DESC LIMIT 40]]):format(liveClause('p'))) or {}

    local discover = {}
    for _, r in ipairs(rows) do discover[#discover + 1] = cardOf(r, cid) end

    -- What this character has given, so a donor can see their own history. Nobody else's.
    local given = MySQL.query.await([[SELECT g.amount, g.body, g.at, p.title, p.slug
        FROM vphone_fund_gifts g
        JOIN vphone_fund_pages p ON p.id = g.page_id
        WHERE g.donor = ? ORDER BY g.id DESC LIMIT 30]], { cid }) or {}

    resolve({
        ok = true,
        page = cardOf(mine, cid),
        -- Only the owner is told the balance, and only about their own page.
        balance = mine and math.floor(num(mine.balance, 0)) or 0,
        gifts = mine and giftsFor(mine.id, 30) or {},
        discover = discover,
        given = given,
        limits = limits(),
    })
end)

V.Callback('v-phone:fund:page', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local row = pageBySlug(cleanSlug(data and data.slug))
    if not row then resolve({ error = 'gone' }) return end

    resolve({
        ok = true,
        page = cardOf(row, p.citizenid),
        supporters = giftsFor(row.id, 20),
        limits = limits(),
    })
end)

--- Is this address free? Asked while typing, so it answers about the address and nothing else.
V.Callback('v-phone:fund:slug', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local slug = cleanSlug(data and data.slug)
    if #slug < 3 then resolve({ ok = true, free = false, reason = 'short', slug = slug }) return end

    local taken = MySQL.scalar.await(
        'SELECT citizenid FROM vphone_fund_pages WHERE slug = ? LIMIT 1', { slug })
    resolve({ ok = true, free = (taken == nil or taken == p.citizenid), slug = slug })
end)

-- ══════════════════════════════════════════════════════════════
-- Writing
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:fund:setup', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid
    data = data or {}

    local slug = cleanSlug(data.slug)
    if #slug < 3 then resolve({ error = 'slug' }) return end
    local title = clean(data.title, 60)
    if title:gsub('%s', '') == '' then resolve({ error = 'title' }) return end
    local blurb = clean(data.blurb, 400)

    local cover = clean(data.cover, 300)
    local avatar = clean(data.avatar, 300)
    if not imageAllowed(cover) or not imageAllowed(avatar) then
        resolve({ error = CFG.inGameOnly == true and 'ingame' or 'badhost' }) return
    end

    local goal = math.max(0, math.floor(num(data.goal, 0)))
    if goalMax() > 0 and goal > goalMax() then goal = goalMax() end

    local existing = pageOf(cid)

    -- The address is unique, and somebody else may have taken it between the check while
    -- typing and the save. Answered here rather than trusting the earlier answer.
    local owner = MySQL.scalar.await(
        'SELECT citizenid FROM vphone_fund_pages WHERE slug = ? LIMIT 1', { slug })
    if owner and owner ~= cid then resolve({ error = 'taken' }) return end

    local tiers = encodeTiers(data.tiers)
    local anon = anonOn() and (data.anon ~= false) or false
    local msgs = messagesOn() and (data.msgs ~= false) or false
    local category = knownCategory(data.category)

    if existing then
        MySQL.query.await([[UPDATE vphone_fund_pages
            SET slug = ?, title = ?, blurb = ?, cover = ?, avatar = ?, category = ?,
                goal = ?, tiers = ?, anon = ?, msgs = ?
            WHERE citizenid = ?]],
            { slug, title, blurb, cover, avatar, category, goal, tiers,
              anon and 1 or 0, msgs and 1 or 0, cid })
    else
        MySQL.insert.await([[INSERT INTO vphone_fund_pages
            (citizenid, slug, title, blurb, cover, avatar, category, goal, tiers, anon, msgs)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)]],
            { cid, slug, title, blurb, cover, avatar, category, goal, tiers,
              anon and 1 or 0, msgs and 1 or 0 })
    end

    resolve({ ok = true, page = cardOf(pageOf(cid), cid) })
end)

--- Open or shut the page. Shutting hides it from the list and refuses new gifts; it does not
--- touch the money already raised or the balance still to withdraw.
V.Callback('v-phone:fund:close', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local shut = (data and data.closed) == true
    local changed = MySQL.update.await(
        'UPDATE vphone_fund_pages SET closed = ? WHERE citizenid = ?',
        { shut and 1 or 0, p.citizenid }) or 0
    if changed <= 0 then resolve({ error = 'nopage' }) return end
    resolve({ ok = true, closed = shut })
end)

--- Take the page down.
---
--- Refused while there is money on it. Deleting a page with a balance would destroy money
--- somebody gave, and "withdraw first" is a sentence; a silent loss is not.
V.Callback('v-phone:fund:delete', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local row = pageOf(cid)
    if not row then resolve({ error = 'nopage' }) return end
    if math.floor(num(row.balance, 0)) > 0 then resolve({ error = 'hasbalance' }) return end

    -- The gifts go with it: they are rows about a page, and one pointing at nothing is what
    -- the retention sweep would have to clean up later anyway.
    MySQL.query.await('DELETE FROM vphone_fund_gifts WHERE page_id = ?', { row.id })
    MySQL.query.await('DELETE FROM vphone_fund_pages WHERE citizenid = ?', { cid })
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Giving
-- ══════════════════════════════════════════════════════════════

-- A second click within a few seconds is not a second gift.
--
-- Buying a picture is protected by a primary key: the same person cannot buy the same thing
-- twice, so a double tap is harmless by construction. Nothing about a GIFT is unique - giving
-- the same page 50 twice is a thing people really do - so there is no key to lean on and the
-- button being disabled on the page is not a guarantee, because the page is a browser.
local lastGift = {}

local function tooSoon(cid)
    local now = os.time()
    local prev = lastGift[cid]
    if prev and now - prev < math.max(0, math.floor(num(CFG.giftCooldown, 3))) then return true end
    lastGift[cid] = now
    return false
end

V.Callback('v-phone:fund:give', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid
    data = data or {}

    local row = pageBySlug(cleanSlug(data.slug))
    if not row then resolve({ error = 'gone' }) return end
    if num(row.closed, 0) == 1 then resolve({ error = 'closed' }) return end
    if row.citizenid == cid then resolve({ error = 'self' }) return end

    -- The amount comes from the giver, which is what giving means - and is exactly why it is
    -- bounded here and nowhere else. The page's tiers are not consulted: a tier is a
    -- suggestion, and reading one as a price would let a page name any number it liked.
    local amount = giftAmount(data.amount)
    if not amount then resolve({ error = 'amount', min = minGift(), max = maxGift() }) return end

    local body = messagesOn() and num(row.msgs, 1) == 1 and clean(data.body, 200) or ''
    local anon = anonOn() and num(row.anon, 1) == 1 and (data.anon == true)

    if tooSoon(cid) then resolve({ error = 'toosoon' }) return end

    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not Bridge.RemoveMoney(acting, amount, 'bank', 'v-phone: Fruitee') then
        resolve({ error = 'nomoney' }) return
    end

    local taken = applyTaxes(amount)
    local net = math.max(0, amount - taken)

    -- `raised` counts the GROSS. Somebody who gives 100 has given 100 towards the target
    -- whatever the server takes off it, and a bar that counted the net would make every goal
    -- on the server quietly unreachable.
    MySQL.update.await([[UPDATE vphone_fund_pages
        SET raised = raised + ?, balance = balance + ?, gifts = gifts + 1
        WHERE id = ?]], { amount, net, row.id })
    MySQL.insert.await([[INSERT INTO vphone_fund_gifts
        (page_id, donor, amount, net, body, anon) VALUES (?,?,?,?,?,?)]],
        { row.id, cid, amount, net, body, anon and 1 or 0 })
    MySQL.insert('INSERT INTO vphone_fund_tx (citizenid, kind, amount) VALUES (?,?,?)',
        { row.citizenid, 'gift', net })

    pcall(function()
        exports[GetCurrentResourceName()]:NotifyCitizen(row.citizenid, 'fruitee',
            LP(src, 'ph.fund_notif_gift'), tostring(amount))
    end)

    local fresh = pageBySlug(row.slug)
    resolve({ ok = true, amount = amount, page = cardOf(fresh, cid),
              supporters = giftsFor(row.id, 20) })
end)

-- ══════════════════════════════════════════════════════════════
-- Getting the money out
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:fund:payout', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local balance = math.floor(num(MySQL.scalar.await(
        'SELECT balance FROM vphone_fund_pages WHERE citizenid = ?', { cid }), 0))
    if balance <= 0 then resolve({ error = 'empty' }) return end
    if balance < payoutMin() then
        resolve({ error = 'payoutmin', min = payoutMin() }) return
    end

    -- Taken first, and conditionally, so two payouts racing cannot both succeed: the second
    -- UPDATE matches no row because the balance is already gone.
    local taken = MySQL.update.await(
        'UPDATE vphone_fund_pages SET balance = balance - ? WHERE citizenid = ? AND balance >= ?',
        { balance, cid, balance }) or 0
    if taken <= 0 then resolve({ error = 'empty' }) return end

    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not Bridge.AddMoney(acting, balance, 'bank', 'v-phone: Fruitee payout') then
        -- Put it back. Money that left the page and never reached the bank is the one outcome
        -- worth engineering against.
        MySQL.update.await('UPDATE vphone_fund_pages SET balance = balance + ? WHERE citizenid = ?',
            { balance, cid })
        resolve({ error = 'nobank' })
        return
    end

    MySQL.insert('INSERT INTO vphone_fund_tx (citizenid, kind, amount) VALUES (?,?,?)',
        { cid, 'payout', -balance })
    resolve({ ok = true, amount = balance })
end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════

--- What a page has raised, for a script that wants to react to one.
---
---     local page = exports['v-phone']:GetFundPage('townhall')
exports('GetFundPage', function(slug)
    local row = pageBySlug(cleanSlug(slug))
    if not row then return nil end
    return {
        slug = tostring(row.slug), title = tostring(row.title),
        goal = math.floor(num(row.goal, 0)), raised = math.floor(num(row.raised, 0)),
        gifts = math.floor(num(row.gifts, 0)), closed = num(row.closed, 0) == 1,
    }
end)

--- Put money onto a page from somewhere else - an event, a fundraiser desk, a script that
--- collects at a door. It is a gift with no giver, so nothing is debited here: the caller has
--- already taken the money, or there was none to take.
---
---     exports['v-phone']:AddFundGift('townhall', 500, 'Charity night')
exports('AddFundGift', function(slug, amount, label)
    if not enabled() then return false end
    local row = pageBySlug(cleanSlug(slug))
    if not row then return false end
    amount = math.floor(num(amount, 0))
    if amount <= 0 then return false end

    local net = math.max(0, amount - applyTaxes(amount))

    MySQL.update.await([[UPDATE vphone_fund_pages
        SET raised = raised + ?, balance = balance + ?, gifts = gifts + 1
        WHERE id = ?]], { amount, net, row.id })
    MySQL.insert('INSERT INTO vphone_fund_gifts (page_id, donor, amount, net, body, anon) '
        .. 'VALUES (?,?,?,?,?,1)', { row.id, '', amount, net, clean(label, 200) })
    return true
end)
