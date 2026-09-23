-- v-phone | server/marketplace.lua
-- VineMarket classifieds and private conversations. Item ownership stays in game.

local CFG = Config.Marketplace or {}
local kinds = { items = true, vehicles = true, furniture = true,
                apartments = true, houses = true, services = true }
local deals = { sale = true, rent = true }
local lastWrite = {}
local publishing = {}
local recentPosts = {}
local ready = false

local function clean(value, limit)
    local s = tostring(value or ''):gsub('<[^>]*>', ''):gsub('[\r\n\t]', ' ')
    return s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, limit)
end

local function idOf(value)
    local id = tonumber(value)
    return id and id > 0 and id <= 2147483647 and id == math.floor(id) and id or nil
end

local function authorize(src, resolve)
    if CFG.enabled == false or not ready then resolve({ error = 'off' }) return nil end
    if PhoneHasApp and not PhoneHasApp(src, 'marketplace') then
        resolve({ error = 'notinstalled' }) return nil
    end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'noplayer' }) return nil end
    return p
end

local function throttle(src, op, seconds)
    local key = tostring(src) .. ':' .. op
    local now = os.time()
    if (lastWrite[key] or 0) + seconds > now then return false end
    lastWrite[key] = now
    return true
end

local function postingTerms()
    local fee = CFG.postingFee == nil and 0 or tonumber(CFG.postingFee)
    if not fee or fee < 0 or fee > 100000000 or fee ~= math.floor(fee) then return nil end
    if fee == 0 then return { fee = 0, label = '' } end
    local account = tostring(CFG.revenueAccount or ''):match('^%s*(.-)%s*$')
    if account == '' or account:find('%s') then return nil end
    return { fee = fee, account = account, label = clean(CFG.revenueLabel, 64) }
end

local function refund(src, amount, reason)
    local ok, done = pcall(Bridge.AddMoney or function() return false end,
        src, amount, 'bank', reason)
    if ok and done == true then return true end
    print('[v-phone] VineMarket posting refund failed; check the bank transaction log')
    return false
end

local function dropPending(id)
    pcall(MySQL.update.await,
        "DELETE FROM vphone_market_listings WHERE id = ? AND status = 'pending'", { id })
end

