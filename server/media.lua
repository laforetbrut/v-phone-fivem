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

--- Which storage this server uses: 'fivemanage', 'custom' or 's3'.
---
--- A convar first, for the same reason the key is one: switching storage should not require
--- editing config.lua, which is a tracked file that an update overwrites and that people paste
--- into support channels. `set phone_media_provider "s3"` in server.cfg and nothing else moves.
function MediaProvider()
    local v = GetConvar('phone_media_provider', '')
    if v ~= '' then return v end
    return tostring(MEDIA.provider or 'fivemanage')
end

local function apiKey()
    local convar = GetConvar('phone_media_key', '')
    if convar ~= '' then return convar end
    return tostring(MEDIA.apiKey or '')
end

--- The headers an upload carries. Fivemanage authenticates with the key in Authorization;
--- a custom provider gets whatever the config listed.
local function uploadHeaders()
    if MediaProvider() == 'fivemanage' then
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
            :format(tostring(MediaProvider()),
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
    -- The provider that uploaded it decides how long it is kept, and the answer is stamped on
    -- the row now rather than read at sweep time - so changing the config later does not
    -- retroactively move files that are already stored, and a server that switches provider
    -- keeps its old files on the clock they were uploaded under.
    local days = Bridge.MediaRetentionDays and Bridge.MediaRetentionDays() or num(MEDIA.autoDeleteDays, 0)
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
-- The bucket
-- ══════════════════════════════════════════════════════════════

--- Read `phone_s3_pathstyle` as a real three-state answer: set to true, set to false, unset.
---
--- **`a and b or c` cannot return false.** It was written as
--- `(convar ~= '') and (convar == 'true') or (default)`, and when the convar is the string
--- `"false"` the middle term is `false`, so Lua falls straight through to the default. Setting
--- the convar to false did nothing at all: it silently deferred to config.lua, which is the
--- opposite of what a server owner writing `set phone_s3_pathstyle "false"` is asking for.
--- Path style is the difference between `host/bucket/key` and `bucket.host/key`, so on a host
--- that needs one and not the other this is the setting between working and 403 on every
--- object.
---
--- Anything other than a recognised word is treated as unset rather than as false, so a typo
--- falls back to the configured value instead of quietly flipping the addressing mode.
local function pathStyleConvar(default)
    local raw = GetConvar('phone_s3_pathstyle', ''):lower()
    if raw == 'true' or raw == '1' or raw == 'yes' or raw == 'on' then return true end
    if raw == 'false' or raw == '0' or raw == 'no' or raw == 'off' then return false end
    return default
end

--- The bucket's settings, with the two secrets read from convars first.
---
--- config.lua is a file people copy, diff and paste into a support channel. server.cfg is not.
--- So a value written in the config is honoured but the convar wins, which is the same
--- arrangement `phone_media_key` already has.
local function s3Config()
    local s3 = MEDIA.s3 or {}
    local function conv(name, fallback)
        local v = GetConvar(name, '')
        if v ~= '' then return v end
        return tostring(fallback or '')
    end
    return {
        endpoint = conv('phone_s3_endpoint', s3.endpoint),
        bucket = conv('phone_s3_bucket', s3.bucket),
        region = conv('phone_s3_region', s3.region ~= '' and s3.region or 'us-east-1'),
        access = conv('phone_s3_key', s3.accessKey),
        secret = conv('phone_s3_secret', s3.secretKey),
        publicBase = conv('phone_s3_public', s3.publicBase),
        -- Carried so the probe writes under the SAME prefix real uploads use. A bucket policy
        -- scoped to that prefix - the correct thing for an operator to write - would otherwise
        -- refuse the probe and the command would report a broken bucket.
        keyPrefix = tostring(s3.keyPrefix or 'vphone'),
        -- **MEGA S4's account id, and why it is its own setting.**
        --
        -- S4 serves an object publicly at the SAME host as its S3 API, with the account id as
        -- the first path segment. The public form is always path-addressed, whatever
        -- `pathStyle` says about the signed request - see `publicUrl` in server/s3.js:
        --
        --     API, signature required   https://s3.g.megas4.com/<bucket>/<key>
        --     public object URL         https://s3.g.megas4.com/<accountId>/<bucket>/<key>
        --
        -- Without it S4 reads the request as an unsigned API call and answers 403 - which is
        -- indistinguishable from a bucket that simply is not public, and sends people to change
        -- settings that were already right.
        --
        -- Set for S4 and left empty everywhere else; Amazon, R2 and MinIO have no such segment.
        accountId = conv('phone_s3_account', s3.accountId),
        pathStyle = pathStyleConvar(s3.pathStyle == true),
    }
end

local function s3Ready()
    local c = s3Config()
    return c.endpoint ~= '' and c.bucket ~= '' and c.access ~= '' and c.secret ~= ''
end

--- Where in the bucket a file goes.
---
--- Dated folders rather than one flat prefix: a bucket with a hundred thousand objects in a
--- single key space is one an operator cannot look through, and a date is the thing they will
--- want to sort by when they do.
--- The image format, once, so the extension on the object and the Content-Type on the request
--- cannot drift apart.
local function imageExt()
    local e = tostring(MEDIA.imageEncoding or 'jpg'):lower()
    if e == 'jpeg' then return 'jpg' end
    if e ~= 'jpg' and e ~= 'png' and e ~= 'webp' then return 'jpg' end
    return e
end

--- **`image/jpg` is not a media type.** The registered name is `image/jpeg`, and a bucket stores
--- whatever Content-Type it is handed and serves it straight back to a browser. Composing the
--- header as `'image/' .. encoding` was harmless while the default was `webp`, whose extension
--- and subtype happen to be the same word, and would have started writing an unregistered type
--- on to every photograph the moment the default changed.
local function imageMime()
    local e = imageExt()
    return e == 'jpg' and 'image/jpeg' or ('image/' .. e)
end

--- The same format again, spelled the way a CANVAS wants it. Never `jpg`.
---
--- **This is the value that crashed the server, and the mechanism is worth writing down.**
--- `imageExt()` answers a FILE EXTENSION and normalises every JPEG spelling to `jpg`. That is
--- right for an object key and wrong for the capture, because screencapture's NUI builds the
--- canvas type by concatenation and nothing in between validates it:
---
---     createBlob(canvas, encoding, quality)  ->  canvas.toBlob(cb, `image/${encoding}`, q)
---
--- `image/jpg` is not a registered media type and not one the canvas accepts, so per the HTML
--- spec the browser silently falls back to `image/png` AND ignores the quality argument. Every
--- photograph then came back a lossless PNG of the whole frame - one to two and a half megabytes
--- where the same picture as JPEG or WebP is one to three hundred kilobytes - and `imageQuality`
--- bought nothing. That payload is base64'd by screencapture, handed across the JS/Lua boundary
--- into this file, and handed straight back across Lua/JS to the uploader, synchronously, on the
--- server's main thread. Ten times the bytes through two runtime boundaries is what turned a
--- shutter press into a SIGSEGV with an empty managed stack and a two-second whole-process hitch.
---
--- Verified against the installed build rather than assumed: screencapture 0.13.0-beta.5,
--- `game/nui/dist/assets/index-*.js` (`createBlob` and `createDataURL` both concatenate) and
--- `game/dist/server.js` (`getMimeType` maps `jpeg` -> `image/jpeg`, so the data URI it answers
--- with stays correct on this spelling too).
local function imageCaptureType()
    local e = imageExt()
    if e == 'jpg' then return 'jpeg' end
    return e
end

local function s3Key(kind, citizenid)
    local prefix = tostring((MEDIA.s3 or {}).keyPrefix or 'vphone'):gsub('^/+', ''):gsub('/+$', '')
    local rand = ('%08x'):format(math.random(0, 0xffffffff))
    local ext = (kind == 'video') and 'webm' or imageExt()
    return ('%s/%s/%s-%s.%s'):format(prefix ~= '' and prefix or 'vphone',
        os.date('!%Y/%m'), tostring(citizenid or 'x'):sub(1, 16), rand, ext)
end

--- Delete one object. Answers true when it is gone or was already gone.
function Bridge.S3DeleteObject(key)
    key = tostring(key or '')
    if key == '' or not s3Ready() then return false end
    -- A stored row may hold the full URL rather than the key, for a file uploaded before the
    -- key was recorded. Nothing can be deleted from a URL alone, so it is reported as a
    -- failure rather than silently dropped - the sweep keeps the row and says so.
    if key:find('^https?://') then return false end

    local done, ok = false, false
    exports[GetCurrentResourceName()]:s3Delete(json.encode(s3Config()), key, function(res)
        local r = json.decode(res or '{}') or {}
        ok = r.ok == true
        done = true
    end)
    -- **Longer than the Node side's worst case, not shorter.** This was eight seconds against a
    -- JS path whose two attempts and backoff could take forty, so the callback above regularly
    -- fired into a closure this loop had already walked away from - a live function reference
    -- being invoked across a runtime boundary with nothing left waiting for its answer. See the
    -- deadline table in server/s3.js: its ceiling is now 18.5 s and every Lua poll sits above it.
    local waited = 0
    while not done and waited < 20000 do Wait(100) waited = waited + 100 end
    return done and ok
end

--- Send one captured file wherever this server keeps its media.
---
--- **The capture comes to the SERVER first, and that is the point.** screencapture's
--- `remoteUpload` emits its whole options table to the capturing client, and this file passed
--- `headers = uploadHeaders()` inside it - so every photograph anybody took sent the operator's
--- API key to that player's machine, while the comment at the top of this file promised the
--- opposite. `serverCapture` carries no headers at all; the upload happens here.
---
--- Answers `url, key` or nil and a reason.
--- How long Lua waits on the Node side of an upload, and how often it looks.
---
--- **The interval is the latency, not the ceiling.** It was `Wait(100)`, so an upload that
--- finished in 180 ms was reported at 200 ms and one that finished the instant after a poll
--- waited a further 100 ms for nothing - fifty milliseconds of pure delay on an average shot,
--- on a path where every other millisecond has been argued over. Five is under one server tick
--- and costs nothing measurable; the thread is asleep either way.
---
--- Measured against a wall clock rather than counted, because `Wait(5)` is a floor: the thread
--- resumes on the next tick, and counting iterations times five would make a 20 s ceiling into
--- something much longer on a busy server.
local UPLOAD_POLL = 5
local UPLOAD_CEILING = 20000

local function waitFor(isDone, ceiling)
    local deadline = GetGameTimer() + (ceiling or UPLOAD_CEILING)
    while not isDone() and GetGameTimer() < deadline do Wait(UPLOAD_POLL) end
    return isDone()
end

--- **The most bytes this file will hand to another runtime, and why there is a number at all.**
---
--- The capture leaves screencapture's Node process as a base64 string, is marshalled into this
--- Lua runtime through a function reference, and is marshalled straight back out to the uploader
--- - both crossings synchronous, both on the server's main thread. Lua reads none of it and
--- changes none of it; it is a courier.
---
--- A courier with no weight limit is what turned a shutter press into a SIGSEGV. With the canvas
--- type spelled wrong every photograph arrived as a full-frame PNG, and nothing anywhere on the
--- path looked at its length before pushing it across a boundary twice.
---
--- Twelve megabytes is far above anything this path can legitimately produce - a 1280x720 frame
--- as JPEG at 0.7 is one to three hundred kilobytes, and even an uncapped 4K PNG in base64 sits
--- under it - and far below the size at which marshalling becomes the interesting risk. So it
--- never fires on a working configuration, and on a broken one the operator gets a console line
--- and the player gets a message, instead of the process getting a signal.
local MAX_PAYLOAD = 12 * 1024 * 1024

--- Is this something we may hand to another runtime? Answers nil when it is, or a console line
--- and the error code the player is shown.
---
--- Type first, then length. `payload` comes from a third-party resource's callback: a build whose
--- shape moved, a capture that failed part way, or a client that dropped could each deliver a
--- nil, a table or a Buffer where a string is expected, and `#payload` on a non-string throws
--- inside a callback whose error nothing above it would ever see.
local function payloadTrouble(payload)
    if type(payload) ~= 'string' then
        return ('capture came back as %s, not a string'):format(type(payload)), 'upload'
    end
    if #payload == 0 then return 'capture came back empty', 'upload' end
    if #payload > MAX_PAYLOAD then
        return ('capture too large: %d bytes, ceiling %d'):format(#payload, MAX_PAYLOAD), 'toolarge'
    end
    return nil
end

local function uploadCapture(payload, kind, citizenid)
    local provider = MediaProvider()

    -- Before either export call, because both of them are a runtime boundary and the whole point
    -- is that nothing unmeasured crosses one.
    local bad, code = payloadTrouble(payload)
    if bad then
        uploadTrouble(bad)
        return nil, code
    end

    if provider == 's3' then
        if not s3Ready() then return nil, 'nokey' end
        local key = s3Key(kind, citizenid)
        local done, out = false, nil
        exports[GetCurrentResourceName()]:s3Put(json.encode(s3Config()), key, payload,
            (kind == 'video') and 'video/webm' or imageMime(),
            function(res) out = json.decode(res or '{}') or {}; done = true end)
        if not waitFor(function() return done end) then return nil, 'timeout' end
        if not out.ok then
            uploadTrouble(tostring(out.body or out.error or 'upload'))
            return nil, 'upload'
        end
        -- The KEY is what a delete needs later. An S3 PUT answers an empty body, so there is
        -- no id to parse out of a response the way a hosted CDN gives one.
        return out.url, key
    end

    -- A hosted CDN: the same multipart POST it always received, made from here.
    local done, out = false, nil
    exports[GetCurrentResourceName()]:mediaPost(MEDIA.endpoint, json.encode(uploadHeaders()),
        MEDIA.formField or 'file', payload, function(res)
            out = json.decode(res or '{}') or {}; done = true
        end)
    if not waitFor(function() return done end) then return nil, 'timeout' end
    if not out.ok then
        uploadTrouble(tostring(out.body or out.error or out.status or 'upload'))
        return nil, 'upload'
    end
    local url = urlFromResponse(out.response)
    if not url then uploadTrouble('no url in the response'); return nil, 'upload' end
    return url, idFromResponse(out.response)
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

--- **A slot is a lease, not a flag.**
---
--- It was a boolean cleared only when the handler resolved, so anything that stopped the handler
--- resolving - a capture resource that never called back, a Node promise held open by a hung TCP
--- connection - left `Uploading[src]` true for the rest of that player's session. Every later
--- photograph then answered `busy`, with no way back short of reconnecting, and nothing anywhere
--- said why. The guard below now answers and releases, and this is the belt to that brace: a
--- lease older than the longest the whole handler is allowed to take is not an upload in
--- progress, it is one that was lost, and the next shot may have the slot.
local UPLOAD_LEASE = 35000

--- May this player start an upload? Returns false and the reason, or true and a release
--- function that must be called on every exit path.
local function takeUploadSlot(src)
    local now = GetGameTimer()
    local held = Uploading[src]
    if held and (now - held) < UPLOAD_LEASE then return false, 'shotbusy' end
    if UploadLast[src] and (now - UploadLast[src]) < UPLOAD_EVERY then return false, 'toosoon' end
    Uploading[src] = now
    UploadLast[src] = now
    -- Only the lease this call took. A release arriving late - the stranded handler finally
    -- answering after the lease expired and a second shot took the slot - must not free the
    -- upload that is running now.
    return true, function()
        if Uploading[src] == now then Uploading[src] = nil end
    end
end

AddEventHandler('playerDropped', function()
    Uploading[source] = nil
    UploadLast[source] = nil
end)

-- ══════════════════════════════════════════════════════════════
-- Photo: capture and upload
-- ══════════════════════════════════════════════════════════════
--- What the capture is asked to produce, and why every field is here.
---
--- The grab happens in the PLAYER'S browser, sharing a CPU with the game's render loop, and
--- everything this table asks for is paid on their machine before a single byte moves.
---
---   * **encoding** decides the cost of the encode, and it is not a close call. Measured in the
---     same Chromium engine CEF is built on, WebP is eight to ten times slower than JPEG at
---     every resolution tested - 141 ms against 15 ms at 1080p on a compressible frame, 556 ms
---     against 61 ms at 4K - and the difference does not shrink on a harder image. WebP's
---     smaller file is a real saving on the operator's bucket; it is not worth half a second of
---     the player's shutter, so JPEG is the default and WebP is the opt-in.
---   * **quality** was never sent at all, so the browser used its own default for whichever
---     format it was handed - and JPEG's default is generous. Measured: a 1080p frame at 0.85
---     is 436 KB against WebP's 309 KB, which would have handed the wire back what the encode
---     just won. At 0.7 it is 311 KB, within one percent of WebP at both 1080p and 1440p, and
---     still ten times faster to produce. The file is the size it always was; only the wait
---     went.
---   * **maxWidth / maxHeight** cap what is encoded and what is sent. The phone draws a
---     thumbnail at roughly 400 px and a full-screen photograph at roughly 800; a player on a
---     4K monitor was encoding and shipping thirty times the pixels of what their own gallery
---     can show, and paying for it twice - once in encode time, once in a base64 string that
---     travels client to server as one net event.
---
--- **Checked against the installed build, not assumed.** An earlier version of this comment said
--- screencapture could not be inspected and that a key it does not know is ignored, so "nothing
--- here can fail closed". Both halves were wrong, and the second one is what shipped the crash:
--- it reads `encoding` on every path, it validates none of them, and an unknown value does not
--- fall back to the old behaviour - it changes the format silently. What its 0.13.0-beta.5 build
--- actually does with this table:
---
---   * **encoding** goes to the NUI and is concatenated into `image/${encoding}` for
---     `canvas.toBlob`. Only `png`, `jpeg` and `webp` are accepted there; anything else becomes
---     a full-size lossless PNG and the quality argument is dropped. See `imageCaptureType`.
---   * **quality** is `toBlob`'s second argument, used when given and otherwise derived from the
---     canvas area (0.7 / 0.6 / 0.5). It only means anything for a lossy type, which is the
---     other half of the same bug.
---   * **maxWidth / maxHeight** are read by `calculateDimensions`, which scales the canvas down
---     to fit and never scales up. Absent, its own defaults are 1920x1080.
---
--- Everything sent is clamped rather than passed through, because this table leaves the Lua
--- runtime: a NaN or an inf reaching a canvas dimension is not a setting, it is an argument to
--- somebody else's allocator.
local function captureOptions()
    local q = tonumber(MEDIA.imageQuality)
    -- `q ~= q` is the NaN test. `0/0` written in a config would otherwise travel the whole way
    -- to `toBlob`'s quality argument, and `math.floor` on it below would throw.
    if not q or q ~= q or q <= 0 or q > 1 then q = 0.7 end
    -- 0 means "no cap" and is the documented way to remove it. Anything else is forced into a
    -- sane integer: under 16 there is no photograph, and over 4096 the encode outlasts the
    -- shutter and the payload outgrows what the boundary below is willing to carry.
    local function side(v, d)
        local n = tonumber(v)
        if not n or n ~= n then n = d end
        if n <= 0 then return nil end
        if n == math.huge then return 4096 end
        return math.floor(math.min(4096, math.max(16, n)))
    end
    return {
        encoding = imageCaptureType(),
        quality = q,
        maxWidth = side(MEDIA.maxWidth, 1280),
        maxHeight = side(MEDIA.maxHeight, 720),
    }
end

-- The camera calls this. It captures the player's screen through screencapture, uploads
-- it, and hands back the URL, which the gallery stores like any photo.
V.Callback('v-phone:media:photo', function(src, resolve)
    if not mediaOn() then resolve({ error = 'off' }) return end
    if apiKey() == '' and MediaProvider() == 'fivemanage' then resolve({ error = 'nokey' }) return end
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

    -- **Where it was taken, read NOW and not when the upload lands.**
    --
    -- The player is standing in front of whatever they photographed at this instant; by the time
    -- a CDN has answered they may be three streets away. It is also the field this path used to
    -- drop entirely - `op = 'add'` in server/main.lua computes it and this handler inserted the
    -- row itself without one - so on the default provider every photograph lost its location and
    -- the Gallery's Places view was empty for anyone whose server uploads.
    local place = (Bridge.PhotoPlaceOf and Bridge.PhotoPlaceOf(src)) or ''

    -- **Two flags, because they answer two different questions.**
    --
    -- There was one, `done`, and screencapture's callback set it before the upload started - so
    -- the guard was disarmed at the exact moment the slow half began. Everything after that
    -- point ran with no ceiling that could answer the caller: a hung CDN held the handler for up
    -- to twenty seconds past a client that had already given up, the upload slot stayed taken
    -- for all of it, and the photograph still landed in the gallery afterwards. The player was
    -- told it failed, could not retry, and watched it appear anyway.
    --
    --   captured  screencapture has handed the frame over. Late callbacks are no-ops.
    --   answered  `resolve` has been called. The ONE thing the guard may look at.
    local captured, answered = false, false
    local function answer(res)
        if answered then return end
        answered = true
        resolve(res)
    end

    -- **One guard, over the whole handler.** Ordered innermost-first with the two above it: the
    -- server gives up at 25 s, the client's own timer at 28 s, and `V.Request` at 30 s. The
    -- layer closest to the work is the one that reports, so the message a player sees names what
    -- actually failed rather than "the server did not answer".
    --
    -- **Armed before the call it protects, not after it.** An export that throws unwinds past
    -- everything below it, and a timeout registered down there would never have been registered
    -- at all - so the one failure the guard exists for is the one it misses.
    SetTimeout(25000, function()
        if answered then return end
        captured = true
        uploadTrouble('timeout')
        answer({ error = 'timeout' })
    end)

    -- **`serverCapture`, not `remoteUpload`.** The difference is where the API key goes:
    -- `remoteUpload` emits its options table to the capturing client and this file put the key
    -- in it, so every photograph sent the operator's credentials to a player's machine.
    -- `serverCapture` uploads nothing and carries no headers - it hands the image back here,
    -- and the upload is made from the server where the key belongs.
    --
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
    --
    -- **`src` is checked before it is sent.** screencapture puts this straight into `emitNet`,
    -- which is a native. Every caller reaching here has come through `Core.GetPlayer(src)` so it
    -- is a number in practice, but "in practice" is not what an argument to somebody else's
    -- native call gets to rely on, and this is the handler that crashed a server.
    local target = tonumber(src)
    if not target or target ~= target or target <= 0 then
        answer({ error = 'x' })
        return
    end
    target = math.floor(target)

    local started = pcall(function()
    exports['screencapture']:serverCapture(target, captureOptions(), function(payload)
        if captured then return end
        captured = true

        -- **The frame exists. Say so before the slow half starts.**
        --
        -- Everything from here is network: an upload to somebody else's host and a database
        -- write. None of it needs the player to keep standing still with their HUD hidden and
        -- their viewfinder frozen, and until now they did, for as long as the CDN took. The
        -- client puts the camera back in the player's hands on this event and says the picture
        -- is being sent; it does not claim the picture is saved, because it is not yet.
        TriggerClientEvent('v-phone:media:captured', target)

        local url, ref = uploadCapture(payload, 'image', p.citizenid)
        if not url then answer({ error = ref or 'upload' }) return end
        remember(p.citizenid, url, 'image', { id = ref })

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
        local row = { url = url, album = '', filter = '', place = place }
        table.insert(shots, 1, row)
        while #shots > 60 do table.remove(shots) end
        -- Waited on: a photo is data the player just made, and a fire-and-forget write
        -- is lost if the server goes down before the query lands.
        p.SetMetadataSync('photos', shots)

        -- **The row, not just the address.** The phone used to throw this URL away and ask for
        -- the whole gallery again - a second round trip through NUI, the client, the server and
        -- back, for a list whose only new entry is the one already in hand. Answering with the
        -- row exactly as it was stored lets the page put it at the front of the list it already
        -- holds, and the two cannot disagree because they are the same table.
        answer({ ok = true, url = url, stored = true, photo = row })
    end, 'base64')
    end)

    if not started then answer({ error = 'noupload' }) end
end)

-- ══════════════════════════════════════════════════════════════
-- Video: record for N seconds, upload, return the URL
-- ══════════════════════════════════════════════════════════════
-- The record button calls this with a duration. It is clamped to the config ceiling so a
-- client cannot ask for a ten-minute recording. screencapture records in the NUI, streams
-- to the server, uploads the finished WebM and cleans up its temp file.
V.Callback('v-phone:media:video', function(src, resolve, data)
    if not Bridge.MediaVideoEnabled() then resolve({ error = 'off' }) return end
    if apiKey() == '' and MediaProvider() == 'fivemanage' then resolve({ error = 'nokey' }) return end
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

    -- **No `headers` here, and that is the point.**
    --
    -- `startVideoCaptureUpload` emits its options table to the capturing client, exactly as
    -- `remoteUpload` did, and this call used to put `headers = uploadHeaders()` inside it - the
    -- Authorization header, with the API key in it. The photo path was moved off that pattern;
    -- this one was left behind, and only escaped notice because `Config.Media.video` ships nil.
    -- The config invites operators to switch it back on, so "unreachable today" is not a fix.
    --
    -- The capture is uploaded by `screencapture` itself here rather than handed back, so
    -- there is no key to send: an unauthenticated POST to an endpoint that needs one fails
    -- honestly and says so, which is the correct outcome until the video path is rebuilt on
    -- `serverCaptureStream` the way the photo path was rebuilt on `serverCapture`.
    -- The same clamps the photo path has, for the same reason: everything below leaves the Lua
    -- runtime. `src` goes straight into screencapture's `emitNet`, and the two dimensions go to
    -- a canvas. `num()` answers whatever `tonumber` gave it, so a NaN or an inf in a config
    -- reached both untouched.
    local vTarget = tonumber(src)
    if not vTarget or vTarget ~= vTarget or vTarget <= 0 then
        if not done then done = true; resolve({ error = 'x' }) end
        return
    end
    vTarget = math.floor(vTarget)
    local function vSide(v, d)
        local n = tonumber(v)
        if not n or n ~= n or n <= 0 then n = d end
        if n == math.huge then return 4096 end
        return math.floor(math.min(4096, math.max(16, n)))
    end

    local vStarted = pcall(function()
    exports['screencapture']:startVideoCaptureUpload(vTarget, MEDIA.endpoint, {
        duration = seconds,
        maxWidth = vSide(MEDIA.video and MEDIA.video.maxWidth, 1280),
        maxHeight = vSide(MEDIA.video and MEDIA.video.maxHeight, 720),
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
        :format(tostring(MediaProvider()),
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

--- The last few files this phone recorded, with the address it stored for each.
---
---     vphone_media_last
---
--- The gallery draws a photograph from the URL in this table, and a tile whose picture fails to
--- load is SILENT - a CSS background that 404s shows the colour underneath, so a wrong address
--- and a missing file look identical on screen. This prints what was actually written, which is
--- the one fact that tells those two apart.
---
--- Read only, console only.
RegisterCommand('vphone_media_last', function(src)
    if src ~= 0 then return end
    local rows = MySQL.query.await([[SELECT url, media_id, kind, at, delete_at
        FROM vphone_media ORDER BY id DESC LIMIT 5]]) or {}
    if #rows == 0 then
        print('[v-phone] media: nothing recorded yet.')
        return
    end
    print(('[v-phone] media: provider is %s. The last %d file(s):')
        :format(MediaProvider(), #rows))
    for _, r in ipairs(rows) do
        print(('    %s'):format(tostring(r.url)))
        print(('        key=%s  kind=%s  expires=%s')
            :format(tostring(r.media_id or '-'), tostring(r.kind),
                    tostring(r.delete_at or 'never')))
    end
    print('[v-phone] media: open the top one in a browser. If it loads there but the phone '
          .. 'shows a blank tile, the address is right and the picture is being refused by the '
          .. 'page; if it does not load, the address is wrong.')
end, true)

--- Find the two settings no documentation can give you.
---
---     vphone_s3_test
---
--- A bucket's REGION as it must appear in the signature, and whether it wants the bucket in the
--- hostname or in the path, are not reliably documented for anything but Amazon. MEGA S4's own
--- `GetBucketLocation` answers an empty string; rclone pins it to path-style while the S4
--- console shows a virtual-hosted hostname. And a wrong region does not say "wrong region" - it
--- says `SignatureDoesNotMatch`, which reads exactly like a wrong secret key and sends people to
--- check the one thing that is right.
---
--- So this uploads a one-pixel PNG under each plausible combination, reports the first the
--- bucket accepts along with the public URL it produced, then asks whether a browser with no
--- credentials can read it, and deletes the pixel again.
---
--- Read only, console only.
RegisterCommand('vphone_s3_test', function(src)
    if src ~= 0 then return end
    local c = s3Config()
    local missing = {}
    if c.endpoint == '' then missing[#missing + 1] = 'phone_s3_endpoint' end
    if c.bucket == '' then missing[#missing + 1] = 'phone_s3_bucket' end
    if c.access == '' then missing[#missing + 1] = 'phone_s3_key' end
    if c.secret == '' then missing[#missing + 1] = 'phone_s3_secret' end
    if #missing > 0 then
        print('[v-phone] s3: not configured. Missing: ' .. table.concat(missing, ', '))
        return
    end

    -- The regions worth trying, most likely first. The configured one leads, because an
    -- operator who already knows it should not have to wait through six guesses.
    local regions = { c.region, 'us-east-1', '', 'eu-central-1',
                      'eu-amsterdam', 'eu-paris', 'eu-luxembourg' }
    print(('[v-phone] s3: probing %s bucket "%s" ...'):format(c.endpoint, c.bucket))

    exports[GetCurrentResourceName()]:s3Probe(json.encode(c), json.encode(regions), function(res)
        local r = json.decode(res or '{}') or {}
        for _, t in ipairs(r.tried or {}) do
            print(('[v-phone] s3:   region=%-14s pathStyle=%-5s %s')
                :format(('"%s"'):format(t.region or ''), tostring(t.pathStyle),
                        t.ok and 'OK' or ('failed ' .. tostring(t.error or t.status or ''))))
        end
        if not r.ok then
            print('[v-phone] s3: nothing worked. A 403 with SignatureDoesNotMatch on EVERY row '
                  .. "is the secret key; a 403 AccessDenied is the key's permissions on this "
                  .. 'bucket; a DNS or TLS error is the endpoint.')
            return
        end
        print(('[v-phone] s3: WORKS with region "%s", pathStyle %s')
            :format(r.region or '', tostring(r.pathStyle)))
        print(('[v-phone] s3: put these in server.cfg -'))
        print(('    set phone_s3_region "%s"'):format(r.region or ''))
        print(('    set phone_s3_pathstyle "%s"'):format(tostring(r.pathStyle)))
        print(('[v-phone] s3: files will be at %s'):format(tostring(r.url or '?')))

        -- Whether a BROWSER can read it, which is a different question from whether the
        -- upload worked. The phone draws a photograph with an <img> carrying no credentials,
        -- so a bucket that takes writes and refuses anonymous reads gives a gallery of empty
        -- frames - and that failure looks like a broken phone, not like a bucket setting.
        local pub = r.publicRead
        if pub == 200 then
            print('[v-phone] s3: and they are publicly readable. Nothing else to do.')
        elseif tonumber(pub) then
            print(('[v-phone] s3: BUT a browser gets HTTP %s on it. Uploads will work and every '
                .. 'photograph will be an empty frame.'):format(tostring(pub)))
            if c.endpoint:find('megas4') and (c.accountId or '') == '' then
                print('[v-phone] s3: on MEGA S4 this is almost always ONE MISSING SETTING.')
                print('[v-phone] s3: S4 serves an object publicly at the same host as its API, '
                      .. 'with your ACCOUNT ID as the first path segment. Without it the request '
                      .. 'is read as an unsigned API call and refused - which looks exactly like '
                      .. 'a bucket that is not public.')
                print('[v-phone] s3: in the MEGA console, right-click any object -> Share -> '
                      .. 'Manage object URL -> Copy. The id is the segment between the host and '
                      .. "the bucket name - letters and digits, around 37 characters. MEGA's "
                      .. 'own specs call it 15 digits and their examples show 18; both are '
                      .. 'wrong, so copy the real one rather than recognising a shape. Then:')
                print('    set phone_s3_account "<that number>"')
            else
                print('[v-phone] s3: grant object URL access on THIS bucket only - keep your '
                      .. 'other buckets private - or set phone_s3_public for a CDN.')
            end
        else
            print(('[v-phone] s3: could not check public readability from the server (%s).')
                :format(tostring(pub)))
            print('[v-phone] s3: that is about the SERVER reaching the address, not about the '
                  .. 'bucket - the upload above worked, so the credentials and the region are '
                  .. 'right. Open the URL above in a browser. If the picture appears, this is '
                  .. 'configured and the check simply cannot be made from here.')
            -- Said only when it is still to do. Telling somebody to set what they have
            -- already set is how a diagnostic loses their trust.
            if MediaProvider() ~= 's3' then
                print('[v-phone] s3: then switch storage over with, in server.cfg:')
                print('    set phone_media_provider "s3"')
            else
                print('[v-phone] s3: storage is already set to s3 - take a photograph with the '
                      .. 'Camera and it will land in this bucket.')
            end
            if r.leftBehind then
                print(('[v-phone] s3: the test file was LEFT IN PLACE so you can open it. '
                    .. 'Delete it afterwards: %s'):format(tostring(r.leftBehind)))
            end
        end
    end)
end, true)

-- ══════════════════════════════════════════════════════════════
-- Auto-deletion
-- ══════════════════════════════════════════════════════════════
--- Ask the host to delete a file.
---
--- Answers true when the file is gone or was never the host's to delete, false when the host
--- was asked and refused. The distinction is what lets the sweep retry instead of dropping the
--- row and orphaning the file: a rejected key or an unreachable host used to look exactly like
--- a successful delete, because nothing looked at the answer.
---
--- nil - "there is nothing to ask" - counts as done: a host with no delete endpoint keeps the
--- file under its own retention, which is the documented arrangement.
local function deleteFromHost(url, mediaId)
    -- The bucket, which deletes by key rather than by a templated URL.
    if MediaProvider() == 's3' then
        return Bridge.S3DeleteObject and Bridge.S3DeleteObject(mediaId or url) or false
    end

    local endpoint = MEDIA.deleteEndpoint
    if not endpoint or endpoint == '' then return true end
    if not mediaId and endpoint:find('{id}', 1, true) then return true end   -- cannot name it

    endpoint = endpoint:gsub('{id}', tostring(mediaId or '')):gsub('{url}', tostring(url or ''))

    -- PerformHttpRequest is asynchronous and the sweep needs the answer, so this waits for it.
    -- Bounded: a host that never replies must not stall the sweep for the other 199 rows.
    local done, good = false, false
    PerformHttpRequest(endpoint, function(status)
        good = (status >= 200 and status < 300) or status == 404
        done = true
    end, (MEDIA.deleteMethod or 'DELETE'), '', uploadHeaders())

    local waited = 0
    while not done and waited < 8000 do Wait(100) waited = waited + 100 end
    return done and good or false
end

--- Delete one file from the host, for the admin cleanup.
---
--- Published rather than copied: `phoneclean media` and the sweep must ask the host the same
--- way, or one of them orphans files the other would have removed.
function Bridge.MediaDeleteOne(url, mediaId)
    return deleteFromHost(url, mediaId)
end

--- How long a file is kept before it is swept, in days, for the provider that uploaded it.
---
--- Per provider on purpose. A hosted CDN is somebody else's quota on a monthly plan and thirty
--- days is generous there; a bucket the operator rents by the gigabyte is theirs, and a year is
--- the point of paying for it. `Config.Media.retentionDays` names both; `autoDeleteDays` is
--- still read so a config that predates this keeps working exactly as it did.
function Bridge.MediaRetentionDays(provider)
    local per = MEDIA.retentionDays
    if type(per) == 'table' then
        local v = tonumber(per[tostring(provider or MediaProvider())])
        if v then return math.max(0, math.floor(v)) end
    end
    return math.max(0, math.floor(num(MEDIA.autoDeleteDays, 30)))
end

--- How far an expiry is pushed when the file is still on screen somewhere.
---
--- Not for ever, and not one day. A week means a file whose post is deleted tomorrow is gone
--- within the week, while a file on a post somebody still reads is re-checked fifty-two times a
--- year rather than every hour.
local KEEP_EXTRA = 7 * 86400

--- Sweep expired media.
---
--- **A file that something is still showing is not deleted.** That is the whole change. The old
--- version deleted on the clock alone, and with files expiring at thirty days while posts live
--- sixty, a photo post older than a month lost its picture and kept its caption. Two clocks
--- that differ are not a bug to be fixed by making them equal - they differ again the next time
--- somebody edits a config - so the question is asked directly.
---
--- **No global gate.** It used to return immediately when `autoDeleteDays` was 0 or absent,
--- which with a per-provider retention means one provider set to "keep for ever" stopped the
--- other provider's files from ever being swept. Every row already carries its own `delete_at`,
--- stamped when it was uploaded, so the row decides and nothing above it needs to agree.
function Bridge.MediaSweep()
    local rows = MySQL.query.await([[SELECT id, url, media_id FROM vphone_media
        WHERE delete_at IS NOT NULL AND delete_at <= NOW() LIMIT 200]]) or {}
    if #rows == 0 then return 0 end

    local removed, kept, failed = 0, 0, 0
    local why = nil

    for _, r in ipairs(rows) do
        local holder = Bridge.MediaReferencedBy and Bridge.MediaReferencedBy(r.url) or nil
        if holder then
            -- Still on screen somewhere. The expiry moves rather than the file, and the row
            -- stays - which also keeps `Bridge.MediaHasUrl` answering true, so the phone does
            -- not start refusing a photograph it took itself.
            MySQL.query.await(
                'UPDATE vphone_media SET delete_at = FROM_UNIXTIME(?) WHERE id = ?',
                { os.time() + KEEP_EXTRA, r.id })
            kept = kept + 1
            why = why or holder
        else
            -- Nothing shows it. The settings that merely POINT at it are cleared first, so a
            -- wallpaper or an avatar falls back to the placeholder it was designed with rather
            -- than to a hole - and only then is the file asked to go.
            if Bridge.MediaForgetSettings then Bridge.MediaForgetSettings(r.url) end
            local ok = deleteFromHost(r.url, r.media_id)
            if ok == false then
                -- The host refused or could not be reached. Keeping the row is the only way
                -- the file is ever asked about again; dropping it would leave the file on the
                -- operator\'s bill with nothing left that knows its name.
                MySQL.query.await(
                    'UPDATE vphone_media SET delete_at = FROM_UNIXTIME(?) WHERE id = ?',
                    { os.time() + 3600, r.id })
                failed = failed + 1
            else
                MySQL.query.await('DELETE FROM vphone_media WHERE id = ?', { r.id })
                removed = removed + 1
            end
        end
    end

    if removed > 0 or failed > 0 or kept > 0 then
        print(('[v-phone] media: swept %d file(s), kept %d still in use%s, %d retry later')
            :format(removed, kept, why and (' (eg ' .. why .. ')') or '', failed))
    end
    return removed
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
