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
    -- `set phone_media true` in server.cfg, same as every other setting in this resource.
    -- Media hosting is the one feature whose configuration is genuinely sensitive - it
    -- carries an API key - so it should be switchable from the file that already holds the
    -- key, without editing a tracked config.lua to turn it on.
    --
    -- The convar wins when set; otherwise Config.Media.enabled decides. Off either way
    -- leaves the camera taking local gallery photos and hides video recording.
    local convar = GetConvar('phone_media', '')
    local on = MEDIA.enabled == true
    if convar ~= '' then on = (convar == 'true' or convar == '1') end

    return on and GetResourceState('screencapture') == 'started'
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

-- Say what the camera is going to do, once, at startup. The Camera app spent a long time
-- reporting "disabled on this server" while the operator had switched it on, and nothing
-- anywhere said which of the three things was actually missing: the setting, the capture
-- resource, or the upload target. One line closes that.
CreateThread(function()
    Wait(3000)
    if not V.SettingBool('camera', true) then
        print('[v-phone] camera: OFF (Config.Settings.camera / set phone_camera true)')
        return
    end
    if mediaOn() then
        print(('[v-phone] camera: on, uploading through screencapture (%s), video %s')
            :format(tostring(MEDIA.provider or 'custom'),
                    MEDIA.video and 'on' or 'off (Config.Media.video)'))
        if apiKey() == '' then
            print('[v-phone] camera: no API key. Set `phone_media_key` or uploads will fail.')
        end
        return
    end
    local target = tostring(V.Setting('cameraUpload', '') or '')
    if GetResourceState('screencapture') == 'started' then
        print('[v-phone] camera: on. screencapture is running but media hosting is off - `set phone_media true` to use it.')
    elseif target ~= '' then
        print('[v-phone] camera: on, uploading through screenshot-basic to the configured target.')
    else
        print('[v-phone] camera: on, but nowhere to put a photo. Set Config.Media (with screencapture) or `phone_cameraUpload`.')
    end
end)

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
-- When an upload fails, say what usually causes it
-- ══════════════════════════════════════════════════════════════
-- The player is told "it did not upload", which is all they can act on. The OPERATOR is the one
-- who can fix it, and until now the only thing in the console was screencapture's own stack
-- trace - accurate, and silent about which of the three usual causes it was.
--
-- Throttled hard: an upload that fails once fails for everybody, and a line per attempt is a
-- log nobody reads.
local lastTrouble = 0

local function uploadTrouble(reason)
    local now = GetGameTimer()
    if lastTrouble ~= 0 and (now - lastTrouble) < 300000 then return end
    lastTrouble = now
    print(('[v-phone] media: an upload failed (%s).'):format(tostring(reason or 'unknown')))
    print('[v-phone] media: the three usual causes, in order of likelihood - the API key is '
          .. 'rejected, the account is out of quota, or the file is larger than the plan '
          .. 'allows.')
    print('[v-phone] media: `write EPIPE` from the host means it closed the connection part '
          .. 'way through the upload. That is nearly always the key. Check `phone_media_key`.')
end

-- ══════════════════════════════════════════════════════════════
-- One upload at a time, and a floor between them
-- ══════════════════════════════════════════════════════════════
-- Every upload below spends the OPERATOR'S quota, with the operator's key, and on a paid plan
-- the operator's money. Neither callback had a rate limit nor an in-flight guard, so a loop was
-- a bill. This is the same arrangement server/gifs.lua uses for the search field, and for the
-- same reason: the thing being spent does not belong to the player spending it.
--
-- Two seconds is far below anything a person does with a camera - a shot, look at it, another -
-- and far above what a loop needs to be useless.
local Uploading, UploadLast = {}, {}
local UPLOAD_EVERY = 2000

--- May this player start an upload? Returns false and the reason, or true and a release
--- function that must be called on every exit path.
local function takeUploadSlot(src)
    if Uploading[src] then return false, 'busy' end
    local now = GetGameTimer()
    if UploadLast[src] and (now - UploadLast[src]) < UPLOAD_EVERY then return false, 'toosoon' end
    Uploading[src] = true
    UploadLast[src] = now
    return true, function() Uploading[src] = nil end
