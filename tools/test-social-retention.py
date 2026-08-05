# -*- coding: utf-8 -*-
"""How long a social row lives, decided once, under real Lua.

    python tools/test-social-retention.py


A bleet, a comment, a story and a social DM are deleted out of four tables, and until this
release **two files each carried their own number for them**: `socialSweep` in server/social.lua
and `PhoneRetentionSweep` in server/retention.lua. Both ran hourly, so the shorter number won and
nothing anywhere said so - posts configured to live sixty days went at thirty, and
`Config.Settings.socialRetentionS3`, a hundred and eighty days of feed for a server paying for its
own bucket, could never have taken effect at all. A documented setting that does nothing is worse
than a behaviour change.

`socKeep` is the one answer now and both sweeps ask it, so this drives the answer AND both call
sites. What it holds to account:

  the order         a `phone_socialRetention*` convar, then a `Config.Retention.social*` key a
                    server set for itself, then `socialRetentionS3` when the media provider is
                    s3, then `Config.Settings`. Most specific first, and each layer is shown
                    losing to the one above it.
  the two sweeps    `plan()` in server/retention.lua must answer exactly what `SocialKeepDays`
                    answers, for all four tables, on both providers. This is the regression the
                    whole change exists to close, so it is asserted per table rather than in
                    aggregate.
  the defaults      60 / 60 / 1 / 30 on fivemanage and 180 / 180 / 1 / 180 on s3, read out of the
                    real config.lua rather than repeated here - the numbers the config comments
                    and both README mirrors now promise an operator.
  a typo            a convar that is set but does not parse still means 0, keep for ever, which
                    is what the resource has always answered. Reading it as "unset" would quietly
                    swap that for six months, and did, in the first draft of this change.

Nothing is mocked but the four inputs: the convar table, the media provider, and the two config
tables. `socKeep`, `SocialKeepDays`, `plan` and `V.Setting` are lifted out of the shipped files as
written, so a change to any of their shapes fails here rather than in a month on somebody's feed.
"""
import io
import os
import re

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts):
    return io.open(os.path.join(ROOT, *parts), encoding='utf-8').read()


def lift(src, pattern, what):
    """One block, as written in the file it ships in.

    The block ends at the first line that is exactly `end` (or `}`), which is why every pattern
    below names a function or a table declared at column zero. Copying the code instead would
    make this test agree with itself for ever.
    """
    m = re.search(pattern, src, re.S)
    if not m:
        raise SystemExit('could not find %s - has it been renamed or reindented?' % what)
    return m.group(0)


SOCIAL = read('server', 'social.lua')
RETENTION = read('server', 'retention.lua')
BRIDGE = read('bridge', 'shared', 'v.lua')

# server/social.lua: the resolution order, and the door retention.lua comes through.
SOC_CHUNK = '\n'.join((
    lift(SOCIAL, r'local RETENTION_KEY = \{.*?\n\}\n', 'RETENTION_KEY'),
    lift(SOCIAL, r'local function socKeep\(kind\).*?\nend\n', 'socKeep'),
    lift(SOCIAL, r'function SocialKeepDays\(kind\).*?\nend\n', 'SocialKeepDays'),
))

# server/retention.lua: what it sweeps, and the helper that no longer decides anything.
RET_CHUNK = '\n'.join((
    lift(RETENTION, r'local R = Config\.Retention or \{\}\n', 'R'),
    lift(RETENTION, r'local function num\(v, d\).*?end\n', 'num'),
    lift(RETENTION, r'local function keep\(key, legacy\).*?\nend\n', 'keep'),
    lift(RETENTION, r'local function socialKeep\(kind, fallback\).*?\nend\n', 'socialKeep'),
    lift(RETENTION, r'local function plan\(\).*?\nend\n', 'plan'),
    'return plan',
))

