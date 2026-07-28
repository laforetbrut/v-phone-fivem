-- v-phone | server/api.lua
--
-- **The integration surface.**
--
-- Everything another resource is meant to call lives here, in one file, so a developer
-- reading the phone for the first time has one place to look and the rest of the server
-- code stays about the phone rather than about being called.
--
-- Three rules hold for every export below:
--
--  1. **A citizen id or a number identifies a person, never a source.** A source changes
--     every time somebody reconnects; an integration written against one breaks quietly.
--     Where a source is genuinely what you have, there is a `...ForPlayer` variant.
--  2. **Nothing here trusts its caller with identity.** You may send a message AS a
--     citizen you name, because a script that pays wages has to; you may not read
--     somebody's messages, because nothing needs to.
--  3. **Every one of them returns something checkable.** A failure is `false, reason`,
--     never a silent nil.
--
-- See API.md for the full documentation with examples.

local function num(v, d) return tonumber(v) or d or 0 end

-- ══════════════════════════════════════════════════════════════
-- People and numbers
-- ══════════════════════════════════════════════════════════════

--- Is this player's phone open right now? Useful for a script that wants to wait rather
--- than interrupt. Read from the player's state bag, which the phone replicates when it
--- opens and closes.
exports('IsPhoneOpen', function(src)
    src = tonumber(src)
    if not src then return false end
    local state = Player(src) and Player(src).state
    return (state and state.phoneOpen) == true
end)

--- Every online character's number, as { [citizenid] = number }. One call rather than a
--- loop of GetNumber, for a script that builds a directory.
exports('GetOnlineNumbers', function()
    local out = {}
    for _, raw in ipairs(GetPlayers()) do
        local src = tonumber(raw)
        local p = Core.GetPlayer(src)
        if p then
            local n = exports[GetCurrentResourceName()]:GetNumber(p.citizenid)
            if n and n ~= '' then out[p.citizenid] = n end
        end
    end
    return out
end)

--- The character behind a number, offline included. Returns a citizen id or nil, never
--- a source: what you do with the person is your business, but you do not get a handle
--- on their session for free.
exports('CitizenOfNumber', function(number)
    return Bridge.Numbers.Owner(tostring(number or ''))
end)

--- Give a character a number, or replace the one they have. For a server that mints
--- numbers itself, or an admin tool that fixes a collision.
exports('SetNumber', function(citizenid, number)
    citizenid = tostring(citizenid or '')
    number = tostring(number or '')
    if citizenid == '' or number == '' then return false, 'args' end

    local taken = Bridge.Numbers.Owner(number)
    if taken and taken ~= citizenid then return false, 'taken' end

    MySQL.update.await('UPDATE vphone_characters SET phone = ? WHERE citizenid = ?', { number, citizenid })
    Bridge.Numbers.Set(citizenid, number)
    -- The phone caches numbers per session, so a character who is connected is asked to
    -- reload rather than left holding the old one until they reconnect.
    local target = Core.GetPlayerByCitizenId(citizenid)
    if target and target.source then
        TriggerClientEvent('v-phone:client:close', target.source)
    end
    return true
end)

