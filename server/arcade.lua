-- v-phone | server/arcade.lua
--
-- **FlappyFruit: a game, and a scoreboard the whole server shares.**
--
-- One table, one row per character per game, holding their best. A leaderboard nobody else can
-- see is a high-score screen; the point of this one is that the number beside your name is
-- being read by people you will meet.
--
-- ══════════════════════════════════════════════════════════════
-- What a score is worth
-- ══════════════════════════════════════════════════════════════
-- **The game runs in a browser, so the score is written by the player's own machine.** There is
-- no version of this where that is not true. Anything sent from a NUI page can be sent by hand,
-- and a leaderboard that pretended otherwise would be lying about what it knows.
--
-- So this does not pretend. It makes the cheap lies fail and says plainly that the expensive
-- ones will not:
--
--   * a hard ceiling, so nobody is ever top of the board with 4294967295;
--   * a TIME check - a score of N needs at least N times the shortest possible gap between two
--     points to have been played. Sending 500 after four seconds is arithmetic, not skill, and
--     it is refused;
--   * one submission every few seconds per character, so the board cannot be hammered;
--   * only a personal best is kept, so a hundred junk submissions still leave one row.
--
-- What that catches is somebody opening the console and posting a number. What it does not
-- catch is somebody slowing the game down and playing it honestly-but-assisted, and nothing
-- server-side can: the frames are on their computer. This is a scoreboard, not a bank - no
-- money moves on it - and that is the reason it is allowed to be only this careful. If a server
-- ever pays out for a high score, the payout belongs behind a staff check and not behind this.

local CFG = Config.Arcade or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

local function boardSize() return math.max(3, math.min(100, math.floor(num(CFG.boardSize, 25)))) end
local function maxScore() return math.max(1, math.floor(num(CFG.maxScore, 9999))) end
local function nickMin() return math.max(1, math.min(16, math.floor(num(CFG.nickMin, 2)))) end
local function nickMax() return math.max(nickMin(), math.min(16, math.floor(num(CFG.nickMax, 12)))) end

--- The shortest time one point can honestly take, in milliseconds.
---
--- In FlappyFruit a point is one gate passed, and the gates arrive at a fixed rate - so the
--- fastest possible run is exactly that rate. Set a little under it here, because a browser
--- that dropped frames reports slightly less elapsed time than it lived through and an honest
--- player must never be told their score was impossible.
local function msPerPoint() return math.max(1, math.floor(num(CFG.msPerPoint, 900))) end

--- Seconds between two submissions from one character.
local function cooldown() return math.max(0, math.floor(num(CFG.submitCooldown, 3))) end

--- Which games exist. A name from the client is checked against this rather than stored as
--- given: the column is part of a primary key, and a client that could invent game names could
--- fill the table with them.
local GAMES = { flappy = true }

local function knownGame(g)
    g = tostring(g or ''):lower():gsub('[^%a]', '')
    return GAMES[g] and g or nil
end

--- A nickname. Letters, digits, spaces and a few marks people actually use, trimmed.
---
--- Deliberately NOT the character's name: this is an arcade board, and somebody who wants to be
--- `xX_Fruit_Xx` on it is doing exactly what an arcade board is for. The row still carries the
--- citizenid, so staff can always tell who a name belongs to.
local function cleanNick(raw)
    local nick = tostring(raw or '')
        :gsub('%c', '')
        :gsub('[^%w%s%-%_%.]', '')
        :gsub('^%s+', ''):gsub('%s+$', '')
        :gsub('%s+', ' ')
    return nick:sub(1, nickMax())
end

