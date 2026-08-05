# -*- coding: utf-8 -*-
"""What a photograph does when the host is slow, under real Lua.

    python tools/test-camera.py

`server/media.lua` is driven here with a real Lua 5.4, a fake `screencapture` and a fake bucket,
on a clock this file advances by hand - so what is asserted is the handler's actual behaviour
against a slow or dead upload host, not a reading of it.

**The bug this exists for.** The handler used to arm one eight-second guard and then let
screencapture's callback clear its flag, which disarmed the guard at the exact moment the slow
half began. Everything after that ran with no ceiling that could answer the caller:

  * the client gave up at ten seconds and told the player the photograph had failed
  * the server kept going for up to twenty more, then stored the picture anyway
  * `Uploading[src]` was held for all of it, so every retry answered "busy"
  * and the string for "busy" was the CALL app's - "You are already on a call"

So the player was told it failed, could not take another, and watched the picture appear in
their gallery a few seconds later. Each of those four is a case below.
"""
import io
import os
import sys

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = io.open(os.path.join(ROOT, 'server', 'media.lua'), encoding='utf-8').read()

failures = []


def check(name, got, want):
    ok = got == want
    print('%-58s %s' % (name, 'ok' if ok else 'FAIL  got %r want %r' % (got, want)))
    if not ok:
        failures.append(name)


# ══════════════════════════════════════════════════════════════
# The world media.lua runs in
# ══════════════════════════════════════════════════════════════
# A cooperative scheduler over real coroutines, because the code under test genuinely yields:
# `uploadCapture` polls for the Node callback with `Wait`. Advancing a millisecond at a time is
# slow to read and exactly right to reason about - every deadline in the file is in milliseconds.
ENV = r"""
NOW = 0
local threads = {}

function CreateThread(fn) threads[#threads + 1] = { co = coroutine.create(fn), at = NOW } end
function SetTimeout(ms, fn)
    threads[#threads + 1] = { co = coroutine.create(fn), at = NOW + (tonumber(ms) or 0) }
end
function Wait(ms) coroutine.yield(tonumber(ms) or 0) end
function GetGameTimer() return NOW end

--- Run the clock forward to `stop`, resuming whatever is due.
function RUN(stop)
    while NOW <= stop do
        for _, t in ipairs(threads) do
            if not t.dead and t.at <= NOW then
                local ok, waited = coroutine.resume(t.co)
                if not ok then error(waited, 0) end
                if coroutine.status(t.co) == 'dead' then
                    t.dead = true
                else
                    t.at = NOW + (tonumber(waited) or 0)
                end
            end
        end
        NOW = NOW + 1
    end
end

-- ── the resource around it ────────────────────────────────────
CONVARS = {}
function GetConvar(name, default)
    local v = CONVARS[name]
    if v == nil then return default end
    return v
end
function GetResourceState(name) return RESOURCE_STATE[name] or 'missing' end
function GetCurrentResourceName() return 'v-phone' end
RESOURCE_STATE = { screencapture = 'started' }

function AddEventHandler() end
function RegisterCommand() end
function PerformHttpRequest() end

CLIENT_EVENTS = {}
function TriggerClientEvent(name, src, ...)
    CLIENT_EVENTS[#CLIENT_EVENTS + 1] = { name = name, src = src, at = NOW }
end

MySQL = {
    insert = function() end,
    query = { await = function() return {} end },
}

HANDLERS = {}
V = {
    Callback = function(name, fn) HANDLERS[name] = fn end,
    Setting = function(_, d) return d end,
    SettingBool = function(_, d) return d end,
}

STORED = nil
Core = { GetPlayer = function(src)
    if src == 0 then return nil end
    return {
        citizenid = 'CID' .. tostring(src),
        GetMetadata = function() return STORED end,
        SetMetadataSync = function(_, v) STORED = v; return true end,
    }
end }

Bridge = {}
function Bridge.PhotoPlaceOf() return 'Vespucci Beach' end

-- A minimal JSON, enough for the two calls media.lua makes on this path.
json = {
    encode = function() return '{}' end,
    decode = function(s) return DECODED[s] or {} end,
}
DECODED = {}

-- ── the fakes the handler talks to ────────────────────────────
-- `CAPTURE_MS` is how long the grab takes; nil means it never answers.
-- `UPLOAD_MS` is how long the bucket takes; nil means it never answers.
CAPTURE_MS, UPLOAD_MS = 100, 300
CAPTURE_OPTIONS, CAPTURE_DATATYPE = nil, nil
-- What the capture resource hands back, in a one-element table so a test can deliver nil.
CAPTURE_PAYLOAD = { 'data:image/jpeg;base64,AAAA' }
-- How many times the payload was pushed across the runtime boundary to the uploader. A capture
-- the handler refuses must not reach this at all.
PUT_CALLS = 0

local screencapture = {
    serverCapture = function(_, _, opts, cb, dataType)
        CAPTURE_OPTIONS, CAPTURE_DATATYPE = opts, dataType
        if not CAPTURE_MS then return end
        SetTimeout(CAPTURE_MS, function() cb(CAPTURE_PAYLOAD[1]) end)
    end,
}

local self = {
    s3Put = function(_, _, _, _, _, cb)
        PUT_CALLS = PUT_CALLS + 1
        if not UPLOAD_MS then return end
        SetTimeout(UPLOAD_MS, function() cb('PUT_OK') end)
    end,
    s3Delete = function(_, _, _, cb) SetTimeout(1, function() cb('{}') end) end,
    mediaPost = function() end,
    s3Probe = function() end,
}

exports = setmetatable({}, { __index = function(_, name)
    if name == 'screencapture' then return screencapture end
    return self
end })

Config = { Media = {
    enabled = true,
    provider = 's3',
    imageEncoding = 'jpg',
    imageQuality = 0.7,
    maxWidth = 1280,
    maxHeight = 720,
    s3 = { endpoint = 'e.example', bucket = 'b', region = 'us-east-1',
           accessKey = 'A', secretKey = 'S', keyPrefix = 'vphone' },
} }
"""

