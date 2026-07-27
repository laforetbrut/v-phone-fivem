-- v-phone | server/bank.lua
--
-- **The bank app: a statement, transfers, and saved beneficiaries.**
--
-- The balance is never the phone's. It is read through `Bridge.Banking` from whatever the
-- server already believes - qb-core, qbx, ESX, ox, or a banking script on top of one - so
-- the number on the phone is the number at the ATM. Upstream this app was a view over a
-- companion `v-banking` resource; that resource does not exist outside the author's own
-- suite, which is why the app answered "not available on this server" on every qb, ESX and
-- ox install. It now reads the bridge, and `v-banking` is preferred only when it is
-- genuinely running.
--
-- What the phone DOES own is the part no framework has: its own statement lines, transfers
-- between characters, and a beneficiary list. Those live in the phone's tables.
--
-- Money is the one thing here that cannot be approximately right, so a transfer is
-- deliberately paranoid:
--
--   * the amount is floored to whole currency and bounded by config, on the server, after
--     the client has been ignored;
--   * the recipient is resolved from a phone number to a citizen id HERE - the client
--     sends a number, never an id and never a name;
--   * the debit goes through `Bridge.RemoveMoney`, which **fails closed**: a debit that
--     cannot be confirmed stops the transfer instead of crediting from nothing;
--   * a credit that fails is **refunded**, and a refund that also fails is escrowed back
--     to the sender rather than silently destroyed;
--   * paying somebody offline holds the money in escrow, so it has left exactly one
--     account and is owed to exactly one other at every point in between.

local BANK = Config.Bank or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return BANK.enabled ~= false end
local function transfersOn() return enabled() and BANK.transfers ~= false end

local function minAmount() return math.max(1, math.floor(num(BANK.minAmount, 1))) end
local function maxAmount() return math.max(0, math.floor(num(BANK.maxAmount, 0))) end
local function feePercent()
    local pct = num(BANK.feePercent, 0)
    if pct < 0 then return 0 end
    return math.min(100, pct)
end
local function dailyLimit() return math.max(0, math.floor(num(BANK.dailyLimit, 0))) end
local function maxFavourites() return math.max(0, math.floor(num(BANK.maxFavourites, 25))) end
local function historyLimit()
    return math.max(1, math.min(200, math.floor(num(BANK.historyLimit, 50))))
end

--- What the bank takes on top of the amount. Floored, so the house never rounds up.
local function feeFor(amount)
    local pct = feePercent()
    if pct <= 0 then return 0 end
    return math.floor(amount * pct / 100)
end

-- ══════════════════════════════════════════════════════════════
-- The phone's own ledger
-- ══════════════════════════════════════════════════════════════
--- One statement line. `amount` is signed: negative left the account.
local function record(citizenid, amount, label, kind, counterparty)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return end
    MySQL.insert('INSERT INTO vphone_bank_tx (citizenid, amount, label, kind, counterparty) VALUES (?,?,?,?,?)', {
        citizenid,
        math.floor(num(amount, 0)),
        tostring(label or ''):sub(1, 60),
        tostring(kind or 'transfer'):sub(1, 12),
        tostring(counterparty or ''):sub(1, 64),
    })
end

--- The phone's lines, newest first, already shaped the way the app draws them.
local function ownHistory(citizenid)
    local rows = MySQL.query.await([[SELECT amount, label, kind, counterparty,
            UNIX_TIMESTAMP(at) AS ts
        FROM vphone_bank_tx WHERE citizenid = ? ORDER BY id DESC LIMIT ?]],
        { citizenid, historyLimit() }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            amount = math.floor(num(r.amount, 0)),
            label = tostring(r.label or ''),
            kind = tostring(r.kind or ''),
            with = tostring(r.counterparty or ''),
            ts = math.floor(num(r.ts, 0)),
        }
    end
    return out
end