# bridge/shared/v.lua: the convar-then-config lookup every setting in the phone goes through.
V_CHUNK = 'V = {}\n' + '\n'.join((
    lift(BRIDGE, r"local SETTING_PREFIX = 'phone_'\n", 'SETTING_PREFIX'),
    lift(BRIDGE, r'local function configSetting\(key, default\).*?\nend\n', 'configSetting'),
    lift(BRIDGE, r'function V\.Setting\(key, default\).*?\nend\n', 'V.Setting'),
))

HARNESS = """
function vec3(x, y, z) return { x = x, y = y, z = z } end
function vector3(x, y, z) return { x = x, y = y, z = z } end
Locales = { en = {}, fr = {} }

CONVARS = {}
function GetConvar(key, default)
    local v = CONVARS[key]
    if v == nil then return default end
    return v
end
"""


def lua_value(v):
    if v is None:
        return 'nil'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return repr(v)
    return "'%s'" % v


def world(provider='fivemanage', convars=None, retention=None, settings=None, social=True):
    """The real config.lua, with the four inputs set for one scenario.

    A fresh runtime each time on purpose: `R` in retention.lua and `SOC` in social.lua are file
    locals captured at load, which is exactly the shape a test that mutates a shared world gets
    wrong.
    """
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(HARNESS)
    lua.execute(V_CHUNK)
    lua.execute(read('config.lua'))

    for key, value in (convars or {}).items():
        lua.execute('CONVARS[%s] = %s' % (lua_value('phone_' + key), lua_value(value)))
    for key, value in (retention or {}).items():
        lua.execute('Config.Retention[%s] = %s' % (lua_value(key), lua_value(value)))
    for key, value in (settings or {}).items():
        lua.execute('Config.Settings[%s] = %s' % (lua_value(key), lua_value(value)))

    if provider is None:
        # server/media.lua has not loaded yet, or the server runs without it.
        lua.execute('MediaProvider = nil')
    else:
        lua.execute("PROVIDER = %s\nfunction MediaProvider() return PROVIDER end"
                    % lua_value(provider))

    # SOC is `Config.Social`, which social.lua takes as a file local.
    lua.execute('SOC = Config.Social')
    if social:
        lua.execute(SOC_CHUNK)
    plan = lua.execute(RET_CHUNK)
    return lua, plan


fails = []


def check(ok, label, detail=''):
    print('  %-4s %s%s' % ('ok' if ok else 'FAIL', label, ('  ' + detail) if detail and not ok else ''))
    if not ok:
        fails.append(label)


def keep(lua, kind):
    return lua.globals().SocialKeepDays(kind)


def swept(plan, table):
    """What `PhoneRetentionSweep` would use for one table, and whether it counts hours."""
    for entry in plan().values():
        if entry['table'] == table:
            return entry['days'], bool(entry['hours'])
    return None, False


TABLES = {
    'posts': 'vphone_social_posts',
    'comments': 'vphone_social_comments',
    'messages': 'vphone_social_dm',
    'stories': 'vphone_social_stories',
}

print('the shipped defaults, out of the real config.lua')
lua, plan = world('fivemanage')
for kind, want in (('posts', 60), ('comments', 60), ('stories', 1), ('messages', 30)):
    check(keep(lua, kind) == want, 'fivemanage keeps %s for %d day(s)' % (kind, want),
          str(keep(lua, kind)))

lua_s3, plan_s3 = world('s3')
for kind, want in (('posts', 180), ('comments', 180), ('stories', 1), ('messages', 180)):
    check(keep(lua_s3, kind) == want, 's3 keeps %s for %d day(s)' % (kind, want),
          str(keep(lua_s3, kind)))

print('')
print('both sweeps ask the same question and get the same answer')
for provider, l, p in (('fivemanage', lua, plan), ('s3', lua_s3, plan_s3)):
    for kind, table in TABLES.items():
        days, _ = swept(p, table)
        check(days == keep(l, kind),
              '%s: retention.lua and social.lua agree on %s' % (provider, kind),
              'sweep %s, social %s' % (days, keep(l, kind)))