DRIVE = r"""
--- Take one photograph as player `src`, and report what the caller was told and when.
function SHOOT(src)
    local seen = { answers = 0, result = nil, at = nil }
    CreateThread(function()
        HANDLERS['v-phone:media:photo'](src, function(res)
            seen.answers = seen.answers + 1
            if seen.result == nil then seen.result = res; seen.at = NOW end
        end)
    end)
    return seen
end
"""


def fresh():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(ENV)
    lua.execute("DECODED['PUT_OK'] = { ok = true, url = 'https://cdn.example/a.jpg' }")
    lua.execute(SRC)
    lua.execute(DRIVE)
    return lua


# ══════════════════════════════════════════════════════════════
# 1. The ordinary photograph
# ══════════════════════════════════════════════════════════════
lua = fresh()
g = lua.globals()
shot = g.SHOOT(1)
g.RUN(2000)

check('a good shot is answered exactly once', shot['answers'], 1)
check('a good shot answers ok', shot['result']['ok'], True)
check('a good shot answers with the url', shot['result']['url'], 'https://cdn.example/a.jpg')

# The row the phone is handed back, so it can put the picture on the roll without asking the
# server for the whole gallery again.
row = shot['result']['photo']
check('the answer carries the stored row', row is not None, True)
check('the row carries where it was taken',
      row['place'] if row is not None else None, 'Vespucci Beach')
check('the gallery row carries it too', g.STORED[1]['place'], 'Vespucci Beach')

# The capture is asked for something the player's machine can encode quickly and the phone can
# actually draw. None of these three was sent before; only `encoding` was.
# **`jpeg`, never `jpg`, and this is the assertion that would have caught the crash.**
#
# screencapture's NUI builds the canvas type by writing `image/` in front of this value, and
# `image/jpg` is not a type any canvas accepts: the browser silently falls back to a full-frame
# lossless PNG and drops the quality argument. A photograph that should be two hundred kilobytes
# became two megabytes, and that string is marshalled across the JS/Lua boundary and back again
# on the server's main thread. The config says `jpg` because that is the file extension; only the
# canvas spelling may go out on the wire.
check('the capture is asked for a canvas-valid subtype', g.CAPTURE_OPTIONS['encoding'], 'jpeg')
check('the capture is given a quality', g.CAPTURE_OPTIONS['quality'], 0.7)
check('the capture is capped in width', g.CAPTURE_OPTIONS['maxWidth'], 1280)
check('the capture is capped in height', g.CAPTURE_OPTIONS['maxHeight'], 720)
check('the capture still asks for base64', g.CAPTURE_DATATYPE, 'base64')