--- The framework's or banking script's own history, when it keeps one, normalised into the
--- same shape. Two sources rather than one because neither is complete: the phone knows
--- about phone transfers and nothing else, the banking script knows about everything else.
local function frameworkHistory(src, citizenid)
    -- Ask for as many as the app will show, so a 50-line history is not quietly trimmed to
    -- the 25 the reader used to hardcode.
    -- `citizenid` is already the held character's during a staff session; the source is routed
    -- too so a server's own `hooks.transactions` sees one consistent identity rather than the
    -- staff member's id paired with somebody else's citizen id.
    local rows = Bridge.Banking and Bridge.Banking.Transactions
        and Bridge.Banking.Transactions(PhoneActingSource and PhoneActingSource(src) or src,
                                        citizenid, historyLimit())
    if type(rows) ~= 'table' then return {} end

    local out = {}
    for _, r in ipairs(rows) do
        if type(r) == 'table' then
            -- Every banking script names these differently, and an amount is sometimes a
            -- string. Whatever arrives is coerced here so the page never has to guess.
            local amount = math.floor(num(r.amount or r.value or 0, 0))
            local label = tostring(r.label or r.reason or r.message or r.type or '')
            local at = r.at or r.date or r.time
            -- **Seconds or milliseconds?** Both arrive here and they cannot be told apart by
            -- type: qb-banking and doc-banking both store `date` as `os.time() * 1000`, while a
            -- DATETIME column read through oxmysql is also a millisecond epoch, and a script
            -- that stores plain `os.time()` is in seconds. `ts` is a SECONDS field - the page
            -- multiplies it by 1000 - so a millisecond value passed through unchanged became a
            -- date tens of thousands of years out. That is what put "Jan 21" and "Nov 15" on one
            -- statement in the wrong order.
            --
            -- Anything past the year 5138 in seconds is a millisecond value: 1e11 seconds is
            -- year 5138, and 1e11 milliseconds is 1973. No real statement sits between them.
            local ts = type(at) == 'number' and math.floor(at) or nil
            if ts and ts > 100000000000 then ts = math.floor(ts / 1000) end
            out[#out + 1] = {
                amount = amount,
                label = label:sub(1, 60),
                kind = 'account',
                with = tostring(r.receiver or r.name or ''):sub(1, 64),
                at = type(at) == 'string' and at:sub(1, 30) or nil,
                ts = ts,
            }
        end
    end
    return out
end