CreateThread(function()
    if CFG.enabled == false then return end
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_market_listings` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `seller_cid` VARCHAR(64) NOT NULL,
        `seller_name` VARCHAR(64) NOT NULL,
        `kind` VARCHAR(16) NOT NULL,
        `deal` VARCHAR(8) NOT NULL,
        `title` VARCHAR(80) NOT NULL,
        `description` VARCHAR(1000) NOT NULL,
        `price` INT UNSIGNED NOT NULL,
        `period` VARCHAR(8) NOT NULL DEFAULT 'once',
        `area` VARCHAR(64) NOT NULL DEFAULT '',
        `image` VARCHAR(400) NOT NULL DEFAULT '',
        `show_phone` TINYINT(1) NOT NULL DEFAULT 0,
        `status` VARCHAR(8) NOT NULL DEFAULT 'active',
        `created_at` INT UNSIGNED NOT NULL,
        `expires_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        KEY `feed` (`status`, `id`),
        KEY `kind_feed` (`kind`, `status`, `id`),
        KEY `seller` (`seller_cid`, `status`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_market_threads` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `listing_id` INT UNSIGNED NOT NULL,
        `buyer_cid` VARCHAR(64) NOT NULL,
        `seller_cid` VARCHAR(64) NOT NULL,
        `created_at` INT UNSIGNED NOT NULL,
        `updated_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        UNIQUE KEY `buyer_listing` (`listing_id`, `buyer_cid`),
        KEY `seller_recent` (`seller_cid`, `updated_at`),
        KEY `buyer_recent` (`buyer_cid`, `updated_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_market_messages` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `thread_id` INT UNSIGNED NOT NULL,
        `sender_cid` VARCHAR(64) NOT NULL,
        `body` VARCHAR(400) NOT NULL,
        `created_at` INT UNSIGNED NOT NULL,
        `read_at` INT UNSIGNED NOT NULL DEFAULT 0,
        PRIMARY KEY (`id`),
        KEY `thread_recent` (`thread_id`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    ready = true
end)

local function listing(id)
    return MySQL.single.await([[SELECT id, seller_cid, seller_name, kind, deal, title,
        description, price, period, area, image, show_phone, status, created_at, expires_at
        FROM vphone_market_listings WHERE id = ?]], { id })
end

local function card(row, cid, detail)
    local active = row.status == 'active' and tonumber(row.expires_at) > os.time()
    local out = { id = row.id, seller = row.seller_name, kind = row.kind,
        deal = row.deal, title = row.title, price = row.price, period = row.period,
        area = row.area, image = row.image, status = active and 'active' or 'closed',
        createdAt = row.created_at, mine = row.seller_cid == cid }
    if detail then
        out.description = row.description
        out.showPhone = tonumber(row.show_phone) == 1
        if out.showPhone and active then
            out.phone = exports['v-phone']:GetNumber(row.seller_cid)
        end
    end
    return out
end

local function threadFor(id, cid)
    local row = MySQL.single.await([[SELECT t.id, t.listing_id, t.buyer_cid, t.seller_cid,
        l.title, l.status, l.expires_at FROM vphone_market_threads t
        JOIN vphone_market_listings l ON l.id = t.listing_id
        WHERE t.id = ? AND (t.buyer_cid = ? OR t.seller_cid = ?)]], { id, cid, cid })
    if row and tonumber(row.expires_at) <= os.time() then row.status = 'closed' end
    return row
end

V.Callback('v-phone:marketplace', function(src, resolve, data)
    local p = authorize(src, resolve)
    if not p then return end
    data = type(data) == 'table' and data or {}
    local op = tostring(data.op or '')
    local cid = p.citizenid

    if op == 'pricing' then
        local terms = postingTerms()
        resolve(terms and { ok = true, fee = terms.fee, label = terms.label }
            or { error = 'payment' })
    elseif op == 'feed' then
        local kind = kinds[data.kind] and data.kind or nil
        local deal = deals[data.deal] and data.deal or nil
        local query = clean(data.query, 48)
        local before = idOf(data.before) or 2147483647
        local where = { "status = 'active'", 'expires_at > ?', 'id < ?' }
        local args = { os.time(), before }
        if kind then where[#where + 1] = 'kind = ?'; args[#args + 1] = kind end
        if deal then where[#where + 1] = 'deal = ?'; args[#args + 1] = deal end
        if query ~= '' then
            where[#where + 1] = '(LOCATE(?, title) > 0 OR LOCATE(?, description) > 0)'
            args[#args + 1] = query; args[#args + 1] = query
        end
        local size = math.max(5, math.min(30, tonumber(CFG.pageSize) or 18))
        args[#args + 1] = size
        local rows = MySQL.query.await('SELECT * FROM vphone_market_listings WHERE '
            .. table.concat(where, ' AND ') .. ' ORDER BY id DESC LIMIT ?', args) or {}
        local out = {}
        for _, row in ipairs(rows) do out[#out + 1] = card(row, cid, false) end
        resolve({ ok = true, listings = out, next = #rows == size and rows[#rows].id or nil })
    elseif op == 'mine' then
        local rows = MySQL.query.await([[SELECT * FROM vphone_market_listings
            WHERE seller_cid = ? AND status <> 'pending' ORDER BY id DESC LIMIT 40]], { cid }) or {}
        local out = {}
        for _, row in ipairs(rows) do out[#out + 1] = card(row, cid, false) end
        resolve({ ok = true, listings = out })
    elseif op == 'detail' then
        local row = idOf(data.id) and listing(idOf(data.id))
        if not row or ((row.status ~= 'active' or tonumber(row.expires_at) <= os.time())
            and row.seller_cid ~= cid) then
            resolve({ error = 'missing' }) return
        end
        resolve({ ok = true, listing = card(row, cid, true) })
    elseif op == 'create' then
        local token = tostring(data.requestId or '')
        if #token > 64 or (token ~= '' and (#token < 8 or not token:match('^[%w%-]+$'))) then
            resolve({ error = 'invalid' }) return
        end
        local previous = recentPosts[cid]
        if token ~= '' and previous and previous.token == token
            and previous.at + 600 > os.time() then
            resolve({ ok = true, id = previous.id }) return
        end
        if not throttle(src, op, 5) then resolve({ error = 'rate' }) return end
        if publishing[cid] then resolve({ error = 'rate' }) return end
        local kind, deal = tostring(data.kind or ''), tostring(data.deal or '')
        local title, description = clean(data.title, 80), clean(data.description, 1000)
        local price = tonumber(data.price)
        local period = deal == 'rent' and tostring(data.period or '') or 'once'
        if not kinds[kind] or not deals[deal] or title == '' or description == ''
            or not price or price < 0 or price > (tonumber(CFG.maxPrice) or 100000000)
            or price ~= math.floor(price)
            or (period ~= 'once' and period ~= 'day' and period ~= 'week' and period ~= 'month')
            or (deal == 'rent' and period == 'once') then
            resolve({ error = 'invalid' }) return
        end
        local count = tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM vphone_market_listings
            WHERE seller_cid = ? AND status = 'active' AND expires_at > ?]], { cid, os.time() })) or 0
        if count >= (tonumber(CFG.maxActive) or 8) then resolve({ error = 'limit' }) return end
        local image = tostring(data.image or '')
        if image ~= '' and (#image > 400 or not PhoneLinkAllowed(image)) then
            resolve({ error = 'image' }) return
        end
        local terms = postingTerms()
        if not terms then resolve({ error = 'payment' }) return end
        publishing[cid] = true
        local now = os.time()
        local inserted, id = pcall(MySQL.insert.await, [[INSERT INTO vphone_market_listings
            (seller_cid, seller_name, kind, deal, title, description, price, period, area,
             image, show_phone, status, created_at, expires_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?, 'pending',?,?)]],
            { cid, clean(p.name, 64), kind, deal, title, description, price, period,
              clean(data.area, 64), image, data.showPhone == true and 1 or 0,
              now, now + math.max(1, math.min(60, tonumber(CFG.daysLive) or 30)) * 86400 })
        id = inserted and idOf(id) or nil
        if not id then
            publishing[cid] = nil
            resolve({ error = 'payment' }) return
        end
        local acting = PhoneActingSource and PhoneActingSource(src) or src
        local reason = ('VineMarket posting fee #%d'):format(id)
        if terms.fee > 0 then
            local debited, paid = pcall(Bridge.RemoveMoney or function() return false end,
                acting, terms.fee, 'bank', reason)
            if not debited then
                print(('[v-phone] VineMarket debit outcome unknown for listing #%d'):format(id))
                publishing[cid] = nil
                resolve({ error = 'payment' }) return
            end
            if paid ~= true then
                dropPending(id)
                publishing[cid] = nil
                resolve({ error = 'nomoney' }) return
            end
            local credited, landed = pcall(Bridge.AddSociety or function() return false end,
                terms.account, terms.fee, reason)
            if not credited then
                print(('[v-phone] VineMarket credit outcome unknown for listing #%d'):format(id))
                publishing[cid] = nil
                resolve({ error = 'payment' }) return
            end
            if landed ~= true then
                local returned = refund(acting, terms.fee, reason .. ' reversed')
                if returned then dropPending(id) end
                publishing[cid] = nil
                resolve({ error = returned and 'noaccount' or 'refund' }) return
            end
        end
        local published, changed = pcall(MySQL.update.await,
            [[UPDATE vphone_market_listings SET status = 'active'
            WHERE id = ? AND status = 'pending']], { id })
        if not published or changed ~= 1 then
            if terms.fee > 0 then
                local reversed, returned = pcall(Bridge.RemoveSociety or function() return false end,
                    terms.account, terms.fee, reason .. ' reversed')
                if reversed and returned == true then
                    if refund(acting, terms.fee, reason .. ' reversed') then dropPending(id) end
                else
                    print('[v-phone] VineMarket posting reversal failed; check the society transaction log')
                end
            else
                dropPending(id)
            end
            publishing[cid] = nil
            resolve({ error = 'payment' }) return
        end
        publishing[cid] = nil
        if token ~= '' then recentPosts[cid] = { token = token, id = id, at = os.time() } end
        resolve({ ok = true, id = id })
    elseif op == 'close' then
        local id = idOf(data.id)
        if not id then resolve({ error = 'invalid' }) return end
        local changed = MySQL.update.await([[UPDATE vphone_market_listings SET status = 'closed'
            WHERE id = ? AND seller_cid = ? AND status = 'active']], { id, cid }) or 0
        resolve({ ok = changed > 0, error = changed == 0 and 'missing' or nil })
    elseif op == 'contact' then
        if not throttle(src, op, 3) then resolve({ error = 'rate' }) return end
        local id = idOf(data.id)
        local row = id and listing(id)
        if not row or row.status ~= 'active' or tonumber(row.expires_at) <= os.time() then
            resolve({ error = 'missing' }) return
        end
        if row.seller_cid == cid then resolve({ error = 'self' }) return end
        MySQL.query.await([[INSERT IGNORE INTO vphone_market_threads
            (listing_id, buyer_cid, seller_cid, created_at, updated_at)
            VALUES (?,?,?,?,?)]], { id, cid, row.seller_cid, os.time(), os.time() })
        local thread = MySQL.scalar.await([[SELECT id FROM vphone_market_threads
            WHERE listing_id = ? AND buyer_cid = ?]], { id, cid })
        resolve({ ok = thread ~= nil, thread = thread })
    elseif op == 'call' then
        if not throttle(src, op, 3) then resolve({ error = 'rate' }) return end
        local id = idOf(data.id)
        local row = id and listing(id)
        if not row or row.status ~= 'active' or tonumber(row.expires_at) <= os.time() then
            resolve({ error = 'missing' }) return
        end
        if row.seller_cid == cid then resolve({ error = 'self' }) return end
        local number = exports['v-phone']:GetNumber(row.seller_cid)
        if not number then resolve({ error = 'missing' }) return end
        local ok, answer = PhoneStartPrivateCall(src, number)
        resolve(ok and { ok = true, id = answer } or { error = answer or 'offline' })
    elseif op == 'inbox' then
        local rows = MySQL.query.await([[SELECT t.id, t.listing_id, t.buyer_cid,
            t.seller_cid, t.updated_at, l.title,
            (SELECT body FROM vphone_market_messages m WHERE m.thread_id = t.id
                ORDER BY id DESC LIMIT 1) AS last_body,
            (SELECT COUNT(*) FROM vphone_market_messages m WHERE m.thread_id = t.id
                AND m.sender_cid <> ? AND m.read_at = 0) AS unread
            FROM vphone_market_threads t JOIN vphone_market_listings l ON l.id = t.listing_id
            WHERE t.buyer_cid = ? OR t.seller_cid = ?
            ORDER BY t.updated_at DESC LIMIT 40]], { cid, cid, cid }) or {}
        local out = {}
        for _, row in ipairs(rows) do
            out[#out + 1] = { id = row.id, listingId = row.listing_id, title = row.title,
                last = row.last_body or '', unread = row.unread,
                role = row.seller_cid == cid and 'seller' or 'buyer' }
        end
        resolve({ ok = true, threads = out })
    elseif op == 'thread' then
        local row = idOf(data.id) and threadFor(idOf(data.id), cid)
        if not row then resolve({ error = 'missing' }) return end
        local messages = MySQL.query.await([[SELECT id, sender_cid, body, created_at
            FROM vphone_market_messages WHERE thread_id = ? ORDER BY id DESC LIMIT 60]],
            { row.id }) or {}
        local out = {}
        for i = #messages, 1, -1 do
            local m = messages[i]
            out[#out + 1] = { id = m.id, mine = m.sender_cid == cid,
                body = m.body, at = m.created_at }
        end
        MySQL.update.await([[UPDATE vphone_market_messages SET read_at = ?
            WHERE thread_id = ? AND sender_cid <> ? AND read_at = 0]],
            { os.time(), row.id, cid })
        resolve({ ok = true, thread = { id = row.id, title = row.title,
            listingId = row.listing_id, status = row.status }, messages = out })
    elseif op == 'send' then
        if not throttle(src, op, 2) then resolve({ error = 'rate' }) return end
        local row = idOf(data.id) and threadFor(idOf(data.id), cid)
        local message = clean(data.body, 400)
        if not row then resolve({ error = 'missing' }) return end
        if row.status ~= 'active' then resolve({ error = 'closed' }) return end
        if message == '' then resolve({ error = 'invalid' }) return end
        local now = os.time()
        local id = MySQL.insert.await([[INSERT INTO vphone_market_messages
            (thread_id, sender_cid, body, created_at) VALUES (?,?,?,?)]],
            { row.id, cid, message, now })
        MySQL.update.await('UPDATE vphone_market_threads SET updated_at = ? WHERE id = ?',
            { now, row.id })
        if id then
            local targetCid = row.seller_cid == cid and row.buyer_cid or row.seller_cid
            local target = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(targetCid)
            if target and target.source and PhoneHasApp(target.source, 'marketplace') then
                exports['v-phone']:Notify(target.source, 'marketplace',
                    LP(target.source, 'app.marketplace'),
                    LP(target.source, 'ph.market_new_message'))
            end
        end
        resolve({ ok = id ~= nil, id = id })
    else
        resolve({ error = 'unknown' })
    end
end)