# The client is told the instant the frame exists, which is what lets it hand the viewfinder and
# the HUD back rather than freezing them until the CDN answers.
events = [(g.CLIENT_EVENTS[i]['name'], g.CLIENT_EVENTS[i]['at'])
          for i in range(1, len(g.CLIENT_EVENTS) + 1)]
check('the client is told the frame was grabbed', len(events), 1)
check('and it is told before the upload finishes', events[0][0], 'v-phone:media:captured')
check('the grab is signalled at the capture, not at the end',
      events[0][1] < shot['at'], True)

# ══════════════════════════════════════════════════════════════
# 2. A bucket that accepts the connection and then goes quiet
# ══════════════════════════════════════════════════════════════
# This is the case the old guard could not answer at all: it had already been disarmed by the
# capture callback, so nothing on the server was left to reply to a caller that had given up.
lua = fresh()
g = lua.globals()
g.UPLOAD_MS = None
shot = g.SHOOT(1)
g.RUN(40000)

check('a hung upload is still answered', shot['answers'], 1)
check('a hung upload answers an error', shot['result']['ok'] is None, True)
check('a hung upload is answered inside the 25s budget', shot['at'] <= 25050, True)
check('a hung upload is answered before the client gives up at 28s',
      shot['at'] < 28000, True)

# **The case the two guards actually differ on.** A hung upload alone is answered either way,
# because `uploadCapture`'s own poll gives up at twenty seconds. What the old arrangement could
# not bound was the SUM: its guard was disarmed the moment the capture landed, so a slow grab and
# then a dead host cost the capture time PLUS the full twenty - up to twenty-eight seconds
# against a client that had already given up at ten. One guard over the whole handler is the
# difference, and this is the case that proves it is one.
lua = fresh()
g = lua.globals()
g.CAPTURE_MS, g.UPLOAD_MS = 7000, None
slow = g.SHOOT(1)
g.RUN(60000)
check('a slow grab and then a dead host is answered', slow['answers'], 1)
check('and the two together still fit inside the 25s budget', slow['at'] <= 25050, True)
check('and inside the client\'s own 28s ceiling', slow['at'] < 28000, True)

# And the slot came back, so the player may try again rather than being told "busy" for the
# rest of their session.
lua = fresh()
g = lua.globals()
g.UPLOAD_MS = None
shot = g.SHOOT(1)
g.RUN(40000)
g.CAPTURE_MS, g.UPLOAD_MS = 100, 300
again = g.SHOOT(1)
g.RUN(45000)
check('the player may shoot again after a hung upload', again['result']['ok'], True)

# ══════════════════════════════════════════════════════════════
# 3. A capture resource that never calls back
# ══════════════════════════════════════════════════════════════
lua = fresh()
g = lua.globals()
g.CAPTURE_MS = None
shot = g.SHOOT(1)
g.RUN(40000)
check('a capture that never answers is answered', shot['answers'], 1)
check('and it is answered inside the budget', shot['at'] <= 25050, True)

# ══════════════════════════════════════════════════════════════
# 4. A second shot while the first is still going up
# ══════════════════════════════════════════════════════════════
lua = fresh()
g = lua.globals()
g.UPLOAD_MS = 6000
first = g.SHOOT(1)
g.RUN(3000)
second = g.SHOOT(1)
g.RUN(4000)

check('a second shot during an upload is refused', second['answers'], 1)
check('and it is refused with the camera\'s own reason, not the call app\'s',
      second['result']['error'], 'shotbusy')