days, hours = swept(plan, 'vphone_social_stories')
check(hours, 'a story is still swept in hours, not days')
days, _ = swept(plan, 'vphone_social_posts')
check(days != 30, 'the retention file no longer answers 30 for a post',
      'this is the number that silently won for four releases')

print('')
print('a Config.Retention value a server set for itself still decides')
lua, plan = world('fivemanage', retention={'socialPosts': 45})
check(keep(lua, 'posts') == 45, 'an explicit 45 beats the shipped 60', str(keep(lua, 'posts')))
check(swept(plan, 'vphone_social_posts')[0] == 45, '...at the retention sweep too')
check(keep(lua, 'comments') == 60, '...and the other three are untouched')

lua, plan = world('s3', retention={'socialPosts': 45})
check(keep(lua, 'posts') == 45, 'an explicit 45 beats the provider table as well',
      str(keep(lua, 'posts')))
check(swept(plan, 'vphone_social_posts')[0] == 45, '...at both call sites')
check(keep(lua, 'comments') == 180, '...and s3 still decides the rest')

lua, plan = world('s3', retention={'socialPosts': 0})
check(keep(lua, 'posts') == 0, 'an explicit 0 means keep for ever, and is not read as absent')
check(swept(plan, 'vphone_social_posts')[0] == 0, '...so neither sweep touches the table')

lua, _ = world('s3', retention={'socialPosts': 'soon'})
check(keep(lua, 'posts') == 180, 'a Config.Retention value that is not a number falls through',
      str(keep(lua, 'posts')))

print('')
print('a convar wins over every table below it')
lua, plan = world('s3', convars={'socialRetentionPosts': '90'}, retention={'socialPosts': 45})
check(keep(lua, 'posts') == 90, 'the convar beats both the s3 table and Config.Retention',
      str(keep(lua, 'posts')))
check(swept(plan, 'vphone_social_posts')[0] == 90, '...at the retention sweep too')

lua, _ = world('fivemanage', convars={'socialRetentionPosts': '90'})
check(keep(lua, 'posts') == 90, 'and on the hosted provider')

lua, _ = world('s3', convars={'socialRetentionPosts': '0'})
check(keep(lua, 'posts') == 0, 'a convar of 0 is a value, not an absence')

lua, _ = world('s3', convars={'socialRetentionPosts': 'never'})
check(keep(lua, 'posts') == 0, 'a convar that does not parse still means keep for ever',
      'reading a typo as unset would swap it for six months - it did, once')

lua, _ = world('s3', convars={'socialRetentionPosts': ''})
check(keep(lua, 'posts') == 180, 'an empty convar counts as unset, the way V.Setting reads it')

print('')
print('the provider table, when it is missing or wrong')
lua, _ = world('s3', settings={'socialRetentionS3': None})
check(keep(lua, 'posts') == 60, 'a config written before socialRetentionS3 keeps the plain four',
      str(keep(lua, 'posts')))

lua, _ = world('s3', settings={'socialRetentionS3': 'yes'})
check(keep(lua, 'posts') == 60, 'and so does one where it is not a table')

lua, _ = world(None)
check(keep(lua, 'posts') == 60, 'server/media.lua not loaded yet is not a crash',
      'it loads after social.lua, and the sweep must survive being early')

print('')
print('what this file does not own')
lua, plan = world('s3')
check(swept(plan, 'vphone_social_notifs')[0] == 14,
      'notification rows keep Config.Retention.socialNotifs',
      'no other sweep touches them, so that number stays where it is')
check(swept(plan, 'vphone_messages')[0] == 30, 'phone SMS is still Config.Retention.messages')
check(keep(lua, 'notifs') == 0,
      'and SocialKeepDays answers nothing for a kind it has no clock for')

lua, plan = world('s3', social=False)
days, _ = swept(plan, 'vphone_social_posts')
check(days == 60, 'without the social module the sweep falls back to Config.Social.retention',
      str(days))

print('')
if fails:
    print('%d failed' % len(fails))
    raise SystemExit(1)
print('all social retention cases pass')
