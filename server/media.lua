-- v-phone | server/media.lua
--
-- **Photo and video hosting, on the server, with the key kept server-side.**
--
-- The camera's photos and the social apps' clips are captured and uploaded through the
-- `screencapture` resource (https://github.com/itschip/screencapture), which does the
-- capture in the player's NUI and streams it to the server, so the CDN API key is never
-- handed to a client.
--
-- Everything this file uploads is written to `vphone_media` with a delete date, and swept
-- when that date passes: the row goes and, if the host can be told, the file goes with it.
-- A player's media is theirs for exactly as long as the operator configured, and no
-- longer.
--
-- All of it is optional. With `Config.Media.enabled` off, the camera keeps taking local
-- gallery photos and video recording is simply not offered.

local MEDIA = Config.Media or {}
local function num(v, d) return tonumber(v) or d or 0 end

-- ══════════════════════════════════════════════════════════════
-- Availability
-- ══════════════════════════════════════════════════════════════
local function mediaOn()
    return MEDIA.enabled == true and GetResourceState('screencapture') == 'started'
end

Bridge = Bridge or {}
function Bridge.MediaEnabled() return mediaOn() end
function Bridge.MediaVideoEnabled()
    return mediaOn() and MEDIA.video ~= nil
end

local function apiKey()
    local convar = GetConvar('phone_media_key', '')
    if convar ~= '' then return convar end
    return tostring(MEDIA.apiKey or '')
end

--- The headers an upload carries. Fivemanage authenticates with the key in Authorization;
--- a custom provider gets whatever the config listed.
local function uploadHeaders()
    if MEDIA.provider == 'fivemanage' then
        return { ['Authorization'] = apiKey() }
    end
    local h = {}
    for k, v in pairs(MEDIA.headers or {}) do h[k] = v end
    if apiKey() ~= '' and not h['Authorization'] then h['Authorization'] = apiKey() end
    return h
end

-- ══════════════════════════════════════════════════════════════
-- Recording an upload for later deletion
-- ══════════════════════════════════════════════════════════════
local function remember(citizenid, url, kind, extra)
    if not url or url == '' then return end
    local days = num(MEDIA.autoDeleteDays, 0)
    local deleteAt = days > 0 and (os.time() + days * 86400) or nil
    MySQL.insert([[INSERT INTO vphone_media (citizenid, url, media_id, kind, delete_at)
        VALUES (?,?,?,?,IF(? IS NULL, NULL, FROM_UNIXTIME(?)))]], {
        tostring(citizenid or ''), url, (extra and extra.id) or nil,
        kind, deleteAt, deleteAt or 0,
    })
end

--- Pull the host's own id for a file out of its upload response, so a delete later can
--- name it. Fivemanage returns it under data; a custom host may differ.
local function idFromResponse(resp)
    if type(resp) ~= 'table' then return nil end
    local data = resp.data or resp
    if type(data) ~= 'table' then return nil end
    return data.id or data.fileId or data.key
end

local function urlFromResponse(resp)
    if type(resp) ~= 'table' then return nil end
    local data = resp.data or resp
    if type(data) == 'table' then return data.url or data.link or data.fileUrl end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Photo: capture and upload
-- ══════════════════════════════════════════════════════════════
-- The camera calls this. It captures the player's screen through screencapture, uploads
-- it, and hands back the URL, which the gallery stores like any photo.
V.Callback('v-phone:media:photo', function(src, resolve)
    if not mediaOn() then resolve({ error = 'off' }) return end
    if apiKey() == '' and MEDIA.provider == 'fivemanage' then resolve({ error = 'nokey' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    -- screencapture's server export uploads for us and calls back with the host response.
    local done = false
    exports['screencapture']:remoteUpload(src, MEDIA.endpoint, {
        encoding = MEDIA.imageEncoding or 'webp',
        headers = uploadHeaders(),
        formField = MEDIA.formField or 'file',
    }, function(response)
        if done then return end
        done = true
        local url = urlFromResponse(response)
        if not url then resolve({ error = 'upload' }) return end
        remember(p.citizenid, url, 'image', { id = idFromResponse(response) })
        resolve({ ok = true, url = url })
    end)

    -- A capture that never calls back must not hang the caller for ever.
    SetTimeout(15000, function()
        if not done then done = true; resolve({ error = 'timeout' }) end
    end)
end)

-- ══════════════════════════════════════════════════════════════
-- Video: record for N seconds, upload, return the URL
-- ══════════════════════════════════════════════════════════════
-- The record button calls this with a duration. It is clamped to the config ceiling so a
-- client cannot ask for a ten-minute recording. screencapture records in the NUI, streams
-- to the server, uploads the finished WebM and cleans up its temp file.
V.Callback('v-phone:media:video', function(src, resolve, data)
    if not Bridge.MediaVideoEnabled() then resolve({ error = 'off' }) return end
    if apiKey() == '' and MEDIA.provider == 'fivemanage' then resolve({ error = 'nokey' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local cap = math.max(1, math.min(30, num(MEDIA.video and MEDIA.video.maxSeconds, 15)))
    local seconds = math.max(1, math.min(cap, math.floor(num(data and data.seconds, cap))))

    local done = false
    exports['screencapture']:startVideoCaptureUpload(src, MEDIA.endpoint, {
        duration = seconds,
        maxWidth = num(MEDIA.video and MEDIA.video.maxWidth, 1280),
        maxHeight = num(MEDIA.video and MEDIA.video.maxHeight, 720),
        headers = uploadHeaders(),
        formField = MEDIA.formField or 'file',
    }, function(result)
        if done then return end
        done = true
        if not result or result.error then resolve({ error = result and result.error or 'capture' }) return end
        local url = urlFromResponse(result.response) or urlFromResponse(result)
        if not url then resolve({ error = 'upload' }) return end
        remember(p.citizenid, url, 'video', { id = idFromResponse(result.response) })
        resolve({ ok = true, url = url, seconds = seconds })
    end)

    -- Recording plus upload can take a while; the timeout is the clip length plus slack.
    SetTimeout((seconds + 25) * 1000, function()
        if not done then done = true; resolve({ error = 'timeout' }) end
    end)
end)

-- ══════════════════════════════════════════════════════════════
-- Auto-deletion
-- ══════════════════════════════════════════════════════════════
local function deleteFromHost(url, mediaId)
    local endpoint = MEDIA.deleteEndpoint
    if not endpoint or endpoint == '' then return end
    if not mediaId and endpoint:find('{id}', 1, true) then return end   -- cannot name it

    endpoint = endpoint:gsub('{id}', tostring(mediaId or '')):gsub('{url}', tostring(url or ''))
    PerformHttpRequest(endpoint, function() end,
        (MEDIA.deleteMethod or 'DELETE'), '', uploadHeaders())
end

--- Sweep expired media: drop the row, and delete the file from the host when it can be
--- named. Runs at boot and then hourly.
function Bridge.MediaSweep()
    if MEDIA.autoDeleteDays == nil or num(MEDIA.autoDeleteDays, 0) <= 0 then return 0 end
    local rows = MySQL.query.await(
        'SELECT id, url, media_id FROM vphone_media WHERE delete_at IS NOT NULL AND delete_at <= NOW() LIMIT 200') or {}
    for _, r in ipairs(rows) do
        deleteFromHost(r.url, r.media_id)
        MySQL.query.await('DELETE FROM vphone_media WHERE id = ?', { r.id })
    end
    if #rows > 0 then print(('[v-phone] media: swept %d expired file(s)'):format(#rows)) end
    return #rows
end

function Bridge.MediaBoot()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_media` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(64) NOT NULL,
        `url`       VARCHAR(400) NOT NULL,
        `media_id`  VARCHAR(128) NULL,
        `kind`      VARCHAR(8) NOT NULL DEFAULT 'image',
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        `delete_at` TIMESTAMP NULL DEFAULT NULL,
        PRIMARY KEY (`id`),
        KEY `owner` (`citizenid`, `id`),
        KEY `expiry` (`delete_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    Bridge.MediaSweep()
    CreateThread(function()
        while true do
            Wait(60 * 60 * 1000)
            Bridge.MediaSweep()
        end
    end)
end
