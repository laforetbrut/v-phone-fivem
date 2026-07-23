-- v-phone | server/police.lua
--
-- **The warrant terminal.**
--
-- Police, standing at a forensics point, read what is on a target's phone. Everything
-- the phone stores in the clear is theirs: texts, contacts, the call log, mail, social
-- posts and DMs. Cipher is end-to-end encrypted and the server holds no key, so the
-- terminal gives its metadata and, only if the operator opted into lawful intercept, a
-- deliberately slow crack of the content.
--
-- Two gates guard every read, and both are checked on the SERVER on every call, never
-- trusted from the client:
--
--  1. the caller is in a police job at or above the configured rank,
--  2. the caller has an OPEN session, started at a terminal within the last few minutes.
--
-- A client that forged either would still be re-checked here and refused.

local POLICE = Config.Police or {}
local function num(v, d) return tonumber(v) or d or 0 end

local Sessions = {}     -- [src] = { target = cid, at = os.time() }

-- ══════════════════════════════════════════════════════════════
-- Authorisation
-- ══════════════════════════════════════════════════════════════
local function isOfficer(p)
    if not p or not p.job then return false end
    local jobs = POLICE.jobs or {}
    for _, name in ipairs(jobs) do
        if p.job.name == name then
            return num(p.job.grade, 0) >= num(POLICE.minGrade, 0)
        end
    end
    return false
end

--- A live session, or nil. Expired sessions are cleared here so nothing else has to.
local function sessionOf(src)
    local s = Sessions[src]
    if not s then return nil end
    if os.time() - s.at > num(POLICE.sessionSeconds, 300) then
        Sessions[src] = nil
        return nil
    end
    return s
end

--- The one guard every forensic read runs first. Returns the session's target cid, or
--- nil plus the reason the read is refused.
local function authorise(src)
    if not POLICE.enabled then return nil, 'off' end
    local p = Core.GetPlayer(src)
    if not p then return nil, 'noplayer' end
    if not isOfficer(p) then return nil, 'unauthorised' end
    local s = sessionOf(src)
    if not s or not s.target then return nil, 'nosession' end
    return s.target, nil
end

local function log(src, message)
    if not POLICE.log then return end
    local p = Core.GetPlayer(src)
    print(('[v-phone] forensics: %s (%s) %s'):format(
        p and p.name or '?', p and p.citizenid or src, message))
    if Core.Log then Core.Log('forensics', message, nil, p and p.citizenid) end
end

-- ══════════════════════════════════════════════════════════════
-- Starting a session
-- ══════════════════════════════════════════════════════════════
-- The client asks to open a session against a number. The server verifies the officer is
-- genuinely near a terminal (it has their coords), resolves the number to a citizen, and
-- opens the session. The number is how police address a suspect; the citizen id stays on
-- the server.
V.Callback('v-phone:police:start', function(src, resolve, data)
    if not POLICE.enabled then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    if not isOfficer(p) then resolve({ error = 'unauthorised' }) return end

    -- Near a terminal? The ped's coordinates are the server's, not a claim from the page.
    local ped = GetPlayerPed(src)
    local coords = ped and GetEntityCoords(ped)
    local near = false
    if coords then
        for _, pt in ipairs(POLICE.points or {}) do
            if #(coords - vector3(pt.x + 0.0, pt.y + 0.0, pt.z + 0.0)) <= (pt.radius or 2.0) + 2.0 then
                near = true
                break
            end
        end
    end
    if not near then resolve({ error = 'notatterminal' }) return end

    -- Optional forensic-kit item.
    if POLICE.item and GetResourceState(GetCurrentResourceName()) == 'started' then
        if not Bridge.HasItem(src, POLICE.item) then resolve({ error = 'noitem' }) return end
    end

    local number = tostring((data and data.number) or ''):gsub('%s', '')
    if number == '' then resolve({ error = 'nonumber' }) return end
    local targetCid = Bridge.Numbers.Owner(number)
    if not targetCid then resolve({ error = 'unknownnumber' }) return end

    Sessions[src] = { target = targetCid, at = os.time() }
    log(src, ('opened a session on %s (%s)'):format(number, targetCid))

    resolve({
        ok = true,
        number = number,
        name = Bridge.NameOfCitizen(targetCid) or number,
        expires = num(POLICE.sessionSeconds, 300),
    })
end)