--- Both sources, newest first. Lines with a real timestamp sort against each other; a
--- banking script that only hands back a preformatted date keeps its own order after them,
--- because inventing a sort key for it would put lines in the wrong place with confidence.
local function statement(src, citizenid)
    local mine = ownHistory(citizenid)
    local theirs = frameworkHistory(src, citizenid)

    local dated, undated = {}, {}
    for _, list in ipairs({ mine, theirs }) do
        for _, row in ipairs(list) do
            if row.ts and row.ts > 0 then dated[#dated + 1] = row else undated[#undated + 1] = row end
        end
    end
    table.sort(dated, function(a, b) return a.ts > b.ts end)

    local out = {}
    for _, row in ipairs(dated) do out[#out + 1] = row end
    for _, row in ipairs(undated) do out[#out + 1] = row end
    while #out > historyLimit() do table.remove(out) end
    return out
end

--- What this character has already sent today, from the phone's own lines. Read from the
--- ledger rather than a counter in memory, so a restart does not reset somebody's limit.
local function sentToday(citizenid)
    local total = MySQL.scalar.await([[SELECT COALESCE(SUM(-amount), 0) FROM vphone_bank_tx
        WHERE citizenid = ? AND kind = 'transfer' AND amount < 0 AND at >= (NOW() - INTERVAL 1 DAY)]],
        { citizenid })
    return math.floor(num(total, 0))
end

-- ══════════════════════════════════════════════════════════════
-- Escrow: paying somebody who is not connected
-- ══════════════════════════════════════════════════════════════
-- The sender is debited immediately, so the money must be somewhere. It is here, owed to
-- one citizen id, until they next open their bank.
local function escrow(citizenid, amount, label, counterparty)
    MySQL.insert([[INSERT INTO vphone_bank_pending (citizenid, amount, label, counterparty)
        VALUES (?,?,?,?)]], {
        tostring(citizenid or ''), math.floor(num(amount, 0)),
        tostring(label or ''):sub(1, 60), tostring(counterparty or ''):sub(1, 64),
    })
end

--- Pay out everything owed to this character, exactly once each.
---
--- The row is CLAIMED by deleting it and checking that this call is the one that deleted
--- it, and only then is the money credited. Claim-then-credit can lose a payment if the
--- process dies in the gap, which is why a failed credit puts the row straight back;
--- credit-then-delete would pay twice on a retry, and inventing money is the worse of the
--- two failures.
local function payPending(src, citizenid)
    -- Whose purse this is. `src` is the connection that asked; during a staff phone-view
    -- session the money belongs to the character being held, not to the staff member.
    -- See PhoneActingSource in server/adminview.lua.
    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not citizenid or citizenid == '' then return 0 end
    local rows = MySQL.query.await([[SELECT id, amount, label, counterparty
        FROM vphone_bank_pending WHERE citizenid = ? LIMIT 25]], { citizenid }) or {}
    if #rows == 0 then return 0 end

    local paid = 0
    for _, r in ipairs(rows) do
        local claimed = MySQL.update.await('DELETE FROM vphone_bank_pending WHERE id = ?', { r.id })
        if num(claimed, 0) >= 1 then
            local amount = math.floor(num(r.amount, 0))
            local label = tostring(r.label or '')
            local who = tostring(r.counterparty or '')
            if amount > 0 and Bridge.AddMoney(acting, amount, 'bank', 'v-phone: transfer') then
                record(citizenid, amount, label, 'transfer', who)
                paid = paid + amount
            else
                -- Put it back rather than keep it: it is still owed.
                escrow(citizenid, amount, label, who)
            end
        end
    end

    if paid > 0 then
        V.Notify(src, LP(src, 'ph.bank_pending_paid', paid), 'success')
    end
    return paid
end

-- ══════════════════════════════════════════════════════════════
-- Beneficiaries
-- ══════════════════════════════════════════════════════════════
-- A saved name and number, per character, in the same per-character store every other
-- phone preference uses. Numbers only: a beneficiary is a phone number the sender typed
-- once, and it is re-resolved to a citizen id on every send, so a saved entry cannot
-- become a way to pay somebody the sender never chose.
local function favourites(citizenid)
    local list = Bridge.KvGet(citizenid, 'bank_favs')
    if type(list) ~= 'table' then return {} end

    local out = {}
    for _, row in ipairs(list) do
        if type(row) == 'table' and row.number then
            out[#out + 1] = {
                name = tostring(row.name or ''):sub(1, 40),
                number = tostring(row.number):sub(1, 20),
            }
        end
    end
    return out
end

local function saveFavourites(citizenid, list)
    while #list > maxFavourites() do table.remove(list) end
    Bridge.KvSet(citizenid, 'bank_favs', list)
end

-- ══════════════════════════════════════════════════════════════
-- Reads
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:bank:data', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    -- Its own code, not the catch-all: "the framework does not know who you are" and "a
    -- query blew up" are different problems and used to produce the same four words.
    if not p then resolve({ error = 'nochar' }) return end

    -- Anything owed to this character is settled before the balance is read, so the number
    -- they see already includes what somebody sent them while they were away.
    --
    -- Isolated on purpose. Escrow is a side errand; if it fails, the balance and the
    -- statement are still perfectly readable, and blanking the whole app over a payment
    -- nobody is waiting for is the wrong trade. The error is printed rather than swallowed.
    local paidOk, paidErr = pcall(payPending, src, p.citizenid)
    if not paidOk then
        print(('[v-phone] bank: pending transfers could not be settled: %s'):format(paidErr))
    end

    -- The balance of whoever the phone is acting as. Reading it for `src` is what showed a
    -- staff member their OWN account while the screen carried somebody else's name.
    local acting = PhoneActingSource and PhoneActingSource(src) or src
    local gotBalance, balances = pcall(function()
        return Bridge.Banking and Bridge.Banking.Balances and Bridge.Banking.Balances(acting)
    end)
    if not gotBalance then
        print(('[v-phone] bank: the balance could not be read: %s'):format(balances))
        resolve({ error = 'nobank' })
        return
    end
    if type(balances) ~= 'table' then
        -- Standalone, or a framework the bridge could not read. Say so rather than
        -- showing a confident zero.
        resolve({ error = 'nobank' })
        return
    end

    -- The statement is the part that touches the phone's own tables, so it is the part most
    -- likely to be upset by a schema that is a version behind. An unreadable statement
    -- leaves the balance on screen instead of taking the app down with it.
    local gotRows, tx = pcall(statement, src, p.citizenid)
    if not gotRows then
        print(('[v-phone] bank: the statement could not be read: %s'):format(tx))
        tx = {}
    end

    -- The remaining two reads touch the phone's own storage as well, so they get the same
    -- treatment: a usable screen beats a blank one over a beneficiary list.
    local limit = dailyLimit()
    local spentToday = 0
    if limit > 0 then
        local ok, used = pcall(sentToday, p.citizenid)
        if ok then spentToday = num(used, 0)
        else print(('[v-phone] bank: the daily total could not be read: %s'):format(used)) end
    end
    local gotFavs, favs = pcall(favourites, p.citizenid)
    if not gotFavs then
        print(('[v-phone] bank: beneficiaries could not be read: %s'):format(favs))
        favs = {}
    end

    resolve({
        ok = true,
        bank = math.floor(num(balances.bank, 0)),
        cash = math.floor(num(balances.cash, 0)),
        number = Bridge.Numbers.Get(p.citizenid) or '',
        name = p.name or '',
        transfers = transfersOn(),
        fee = feePercent(),
        min = minAmount(),
        max = maxAmount(),
        -- What is left of today's allowance, or nil when there is no limit at all: the app
        -- draws the line only when there is one.
        remaining = limit > 0 and math.max(0, limit - spentToday) or nil,
        favourites = favs,
        -- Already read, and already survived its own failure above. Calling `statement` a
        -- second time here would both double the queries and undo that.
        transactions = tx,
    })
end)

-- ══════════════════════════════════════════════════════════════
-- The card
-- ══════════════════════════════════════════════════════════════
-- The Wallet app draws a bank card. Upstream that card was minted by `v-banking`, and the
-- page asked `v-banking:card` - a callback nobody on a qb-core, ESX or ox server answers, so
-- the card was simply never there.
--
-- A card is three facts: a number, a holder, and a balance. The balance is the framework's,
-- the holder is the character's own name, and the number is the only thing that had to be
-- invented - so the phone mints one and keeps it, exactly the way it already does with phone
-- numbers. It is stable for the life of the character and means nothing to anything outside
-- the phone: it is a display, not an account.
local function cardNumber(citizenid)
    local existing = Bridge.KvGet(citizenid, 'card')
    if type(existing) == 'string' and existing ~= '' then return existing end

    -- Four groups of four. Deliberately not derived from the citizen id: a card number that
    -- can be reversed into an identifier is worse than a random one.
    local parts = {}
    for i = 1, 4 do parts[i] = ('%04d'):format(math.random(0, 9999)) end
    local number = table.concat(parts, ' ')
    Bridge.KvSet(citizenid, 'card', number)
    return number
end

V.Callback('v-phone:card', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'nochar' }) return end

    local acting = PhoneActingSource and PhoneActingSource(src) or src
    local balances = Bridge.Banking and Bridge.Banking.Balances and Bridge.Banking.Balances(acting)
    local holder = p.name or ''
    -- The name on a card is the character's, and a framework that will not say who they are
    -- leaves it blank rather than guessing.
    local ok, id = pcall(function()
        return Bridge.Identity and Bridge.Identity(p.citizenid, src)
    end)
    if ok and type(id) == 'table' and id.first then
        holder = ((tostring(id.first) .. ' ' .. tostring(id.last or '')):gsub('%s+$', ''))
    end

    resolve({
        ok = true,
        card = cardNumber(p.citizenid),
        holder = holder:upper():sub(1, 30),
        bank = type(balances) == 'table' and math.floor(num(balances.bank, 0)) or nil,
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Transfers
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:bank:transfer', function(src, resolve, data)
    if not transfersOn() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'x' }) return end
    -- Whose money is being sent. During a staff phone-view session that is the character being
    -- held, not the staff member - `p` is already theirs, and this makes the PURSE match the
    -- name on the statement line. Without it a transfer sent from a held phone debited the
    -- staff member and credited the recipient, which is the worst kind of near-miss.
    local acting = PhoneActingSource and PhoneActingSource(src) or src

    -- Whole currency only, and the client's number is a suggestion.
    local amount = math.floor(num(data and data.amount, 0))
    if amount < minAmount() then resolve({ error = 'toosmall' }) return end
    if maxAmount() > 0 and amount > maxAmount() then resolve({ error = 'toobig' }) return end

    local limit = dailyLimit()
    if limit > 0 and sentToday(p.citizenid) + amount > limit then
        resolve({ error = 'daily' })
        return
    end

    -- A number, resolved here. The client never names a citizen id.
    local number = tostring((data and data.number) or ''):gsub('%s', '')
    if number == '' then resolve({ error = 'needsnumber' }) return end
    local targetCid = Bridge.Numbers.Owner(number)
    if not targetCid then resolve({ error = 'unknownnumber' }) return end
    if targetCid == p.citizenid then resolve({ error = 'self' }) return end

    local note = tostring((data and data.note) or ''):sub(1, 40)
    local target = Core.GetPlayerByCitizenId(targetCid)
    if not target and BANK.offlineTransfers == false then
        resolve({ error = 'offline' })
        return
    end

    local fee = feeFor(amount)
    local total = amount + fee
    local myName = tostring(p.name or ''):sub(1, 40)
    local theirName = Bridge.NameOfCitizen(targetCid) or number

    -- The debit first, and it fails closed: nothing below runs unless the money actually
    -- left. `total`, so the fee is paid by the sender and the recipient gets the round
    -- number they were promised.
    if not Bridge.RemoveMoney(acting, total, 'bank') then
        resolve({ error = 'funds' })
        return
    end

    --- Put it back where it came from. Escrowed if even that fails, because the one
    --- outcome that is not acceptable is money that stopped existing.
    local function refund()
        if not Bridge.AddMoney(acting, total, 'bank', 'v-phone: transfer refunded') then
            escrow(p.citizenid, total, '', theirName)
        end
    end

    if target and target.source then
        if not Bridge.AddMoney(target.source, amount, 'bank',
            ('v-phone: from %s'):format(myName)) then
            refund()
            resolve({ error = 'credit' })
            return
        end
        -- The label is the sender's own note and nothing else. "From Alice" written here
        -- would freeze one language into a row that outlives the setting: the page composes
        -- the wording from `counterparty` and the sign instead.
        record(targetCid, amount, note, 'transfer', myName)

        -- And a line in the BANK's own statement, both ends.
        --
        -- Without it the two histories are halves of one story: a transfer made on the phone
        -- is missing from the ATM, and the player is left wondering which of the two screens
        -- is lying. The money has already moved by this point, so a statement that cannot be
        -- written is a cosmetic loss and is deliberately not checked.
        if Bridge.Banking and Bridge.Banking.WriteStatement then
            local label = note ~= '' and note or ('v-phone: %s'):format(theirName)
            Bridge.Banking.WriteStatement(acting, 'checking', total, label, 'withdraw', false)
            Bridge.Banking.WriteStatement(target.source, 'checking', amount,
                note ~= '' and note or ('v-phone: %s'):format(myName), 'deposit', false)
        end

        -- One notification, on the bank, the way a banking app does it. This used to be a
        -- framework toast AND a text message, which is two alerts for one payment.
        local body = ('+%d - %s'):format(amount, myName)
        if note ~= '' then body = body .. ' - ' .. note end
        pcall(function()
            exports[GetCurrentResourceName()]:Notify(
                target.source, 'bank', LP(target.source, 'ph.bank_notify_in'), body)
        end)
    else
        escrow(targetCid, amount, note, myName)

        -- Nobody to show a banner to, and a banner would be gone before they connected
        -- anyway. A text persists, so it is still there when they pick the phone up - which
        -- is the only way somebody paid while offline finds out without going looking.
        local body = LP(nil, 'ph.bank_received', amount, myName)
        if note ~= '' then body = body .. ' - ' .. note end
        pcall(function()
            exports[GetCurrentResourceName()]:SendServiceMessage(targetCid, 'iFruit Bank', body)
        end)
    end

    -- Two lines that add up to what left the account: the transfer, and the fee beside it.
    -- One combined line for `total` made the statement disagree with the amount the player
    -- typed, and a fee recorded as zero showed up as "Fee 15" worth nothing at all.
    record(p.citizenid, -amount, note, 'transfer', theirName)
    if fee > 0 then
        -- No label at all: `kind` says what it is, and the page prints the translation.
        record(p.citizenid, -fee, '', 'fee', theirName)
    end

    resolve({ ok = true, amount = amount, fee = fee, to = theirName,
              held = (target == nil) or nil })
end)

