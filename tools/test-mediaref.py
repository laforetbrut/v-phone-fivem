# -*- coding: utf-8 -*-
"""Is anything still showing this photograph? Under real Lua.

    python tools/test-mediaref.py


The sweep deletes a file when its time is up. This is the question it must ask first, and the
one that decides whether a post keeps its caption and loses its picture.

**The case that matters most is the fragment.** The gallery appends its edit recipe to the URL -
`...#vp=<recipe>` - and that rides along into every column. So the natural way to write this
check, `WHERE image = ?`, answers "nobody is using it" for every photograph a player has
retouched, and the file is deleted out from under a post that is still on screen. That single
mistake is the whole bug, and it is invisible unless somebody tests with a retouched photo.

The queries are driven against a recorded fake, so what is asserted is the SQL that would be
sent, not a mock's opinion of it.
"""
import io
import os
import re

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'server', 'mediaref.lua'), encoding='utf-8').read()

lua = lupa.LuaRuntime(unpack_returned_tuples=True)

# A fake database. Every table exists; a row is "found" when the query's own WHERE would match
# the stored value, which is decided here in Python so the Lua under test gets no help.
lua.execute("""
STORED = {}          -- [table.column] = the value a row holds
ASKED  = {}          -- every query, for inspection

MySQL = { scalar = { await = function(q, args)
    ASKED[#ASKED+1] = { q = q, a = args }
    if q:find('information_schema') then return 1 end
    return PYMATCH(q, args)
end }, update = { await = function() return 0 end },
   query = { await = function() return {} end } }
""")


def like_to_regex(pattern):
    """SQL LIKE as a regex.

    Written by splitting on the wildcards rather than by escaping and substituting: since
    Python 3.7 `re.escape` leaves `%` alone, so the obvious `re.escape(v).replace(r'\\%', '.*')`
    replaces nothing and every LIKE silently fails to match. That cost this test seven false
    failures before the fake was believed over the code.
    """
    return '^' + '.*'.join(re.escape(part) for part in str(pattern).split('%')) + '$'


def pymatch(q, args):
    """Answer the query the way a database would, given STORED."""
    q = str(q)
    vals = [str(args[i]) for i in range(1, len(args) + 1)] if args is not None else []

    m = re.search(r'FROM `([a-z_]+)` WHERE `([a-z0-9_]+)`', q)
    if m:
        key = '%s.%s' % (m.group(1), m.group(2))
        stored = g.STORED[key]
        if stored is None:
            return None
        stored = str(stored)
        for v in vals:
            if '%' in v:
                if re.match(like_to_regex(v), stored, re.S):
                    return 1
            elif v == stored:
                return 1
        return None

    if 'vphone_kv' in q:
        for key in ('photos', 'phone'):
            stored = g.STORED['vphone_kv.' + key]
            if stored is None:
                continue
            for v in vals:
                if re.match(like_to_regex(v), str(stored), re.S):
                    return key
        return None
    return None


lua.globals().PYMATCH = pymatch
lua.execute('Bridge = {}')
lua.execute(src)
g = lua.globals()

fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


def reset():
    lua.execute('STORED = {} ASKED = {}')


URL = 'https://cdn.example/ab/cd/photo.webp'
RECIPE = URL + '#vp=eyJjcm9wIjoxfQ'

print('nothing anywhere')
reset()
check(g.Bridge.MediaReferencedBy(URL) is None, 'an unreferenced file is reported unreferenced')

print('a plain reference')
for place in ['vphone_social_posts.image', 'vphone_messages.attachment',
              'vphone_contacts.photo', 'vphone_mail.image',
              'vphone_hush_profiles.photo3', 'vphone_social_accounts.cover']:
    reset()
    lua.execute("STORED['%s'] = '%s'" % (place, URL))
    check(g.Bridge.MediaReferencedBy(URL) == place, 'found in ' + place)

print('THE FRAGMENT: the same photo, retouched')
for place in ['vphone_social_posts.image', 'vphone_messages.attachment',
              'vphone_contacts.photo']:
    reset()
    lua.execute("STORED['%s'] = '%s'" % (place, RECIPE))
    got = g.Bridge.MediaReferencedBy(URL)
    check(got == place,
          'a retouched copy in %s is still a reference' % place,
          'equality alone would delete a photo that is on screen' if got is None else str(got))

print('the JSON array of a multi-photo post')
reset()
lua.execute("""STORED['vphone_social_posts.images'] =
    '["https://cdn.example/other.webp","%s","https://cdn.example/third.webp"]'""" % URL)
check(g.Bridge.MediaReferencedBy(URL) == 'vphone_social_posts.images',
      'found inside the images array')
reset()
lua.execute("""STORED['vphone_social_posts.images'] = '["%s"]'""" % RECIPE)
check(g.Bridge.MediaReferencedBy(URL) == 'vphone_social_posts.images',
      'and found there retouched too')