CreateThread(function()
    if not enabled() then return end
    Wait(700)
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_arcade_scores` (
        `citizenid` VARCHAR(64)  NOT NULL,
        `game`      VARCHAR(16)  NOT NULL DEFAULT 'flappy',
        `nick`      VARCHAR(16)  NOT NULL DEFAULT '',
        `score`     INT UNSIGNED NOT NULL DEFAULT 0,
        `plays`     INT UNSIGNED NOT NULL DEFAULT 0,
        `at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        -- One row per character per game: the board holds bests, not attempts, so a hundred
        -- junk submissions still leave exactly one row behind.
        PRIMARY KEY (`citizenid`, `game`),
        KEY `board` (`game`, `score`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

-- ══════════════════════════════════════════════════════════════
-- Reading
-- ══════════════════════════════════════════════════════════════

local function rowOf(cid, game)
    return MySQL.single.await(
        'SELECT nick, score, plays FROM vphone_arcade_scores WHERE citizenid = ? AND game = ?',
        { cid, game })
end

local function board(game, cid)
    local rows = MySQL.query.await([[SELECT nick, score, citizenid, at
        FROM vphone_arcade_scores
        WHERE game = ? AND score > 0
        ORDER BY score DESC, at ASC
        LIMIT ?]], { game, boardSize() }) or {}

    local out = {}
    for i, r in ipairs(rows) do
        out[#out + 1] = {
            rank = i,
            -- A row whose owner never set one shows as unnamed rather than as their citizen id.
            nick = tostring(r.nick or ''),
            score = math.floor(num(r.score, 0)),
            mine = r.citizenid == cid,
            ts = r.at,
        }
    end
    return out
end

--- Where somebody sits when they are not in the top N.
---
--- Counted rather than read off the list: a player at 300th has no row in the twenty-five above
--- them, and "you are not on the board" is a worse answer than "you are 300th".
local function rankOf(cid, game, score)
    if score <= 0 then return nil end
    local better = MySQL.scalar.await(
        'SELECT COUNT(*) FROM vphone_arcade_scores WHERE game = ? AND score > ?',
        { game, score })
    return math.floor(num(better, 0)) + 1
end

V.Callback('v-phone:arcade:open', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid

    local game = knownGame(data and data.game) or 'flappy'
    local mine = rowOf(cid, game)
    local best = mine and math.floor(num(mine.score, 0)) or 0

    resolve({
        ok = true,
        game = game,
        nick = mine and tostring(mine.nick or '') or '',
        best = best,
        plays = mine and math.floor(num(mine.plays, 0)) or 0,
        rank = rankOf(cid, game, best),
        board = board(game, cid),
        limits = {
            nickMin = nickMin(), nickMax = nickMax(),
            boardSize = boardSize(), maxScore = maxScore(),
        },
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Writing
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:arcade:nick', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local game = knownGame(data and data.game) or 'flappy'
    local nick = cleanNick(data and data.nick)
    if #nick < nickMin() then resolve({ error = 'nick' }) return end

    -- Upserted rather than updated: somebody may choose a name before they have ever played,
    -- which is the ordinary way round.
    MySQL.query.await([[INSERT INTO vphone_arcade_scores (citizenid, game, nick, score)
        VALUES (?,?,?,0) ON DUPLICATE KEY UPDATE nick = VALUES(nick)]],
        { p.citizenid, game, nick })
    resolve({ ok = true, nick = nick })
end)

-- One submission per character every few seconds. Cheap, and it stops the board being hammered
-- by something in a loop.
local lastSubmit = {}

V.Callback('v-phone:arcade:score', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid
    data = data or {}

    local game = knownGame(data.game) or 'flappy'
    local score = math.floor(num(data.score, 0))
    if score < 0 then resolve({ error = 'score' }) return end

    -- The ceiling. Nobody is ever top of the board with a number nothing could have produced.
    if score > maxScore() then resolve({ error = 'toobig', max = maxScore() }) return end

    -- The time check, and the reason this file has a `msPerPoint` at all. A run that scored N
    -- has to have lasted at least as long as N gates take to arrive; anything shorter did not
    -- happen. `ms` is the client's own clock, which a determined cheat can also lie about -
    -- but it has to lie about BOTH numbers consistently now, which is a different job from
    -- pasting a big one.
    local ms = math.floor(num(data.ms, 0))
    if score > 0 and ms < score * msPerPoint() then
        resolve({ error = 'impossible' }) return
    end

    local now = os.time()
    if lastSubmit[cid] and now - lastSubmit[cid] < cooldown() then
        resolve({ error = 'toosoon' }) return
    end
    lastSubmit[cid] = now

    local nick = cleanNick(data.nick)
    local existing = rowOf(cid, game)
    local best = existing and math.floor(num(existing.score, 0)) or 0

    -- `GREATEST` rather than a comparison here: two runs finishing at once would otherwise
    -- race, and the lower one could land last and overwrite the higher.
    MySQL.query.await([[INSERT INTO vphone_arcade_scores (citizenid, game, nick, score, plays)
        VALUES (?,?,?,?,1)
        ON DUPLICATE KEY UPDATE
            score = GREATEST(score, VALUES(score)),
            plays = plays + 1,
            nick = IF(VALUES(nick) = '', nick, VALUES(nick))]],
        { cid, game, nick, score })

    local fresh = rowOf(cid, game)
    local newBest = fresh and math.floor(num(fresh.score, 0)) or score

    resolve({
        ok = true,
        best = newBest,
        beaten = score > best,
        rank = rankOf(cid, game, newBest),
        board = board(game, cid),
    })
end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════

--- The top of the board, for a script that wants to put it on a screen somewhere in the city.
---
---     local top = exports['v-phone']:GetArcadeBoard('flappy', 10)
exports('GetArcadeBoard', function(game, limit)
    if not enabled() then return {} end
    local one = knownGame(game) or 'flappy'
    local rows = MySQL.query.await([[SELECT nick, score FROM vphone_arcade_scores
        WHERE game = ? AND score > 0 ORDER BY score DESC, at ASC LIMIT ?]],
        { one, math.max(1, math.min(100, math.floor(num(limit, 10)))) }) or {}
    local out = {}
    for i, r in ipairs(rows) do
        out[#out + 1] = { rank = i, nick = tostring(r.nick or ''), score = math.floor(num(r.score, 0)) }
    end
    return out
end)

--- Wipe the board, for a server that runs seasons.
---
---     exports['v-phone']:ResetArcadeBoard('flappy')
---
--- Deliberately not on a timer and not run by an update: it is somebody else's leaderboard.
exports('ResetArcadeBoard', function(game)
    local one = knownGame(game)
    if not one then return 0 end
    return math.floor(num(MySQL.update.await(
        'UPDATE vphone_arcade_scores SET score = 0 WHERE game = ?', { one }), 0))
end)