-- ══════════════════════════════════════════════════════════════
-- Beneficiary edits
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:bank:favourite', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'x' }) return end

    local op = tostring((data and data.op) or '')
    local list = favourites(p.citizenid)

    if op == 'add' then
        if maxFavourites() <= 0 then resolve({ error = 'off' }) return end
        local number = tostring((data and data.number) or ''):gsub('%s', ''):sub(1, 20)
        if number == '' then resolve({ error = 'needsnumber' }) return end
        -- A beneficiary has to be somebody. Saving an unreachable number would only fail
        -- later, at the point where the player has already typed an amount.
        local cid = Bridge.Numbers.Owner(number)
        if not cid then resolve({ error = 'unknownnumber' }) return end
        if cid == p.citizenid then resolve({ error = 'self' }) return end

        local name = tostring((data and data.name) or ''):sub(1, 40)
        if name == '' then name = Bridge.NameOfCitizen(cid) or number end

        for i, row in ipairs(list) do
            if row.number == number then
                list[i] = { name = name, number = number }   -- already saved: rename it
                saveFavourites(p.citizenid, list)
                resolve({ ok = true, favourites = list })
                return
            end
        end
        if #list >= maxFavourites() then resolve({ error = 'full' }) return end
        table.insert(list, { name = name, number = number })
        saveFavourites(p.citizenid, list)
        resolve({ ok = true, favourites = list })
        return
    end

    if op == 'del' then
        local number = tostring((data and data.number) or ''):gsub('%s', '')
        for i = #list, 1, -1 do
            if list[i].number == number then table.remove(list, i) end
        end
        saveFavourites(p.citizenid, list)
        resolve({ ok = true, favourites = list })
        return
    end

    resolve({ error = 'badop' })