V.Callback('v-phone:police:end', function(src, resolve)
    Sessions[src] = nil
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- The reads
-- ══════════════════════════════════════════════════════════════

--- Texts, both directions, newest first. Content in the clear, because SMS is.
V.Callback('v-phone:police:messages', function(src, resolve)
    local cid, err = authorise(src)
    if not cid then resolve({ error = err }) return end
    log(src, 'read messages')
    local rows = MySQL.query.await([[
        SELECT m.from_cid, m.to_cid, m.body, m.at, (m.from_cid = ?) AS outgoing,
               cf.phone AS from_num, ct.phone AS to_num
        FROM vphone_messages m
        LEFT JOIN vphone_characters cf ON cf.citizenid = m.from_cid
        LEFT JOIN vphone_characters ct ON ct.citizenid = m.to_cid
        WHERE (m.from_cid = ? OR m.to_cid = ?) AND m.group_id IS NULL
        ORDER BY m.id DESC LIMIT 500
    ]], { cid, cid, cid }) or {}
    for _, r in ipairs(rows) do r.outgoing = num(r.outgoing, 0) == 1 end
    resolve({ ok = true, rows = rows })
end)

V.Callback('v-phone:police:contacts', function(src, resolve)
    local cid, err = authorise(src)
    if not cid then resolve({ error = err }) return end
    log(src, 'read contacts')
    resolve({ ok = true, rows = MySQL.query.await(
        'SELECT name, number, favourite FROM vphone_contacts WHERE citizenid = ? ORDER BY name',
        { cid }) or {} })
end)

V.Callback('v-phone:police:calls', function(src, resolve)
    local cid, err = authorise(src)
    if not cid then resolve({ error = err }) return end
    log(src, 'read call log')
    resolve({ ok = true, rows = MySQL.query.await([[
        SELECT other_num, direction, answered, at FROM vphone_calls
        WHERE citizenid = ? ORDER BY id DESC LIMIT 200]], { cid }) or {} })
end)

V.Callback('v-phone:police:social', function(src, resolve)
    local cid, err = authorise(src)
    if not cid then resolve({ error = err }) return end
    log(src, 'read social')
    local posts = MySQL.query.await([[SELECT app, kind, body, image, at
        FROM vphone_social_posts WHERE citizenid = ? ORDER BY id DESC LIMIT 100]], { cid }) or {}
    local dms = MySQL.query.await([[
        SELECT d.app, d.body, d.image, d.at, (d.from_cid = ?) AS outgoing,
               af.handle AS from_handle, at2.handle AS to_handle
        FROM vphone_social_dm d
        LEFT JOIN vphone_social_accounts af ON af.citizenid = d.from_cid AND af.app = d.app
        LEFT JOIN vphone_social_accounts at2 ON at2.citizenid = d.to_cid AND at2.app = d.app
        WHERE d.from_cid = ? OR d.to_cid = ?
        ORDER BY d.id DESC LIMIT 200]], { cid, cid, cid }) or {}
    for _, r in ipairs(dms) do r.outgoing = num(r.outgoing, 0) == 1 end
    resolve({ ok = true, posts = posts, dms = dms })
end)

-- ══════════════════════════════════════════════════════════════
-- Cipher
-- ══════════════════════════════════════════════════════════════
-- The honest part. The metadata is real and always available. The content is end-to-end
-- encrypted and the server has no key, so unless lawful intercept was on when the message
-- was sent, there is nothing to recover and the terminal says so plainly.
V.Callback('v-phone:police:cipher', function(src, resolve)
    local cid, err = authorise(src)
    if not cid then resolve({ error = err }) return end
    log(src, 'pulled cipher metadata')

    local intercept = (POLICE.cipher and POLICE.cipher.intercept) == true

    local rows = MySQL.query.await(([[
        SELECT m.id, m.from_cid, m.to_cid, m.at, (m.from_cid = ?) AS outgoing,
               pf.handle AS from_handle, pt.handle AS to_handle,
               pf.fingerprint AS from_fp, pt.fingerprint AS to_fp%s
        FROM vphone_cipher_messages m
        LEFT JOIN vphone_cipher_profiles pf ON pf.citizenid = m.from_cid
        LEFT JOIN vphone_cipher_profiles pt ON pt.citizenid = m.to_cid
        WHERE m.from_cid = ? OR m.to_cid = ?
        ORDER BY m.id DESC LIMIT 200
    ]]):format(intercept and ', m.intercept IS NOT NULL AS recoverable' or ', 0 AS recoverable'),
        { cid, cid, cid }) or {}
    for _, r in ipairs(rows) do
        r.outgoing = num(r.outgoing, 0) == 1
        r.recoverable = num(r.recoverable, 0) == 1
        -- The content never leaves the server here. Cracking is a second, costly step.
    end
    resolve({
        ok = true,
        rows = rows,
        interceptOn = intercept,   -- the terminal tells the officer whether a crack is even possible
    })
end)

--- The crack. Only meaningful when intercept is on and the message has a recoverable
--- copy. It is deliberately slow and can fail, so reading a Cipher thread is a project,
--- not a click.
V.Callback('v-phone:police:crack', function(src, resolve, data)
    local cid, err = authorise(src)
    if not cid then resolve({ error = err }) return end
    if not (POLICE.cipher and POLICE.cipher.intercept) then resolve({ error = 'noindercept' }) return end

    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve({ error = 'args' }) return end

    local row = MySQL.single.await(
        'SELECT intercept, from_cid, to_cid FROM vphone_cipher_messages WHERE id = ?', { id })
    if not row or not row.intercept then resolve({ error = 'norecover' }) return end
    -- Only a message this session's target was part of, so a warrant on one suspect does
    -- not open the whole network.
    if row.from_cid ~= cid and row.to_cid ~= cid then resolve({ error = 'scope' }) return end

    -- The cost: real seconds of work, and a roll that can miss. The wait is on the
    -- server so a client cannot skip it.
    Wait(math.floor(num(POLICE.cipher.crackSeconds, 20) * 1000))
    if math.random() > num(POLICE.cipher.successChance, 0.6) then
        log(src, ('crack on cipher #%d FAILED'):format(id))
        resolve({ ok = true, cracked = false })
        return
    end

    -- The recoverable copy is unwrapped by the phone, not stored in the clear even here:
    -- CipherRecover reverses the server-side wrap. See main.lua.
    local plain = CipherRecover and CipherRecover(row.intercept) or nil
    log(src, ('crack on cipher #%d succeeded'):format(id))
    resolve({ ok = true, cracked = true, body = plain })
end)

AddEventHandler('playerDropped', function() Sessions[source] = nil end)
