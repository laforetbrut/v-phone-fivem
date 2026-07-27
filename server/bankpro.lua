-- v-phone | server/bankpro.lua
--
-- **Bank Pro: the company account, on the phone.**
--
-- The Bank app is a person's money. This is a business's: the society account behind a job,
-- for the character who runs it. Deposit takings, pay somebody, move money to another company,
-- read what has been moved and by whom.
--
-- **There are no phone numbers here.** A company is paid by ACCOUNT, and an employee by who
-- they are - not by whichever number they happen to be carrying. That is the difference
-- between this and the Bank app, and it is deliberate: a business transfer that went to a
-- number would be a business transfer that can go to a stranger who bought a SIM.
--
-- Every decision is the server's:
--
--   * whether this character may open it at all - the job, the grade, `isboss`
--   * what the account is called - derived from their job, never named by the page
--   * whether the money moved - `Bridge.RemoveSociety` fails closed, and the credit only
--     happens once the debit is confirmed
--
-- The page sends an amount and a destination, and nothing else it says is believed.

local CFG = Config.BankPro or {}

local function num(v, d) return tonumber(v) or d or 0 end

local function enabled()
    return CFG.enabled ~= false
end

--- The job this character actually holds, from the framework rather than from the page.
local function jobOf(p)
    local job = p and p.job
    if type(job) ~= 'table' then return nil end
    return job
end

--- May this character use Bank Pro, and for which account?
---
--- Returns the account name and the job, or nil and a reason. The account is DERIVED - the
--- page never names one - so a player who edits a request cannot reach a company they do not
--- work for.
local function accountFor(p)
    if not enabled() then return nil, 'off' end
    local job = jobOf(p)
    if not job or job.name == 'unemployed' then return nil, 'nojob' end

    -- A job list, when the operator wrote one. Empty means every job qualifies, which is the
    -- sensible default for a resource that cannot know what jobs a server has.
    local jobs = CFG.jobs
    if type(jobs) == 'table' and next(jobs) ~= nil then
        local listed = false
        for _, name in ipairs(jobs) do
            if tostring(name):lower() == tostring(job.name):lower() then listed = true break end
        end
        if not listed then return nil, 'notallowed' end
    end

    -- Who counts as running the business. `isboss` is what qb marks a boss grade with; a
    -- minimum grade covers a server that does not use the flag.
    if CFG.requireBoss ~= false and job.boss ~= true then
        local minGrade = math.floor(num(CFG.minGrade, -1))
        if minGrade < 0 or num(job.grade, 0) < minGrade then return nil, 'notboss' end
    end

    local prefix = tostring(CFG.accountPrefix or '')
    return prefix .. tostring(job.name), job
end

-- ══════════════════════════════════════════════════════════════
-- The ledger
-- ══════════════════════════════════════════════════════════════
-- The phone keeps its own record of what the phone did. It is deliberately not an attempt to
-- mirror the banking script's statement: that script has its own, it is authoritative, and two
-- half-histories are worse than one complete one. What this answers is the question a business
-- owner actually asks about an app - "who moved money with THIS, and when".