end)

-- ══════════════════════════════════════════════════════════════
-- Money arriving: the notification
-- ══════════════════════════════════════════════════════════════
-- A banking app that says nothing when you are paid is not a banking app. Every framework
-- announces its own money changes, so this listens rather than polls - the event carries the
-- amount and, usefully, the REASON, which is how a paycheck can be labelled as one.
--
-- The event names are not guessed. qb-core and qbx_core both fire
-- `QBCore:Server:OnMoneyChange(src, type, amount, action, reason)`; qbx additionally fires
-- `qbx_core:server:onPaycheck(src, amount)`; ESX fires `esx:addAccountMoney`,
-- `esx:removeAccountMoney` and `esx:setAccountMoney` with `(src, account, amount, reason)`.
-- ox_core has no comparable server event, which is what `pollSeconds` is for.
local NOTIFY = BANK.notify or {}
local function notifyOn() return enabled() and NOTIFY.enabled ~= false end
local function notifyMin() return math.max(0, math.floor(num(NOTIFY.minAmount, 1))) end

--- Should a statement line be written for money the phone did not move itself?
---
--- 'auto' writes one only when NO dedicated banking script is running. With one present
--- that line already exists in its own history - which the statement merges - so writing a
--- second would show every salary twice.
local function shouldRecord()
    local mode = NOTIFY.record
    if mode == true then return true end
    if mode == false then return false end
    -- The question is not "is a banking script running" - it is "can its history be read".
    -- On qb-banking, okokBanking or esx_banking the answer is no, and treating those as
    -- somebody else's problem left the statement permanently empty.
    if Bridge.Banking and Bridge.Banking.HistoryReadable then
        return not Bridge.Banking.HistoryReadable()
    end
    return true
