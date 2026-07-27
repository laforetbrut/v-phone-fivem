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
    -- `kind` and `attachment` are selected, not just `body`. A picture message stores nothing
    -- in `body` - the file is in `attachment` - so a terminal that read only the body drew a
    -- row with an empty line in it, which reads as a bug rather than as evidence. A photo
    -- somebody sent is often the whole reason there is a warrant.
    local rows = MySQL.query.await([[
        SELECT m.from_cid, m.to_cid, m.body, m.kind, m.attachment, m.at,
               (m.from_cid = ?) AS outgoing,
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

-- ══════════════════════════════════════════════════════════════
-- The crack: a cryptanalysis bench
-- ══════════════════════════════════════════════════════════════
-- Reading an intercepted Cipher message is WORK. It used to be a twenty second `Wait` and a
-- dice roll, which had two problems worth naming. The obvious one: the outcome had nothing to
-- do with the officer, who watched a spinner and then read either the message or "failed",
-- with no move available in either case. The quiet one: that wait is twice the client's ten
-- second request timeout, so every single crack printed "no answer from the server after 10s"
-- and the real answer arrived to a callback that had already been dropped - the officer never
-- saw the result at all, whichever way the roll went.
--
-- Three benches now, each a different real technique, each generated per message:
--
--   substitution - a monoalphabetic cipher and a frequency table. Classical cryptanalysis.
--   xorkey       - a repeating-key XOR whose header is known. Align the key, read the text.
--   rotors       - four rotors and a system of modular constraints to satisfy.
--
-- **What the server keeps.** The answers, and only the answers. The puzzle handed over is
-- solvable and contains nothing about the seized message: the substitution phrase is a cover
-- phrase from the config, deliberately never the content, because the content is the prize.
-- The plaintext is fetched at the END, once the submitted solution has been checked HERE.
--
-- A minigame is played on a client, so a scripted client can always solve it instantly. That is
-- true of every minigame in this ecosystem and it is not pretended otherwise; what is enforced
-- is the part a client cannot fake alone - the clock (`minSeconds`), the attempt count, the
-- session, the scope, and the fact that a solution is CHECKED rather than announced.

local Cracks = {}       -- [src] = the live bench
local CrackTries = {}   -- [src] = { [messageId] = attempts spent }

local ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

local function crackCfg()
    local c = (POLICE.cipher and POLICE.cipher.crack) or {}
    return c
end

--- Letters only, uppercase. The one shape both sides compare in, so a submitted answer with
--- different spacing or case is not marked wrong for it.
local function lettersOf(text)
    return (tostring(text or ''):upper():gsub('[^A-Z]', ''))
end

--- A shuffled alphabet, and its inverse.
local function substitutionKey()
    local letters = {}
    for i = 1, #ALPHA do letters[i] = ALPHA:sub(i, i) end
    for i = #letters, 2, -1 do
        local j = math.random(i)
        letters[i], letters[j] = letters[j], letters[i]
    end
    -- A letter mapped to itself gives the puzzle away for free, so the derangement is fixed up
    -- rather than re-rolled: swapping with a neighbour cannot create a new fixed point here.
    for i = 1, #letters do
        if letters[i] == ALPHA:sub(i, i) then
            local j = (i % #letters) + 1
            letters[i], letters[j] = letters[j], letters[i]
        end
    end
    return letters
end

--- Bench one: a phrase under a monoalphabetic substitution, with a frequency table and a few
--- mappings given away. The officer assigns the rest.
local function benchSubstitution(cfg)
    local phrases = cfg.phrases
    if type(phrases) ~= 'table' or #phrases == 0 then
        phrases = { 'MEET ME BEHIND THE PIER AT MIDNIGHT' }
    end
    local phrase = tostring(phrases[math.random(#phrases)] or ''):upper()

    local key = substitutionKey()          -- plain index -> cipher letter
    local cipher, freq = {}, {}
    for i = 1, #phrase do
        local ch = phrase:sub(i, i)
        local at = ALPHA:find(ch, 1, true)
        if at then
            local enc = key[at]
            cipher[#cipher + 1] = enc
            freq[enc] = (freq[enc] or 0) + 1
        else
            cipher[#cipher + 1] = ' '
        end
    end

    -- The hints: the most frequent cipher letters, because that is where a real analyst starts
    -- and because a hint on a letter used once is not a foothold.
    local order = {}
    for letter, n in pairs(freq) do order[#order + 1] = { letter = letter, n = n } end
    table.sort(order, function(a, b)
        if a.n == b.n then return a.letter < b.letter end
        return a.n > b.n
    end)
    local given, want = {}, math.max(0, math.floor(num(cfg.hints, 4)))
    for i = 1, math.min(want, #order) do
        local enc = order[i].letter
        for at = 1, #ALPHA do
            if key[at] == enc then given[#given + 1] = { c = enc, p = ALPHA:sub(at, at) } break end
        end
    end

    -- The histogram, most frequent first, ties broken alphabetically so the table is stable.
    -- `order` is already exactly that list, so it is reused rather than sorted twice.
    local histogram = {}
    for i, row in ipairs(order) do histogram[i] = { c = row.letter, n = row.n } end

    return {
        kind = 'substitution',
        cipher = table.concat(cipher),
        freq = histogram,
        hints = given,
    }, lettersOf(phrase)
end

--- Bench two: repeating-key XOR over a known header. The key is short and the header is given,
--- so the officer turns each key byte until the decode reads as the header - which is exactly
--- how a real known-plaintext attack feels, minus the arithmetic.
local function benchXor()
    local HEADERS = { 'CIPHER-PACKET', 'SESSION-BEGIN', 'CHANNEL-OPEN', 'KEY-EXCHANGE' }
    local header = HEADERS[math.random(#HEADERS)]
    local width = math.random(3, 4)
    local key = {}
    for i = 1, width do key[i] = math.random(1, 255) end

    local bytes = {}
    for i = 1, #header do
        local plain = header:byte(i)
        -- Lua 5.4 has integer bitwise operators, and the phone's server files already rely on
        -- 5.4 elsewhere. `~` here is XOR, not unary NOT: both operands are present.
        bytes[i] = plain ~ key[((i - 1) % width) + 1]
    end

    return {
        kind = 'xorkey',
        header = header,
        width = width,
        bytes = bytes,
    }, key
end

--- Bench three: four rotors, and a system of modular constraints they must all satisfy.
---
--- Checked by RE-EVALUATING the constraints rather than by comparing against the rotors this
--- function happened to pick. A second arrangement that satisfies every clue is a correct
--- answer - the officer solved the system - and marking it wrong would be the bench lying.
local function benchRotors()
    local r = {}
    for i = 1, 4 do r[i] = math.random(0, 25) end

    local clues = {
        { op = 'sum',  a = 1, b = 3, v = (r[1] + r[3]) % 26 },
        { op = 'diff', a = 2, b = 4, v = (r[2] - r[4]) % 26 },
        { op = 'sum',  a = 1, b = 2, v = (r[1] + r[2]) % 26 },
        { op = 'total', v = r[1] + r[2] + r[3] + r[4] },
    }
    return { kind = 'rotors', rotors = 4, clues = clues }, clues
end

--- Does a submitted rotor set satisfy every clue?
local function rotorsSatisfy(clues, given)
    if type(given) ~= 'table' then return false end
    local r = {}
    for i = 1, 4 do
        local v = math.floor(num(given[i], -1))
        if v < 0 or v > 25 then return false end
        r[i] = v
    end
    for _, c in ipairs(clues) do
        if c.op == 'sum' then
            if (r[c.a] + r[c.b]) % 26 ~= c.v then return false end
        elseif c.op == 'diff' then
            if (r[c.a] - r[c.b]) % 26 ~= c.v then return false end
        elseif c.op == 'total' then
            if (r[1] + r[2] + r[3] + r[4]) ~= c.v then return false end
        end
    end
    return true
end

--- The whole bench for one message: the stages the operator asked for, in order.
local function buildBench(cfg)
    local wanted = cfg.stages
    if type(wanted) ~= 'table' then wanted = { 'substitution', 'xorkey', 'rotors' } end

    local stages, answers = {}, {}
    for _, name in ipairs(wanted) do
        local stage, answer
        if name == 'substitution' then stage, answer = benchSubstitution(cfg)
        elseif name == 'xorkey' then stage, answer = benchXor()
        elseif name == 'rotors' then stage, answer = benchRotors() end
        if stage then
            stages[#stages + 1] = stage
            answers[#answers + 1] = answer
        end
    end
    return stages, answers
end

--- The recoverable copy, unwrapped. Not stored in the clear even here: `CipherRecover`
--- reverses the server-side wrap. See main.lua.
local function plaintextOf(id)
    local row = MySQL.single.await(
        'SELECT intercept FROM vphone_cipher_messages WHERE id = ?', { id })
    if not row or not row.intercept then return nil end
    return CipherRecover and CipherRecover(row.intercept) or nil
end

--- Shared by both routes: is this message one this officer may even try?
local function crackable(src, cid, id)
    if not (POLICE.cipher and POLICE.cipher.intercept) then return nil, 'nointercept' end
    if id <= 0 then return nil, 'args' end
    local row = MySQL.single.await(
        'SELECT intercept, from_cid, to_cid FROM vphone_cipher_messages WHERE id = ?', { id })
    if not row or not row.intercept then return nil, 'norecover' end
    -- Only a message this session's target was part of, so a warrant on one suspect does
    -- not open the whole network.
    if row.from_cid ~= cid and row.to_cid ~= cid then return nil, 'scope' end
    return row
end

--- Opening the bench. Answers immediately - there is no long wait on this path at all, which
--- is the other half of the log spam going away.
V.Callback('v-phone:police:crack', function(src, resolve, data)
    local cid, err = authorise(src)
    if not cid then resolve({ error = err }) return end

    local id = math.floor(num(data and data.id, 0))
    local row, why = crackable(src, cid, id)
    if not row then resolve({ error = why }) return end

    -- ── The old route, for an operator who preferred the roll ──
    if (POLICE.cipher.minigame == false) then
        -- Capped below the client's request timeout, deliberately. A server that waits longer
        -- than the client is willing to wait does not produce a slow feature; it produces a
        -- feature that never answers.
        local seconds = math.min(math.max(0, num(POLICE.cipher.crackSeconds, 20)), 8)
        Wait(math.floor(seconds * 1000))
        if math.random() > num(POLICE.cipher.successChance, 0.6) then
            log(src, ('crack on cipher #%d FAILED'):format(id))
            resolve({ ok = true, cracked = false })
            return
        end
        log(src, ('crack on cipher #%d succeeded'):format(id))
        resolve({ ok = true, cracked = true, body = plaintextOf(id) })
        return
    end

    local cfg = crackCfg()
    local spent = (CrackTries[src] or {})[id] or 0
    local allowed = math.max(1, math.floor(num(cfg.attempts, 3)))
    if spent >= allowed then resolve({ error = 'noattempts' }) return end

    local stages, answers = buildBench(cfg)
    if #stages == 0 then
        -- An operator who emptied the stage list asked for the crack to be free. Honour it
        -- rather than handing back a bench with nothing on it.
        log(src, ('crack on cipher #%d granted (no stages configured)'):format(id))
        resolve({ ok = true, cracked = true, body = plaintextOf(id) })
        return
    end

    -- The attempt is spent HERE, when the bench opens - not when it is submitted.
    --
    -- Spending it on submission left the obvious way out: read the puzzle, close the terminal
    -- without answering, open it again and get a fresh one for free. That made `attempts` a
    -- number with nothing behind it. Charged at the door, walking away costs exactly what
    -- getting it wrong costs, which is what an attempt is supposed to mean.
    CrackTries[src] = CrackTries[src] or {}
    CrackTries[src][id] = spent + 1

    Cracks[src] = {
        id = id,
        answers = answers,
        stages = #stages,
        at = os.time(),
    }
    log(src, ('opened the bench on cipher #%d (%d stages)'):format(id, #stages))
    resolve({
        ok = true,
        bench = {
            id = id,
            stages = stages,
            seconds = math.max(20, math.floor(num(cfg.seconds, 150))),
            attemptsLeft = allowed - spent,
        },
    })
end)

--- Submitting the solution. Every stage is checked here, against what this server generated.
V.Callback('v-phone:police:cracksolve', function(src, resolve, data)
    local cid, err = authorise(src)
    if not cid then resolve({ error = err }) return end

    local bench = Cracks[src]
    if not bench then resolve({ error = 'nobench' }) return end
    local id = math.floor(num(data and data.id, 0))
    if id ~= bench.id then resolve({ error = 'nobench' }) return end

    -- Already charged when the bench opened. Consumed here so one puzzle cannot be submitted
    -- twice - and so a correct answer replayed against a new puzzle is `nobench`, not a pass.
    Cracks[src] = nil

    local cfg = crackCfg()

    -- Given up, or the clock ran out. Told apart from a wrong answer, because they are
    -- different things to an officer: one is out of time, the other is out of ideas.
    if data and data.gaveup then resolve({ ok = true, cracked = false, reason = 'gaveup' }) return end

    local floorSeconds = math.max(0, num(cfg.minSeconds, 4)) * bench.stages
    if (os.time() - bench.at) < floorSeconds then
        log(src, ('crack on cipher #%d REFUSED: solved in under %ds'):format(id, floorSeconds))
        resolve({ error = 'toofast' })
        return
    end

    local given = (data and data.answers) or {}
    for i, answer in ipairs(bench.answers) do
        local sent = given[i]
        local okStage
        if type(answer) == 'string' then
            -- Substitution: the decoded phrase, compared as letters.
            okStage = lettersOf(sent) == answer
        elseif type(answer) == 'table' and answer[1] and type(answer[1]) == 'table' then
            -- Rotors: a clue list, re-evaluated against what was submitted.
            okStage = rotorsSatisfy(answer, sent)
        else
            -- XOR: the key bytes, in order.
            okStage = type(sent) == 'table'
            if okStage then
                for k, byte in ipairs(answer) do
                    if math.floor(num(sent[k], -1)) ~= byte then okStage = false break end
                end
            end
        end
        if not okStage then
            log(src, ('crack on cipher #%d failed at stage %d'):format(id, i))
            resolve({ ok = true, cracked = false, reason = 'wrong', stage = i })
            return
        end
    end

    -- ── Solved, and the roll still stands ──
    --
    -- Both gates, on purpose. The bench is the officer's part: it can be learned, and an officer
    -- who has learned it deserves to get through it every time. `successChance` is the recovered
    -- COPY's part, and it belongs to the wiretap rather than to the person at the keyboard - a
    -- fragment can come back corrupt no matter how well the key was recovered.
    --
    -- Which is why the failure says which gate closed. "You solved it and the fragment was
    -- unusable" and "you got the key wrong" are the same screen otherwise, and an officer who
    -- cannot tell them apart learns nothing from either.
    local chance = num(POLICE.cipher.successChance, 0.6)
    if math.random() > chance then
        log(src, ('crack on cipher #%d solved, fragment CORRUPT'):format(id))
        resolve({ ok = true, cracked = false, reason = 'corrupt' })
        return
    end

    log(src, ('crack on cipher #%d SOLVED'):format(id))
    resolve({ ok = true, cracked = true, body = plaintextOf(id) })
end)

AddEventHandler('playerDropped', function()
    Sessions[source] = nil
    -- The bench and the attempt tally go with them. A source id is reused by the next player to
    -- connect, so leaving either behind hands somebody else's spent attempts to a new officer.
    Cracks[source] = nil
    CrackTries[source] = nil
end)