end

AddEventHandler('playerDropped', function()
    Uploading[source] = nil
    UploadLast[source] = nil
end)

-- ══════════════════════════════════════════════════════════════
-- Photo: capture and upload
-- ══════════════════════════════════════════════════════════════
-- The camera calls this. It captures the player's screen through screencapture, uploads
-- it, and hands back the URL, which the gallery stores like any photo.
V.Callback('v-phone:media:photo', function(src, resolve)
    if not mediaOn() then resolve({ error = 'off' }) return end
    if apiKey() == '' and MEDIA.provider == 'fivemanage' then resolve({ error = 'nokey' }) return end
    -- The resource that does the capturing. Without it there is no callback to wait for, and
    -- waiting anyway is what put "no answer from the server after 10s" in the console: an
    -- absent dependency should be an answer, not a silence.
    if GetResourceState('screencapture') ~= 'started' then resolve({ error = 'noupload' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local allowed, release = takeUploadSlot(src)
    if not allowed then resolve({ error = release }) return end
    -- Four exits from here - the upload failed, it worked, the capture resource never answered,
    -- the timeout fired - and the slot has to come back on all of them. Wrapping `resolve` is
    -- the only arrangement where a path added later cannot forget.
    do
        local answer = resolve
        resolve = function(res) release(); answer(res) end
    end

    -- screencapture's server export uploads for us and calls back with the host response.
    local done = false
    -- The fifth argument is the one that matters, and leaving it off is why every upload
    -- came back `400 request Content-Type isn't multipart/form-data`.
    --
    -- screencapture's `remoteUpload(source, url, options, callback, dataType)` defaults
    -- dataType to 'base64', and its `createRequestBody` only builds a FormData - the only
    -- path that sets a multipart Content-Type - when dataType is 'blob'. On 'base64' it posts
    -- the raw string with nothing but our own headers, which Fivemanage rightly rejects.
    -- Guarded. An export that throws - a screencapture build whose signature moved, a client
    -- that dropped mid-capture - never reaches its callback, and an unguarded call takes the
    -- error with it, leaving the caller waiting on a request that can no longer be answered.
    -- **Armed before the call it protects, not after it.** An export that throws unwinds
    -- past everything below it, and a timeout registered down there would never have been
    -- registered at all - so the one failure the guard exists for is the one it misses.
    SetTimeout(8000, function()
        if not done then done = true; uploadTrouble('timeout'); resolve({ error = 'timeout' }) end
    end)

    local started = pcall(function()
    exports['screencapture']:remoteUpload(src, MEDIA.endpoint, {
        encoding = MEDIA.imageEncoding or 'webp',
        headers = uploadHeaders(),
        formField = MEDIA.formField or 'file',
    }, function(response)
        if done then return end
        done = true
        local url = urlFromResponse(response)
        if not url then uploadTrouble('no url in the response'); resolve({ error = 'upload' }) return end
        remember(p.citizenid, url, 'image', { id = idFromResponse(response) })

        -- Store it here rather than sending the client back round through `v-phone:photo`
        -- with op=add. That path runs every URL past the WALLPAPER host allowlist - which
        -- exists to stop a player pasting an arbitrary link, and which naturally does not
        -- list whichever CDN the operator uploads to. So every photo the phone took was
        -- refused as `badhost` and the gallery stayed empty.
        --
        -- This URL needs no allowlist: the server produced it, seconds ago, from this
        -- player's own capture. Nothing was taken on trust.
        local shots = p.GetMetadata('photos')
        if type(shots) ~= 'table' then shots = {} end
        table.insert(shots, 1, { url = url, album = '', filter = '' })
        while #shots > 60 do table.remove(shots) end
        -- Waited on: a photo is data the player just made, and a fire-and-forget write
        -- is lost if the server goes down before the query lands.
        p.SetMetadataSync('photos', shots)

        resolve({ ok = true, url = url, stored = true })
    end, 'blob')
    end)

    if not started then
        if not done then done = true; resolve({ error = 'noupload' }) end
    end
end)

-- The timeout above is eight seconds and that is deliberate: **under the caller's own patience,
-- not over it.** It was fifteen once, against a request that gives up at ten, so the guard could
-- only ever fire after the client had already printed "no answer from the server" - the one line
-- it exists to prevent.

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

    -- A video is a bigger upload than a photograph and the same quota. Same slot.
    local vAllowed, vRelease = takeUploadSlot(src)
    if not vAllowed then resolve({ error = vRelease }) return end
    do
        local answer = resolve
        resolve = function(res) vRelease(); answer(res) end
    end

    local cap = math.max(1, math.min(30, num(MEDIA.video and MEDIA.video.maxSeconds, 15)))
    local seconds = math.max(1, math.min(cap, math.floor(num(data and data.seconds, cap))))

    local done = false

    -- **Armed first, and the export guarded.** Neither was true here, and the pair of
    -- omissions cost more than a lost clip: `startVideoCaptureUpload` throwing unwound past the
    -- SetTimeout that used to sit below it, so the timeout was never registered and the wrapped
    -- `resolve` that gives the upload slot back was never called. `Uploading[src]` stayed true
    -- until that player disconnected and every later upload answered `busy` - a camera that
    -- stops working for the rest of the session, with nothing said. The photo path above has
    -- been guarded since it was written; this one was simply missed.
    SetTimeout((seconds + 25) * 1000, function()
        if not done then done = true; uploadTrouble('video timeout'); resolve({ error = 'timeout' }) end
    end)

    local vStarted = pcall(function()
    exports['screencapture']:startVideoCaptureUpload(src, MEDIA.endpoint, {
        duration = seconds,
        maxWidth = num(MEDIA.video and MEDIA.video.maxWidth, 1280),
        maxHeight = num(MEDIA.video and MEDIA.video.maxHeight, 720),
        headers = uploadHeaders(),
        formField = MEDIA.formField or 'file',
    }, function(result)
        if done then return end
        done = true
        if not result or result.error then
            uploadTrouble(result and result.error or 'capture')
            resolve({ error = result and result.error or 'capture' })
            return
        end
        local url = urlFromResponse(result.response) or urlFromResponse(result)
        if not url then uploadTrouble('no url in the response'); resolve({ error = 'upload' }) return end
        remember(p.citizenid, url, 'video', { id = idFromResponse(result.response) })
        resolve({ ok = true, url = url, seconds = seconds })
    end)
    end)

    if not vStarted then
        if not done then done = true; resolve({ error = 'noupload' }) end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Asking the host directly
-- ══════════════════════════════════════════════════════════════
-- **A one-pixel PNG, valid enough to be decoded.**
--
-- Small enough that "the file was too big" cannot be the answer, and a real image so a host
-- that inspects the bytes is not refusing it for being nonsense. The checksums are computed
-- rather than stubbed: a file with a wrong CRC is rejected as a broken file, and the test
-- would then report a refused KEY while the host was complaining about the picture - which is
-- exactly the confusion this command exists to remove.
local CRC_TABLE
local function crc32(str)
    if not CRC_TABLE then
        CRC_TABLE = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
            end
            CRC_TABLE[i] = c
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #str do
        crc = CRC_TABLE[(crc ~ str:byte(i)) & 0xFF] ~ (crc >> 8)
    end
    return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

local function adler32(str)
    local a, b = 1, 0
    for i = 1, #str do
        a = (a + str:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

local function onePixelPng()
    local function be32(n)
        n = math.floor(n) % 4294967296
        return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
                           math.floor(n / 256) % 256, n % 256)
    end
    local function chunk(kind, payload)
        return be32(#payload) .. kind .. payload .. be32(crc32(kind .. payload))
    end
    -- Signature, IHDR for a 1x1 truecolour image, one IDAT holding a STORED deflate block,
    -- then IEND. A stored block needs no compressor: two header bytes, the length and its
    -- complement, then the bytes themselves.
    local sig = string.char(137, 80, 78, 71, 13, 10, 26, 10)
    local ihdr = chunk('IHDR', be32(1) .. be32(1) .. string.char(8, 2, 0, 0, 0))
    local raw = string.char(0, 0, 0, 0)          -- the filter byte, then one black RGB pixel
    local zlib = string.char(0x78, 0x01)         -- deflate, 32k window, no preset dictionary
        .. string.char(0x01, #raw % 256, math.floor(#raw / 256),
                       255 - (#raw % 256), 255 - math.floor(#raw / 256))
        .. raw
        .. be32(adler32(raw))
    return sig .. ihdr .. chunk('IDAT', zlib) .. chunk('IEND', '')
end

--- Post a small multipart body to the configured endpoint and print the status.
---
--- Not through screencapture on purpose: this is the question "does the endpoint accept our
--- key", and putting the capture resource in the middle is how it stopped being answerable.
local function mediaSelfTest()
    local endpoint = tostring(MEDIA.endpoint or '')
    if endpoint == '' then
        print('[v-phone] media test: no endpoint configured (Config.Media.endpoint).')
        return
    end
    local key = apiKey()
    print(('[v-phone] media test: %s'):format(endpoint))
    print(('[v-phone] media test: provider %s, key %s, field %s')
        :format(tostring(MEDIA.provider or 'custom'),
                key == '' and 'MISSING' or ('set, ' .. #key .. ' chars'),
                tostring(MEDIA.formField or 'file')))
    if key == '' then
        print('[v-phone] media test: there is no key to test with. Set `phone_media_key`.')
        return
    end

    local boundary = 'vphoneselftest'
    local field = tostring(MEDIA.formField or 'file')
    local body = table.concat({
        '--' .. boundary,
        ('Content-Disposition: form-data; name="%s"; filename="vphone-test.png"'):format(field),
        'Content-Type: image/png',
        '',
        onePixelPng(),
        '--' .. boundary .. '--',
        '',
    }, '\r\n')

    local headers = uploadHeaders()
    headers['Content-Type'] = 'multipart/form-data; boundary=' .. boundary

    PerformHttpRequest(endpoint, function(status, text)
        -- `status` is 0 when the request never completed, which is the EPIPE case: the socket
        -- was closed before an answer existed. Said in words, because 0 is not a status code
        -- and reads as a bug in this command rather than as the finding it is.
        if not status or status == 0 then
            print('[v-phone] media test: NO ANSWER. The host closed the connection without '
                  .. 'replying - the same failure screencapture reports as `write EPIPE`.')
            print('[v-phone] media test: a host that hangs up on a one-pixel file is refusing '
                  .. 'the KEY, not the file. Check `phone_media_key` against your Fivemanage '
                  .. 'dashboard, and check the token is for the endpoint above.')
            return
        end
        print(('[v-phone] media test: HTTP %d'):format(status))
        print('[v-phone] media test: ' .. tostring(text or ''):gsub('%c', ' '):sub(1, 400))
        if status == 401 or status == 403 then
            print('[v-phone] media test: the key was refused. That is the whole answer.')
        elseif status == 404 then
            print('[v-phone] media test: no such endpoint. Check Config.Media.endpoint.')
        elseif status == 413 then
            print('[v-phone] media test: the host refused a ONE PIXEL file for size, which '
                  .. 'means the limit is not about the file.')
        elseif status == 429 then
            print('[v-phone] media test: rate limited or out of quota.')
        elseif status >= 200 and status < 300 then
            print('[v-phone] media test: the endpoint and the key are fine. If real uploads '
                  .. 'still fail, the difference is the size of what is being sent - try '
                  .. '`imageEncoding = \'jpg\'` or a smaller capture.')
        end
    end, 'POST', body, headers)
end

--- Console only. `src ~= 0` refuses it from a player, because the answer quotes headers.
RegisterCommand('vphone_media_test', function(src)
    if src ~= 0 then return end
    mediaSelfTest()
end, true)

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