end

--- Tell a player money moved, and file it if this phone is the only thing keeping a record.
---
--- `reason` is the framework's own string. A reason beginning `v-phone` is the phone itself
--- moving money - a transfer, or a purchase in the store - and those already report back
--- through their own path, so announcing them here would say everything twice.
local function moneyMoved(src, amount, incoming, reason, kind)
    if not notifyOn() then return end
    src = tonumber(src)
    amount = math.floor(math.abs(num(amount, 0)))
    if not src or amount < notifyMin() or amount <= 0 then return end

    reason = tostring(reason or '')
    if reason:lower():find('^v%-phone') then return end
    if not incoming and NOTIFY.outgoing ~= true then return end

    local p = Core.GetPlayer(src)
    if not p then return end

    -- A banner on the phone, with the bank's own icon, through the same export any other
    -- resource would use.
    local title = LP(src, incoming and 'ph.bank_notify_in' or 'ph.bank_notify_out')
    local body = (incoming and '+' or '-') .. tostring(amount)
    if reason ~= '' then body = body .. ' - ' .. reason end
    pcall(function()
        exports[GetCurrentResourceName()]:Notify(src, 'bank', title, body)
    end)

    if shouldRecord() then
        record(p.citizenid, incoming and amount or -amount, reason, kind or 'account', '')
    end