g.RUN(12000)
check('the first shot still lands', first['result']['ok'], True)

# ══════════════════════════════════════════════════════════════
# 5. A slot nothing ever released
# ══════════════════════════════════════════════════════════════
# The lease is the backstop under the guard: even if a future path forgets to release, a slot
# older than the longest the handler may run is not an upload in progress.
lua = fresh()
g = lua.globals()
lua.execute("""
-- Reach past the guard entirely: pretend a handler took the slot and vanished, the way a
-- throwing export used to.
STRANDED = SHOOT(1)
""")
g.RUN(200)
lua.execute('CAPTURE_MS = nil')       # the retry's own capture will not answer either
g.RUN(40000)
retry = g.SHOOT(1)
g.RUN(80000)
check('a stranded slot does not lock the player out', retry['answers'], 1)
check('and the refusal is not "busy"', retry['result']['error'] != 'shotbusy', True)

# ══════════════════════════════════════════════════════════════
# 6. A capture too large to hand to another runtime
# ══════════════════════════════════════════════════════════════
# **This is the crash, as a test.** The capture arrives as a base64 string, is marshalled from
# screencapture's Node process into this Lua runtime, and is marshalled straight back out to the
# uploader - two synchronous crossings on the server's main thread, with Lua reading none of it.
# Nothing on that path measured the string. With the canvas type spelled `image/jpg` the browser
# silently produced a full-frame PNG instead of a JPEG, so every photograph was ten times the
# size it was supposed to be, and a shutter press ended in a SIGSEGV with an empty managed stack.
#
# The size is now refused before either export call. What is asserted is both halves: the player
# is told, and the bytes never reach the boundary.
lua = fresh()
g = lua.globals()
lua.execute("CAPTURE_PAYLOAD = { string.rep('A', 13 * 1024 * 1024) }")
huge = g.SHOOT(1)
g.RUN(30000)
check('an oversized capture is answered', huge['answers'], 1)
check('and it is answered with a reason of its own', huge['result']['error'], 'toolarge')
check('and it never crosses to the uploader', g.PUT_CALLS, 0)

# The slot comes back, so one bad frame does not end the session's camera.
g.CAPTURE_PAYLOAD[1] = 'data:image/jpeg;base64,AAAA'
after = g.SHOOT(1)
g.RUN(60000)
check('and the player may shoot again afterwards', after['result']['ok'], True)

# A capture resource that answers with something that is not a string at all - a build whose
# shape moved, a client that dropped part way. `#payload` on a nil throws inside a callback
# whose error nothing above it would ever see, so the type is checked before the length.
lua = fresh()
g = lua.globals()
lua.execute('CAPTURE_PAYLOAD = {}')      # cb(nil)
none = g.SHOOT(1)
g.RUN(30000)
check('a capture that is not a string is answered', none['answers'], 1)
check('and it is answered as a failed upload', none['result']['error'], 'upload')
check('and it never crosses to the uploader either', g.PUT_CALLS, 0)

# ══════════════════════════════════════════════════════════════
# 7. What is sent to the capture resource is bounded
# ══════════════════════════════════════════════════════════════
# Everything in this table leaves the Lua runtime for somebody else's canvas. A NaN written in a
# config used to reach `math.floor`, which throws, and an inf would have reached an allocator.
lua = fresh()
g = lua.globals()
lua.execute("""
Config.Media.imageQuality = 0/0
Config.Media.maxWidth = 1/0
Config.Media.maxHeight = -5
""")
odd = g.SHOOT(1)
g.RUN(2000)
check('a NaN quality falls back rather than travelling', g.CAPTURE_OPTIONS['quality'], 0.7)
check('an infinite width is clamped', g.CAPTURE_OPTIONS['maxWidth'], 4096)
check('a negative height is dropped, not sent', g.CAPTURE_OPTIONS['maxHeight'], None)
check('and the photograph still works', odd['result']['ok'], True)

print()
if failures:
    print('FAILED: %d' % len(failures))
    for f in failures:
        print('  ' + f)
    sys.exit(1)
print('camera capture path: all checks passed')
