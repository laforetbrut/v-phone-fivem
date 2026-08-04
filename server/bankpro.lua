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
-- The history shows the movements of the account IN GENERAL, not only the ones made with the
-- phone. On a banking script whose statement can be read - qb-banking keeps every line in
-- `bank_statements` - that statement IS the history: an ATM deposit, a payroll another script
-- ran, a transfer made at the bank, and the phone's own movements too, because every phone
-- movement is written into the same statement. One read, one complete history.
--
-- The phone keeps its own log as well, and falls back to it when the bank cannot be read - a
-- business on such a server still sees what the phone did, which is better than nothing.

local function historyLimit()
    return math.max(1, math.min(50, math.floor(num(CFG.historyLimit, 50))))
end

CreateThread(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_bankpro_log` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `account`   VARCHAR(60) NOT NULL,
        `citizenid` VARCHAR(64) NOT NULL,
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

--- Normalised for the app: every row is `{ label, amount (SIGNED: + in, - out), at, who }`, so
--- the page renders one shape whether it came from the bank's statement or the phone's log.
local function history(account)
    local limit = historyLimit()

    -- The account's own statement first, so the history is the whole account and not just the
    -- phone. `date` comes back as a millisecond epoch and `amount` unsigned; the sign is put
    -- back from `statement_type` here, exactly as the personal Bank does.
    if Bridge.Banking and Bridge.Banking.SocietyTransactions then
        local rows = Bridge.Banking.SocietyTransactions(account, limit)
        if type(rows) == 'table' and #rows > 0 then
            local out = {}
            for _, r in ipairs(rows) do
                -- Trimmed here as well as in the query: a hook or a bank export may hand back
                -- more than was asked for, and the cap is what the app promised to show.
                if #out >= limit then break end
                local amt = math.abs(math.floor(num(r.amount, 0)))
                local outward = tostring(r.statement_type) == 'withdraw'
                    or (num(r.amount, 0) < 0)   -- a bank that already signs it
                -- The same seconds-or-milliseconds question as the personal statement: this
                -- reads the same `date` column, and both qb-banking and doc-banking store it as
                -- `os.time() * 1000`. See server/bank.lua for why 1e11 is the dividing line.
                local at = r.at
                if type(at) == 'number' and at > 100000000000 then at = math.floor(at / 1000) end
                out[#out + 1] = {
                    label = tostring(r.label or r.reason or ''),
                    amount = outward and -amt or amt,
                    at = at,
                }
            end
            return out
        end
    end

    -- Fallback: the phone's own log, for a bank whose statement cannot be read.
    local rows = MySQL.query.await([[SELECT name, kind, amount, target, note, at
        FROM vphone_bankpro_log WHERE account = ? ORDER BY id DESC LIMIT ?]],
        { account, limit }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local inward = r.kind == 'deposit'
        local amt = math.abs(math.floor(num(r.amount, 0)))
        out[#out + 1] = {
            label = (r.target ~= '' and r.target) or tostring(r.kind or ''),
            who = r.name,
            note = r.note,
            amount = inward and amt or -amt,
            at = r.at,
        }
    end
    return out
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
    -- The bank balance of whoever the phone is acting as: during a staff phone-view session
    -- that is the held character, not the staff member. See PhoneActingSource in adminview.lua.
    local acting = PhoneActingSource and PhoneActingSource(src) or src
    local mine = Bridge.Banking and Bridge.Banking.Balances and Bridge.Banking.Balances(acting) or nil

    resolve({
        ok = true,
        account = account,
        job = { name = job.name, label = job.label or job.name,
                grade = job.grade, gradeLabel = job.gradeLabel or '' },
        -- nil, not zero: the app says "this cannot be read" rather than showing a company
        -- an empty balance it does not have.
        balance = balance,
        readable = balance ~= nil,
        -- The boss's OWN bank balance, so the deposit sheet can refuse before it asks. No cash:
        -- Bank Pro never touches a pocket, so it has no reason to know what is in one.
        mine = { bank = math.floor(num(mine and mine.bank, 0)) },
        limits = {
            min = math.max(1, math.floor(num(CFG.minAmount, 1))),
            max = math.floor(num(CFG.maxAmount, 0)),
        },
        employees = CFG.employees ~= false,
        deposit = CFG.allowDeposit ~= false,
        withdraw = CFG.allowWithdraw ~= false,
        -- The only accounts a transfer may reach, sent so the app can offer them as a list
        -- rather than a text box. It is not the authority - `pay` checks the same list again
        -- - but an app that offers a destination it will then refuse is a worse app.
        payees = (function()
            -- **Named, not printed raw.** An account is a key - `mechanic`, `mechanic2`,
            -- `realestate` - and a list of keys is what a database looks like, not what a
            -- business owner picking a company to pay should read.
            --
            -- Three sources, best first: what the operator wrote in `Config.BankPro.payeeLabels`,
            -- then the job's own label from the framework, then the key with its separators
            -- tidied by the page. Nothing is invented: an account nobody has named still shows,
            -- because a missing name is not a reason to hide a payee.
            local labels = type(CFG.payeeLabels) == 'table' and CFG.payeeLabels or {}
            local jobs = nil
            if Bridge.Jobs and Bridge.Jobs.All then
                local ok, all = pcall(Bridge.Jobs.All)
                jobs = ok and type(all) == 'table' and all or nil
            end

            local prefix = tostring(CFG.accountPrefix or '')
            local out = {}
            for _, entry in ipairs(CFG.payees or {}) do
                -- Either `'mechanic'` or `{ account = 'mechanic', label = 'Los Santos Customs' }`.
                -- One list, so choosing a company and naming it is one decision in one place.
                local value = tostring(type(entry) == 'table' and (entry.account or entry.id or '')
                                       or entry)
                local own = type(entry) == 'table' and entry.label or nil
                if value ~= '' and value:lower() ~= account:lower() then
                    -- The job behind the account, so `society_mechanic` finds `mechanic`.
                    local jobName = value
                    if prefix ~= '' and value:sub(1, #prefix) == prefix then
                        jobName = value:sub(#prefix + 1)
                    end
                    local job = jobs and (jobs[jobName] or jobs[value]) or nil
                    out[#out + 1] = {
                        account = value,
                        -- The entry's own label first: it is the most specific thing anybody
                        -- wrote about this account.
                        label = tostring(own or labels[value] or labels[jobName]
                                         or (type(job) == 'table' and job.label)
                                         or jobName),
                    }
                end
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
---
--- **The people who are not employees have to be STANDING THERE.** Every connected character
--- used to appear, which made the app a server-wide roster: forty names a boss has never met,
--- most of them nowhere near the business, and the one they actually wanted buried among them.
--- Paying somebody is something you do while looking at them, so the list is what is within
--- `Config.BankPro.payRadius` of the phone - and it is their PHONE's name, the one that shows
--- when they ring you, not a citizen id.
---
--- Employees are NOT filtered by distance: payday is not a thing a boss should have to walk
--- round the map to do.
V.Callback('v-phone:bankpro:staff', function(src, resolve)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local account, why = accountFor(p)
    if not account then resolve({ error = why }) return end
    if CFG.employees == false then resolve({ ok = true, staff = {} }) return end

    local job = jobOf(p)

    -- Where the phone is, which under an admin hold is the held character and not the staff
    -- member: a nearby list drawn round the wrong body is a list of the wrong people.
    local hereSrc = PhoneActingSource and PhoneActingSource(src) or src
    local here = GetEntityCoords(GetPlayerPed(hereSrc))
    local radius = num(CFG.payRadius, 15.0)
    if radius <= 0 then radius = 15.0 end

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
            elseif CFG.payAnyone ~= false and #(here - GetEntityCoords(GetPlayerPed(other))) <= radius then
                -- Anybody else standing here. A business pays contractors, suppliers and
                -- people who did it a favour, and none of those are on its payroll - so
                -- restricting payment to employees was the app deciding how a business is run.
                --
                -- A LIST rather than a text box, near rather than everywhere, and named the
                -- way their phone names them: an app that accepts a typed citizen id is an
                -- app that pays whoever you can guess.
                others[#others + 1] = {
                    citizenid = op.citizenid,
                    name = op.name,
                    grade = (ojob and ojob.label) or '',
                }
            end
        end
    end
    resolve({ ok = true, staff = out, others = others, anyone = CFG.payAnyone ~= false,
              radius = math.floor(radius) })
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
    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not Bridge.AddMoney(acting, amount, 'bank', 'Bank Pro withdrawal') then
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
        Bridge.Banking.WriteStatement(acting, account, amount,
            ('v-phone: %s'):format(p.name or p.citizenid), 'withdraw', true)
        Bridge.Banking.WriteStatement(acting, 'checking', amount,
            ('v-phone: %s'):format(account), 'deposit', false)
    end
    Core.Log('bankpro', ('%s withdrew %d from %s'):format(p.name or p.citizenid, amount, account),
        nil, p.citizenid)
    resolve({ ok = true, amount = amount,
              balance = Bridge.SocietyBalance and Bridge.SocietyBalance(account) or nil })
end)

--- The boss's own BANK money into the company. Never cash: a deposit comes out of the boss's
--- personal bank account and into the society account, both sides written to the statement.
V.Callback('v-phone:bankpro:deposit', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local account, why = accountFor(p)
    if not account then resolve({ error = why }) return end
    if CFG.allowDeposit == false then resolve({ error = 'notallowed' }) return end

    local limits = { min = math.max(1, math.floor(num(CFG.minAmount, 1))),
                     max = math.floor(num(CFG.maxAmount, 0)) }
    local amount, bad = amountFrom(data, limits)
    if not amount then resolve({ error = bad }) return end

    -- From the bank, always. The `from` the page used to send is ignored on purpose.
    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not Bridge.RemoveMoney(acting, amount, 'bank', 'Bank Pro deposit') then
        resolve({ error = 'nomoney' })
        return
    end

    if not (Bridge.AddSociety and Bridge.AddSociety(account, amount,
            'v-phone: deposit by ' .. (p.name or p.citizenid))) then
        -- Straight back into the bank it came from.
        Bridge.AddMoney(acting, amount, 'bank', 'Bank Pro deposit reversed')
        resolve({ error = 'noaccount' })
        return
    end

    record(account, p, 'deposit', amount, p.name or p.citizenid, data and data.note)
    if Bridge.Banking and Bridge.Banking.WriteStatement then
        Bridge.Banking.WriteStatement(acting, account, amount,
            ('v-phone: %s'):format(p.name or p.citizenid), 'deposit', true)
        Bridge.Banking.WriteStatement(acting, 'checking', amount,
            ('v-phone: %s'):format(account), 'withdraw', false)
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
    -- Only the COMPANY's money moves here, never the caller's own purse - but the statement
    -- line is filed against a player id, and it has to be the character whose phone this is.
    local acting = PhoneActingSource and PhoneActingSource(src) or src

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
        -- **Paying yourself is a withdrawal wearing a payslip.**
        --
        -- A boss naming their own citizen id as the payee moved company money into their own
        -- account through the wages path - which has no daily ceiling, does not check
        -- `allowWithdraw`, and is logged as a payment rather than as a withdrawal. The
        -- `account` branch below has always refused a self-target (`who:lower() == account`);
        -- this branch never did, and it is the one that moves money to a person.
        if who == p.citizenid then resolve({ error = 'self' }) return end
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
            Bridge.Banking.WriteStatement(acting, account, amount,
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
        -- The same list, read the same two ways. This is the authority - the payload above is
        -- only what was offered - so a destination the page invented is refused here.
        local allowed = false
        for _, entry in ipairs(CFG.payees or {}) do
            local value = tostring(type(entry) == 'table' and (entry.account or entry.id or '')
                                   or entry)
            if value:lower() == who:lower() then allowed = true break end
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
            Bridge.Banking.WriteStatement(acting, account, amount,
                ('v-phone: %s'):format(who), 'withdraw', true)
            Bridge.Banking.WriteStatement(acting, who, amount,
                ('v-phone: %s'):format(account), 'deposit', true)
        end
        resolve({ ok = true, amount = amount,
                  balance = Bridge.SocietyBalance and Bridge.SocietyBalance(account) or nil })
        return
    end

    resolve({ error = 'noTarget' })
end)