end

--- Anyone else's money movement, announced on the phone. For a job script, a shop, a
--- society payout - anything that pays a player and wants them to know.
---
---     exports['v-phone']:NotifyMoney(src, 250, 'Overtime')
exports('NotifyMoney', function(src, amount, label)
    local value = math.floor(num(amount, 0))
    if value == 0 then return false end
    moneyMoved(src, value, value > 0, tostring(label or ''), 'account')
    return true
end)

-- qb-core and qbx_core. One handler for both: qbx kept the event name.
AddEventHandler('QBCore:Server:OnMoneyChange', function(src, moneyType, amount, action, reason)
    -- 'set' hands over the new BALANCE rather than a delta, so there is no movement to
    -- report from it without tracking the previous value; the add/remove pair covers every
    -- normal payment.
    if action ~= 'add' and action ~= 'remove' then return end
    local kind = tostring(reason or ''):lower():find('paycheck') and 'salary' or 'account'
    moneyMoved(src, amount, action == 'add', reason, kind)
end)

-- qbx names its paycheck explicitly, which is better than matching on a reason string.
AddEventHandler('qbx_core:server:onPaycheck', function(src, amount)
    -- Deliberately silent: the money-change handler above has already announced this from
    -- the AddMoney underneath it. This exists to LABEL it, so the statement line says
    -- salary rather than a bare deposit.
    if not shouldRecord() then return end
    local p = Core.GetPlayer(src)
    if not p then return end
    MySQL.update.await([[UPDATE vphone_bank_tx SET kind = 'salary'
        WHERE citizenid = ? AND amount = ? AND kind = 'account'
        ORDER BY id DESC LIMIT 1]], { p.citizenid, math.floor(num(amount, 0)) })
end)

-- ESX.
AddEventHandler('esx:addAccountMoney', function(src, account, amount, reason)
    if account ~= 'bank' and account ~= 'money' then return end
    moneyMoved(src, amount, true, reason, 'account')
end)
AddEventHandler('esx:removeAccountMoney', function(src, account, amount, reason)
    if account ~= 'bank' and account ~= 'money' then return end
    moneyMoved(src, amount, false, reason, 'account')
end)

-- ══════════════════════════════════════════════════════════════
-- The fallback for a framework with no money event
-- ══════════════════════════════════════════════════════════════
-- ox_core, and any bespoke setup, changes a balance without announcing it. Sampling is the
-- only way to notice, so it is opt-in and off by default: it costs one balance read per
-- online player per interval, and on qb, qbx or ESX the events above already do the job
-- instantly and with a reason attached.
local lastSeen = {}

AddEventHandler('playerDropped', function()
    lastSeen[source] = nil
end)