print('a longer URL that merely starts the same way')
reset()
lua.execute("STORED['vphone_social_posts.image'] = '%s-thumbnail.webp'" % URL)
check(g.Bridge.MediaReferencedBy(URL) is None,
      'is not counted as a reference',
      'a bare %url% wildcard would keep files nobody has for ever')

print('the three that are not columns')
for key, label in [('photos', 'the gallery'), ('phone', 'the wallpaper and card photo')]:
    reset()
    lua.execute("""STORED['vphone_kv.%s'] = '{"a":1,"url":"%s","b":2}'""" % (key, URL))
    got = g.Bridge.MediaReferencedBy(URL)
    check(got == 'vphone_kv.' + key, '%s is found' % label, str(got))

print('the kv check runs last')
reset()
lua.execute("STORED['vphone_social_posts.image'] = '%s'" % URL)
g.Bridge.MediaReferencedBy(URL)
asked = [str(g.ASKED[i]['q']) for i in range(1, len(g.ASKED) + 1)]
kv = [i for i, q in enumerate(asked) if 'vphone_kv' in q]
check(not kv,
      'a hit in an indexed column never reaches the unindexed blob scan',
      'the kv LIKE has no index and must be the last resort')

print('the kv query names the columns the table actually has')
# The first version of mediaref.lua asked for `k` and `v`; vphone_kv declares `key` and
# `value` (bridge/server/kv.lua). The pcall swallowed the SQL error, so the check answered
# "not referenced" every time and the gallery protected nothing - and the test passed, because
# the fake answered whatever the query asked for. A stub that agrees with the code cannot catch
# the code being wrong about the world, so the schema is read from the file that declares it.
kv = io.open(os.path.join(ROOT, 'bridge', 'server', 'kv.lua'), encoding='utf-8').read()
create = kv[kv.index('CREATE TABLE IF NOT EXISTS `vphone_kv`'):]
create = create[:create.index(') ENGINE')]
real = set(re.findall(r'`([a-z_]+)`\s+(?:VARCHAR|LONGTEXT|TEXT|INT)', create))
check('key' in real and 'value' in real,
      'the table declares key and value', str(sorted(real)))

# The QUERY, not the file. The first version of this check searched the whole of mediaref.lua
# for the string `key`, and passed on the comment that explains the bug - so reintroducing the
# bug did not fail the test. A check that can be satisfied by prose is not a check.
# Taken from the LAST `SELECT` before `FROM vphone_kv` to the end of that statement. A regex
# starting at any SELECT crosses the earlier one in this file and swallows the comment between
# them - which is how the previous attempt read `k` and `v` out of prose and failed a correct
# file.
at = src.find('FROM vphone_kv')
start = src.rfind('SELECT', 0, at)
end = src.find('LIMIT 1', at)
stmt = src[start:end] if (at > 0 and start >= 0 and end > 0) else None
check(bool(stmt), 'the kv query was found in the source')
asked_cols = set(re.findall(r'`([a-z_]+)`', stmt or ''))
check(asked_cols and asked_cols.issubset(real),
      'and it names only columns the table has',
      'asks for ' + ', '.join(sorted(asked_cols)) + ' - the table has ' + ', '.join(sorted(real)))

print('the gallery delete asks only after the gallery has been written')
# Deleting a photograph in `server/main.lua` takes it out of the `photos` row and then, when
# nothing else shows the file, deletes the file. Those two steps have a required order, and it
# is the whole correctness argument: the check above scans `vphone_kv` for the URL and `photos`
# IS a `vphone_kv` row, so a check made before the write reads a database that still holds the
# photograph, answers "referenced", and keeps a file nothing points at any more.
#
# The check used to be spawned inside the `del` branch, above the write. It gave the right
# answer anyway - but only because the kv scan is the LAST of the eighteen queries above, which
# handed the write seventeen round trips of head start. That is an accident of ordering inside
# mediaref.lua, where the kv scan is last for SPEED. This asserts the order that does not
# depend on it.
main = io.open(os.path.join(ROOT, 'server', 'main.lua'), encoding='utf-8').read()
at = main.find("V.Callback('v-phone:photo'")
region = main[at:main.find('V.Callback(', at + 12)] if at >= 0 else ''
write_at = region.find("SetMetadataSync('photos'")
ask_at = region.find('MediaReferencedBy')
check(region and write_at >= 0 and ask_at >= 0 and write_at < ask_at,
      'the gallery row is written before the file is asked about',
      'asking first reads a row that still lists the photo, so nothing is ever deleted')

print('an empty url asks nothing at all')
reset()
check(g.Bridge.MediaReferencedBy('') is None, 'answered without a query')
check(len(g.ASKED) == 0, 'and no query was sent', str(len(g.ASKED)))

print()
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all reference cases pass')