CreateThread(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_bankpro_log` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `account`   VARCHAR(60) NOT NULL,
        `citizenid` VARCHAR(60) NOT NULL,
        `name`      VARCHAR(80) NOT NULL DEFAULT '',
        `kind`      VARCHAR(16) NOT NULL,
        `amount`    INT NOT NULL DEFAULT 0,
        `target`    VARCHAR(80) NOT NULL DEFAULT '',
        `note`      VARCHAR(100) NOT NULL DEFAULT '',
        `at`        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `account` (`account`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])
end)

local function record(account, p, kind, amount, target, note)
    MySQL.insert('INSERT INTO vphone_bankpro_log (account, citizenid, name, kind, amount, target, note) '
        .. 'VALUES (?,?,?,?,?,?,?)',
        { account, p.citizenid, p.name or '', kind, math.floor(amount), tostring(target or ''),
          tostring(note or ''):sub(1, 100) })
end

local function history(account)
    local rows = MySQL.query.await([[SELECT name, kind, amount, target, note, at
        FROM vphone_bankpro_log WHERE account = ? ORDER BY id DESC LIMIT 40]], { account }) or {}
    return rows
end

-- ══════════════════════════════════════════════════════════════
-- What the app reads
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:bankpro:open', function(src, resolve)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local account, jobOrWhy = accountFor(p)
    if not account then resolve({ error = jobOrWhy }) return end
    local job = jobOrWhy

    local balance = Bridge.SocietyBalance and Bridge.SocietyBalance(account) or nil
    local mine = Bridge.Banking and Bridge.Banking.Balances and Bridge.Banking.Balances(src) or nil

    resolve({
        ok = true,
        account = account,
        job = { name = job.name, label = job.label or job.name,
                grade = job.grade, gradeLabel = job.gradeLabel or '' },
        -- nil, not zero: the app says "this cannot be read" rather than showing a company
        -- an empty balance it does not have.
        balance = balance,
        readable = balance ~= nil,
        -- What the player has, so the deposit sheet can refuse before it asks.
        mine = { cash = math.floor(num(mine and mine.cash, 0)),
                 bank = math.floor(num(mine and mine.bank, 0)) },
        limits = {
            min = math.max(1, math.floor(num(CFG.minAmount, 1))),
            max = math.floor(num(CFG.maxAmount, 0)),
        },
        employees = CFG.employees ~= false,
        withdraw = CFG.allowWithdraw ~= false,
        -- The only accounts a transfer may reach, sent so the app can offer them as a list
        -- rather than a text box. It is not the authority - `pay` checks the same list again
        -- - but an app that offers a destination it will then refuse is a worse app.
        payees = (function()
            local out = {}
            for _, name in ipairs(CFG.payees or {}) do
                local value = tostring(name)
                if value ~= '' and value:lower() ~= account:lower() then out[#out + 1] = value end
            end
            return out
        end)(),
        history = history(account),
    })
end)

--- Who works here, for paying one of them.
---
--- By CHARACTER, not by phone number. Only characters currently online are offered: paying
--- somebody who is not connected means a framework write behind their back, and every
--- framework does that differently.
V.Callback('v-phone:bankpro:staff', function(src, resolve)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local account, why = accountFor(p)
    if not account then resolve({ error = why }) return end
    if CFG.employees == false then resolve({ ok = true, staff = {} }) return end

    local job = jobOf(p)
    local out, others = {}, {}
    for _, raw in ipairs(GetPlayers()) do
        local other = tonumber(raw)
        local op = other and Core.GetPlayer(other)
        local ojob = op and jobOf(op)
        if op and op.citizenid ~= p.citizenid then
            if ojob and ojob.name == job.name then
                out[#out + 1] = {
                    citizenid = op.citizenid,
                    name = op.name,
                    grade = ojob.gradeLabel ~= '' and ojob.gradeLabel or tostring(ojob.grade or 0),
                }
            elseif CFG.payAnyone ~= false then
                -- Anybody else connected. A business pays contractors, suppliers and people
                -- who did it a favour, and none of those are on its payroll - so restricting
                -- payment to employees was the app deciding how a business is run.
                --
                -- A LIST rather than a text box, and only characters who are online: an app
                -- that accepts a typed citizen id is an app that pays whoever you can guess.
                others[#others + 1] = {
                    citizenid = op.citizenid,
                    name = op.name,
                    grade = (ojob and ojob.label) or '',
                }
            end
        end
    end
    resolve({ ok = true, staff = out, others = others, anyone = CFG.payAnyone ~= false })
end)

-- ══════════════════════════════════════════════════════════════
-- What the app does
-- ══════════════════════════════════════════════════════════════

local function amountFrom(data, limits)
    local amount = math.floor(num(data and data.amount, 0))
    if amount < limits.min then return nil, 'amount' end
    if limits.max > 0 and amount > limits.max then return nil, 'toobig' end
    return amount
end

--- Company money into the player's own bank.
V.Callback('v-phone:bankpro:withdraw', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local account, why = accountFor(p)
    if not account then resolve({ error = why }) return end
    if CFG.allowWithdraw == false then resolve({ error = 'notallowed' }) return end

    local limits = { min = math.max(1, math.floor(num(CFG.minAmount, 1))),
                     max = math.floor(num(CFG.maxAmount, 0)) }
    local amount, bad = amountFrom(data, limits)
    if not amount then resolve({ error = bad }) return end

    -- The debit first, and only then the credit. The other order pays a player out of a
    -- company that could not afford it the moment the debit fails.
    if not (Bridge.RemoveSociety and Bridge.RemoveSociety(account, amount,
            'v-phone: withdrawal by ' .. (p.name or p.citizenid))) then
        resolve({ error = 'nofunds' })
        return
    end
    if not Bridge.AddMoney(src, amount, 'bank', 'Bank Pro withdrawal') then
        -- Put it back. A credit that failed after a confirmed debit is money deleted.
        if Bridge.AddSociety then
            Bridge.AddSociety(account, amount, 'v-phone: withdrawal reversed')
        end
        resolve({ error = 'x' })
        return
    end

    record(account, p, 'withdraw', amount, p.name or p.citizenid, data and data.note)
    -- Both statements the bank itself keeps: out of the company, into the person. Without
    -- these the ATM shows a balance that changed for no reason anybody can point at.
    if Bridge.Banking and Bridge.Banking.WriteStatement then
        Bridge.Banking.WriteStatement(src, account, amount,
            ('v-phone: %s'):format(p.name or p.citizenid), 'withdraw', true)
        Bridge.Banking.WriteStatement(src, 'checking', amount,
            ('v-phone: %s'):format(account), 'deposit', false)
    end
    Core.Log('bankpro', ('%s withdrew %d from %s'):format(p.name or p.citizenid, amount, account),
        nil, p.citizenid)
    resolve({ ok = true, amount = amount,
              balance = Bridge.SocietyBalance and Bridge.SocietyBalance(account) or nil })
end)

--- The player's own money into the company.
V.Callback('v-phone:bankpro:deposit', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local account, why = accountFor(p)
    if not account then resolve({ error = why }) return end

    local limits = { min = math.max(1, math.floor(num(CFG.minAmount, 1))),
                     max = math.floor(num(CFG.maxAmount, 0)) }
    local amount, bad = amountFrom(data, limits)
    if not amount then resolve({ error = bad }) return end

    local purse = (data and data.from == 'cash') and 'cash' or 'bank'
    if not Bridge.RemoveMoney(src, amount, purse) then resolve({ error = 'nomoney' }) return end

    if not (Bridge.AddSociety and Bridge.AddSociety(account, amount,
            'v-phone: deposit by ' .. (p.name or p.citizenid))) then
        -- Straight back into the pocket it came from.
        Bridge.AddMoney(src, amount, purse, 'Bank Pro deposit reversed')
        resolve({ error = 'noaccount' })
        return
    end

    record(account, p, 'deposit', amount, p.name or p.citizenid, data and data.note)
    if Bridge.Banking and Bridge.Banking.WriteStatement then
        Bridge.Banking.WriteStatement(src, account, amount,
            ('v-phone: %s'):format(p.name or p.citizenid), 'deposit', true)
        if purse == 'bank' then
            Bridge.Banking.WriteStatement(src, 'checking', amount,
                ('v-phone: %s'):format(account), 'withdraw', false)
        end
    end
    resolve({ ok = true, amount = amount,
              balance = Bridge.SocietyBalance and Bridge.SocietyBalance(account) or nil })
end)

--- Pay an employee, or another company.
---
--- `to` is either `staff:<citizenid>` or `account:<name>`. Both are checked here: an employee
--- must actually hold this job, and an account must be one the operator listed. Neither is
--- taken on the page's word.
V.Callback('v-phone:bankpro:pay', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local account, why = accountFor(p)
    if not account then resolve({ error = why }) return end

    local limits = { min = math.max(1, math.floor(num(CFG.minAmount, 1))),
                     max = math.floor(num(CFG.maxAmount, 0)) }
    local amount, bad = amountFrom(data, limits)
    if not amount then resolve({ error = bad }) return end

    local to = tostring((data and data.to) or '')
    local kind, who = to:match('^(%a+):(.+)$')
    if not kind then resolve({ error = 'noTarget' }) return end

    if kind == 'staff' or kind == 'person' then
        if kind == 'staff' and CFG.employees == false then resolve({ error = 'notallowed' }) return end
        if kind == 'person' and CFG.payAnyone == false then resolve({ error = 'notallowed' }) return end

        local target = Core.GetPlayerByCitizenId(who)
        local job = jobOf(p)
        local theirs = target and jobOf(target)

        -- `staff` means a colleague and is checked as one. `person` is anybody CONNECTED -
        -- a contractor, a supplier, somebody who did the business a favour - and the check
        -- that matters there is simply that they exist right now, because paying an offline
        -- character means writing behind their back and every framework does that differently.
        if not target then resolve({ error = 'nostaff' }) return end
        if kind == 'staff' and (not theirs or theirs.name ~= job.name) then
            resolve({ error = 'nostaff' })
            return
        end

        if not (Bridge.RemoveSociety and Bridge.RemoveSociety(account, amount,
                'v-phone: paid ' .. (target.name or who))) then
            resolve({ error = 'nofunds' })
            return
        end
        if not Bridge.AddMoney(target.source, amount, 'bank', 'Bank Pro payment') then
            if Bridge.AddSociety then
                Bridge.AddSociety(account, amount, 'v-phone: payment reversed')
            end
            resolve({ error = 'x' })
            return
        end

        record(account, p, 'pay', amount, target.name or who, data and data.note)
        if Bridge.Banking and Bridge.Banking.WriteStatement then
            Bridge.Banking.WriteStatement(src, account, amount,
                ('v-phone: %s'):format(target.name or who), 'withdraw', true)
            Bridge.Banking.WriteStatement(target.source, 'checking', amount,
                ('v-phone: %s'):format(account), 'deposit', false)
        end
        -- Told, rather than discovered later in a statement.
        exports[GetCurrentResourceName()]:Notify(target.source, 'bank',
            LP(target.source, 'ph.bankpro_paid_title'),
            (LP(target.source, 'ph.bankpro_paid_body') or '%s'):format(tostring(amount)))
        resolve({ ok = true, amount = amount,
                  balance = Bridge.SocietyBalance and Bridge.SocietyBalance(account) or nil })
        return
    end

    if kind == 'account' then
        -- Only an account the operator listed. A free-text destination is a way to move a
        -- company's money into a name nobody has ever heard of.
        local allowed = false
        for _, name in ipairs(CFG.payees or {}) do
            if tostring(name):lower() == who:lower() then allowed = true break end
        end
        if not allowed then resolve({ error = 'nopayee' }) return end
        if who:lower() == account:lower() then resolve({ error = 'self' }) return end

        if not (Bridge.RemoveSociety and Bridge.RemoveSociety(account, amount,
                'v-phone: transfer to ' .. who)) then
            resolve({ error = 'nofunds' })
            return
        end
        if not (Bridge.AddSociety and Bridge.AddSociety(who, amount,
                'v-phone: transfer from ' .. account)) then
            Bridge.AddSociety(account, amount, 'v-phone: transfer reversed')
            resolve({ error = 'noaccount' })
            return
        end

        record(account, p, 'transfer', amount, who, data and data.note)
        if Bridge.Banking and Bridge.Banking.WriteStatement then
            Bridge.Banking.WriteStatement(src, account, amount,
                ('v-phone: %s'):format(who), 'withdraw', true)
            Bridge.Banking.WriteStatement(src, who, amount,
                ('v-phone: %s'):format(account), 'deposit', true)
        end
        resolve({ ok = true, amount = amount,
                  balance = Bridge.SocietyBalance and Bridge.SocietyBalance(account) or nil })
        return
    end

    resolve({ error = 'noTarget' })
end)