CreateThread(function()
    local every = math.floor(num(NOTIFY.pollSeconds, 0))
    if every <= 0 or not notifyOn() then return end
    every = math.max(15, every)
    V.Info(('[v-phone] bank: sampling balances every %ds for money notifications'):format(every))

    while true do
        Wait(every * 1000)
        for _, id in ipairs(GetPlayers()) do
            local src = tonumber(id)
            local balances = src and Bridge.Banking and Bridge.Banking.Balances
                and Bridge.Banking.Balances(PhoneActingSource and PhoneActingSource(src) or src)
            if type(balances) == 'table' then
                local now = math.floor(num(balances.bank, 0))
                local before = lastSeen[src]
                -- The first sample only establishes the baseline: announcing a difference
                -- from nothing would greet every player with their whole balance.
                if before and now ~= before then
                    moneyMoved(src, now - before, now > before, '', 'account')
                end
                lastSeen[src] = now
            end
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Boot
-- ══════════════════════════════════════════════════════════════
function Bridge.BankBoot()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_bank_tx` (
        `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid`    VARCHAR(64)  NOT NULL,
        `amount`       BIGINT       NOT NULL DEFAULT 0,
        `label`        VARCHAR(60)  NOT NULL DEFAULT '',
        `kind`         VARCHAR(12)  NOT NULL DEFAULT 'transfer',
        `counterparty` VARCHAR(64)  NOT NULL DEFAULT '',
        `at`           TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `owner_idx` (`citizenid`, `id`),
        KEY `spend_idx` (`citizenid`, `kind`, `at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- Escrow is deliberately its own table rather than a flag on a statement line: a line
    -- is history and must never change, an owed payment is state and gets deleted.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_bank_pending` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(64)  NOT NULL,
        `amount`    BIGINT       NOT NULL DEFAULT 0,
        `label`     VARCHAR(60)  NOT NULL DEFAULT '',
        `counterparty` VARCHAR(64) NOT NULL DEFAULT '',
        `at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `owed_idx` (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- `CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists, so a column
    -- added after the first release never appears and every read of it fails with "Unknown
    -- column". `counterparty` on the escrow table was added one commit after the table
    -- itself, which broke the whole app on any server that had already started once: the
    -- callback threw, and the app could only say "something went wrong".
    --
    -- Same idempotent shape the messages table already uses. Cheap on every later boot: one
    -- metadata lookup that finds the column and stops.
    local function ensureColumn(tbl, column, definition)
        local has = MySQL.scalar.await([[SELECT 1 FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
            LIMIT 1]], { tbl, column })
        if has then return false end
        MySQL.query.await(('ALTER TABLE `%s` ADD COLUMN `%s` %s'):format(tbl, column, definition))
        print(('[v-phone] bank: added %s.%s'):format(tbl, column))
        return true
    end
    ensureColumn('vphone_bank_pending', 'counterparty', "VARCHAR(64) NOT NULL DEFAULT ''")
    ensureColumn('vphone_bank_tx', 'counterparty', "VARCHAR(64) NOT NULL DEFAULT ''")
    ensureColumn('vphone_bank_tx', 'kind', "VARCHAR(12) NOT NULL DEFAULT 'transfer'")

    -- Statement lines expire; escrow never does. Money that is owed stays owed however
    -- long the character stays away.
    local days = math.floor(num(BANK.retentionDays, 0))
    if days > 0 then
        CreateThread(function()
            while true do
                MySQL.query.await(
                    'DELETE FROM vphone_bank_tx WHERE at < (NOW() - INTERVAL ? DAY)', { days })
                Wait(6 * 60 * 60 * 1000)
            end
        end)
    end

    -- One line at boot saying what the app will do, because "not available on this server"
    -- with no reason given is exactly the bug this file was written to fix.
    CreateThread(function()
        Wait(3000)
        if not enabled() then
            V.Info('[v-phone] bank: OFF (Config.Bank.enabled)')
            return
        end
        local reader = (GetResourceState('v-banking') == 'started') and 'v-banking'
            or ('the ' .. tostring(Bridge.framework or '?') .. ' bridge')
        local keeping = shouldRecord() and 'the phone keeps the statement'
            or 'the banking script keeps the statement'
        V.Info(('[v-phone] bank: on, balance from %s, transfers %s, %s')
            :format(reader, transfersOn() and 'on' or 'off', keeping))
    end)
end