--- Give a character a NEW number in the current `Config.NumberFormat`.
---
--- The case this exists for: a qb-core server that already has players, whose numbers the
--- phone adopted from `charinfo` because that is the friendly default. Setting
--- `Config.Compat.numbers = 'phone'` stops it adopting any MORE of them - but it cannot
--- retroactively change one already stored, so without this the switch appears to do nothing
--- on exactly the server that wanted it.
---
--- **Anybody who saved the old number in their contacts still has the old number.** That is
--- not something this can fix: a contact is a row on somebody else's phone, and rewriting
--- other people's address books to follow a staff action would be worse than the problem. The
--- character's own contacts, messages and call log are untouched - only the number changes.
exports('Renumber', function(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return false, 'args' end

    local old = MySQL.scalar.await('SELECT phone FROM vphone_characters WHERE citizenid = ?',
        { citizenid })
    if old == nil then return false, 'nocharacter' end

    local fresh = PhoneMintNumber()
    if not fresh then return false, 'exhausted' end

    MySQL.update.await('UPDATE vphone_characters SET phone = ? WHERE citizenid = ?',
        { fresh, citizenid })
    -- The cache is per session and nothing else invalidates it, so a connected character
    -- would keep answering with the old number until they reconnected.
    PhoneForgetNumber(citizenid, old)
    Bridge.Numbers.Set(citizenid, fresh)

    local target = Core.GetPlayerByCitizenId(citizenid)
    if target and target.source then
        PhoneSetOnline(fresh, target.source)
        TriggerClientEvent('v-phone:client:close', target.source)
    end
    Core.Log('phone', ('renumbered %s: %s -> %s'):format(citizenid, tostring(old), fresh),
        nil, citizenid)
    return true, fresh, old
end)

--- Every character on the server, renumbered.
---
--- Deliberately NOT parallel and deliberately paced: this is one UPDATE plus one uniqueness
--- check per character, and running it over a few thousand rows as fast as Lua can is how a
--- server stutters for everybody at once. A number is not urgent.
exports('RenumberAll', function()
    local rows = MySQL.query.await('SELECT citizenid FROM vphone_characters') or {}
    local self = exports[GetCurrentResourceName()]
    local done, failed = 0, 0
    for i, row in ipairs(rows) do
        if self:Renumber(row.citizenid) then done = done + 1 else failed = failed + 1 end
        if i % 25 == 0 then Wait(0) end
    end
    return done, failed
end)

--- A loud, full-screen alert on every phone on the server.
---
--- Not a notification. This is the one thing the phone draws with the handset SHUT and with the
--- player's own volume setting ignored, because an emergency alert that waits for somebody to
--- open their phone is not an emergency alert.
---
--- It reaches **every connected player**, with no signal, battery or item check: a citywide
--- warning is not carried by the phone network in the fiction any more than it is in reality,
--- and a player whose phone is flat is exactly the player who most needs telling. That is also
--- why it sits behind the staff ace and `Config.Admin.actions.emergency`.
---
---     exports['v-phone']:EmergencyAlert('EARTHQUAKE', 'Get away from buildings')
exports('EmergencyAlert', function(kind, body, title)
    if (Config.Admin and Config.Admin.actions
        and Config.Admin.actions.emergency == false) then return 0 end

    local alert = {
        kind = tostring(kind or ''):gsub('[%c]', ''):sub(1, 24),
        title = tostring(title or ''):gsub('[%c]', ''):sub(1, 60),
        body = tostring(body or ''):gsub('[%c]', ''):sub(1, 300),
        -- Whether it takes the whole screen. Off: an alert is a notification that buzzes hard
        -- and sounds loudly, which is what makes it impossible to miss - not the square
        -- footage. Decided here rather than on the client so one server setting governs it.
        fullScreen = (Config.Admin and Config.Admin.emergencyFullScreen) == true,
    }
    if alert.body == '' and alert.title == '' then return 0 end

    local n = 0
    for _, raw in ipairs(GetPlayers()) do
        local src = tonumber(raw)
        if src then
            TriggerClientEvent('v-phone:client:emergency', src, alert)
            n = n + 1
        end
    end
    Core.Log('admin', ('emergency alert: %s / %s'):format(alert.kind, alert.body))
    return n
end)

-- ══════════════════════════════════════════════════════════════
-- Speaking into every phone
-- ══════════════════════════════════════════════════════════════
-- The sibling of the emergency alert above, and the same idea taken one step: instead of a
-- written warning, the staff member's own microphone.
--
-- **Where the difficulty is.** pma-voice has no listen-only channel - joining a call channel
-- makes every member a mutual voice target - so a channel with sixty players on it is sixty
-- open microphones. The channel is what makes the broadcaster audible; making it ONE-WAY is
-- done on each listener's machine, by turning every other listener down to zero and keeping
-- only the broadcaster. See `v-phone:client:voiceBroadcast` in client/main.lua.
--
-- One broadcast at a time, server-wide. Two people talking into every phone at once is not a
-- feature anybody asked for, and the second would silently join the first's channel.

local Broadcast = nil       -- { by, name, until_ } while one is live

local function voiceCfg()
    return (Config.Admin and Config.Admin.voice) or {}
end

--- Everybody, and what it costs to reach them.
---
--- Like the emergency alert, this ignores signal, battery and whether a phone is even in the
--- player's pocket: it is a staff tool, not a phone call, and a broadcast that skipped a flat
--- battery would skip exactly the player who needed telling.
function VoiceBroadcastStart(src, seconds)
    if voiceCfg().enabled == false then return nil, 'off' end
    if Broadcast and os.time() < Broadcast.until_ then return nil, 'busy' end

    src = tonumber(src) or 0
    seconds = math.max(1, math.floor(tonumber(seconds) or 60))
    local channel = math.floor(tonumber(voiceCfg().channel) or 690)

    Broadcast = {
        by = src,
        name = GetPlayerName(src) or 'Staff',
        until_ = os.time() + seconds,
    }

    local n = 0
    for _, raw in ipairs(GetPlayers()) do
        local id = tonumber(raw)
        if id then
            TriggerClientEvent('v-phone:client:voiceBroadcast', id, {
                on = true,
                channel = channel,
                -- Who to KEEP audible. Every other listener is turned down on each machine,
                -- so this one id is the difference between a broadcast and a riot.
                speaker = src,
                seconds = seconds,
                -- Whether a player already on a call is pulled in. Off by default: joining
                -- them to this channel drops them out of their conversation, and ending the
                -- broadcast would set their channel to zero - hanging up on them.
                interruptCalls = voiceCfg().interruptCalls == true,
                banner = voiceCfg().banner ~= false,
                ring = voiceCfg().ring ~= false,
            })
            n = n + 1
        end
    end

    -- The close is scheduled here rather than trusted to each client's own timer. A client
    -- that crashed mid-broadcast is a client that never turned anybody's voice back up.
    SetTimeout(seconds * 1000 + 500, function()
        if Broadcast and Broadcast.by == src and os.time() >= Broadcast.until_ then
            VoiceBroadcastStop()
        end
    end)

    Core.Log('admin', ('voice broadcast: %s to %d phone(s) for %ds')
        :format(Broadcast.name, n, seconds))
    return n
end

--- Close it, from the command or from the timer. Safe to call when nothing is running.
function VoiceBroadcastStop()
    if not Broadcast then return 0 end
    Broadcast = nil

    local n = 0
    for _, raw in ipairs(GetPlayers()) do
        local id = tonumber(raw)
        if id then
            TriggerClientEvent('v-phone:client:voiceBroadcast', id, { on = false })
            n = n + 1
        end
    end
    return n
end

--- Somebody who joined mid-broadcast still gets it. Without this they are the one player who
--- cannot hear the announcement everybody else is listening to.
AddEventHandler('playerJoining', function()
    if not Broadcast or os.time() >= Broadcast.until_ then return end
    local id = source
    SetTimeout(8000, function()
        if not Broadcast or os.time() >= Broadcast.until_ then return end
        TriggerClientEvent('v-phone:client:voiceBroadcast', id, {
            on = true,
            channel = math.floor(tonumber(voiceCfg().channel) or 690),
            speaker = Broadcast.by,
            seconds = math.max(1, Broadcast.until_ - os.time()),
            interruptCalls = voiceCfg().interruptCalls == true,
            banner = voiceCfg().banner ~= false,
            ring = false,       -- they have just loaded in; a klaxon on arrival is not a welcome
        })
    end)
end)

--- A broadcast whose speaker disconnected is a channel nobody is talking on.
AddEventHandler('playerDropped', function()
    if Broadcast and Broadcast.by == source then VoiceBroadcastStop() end
end)

--- For a staff menu, or a script of your own.
---
---     exports['v-phone']:VoiceBroadcast(source, 30)
---     exports['v-phone']:VoiceBroadcast(nil)          -- stop
exports('VoiceBroadcast', function(src, seconds)
    if not src then return VoiceBroadcastStop() end
    return VoiceBroadcastStart(src, seconds)
end)

-- ══════════════════════════════════════════════════════════════
-- Messages
-- ══════════════════════════════════════════════════════════════

--- Text somebody from a NAME rather than from a number: a dispatch, a shop confirming an
--- order, a fixer handing out a job. It lands in the conversation list like any other
--- message, raises the badge, makes the phone buzz, and cannot be replied to - there is no
--- number behind it.
---
--- `who` is whichever identifier your script happens to hold: a source id, a phone number,
--- or a citizen id. All three work.
---
---     exports['v-phone']:SendServiceMessage(source, 'LS Customs', 'Your car is ready.')
---     exports['v-phone']:SendServiceMessage('5550142', 'Dispatch', 'Meet at the docks.')
---     exports['v-phone']:SendServiceMessage(citizenid, 'Unknown', 'Bring the package.')
---
--- Returns `true`, or `false` plus one of `nonumber` (nobody by that identifier) or `empty`
--- (nothing to send). The sender name is capped at twelve characters, which is what the
--- column holds; longer ones are shortened and the console says so once.
---
--- **The delivery is the phone's own**, not an INSERT of its own: this used to write the row
--- and stop, so the message existed in the table and appeared only on the app's next cold
--- open. Everything about arriving - the live thread, the badge, the tone, the buzz, and the
--- sound anybody standing next to the player hears - now happens because it goes through the
--- same path a real message does.
exports('SendServiceMessage', function(who, label, body)
    return PhoneServiceMessage(who, label, body)
end)

--- The same thing, under the name a script author looks for first.
exports('SendSMS', function(who, label, body)
    return PhoneServiceMessage(who, label, body)
end)

--- What was said in one conversation, oldest first.
---
---     for _, m in ipairs(exports['v-phone']:GetMessages(cid, '5550142', 20)) do
---         print(m.mine and 'them' or 'you', m.body)
---     end
---
--- Each row is `{ id, mine, body, kind, attachment, at, seen }`. `mine` is from the point of
--- view of the citizen id you asked about. Reading does NOT mark the thread read: a script
--- asking what was said has not read it on the player's behalf.
exports('GetMessages', function(citizenid, otherNumber, limit)
    return PhoneConversation(citizenid, otherNumber, limit)
end)

-- ══════════════════════════════════════════════════════════════
-- Calls
-- ══════════════════════════════════════════════════════════════

--- Ring somebody, as though this player had dialled it themselves.
---
---     exports['v-phone']:Call(source, '5550142')
---     exports['v-phone']:Call(source, '5550142', { anonymous = true })
---
--- Goes through the phone's own dialler, so every rule a player meets applies here too: the
--- caller needs a phone and a signal, the other end must be connected and not already on a call,
--- Do Not Disturb is honoured, and anybody standing near the ringing phone hears it.
---
--- Returns `true, callId`, or `false` plus an error key: `busy`, `busy_them`, `offline`, `dnd`,
--- `nonumber`, `nophone`, `unreachable`, `self`, `noplayer`.
exports('Call', function(src, toNumber, opts)
    return PhoneStartCall(src, toNumber, opts)
end)

--- Hang up whatever this player is on. Works from either end, and on a conference it removes
--- this one person rather than ending it for everybody.
---
---     exports['v-phone']:EndCall(source)
exports('EndCall', function(src, reason)
    return PhoneEndCall(src, reason)
end)

--- Everything unread, as a count per app. For a HUD that wants a badge without opening
--- the phone.
exports('UnreadCount', function(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return 0 end
    -- Deleted messages are not unread ones. A HUD reading this and a phone reading its own list
    -- must arrive at the same number, or the badge outside the phone contradicts the badge in it.
    return num(MySQL.scalar.await([[
        SELECT COUNT(*) FROM vphone_messages
        WHERE to_cid = ? AND seen = 0
          AND id NOT IN (SELECT message_id FROM vphone_message_hidden WHERE citizenid = ?)]],
        { citizenid, citizenid }), 0)
end)

-- ══════════════════════════════════════════════════════════════
-- Contacts
-- ══════════════════════════════════════════════════════════════

--- Put a contact in somebody's phone. A job that hands out a supervisor's number, a
--- mission that gives you a fixer. Returns false if they already have that number.
exports('AddContact', function(citizenid, name, number, favourite)
    citizenid = tostring(citizenid or '')
    name = tostring(name or ''):sub(1, 40)
    number = tostring(number or ''):sub(1, 20)
    if citizenid == '' or name == '' or number == '' then return false, 'args' end

    local exists = MySQL.scalar.await(
        'SELECT 1 FROM vphone_contacts WHERE citizenid = ? AND number = ?', { citizenid, number })
    if exists then return false, 'exists' end

    MySQL.insert.await(
        'INSERT INTO vphone_contacts (citizenid, name, number, favourite) VALUES (?,?,?,?)',
        { citizenid, name, number, favourite and 1 or 0 })
    return true
end)

--- Take one back out, by number.
exports('RemoveContact', function(citizenid, number)
    local n = MySQL.update.await('DELETE FROM vphone_contacts WHERE citizenid = ? AND number = ?',
        { tostring(citizenid or ''), tostring(number or '') })
    return (n or 0) > 0
end)

--- Read somebody's contacts. Deliberately the only read of private data here, because a
--- dispatch or a phonebook script legitimately needs it and it exposes nothing the
--- player did not already put in themselves.
exports('GetContacts', function(citizenid)
    return MySQL.query.await(
        'SELECT name, number, favourite FROM vphone_contacts WHERE citizenid = ? ORDER BY name',
        { tostring(citizenid or '') }) or {}
end)

-- ══════════════════════════════════════════════════════════════
-- Battery
-- ══════════════════════════════════════════════════════════════

--- Set the battery outright, 0 to 100. For an EMP, a story beat, or an admin tool.
exports('SetBattery', function(src, percent)
    src = tonumber(src)
    if not src then return false, 'args' end
    local self = exports[GetCurrentResourceName()]
    local now = tonumber(self:GetBattery(src)) or 0
    self:AddBattery(src, math.max(0, math.min(100, num(percent, 100))) - now)
    return true
end)

-- ══════════════════════════════════════════════════════════════
-- The apps
-- ══════════════════════════════════════════════════════════════

--- Install an optional app on somebody's phone without making them find it in the
--- store: a job that hands you its tool the day you are hired.
exports('InstallApp', function(citizenid, appId)
    citizenid = tostring(citizenid or '')
    appId = tostring(appId or '')
    if citizenid == '' or appId == '' then return false, 'args' end

    local prefs = Bridge.KvGet(citizenid, 'phone') or {}
    prefs.added = prefs.added or {}
    for _, id in ipairs(prefs.added) do
        if id == appId then return false, 'exists' end
    end
    prefs.added[#prefs.added + 1] = appId
    Bridge.KvSet(citizenid, 'phone', prefs)

    local target = Core.GetPlayerByCitizenId(citizenid)
    if target and target.source then TriggerClientEvent('v-phone:client:close', target.source) end
    return true
end)

--- And take it away again.
exports('UninstallApp', function(citizenid, appId)
    citizenid = tostring(citizenid or '')
    appId = tostring(appId or '')
    local prefs = Bridge.KvGet(citizenid, 'phone') or {}
    local kept, found = {}, false
    for _, id in ipairs(prefs.added or {}) do
        if id == appId then found = true else kept[#kept + 1] = id end
    end
    if not found then return false, 'missing' end
    prefs.added = kept
    Bridge.KvSet(citizenid, 'phone', prefs)

    local target = Core.GetPlayerByCitizenId(citizenid)
    if target and target.source then TriggerClientEvent('v-phone:client:close', target.source) end
    return true
end)

-- ══════════════════════════════════════════════════════════════
-- Notifications
-- ══════════════════════════════════════════════════════════════

--- A banner on the phone, from your own app or your own script. `Notify` already exists
--- and takes (src, app, title, body); this one addresses a CHARACTER, which is what a
--- script that does not track sources actually has.
exports('NotifyCitizen', function(citizenid, app, title, body)
    local target = Core.GetPlayerByCitizenId(tostring(citizenid or ''))
    if not target or not target.source then return false, 'offline' end
    return exports[GetCurrentResourceName()]:Notify(target.source,
        tostring(app or 'phone'), tostring(title or ''), tostring(body or ''))
end)

--- Everybody at once, for a server announcement. Rate limited by nothing but your own
--- judgement: a phone that buzzes constantly is a phone players turn off.
exports('NotifyAll', function(app, title, body)
    local self = exports[GetCurrentResourceName()]
    for _, raw in ipairs(GetPlayers()) do
        self:Notify(tonumber(raw), tostring(app or 'phone'),
            tostring(title or ''), tostring(body or ''))
    end
    return true
end)

-- ══════════════════════════════════════════════════════════════
-- Mail
-- ══════════════════════════════════════════════════════════════

--- Send mail to a character's iFruit address. For an application form, a payslip, a
--- receipt: the things a message is too small for.
exports('SendMail', function(toCitizenid, fromAddress, subject, body)
    toCitizenid = tostring(toCitizenid or '')
    if toCitizenid == '' then return false, 'args' end

    -- Mail is addressed to an ADDRESS, not to a character: somebody who has never opened
    -- the Mail app has nowhere to receive it.
    local address = MySQL.scalar.await(
        'SELECT address FROM vphone_mail_accounts WHERE citizenid = ? LIMIT 1', { toCitizenid })
    if not address or address == '' then return false, 'nomailbox' end

    -- Two rows, exactly as a mail the app itself sends: the letter, then a line in the
    -- recipient's box pointing at it.
    local mailId = MySQL.insert.await(
        'INSERT INTO vphone_mail (from_addr, to_addr, subject, body) VALUES (?,?,?,?)', {
            tostring(fromAddress or 'noreply@ls.com'):sub(1, 64), address,
            tostring(subject or ''):sub(1, 120), tostring(body or ''),
        })
    if not mailId then return false, 'x' end
    MySQL.insert.await(
        "INSERT INTO vphone_mail_box (mail_id, address, folder) VALUES (?,?,'inbox')",
        { mailId, address })

    local target = Core.GetPlayerByCitizenId(toCitizenid)
    if target and target.source then
        exports[GetCurrentResourceName()]:Notify(target.source, 'mail',
            tostring(fromAddress or 'Mail'), tostring(subject or ''))
    end
    return true
end)

--- `QbMail(citizenid, mailData)` is defined in bridge/server/qb-phone.lua, next to the rest
--- of the qb-core compatibility. It takes qb's `{ sender, subject, message }` shape, turns
--- the sender into an address and the HTML body into text, and falls back to a service
--- message when the recipient has no mailbox. Use it if you are porting a script written
--- against qb-phone; use SendMail above for anything new.

-- ══════════════════════════════════════════════════════════════
-- What the phone tells you
-- ══════════════════════════════════════════════════════════════
-- Listen rather than poll. Each of these fires on the SERVER with a citizen id, so an
-- integration written against them survives a reconnect.
--
--     AddEventHandler('v-phone:messageSent', function(fromCid, toCid, body, kind) end)
--     AddEventHandler('v-phone:phoneOpened', function(src, citizenid) end)
--     AddEventHandler('v-phone:phoneClosed', function(src, citizenid) end)
--
-- These three are emitted from the places that do the work. There are deliberately not
-- more of them: an event nobody fires is worse than no event at all.

--- A read-only description of what this phone is and what it decided at boot. For a
--- diagnostics command, or for a script that wants to adapt to the server it is on.
exports('GetPhoneInfo', function()
    return {
        version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0),
        framework = Bridge.framework,
        frameworkResource = Bridge.frameworkResource,
        inventory = Bridge.InventoryResource and Bridge.InventoryResource() or nil,
        numberFormat = V.Setting('numberFormat', Config.NumberFormat),
        apps = (function()
            local ids = {}
            for _, a in ipairs(Config.Apps) do ids[#ids + 1] = a.id end
            return ids
        end)(),
        social = V.SettingBool('social', true),
    }
end)

-- ══════════════════════════════════════════════════════════════
-- External charging
-- ══════════════════════════════════════════════════════════════
-- Another resource charges the phone: an electric car, a solar backpack, a socket prop.
-- It calls this while the player is plugged in and calls it again with `on = false` when
-- they unplug. The phone treats them as if they were at a charger for as long as it is on.
--
--     -- an electric vehicle script, on enter with charge to spare:
--     exports['v-phone']:SetCharging(src, true, 1.5)
--     -- on leave, or when the car runs flat:
--     exports['v-phone']:SetCharging(src, false)
--- **It expires.** A resource that switches charging ON and never switches it off - because
--- it crashed, was stopped, or simply forgot a code path - used to leave the phone charging
--- for the rest of the session. It is the first branch `chargeRateAt` reads, so nothing else
--- can correct it, and the player sees a battery that fills for ever with no charger in sight.
---
--- Every call renews the lease. A script that means it is plugged in says so again well inside
--- `Config.ExternalCharging.leaseSeconds`, which is what a charging script does anyway: it
--- runs a loop. One that has gone away stops renewing, and the phone unplugs itself.
exports('SetCharging', function(src, on, rate)
    src = tonumber(src)
    if not src then return false, 'args' end
    if not on then
        ExternalCharge[src] = nil
        ExternalChargeUntil[src] = nil
        return true
    end
    local cfg = Config.ExternalCharging or {}
    local wanted = tonumber(rate) or cfg.defaultRate or 1.0
    ExternalCharge[src] = math.max(0.1, math.min(tonumber(cfg.maxRate) or 4.0, wanted))
    ExternalChargeUntil[src] = os.time() + math.max(10, math.floor(tonumber(cfg.leaseSeconds) or 120))
    return true
end)

--- Is another resource charging this phone right now? For a car dashboard.
exports('IsCharging', function(src)
    src = tonumber(src)
    return src ~= nil and (ExternalCharge[src] or 0) > 0
end)

-- ══════════════════════════════════════════════════════════════
-- Admin: acting on a character's phone
-- ══════════════════════════════════════════════════════════════

--- Everything about a character's phone, for a support tool: number, battery, unread
--- count, and their social handles. Reads only; changes nothing.
exports('AdminReadPhone', function(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return nil end
    local self = exports[GetCurrentResourceName()]
    local target = Core.GetPlayerByCitizenId(citizenid)
    return {
        citizenid = citizenid,
        name = Bridge.NameOfCitizen(citizenid),
        number = self:GetNumber(citizenid),
        online = target ~= nil,
        battery = target and self:GetBattery(target.source) or nil,
        open = target and self:IsPhoneOpen(target.source) or false,
        unread = self:UnreadCount(citizenid),
        handles = {
            bleeter = self:SocialHandle(citizenid, 'bleeter'),
            snap    = self:SocialHandle(citizenid, 'snap'),
            hush    = self:SocialHandle(citizenid, 'hush'),
        },
    }
end)

--- Delete every trace of a character's phone data: a character reset, a ban cleanup, a
--- data request. Returns how many rows went. IRREVERSIBLE - that is the point of a wipe.
exports('WipePhone', function(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return false, 'args' end

    -- Keyed by `citizenid`. Messages and the DM / like / follow tables are keyed by the
    -- two ends of a conversation instead, so they are handled separately below.
    local byCitizen = {
        'vphone_kv', 'vphone_characters', 'vphone_contacts',
        'vphone_calls', 'vphone_voicemail', 'vphone_notes', 'vphone_mail_accounts',
        'vphone_app_data', 'vphone_cipher_profiles', 'vphone_cipher_clears',
        'vphone_social_accounts', 'vphone_social_posts', 'vphone_social_likes',
        'vphone_social_comments', 'vphone_social_reposts', 'vphone_social_stories',
        'vphone_social_story_seen', 'vphone_hush_profiles', 'vphone_group_members',
        'vphone_media',
    }
    local removed = 0
    for _, tbl in ipairs(byCitizen) do
        local n = MySQL.update.await(('DELETE FROM %s WHERE citizenid = ?'):format(tbl), { citizenid })
        removed = removed + (tonumber(n) or 0)
    end

    -- Keyed by from_cid / to_cid.
    for _, tbl in ipairs({ 'vphone_messages', 'vphone_hush_likes', 'vphone_social_follows',
                           'vphone_social_dm', 'vphone_cipher_messages' }) do
        local n = MySQL.update.await(
            ('DELETE FROM %s WHERE from_cid = ? OR to_cid = ?'):format(tbl), { citizenid, citizenid })
        removed = removed + (tonumber(n) or 0)
    end

    local target = Core.GetPlayerByCitizenId(citizenid)
    if target and target.source then TriggerClientEvent('v-phone:client:close', target.source) end
    return true, removed
end)

--- Open a player's phone on their own screen. For support: "let me see what you see".
exports('OpenPhoneFor', function(src)
    src = tonumber(src)
    if not src or not Core.GetPlayer(src) then return false, 'offline' end
    TriggerClientEvent('v-phone:client:open', src)
    return true
end)

-- ══════════════════════════════════════════════════════════════
-- Import / export: a character's whole phone, as one table
-- ══════════════════════════════════════════════════════════════
-- For a character transfer, a backup, or a support restore. Export gives you a plain
-- table; import writes it back under a citizen id. The number is deliberately NOT carried:
-- a number belongs to the server that minted it.
local EXPORT_TABLES = {
    contacts = { t = 'vphone_contacts',      key = 'citizenid' },
    notes    = { t = 'vphone_notes',         key = 'citizenid' },
    appdata  = { t = 'vphone_app_data',      key = 'citizenid' },
    prefs    = { t = 'vphone_kv',            key = 'citizenid' },
    mailbox  = { t = 'vphone_mail_accounts', key = 'citizenid' },
}

exports('ExportPhone', function(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return nil end
    local out = { citizenid = citizenid, version = 1 }
    for name, spec in pairs(EXPORT_TABLES) do
        out[name] = MySQL.query.await(
            ('SELECT * FROM %s WHERE %s = ?'):format(spec.t, spec.key), { citizenid }) or {}
    end
    return out
end)

--- Write an exported phone back. `replace` clears the character's current rows first, so
--- a restore does not double up. Rows are re-keyed to the target citizen id.
exports('ImportPhone', function(citizenid, data, replace)
    citizenid = tostring(citizenid or '')
    if citizenid == '' or type(data) ~= 'table' then return false, 'args' end

    for name, spec in pairs(EXPORT_TABLES) do
        local rows = data[name]
        if type(rows) == 'table' then
            if replace then
                MySQL.query.await(('DELETE FROM %s WHERE %s = ?'):format(spec.t, spec.key), { citizenid })
            end
            for _, row in ipairs(rows) do
                row[spec.key] = citizenid
                row.id = nil
                local cols, marks, vals = {}, {}, {}
                for col, value in pairs(row) do
                    cols[#cols + 1] = '`' .. col .. '`'
                    marks[#marks + 1] = '?'
                    vals[#vals + 1] = value
                end
                if #cols > 0 then
                    MySQL.insert.await(('INSERT INTO %s (%s) VALUES (%s)')
                        :format(spec.t, table.concat(cols, ','), table.concat(marks, ',')), vals)
                end
            end
        end
    end

    local target = Core.GetPlayerByCitizenId(citizenid)
    if target and target.source then TriggerClientEvent('v-phone:client:close', target.source) end
    return true
end)
