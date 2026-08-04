# -*- coding: utf-8 -*-
"""Four photographs on one post: what the server accepts, and what it refuses. Under real Lua.

    python tools/test-multiphoto.py


The security half is the one that matters. A list is not one attachment with extras: an allowed
host on the first URL does not vouch for the fourth, and a version that checked only `image` -
the cover - would have made the other three a way straight past the host gate. Every URL is
checked on its own, and the test below sends a good cover with a bad third picture.

The shape half is what keeps the rest of the phone working. `image` still holds the FIRST
picture, because the profile grid, the share sheet, the story row, the home widget and every
export read that one field and none of them was taught about lists. `images` is written only
when there is more than one, so a single-photo post is byte for byte the row it always was.
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'server', 'social.lua'), encoding='utf-8').read()

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
function num(v, d) return tonumber(v) or d or 0 end
SOC = { maxImages = 4 }
V = { Setting = function(_, fallback) return fallback end }

-- Only this host is allowed, which is what makes a mixed list interesting.
function imageAllowed(url)
    return tostring(url):find('^https://ok%.example/') ~= nil
end

-- A minimal json, so the encode/decode round trip is real rather than stubbed.
json = { encode = function(t)
    local parts = {}
    for _, v in ipairs(t) do parts[#parts+1] = '"' .. tostring(v) .. '"' end
    return '[' .. table.concat(parts, ',') .. ']'
end, decode = function(s)
    local out = {}
    for m in tostring(s):gmatch('"([^"]*)"') do out[#out+1] = m end
    return out
end }
""")

# `maxImages` and `imagesOf`, exactly as the file writes them.
start = src.index('--- How many photographs one post may carry.')
end = src.index('\nlocal function cleanPosts', start)
lua.execute(src[start:end].replace('local function', 'function'))

# The write-side validation, lifted out of the post callback.
wstart = src.index('    -- **Every URL is checked on its own.**')
wend = src.index('\n    -- A clip is one file.', wstart)
# The lifted code answers by calling `resolve` and then RETURNING, so it runs inside its own
# function - otherwise a refusal returns out of the wrapper before the answer can be read, which
# is what the first version of this did.
lua.execute("""
function accept(data, kind, body)
    body = body or ''
    local resolved = nil
    local function resolve(r) resolved = r end
    local function run()
""" + src[wstart:wend] + """
        if kind == 'video' then list = { image } end
        return { ok = true, image = image, images = list,
                 stored = #list > 1 and json.encode(list) or nil }
    end
    local out = run()
    if resolved then return resolved end
    return out
end
""")

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


OK1 = 'https://ok.example/1.png'
OK2 = 'https://ok.example/2.png'
OK3 = 'https://ok.example/3.png'
OK4 = 'https://ok.example/4.png'
OK5 = 'https://ok.example/5.png'
BAD = 'https://evil.example/x.png'


def accept(images=None, image=None, kind='photo', body=''):
    data = {}
    if images is not None:
        data['images'] = lua.table_from(images)
    if image is not None:
        data['image'] = image
    return g.accept(lua.table_from(data), kind, body)


def listof(r):
    t = r['images']
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []


print('one photograph, which is every post that already exists')
r = accept(images=[OK1])
check(r['ok'] is True and r['image'] == OK1, 'accepted')
check(r['stored'] is None,
      'and nothing is written to `images`',
      'a single-photo row stays byte for byte what it always was')

print('four photographs')
r = accept(images=[OK1, OK2, OK3, OK4])
check(listof(r) == [OK1, OK2, OK3, OK4], 'all four are kept, in order', str(listof(r)))
check(r['image'] == OK1,
      'and `image` is the FIRST one',
      'the profile grid, the share sheet and every export read that field')

print('a bad host anywhere in the list')
r = accept(images=[OK1, OK2, BAD, OK4])
check(r['error'] == 'badhost',
      'refused, not silently dropped',
      'checking only the cover would have let the other three past the gate')
r = accept(images=[BAD])
check(r['error'] == 'badhost', 'and a bad cover is refused too')

print('more than the cap')
r = accept(images=[OK1, OK2, OK3, OK4, OK5])
check(len(listof(r)) == 4, 'truncated to four', str(len(listof(r))))
check(r['ok'] is True,
      'and posted rather than refused',
      'answering "too many" to somebody who attached five helps nobody')

print('the same photograph twice')
r = accept(images=[OK1, OK1, OK2])
check(listof(r) == [OK1, OK2], 'counted once', str(listof(r)))

print('an old client that only knows `image`')
r = accept(image=OK1)
check(r['ok'] is True and r['image'] == OK1 and r['stored'] is None,
      'still posts, exactly as before')

print('a text post with nothing in it')
r = accept(images=[], kind='text', body='   ')
check(r['error'] == 'empty', 'refused')
r = accept(images=[], kind='text', body='hello')
check(r['ok'] is True and r['image'] == '', 'and a text post needs no photograph')

print('a photo post with no photograph')
r = accept(images=[], kind='photo')
check(r['error'] == 'noimage', 'refused')

print('a clip is one file')
r = accept(images=[OK1, OK2, OK3], kind='video')
check(listof(r) == [OK1],
      'the extra frames are dropped',
      'four videos decoding in one card is a frame-rate problem, not a feature')

print('reading a row back')
row = lua.table_from({'image': OK1, 'images': '["%s","%s"]' % (OK1, OK2)})
out = g.imagesOf(row)
check([out[i] for i in range(1, len(out) + 1)] == [OK1, OK2], 'both come back')
row = lua.table_from({'image': OK1})
out = g.imagesOf(row)
check([out[i] for i in range(1, len(out) + 1)] == [OK1],
      'a row written before the column existed reads as its one photograph')
row = lua.table_from({'image': OK1, 'images': 'not json at all'})
out = g.imagesOf(row)
check([out[i] for i in range(1, len(out) + 1)] == [OK1],
      'and a corrupt list falls back to the cover rather than taking the feed down')

print()
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all multi-photo cases pass')
