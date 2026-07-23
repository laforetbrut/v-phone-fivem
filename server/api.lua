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

    MySQL.update.await('UPDATE phone_characters SET phone = ? WHERE citizenid = ?', { number, citizenid })
    Bridge.Numbers.Set(citizenid, number)
    -- The phone caches numbers per session, so a character who is connected is asked to
    -- reload rather than left holding the old one until they reconnect.
    local target = Core.GetPlayerByCitizenId(citizenid)
    if target and target.source then
        TriggerClientEvent('v-phone:client:close', target.source)
    end
    return true
end)

-- ══════════════════════════════════════════════════════════════
-- Messages
-- ══════════════════════════════════════════════════════════════

--- A message from a name rather than from a number: a shop confirming an order, a
--- dispatch, a bank. It lands in the conversation list like any other, and the sender is
--- shown as the label you gave.
---
---     exports['v-phone']:SendServiceMessage(cid, 'LS Customs', 'Your car is ready.')
exports('SendServiceMessage', function(toCitizenid, label, body)
    toCitizenid = tostring(toCitizenid or '')
    if toCitizenid == '' then return false, 'args' end
    body = tostring(body or '')
    if body:gsub('%s', '') == '' then return false, 'empty' end
    label = tostring(label or 'iFruit'):sub(1, 40)

    local target = Core.GetPlayerByCitizenId(toCitizenid)
    if target and target.source then
        exports[GetCurrentResourceName()]:Notify(target.source, 'messages', label, body)
    end

    -- Stored so it survives a reconnect. The sender id is the label rather than a
    -- number, so nobody calls back a service that cannot answer.
    MySQL.insert.await('INSERT INTO phone_messages (from_cid, to_cid, body) VALUES (?,?,?)',
        { ('svc:%s'):format(label):sub(1, 16), toCitizenid, body:sub(1, 500) })
    return true
end)

--- Everything unread, as a count per app. For a HUD that wants a badge without opening
--- the phone.
exports('UnreadCount', function(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return 0 end
    return num(MySQL.scalar.await(
        'SELECT COUNT(*) FROM phone_messages WHERE to_cid = ? AND seen = 0', { citizenid }), 0)
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
        'SELECT 1 FROM phone_contacts WHERE citizenid = ? AND number = ?', { citizenid, number })
    if exists then return false, 'exists' end

    MySQL.insert.await(
        'INSERT INTO phone_contacts (citizenid, name, number, favourite) VALUES (?,?,?,?)',
        { citizenid, name, number, favourite and 1 or 0 })
    return true
end)

--- Take one back out, by number.
exports('RemoveContact', function(citizenid, number)
    local n = MySQL.update.await('DELETE FROM phone_contacts WHERE citizenid = ? AND number = ?',
        { tostring(citizenid or ''), tostring(number or '') })
    return (n or 0) > 0
end)

--- Read somebody's contacts. Deliberately the only read of private data here, because a
--- dispatch or a phonebook script legitimately needs it and it exposes nothing the
--- player did not already put in themselves.
exports('GetContacts', function(citizenid)
    return MySQL.query.await(
        'SELECT name, number, favourite FROM phone_contacts WHERE citizenid = ? ORDER BY name',
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
        'SELECT address FROM phone_mail_accounts WHERE citizenid = ? LIMIT 1', { toCitizenid })
    if not address or address == '' then return false, 'nomailbox' end

    -- Two rows, exactly as a mail the app itself sends: the letter, then a line in the
    -- recipient's box pointing at it.
    local mailId = MySQL.insert.await(
        'INSERT INTO phone_mail (from_addr, to_addr, subject, body) VALUES (?,?,?,?)', {
            tostring(fromAddress or 'noreply@ls.com'):sub(1, 64), address,
            tostring(subject or ''):sub(1, 120), tostring(body or ''),
        })
    if not mailId then return false, 'x' end
    MySQL.insert.await(
        "INSERT INTO phone_mail_box (mail_id, address, folder) VALUES (?,?,'inbox')",
        { mailId, address })

    local target = Core.GetPlayerByCitizenId(toCitizenid)
    if target and target.source then
        exports[GetCurrentResourceName()]:Notify(target.source, 'mail',
            tostring(fromAddress or 'Mail'), tostring(subject or ''))
    end
    return true
end)

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
