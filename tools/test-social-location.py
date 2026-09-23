# -*- coding: utf-8 -*-
"""Bleeter location posts use the server ped and leave ordinary posts unchanged."""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
source = io.open(os.path.join(ROOT, 'server', 'social.lua'), encoding='utf-8').read()
start = source.index("V.Callback('v-phone:soc:post'")
end = source.index("\nV.Callback('v-phone:soc:like'", start)

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute("""
SOC = { postMax = 280 }
json = { encode = function() return '[]' end }
function num(value, fallback) return tonumber(value) or fallback end
function appOfKind(kind) return kind == 'photo' and 'snap' or 'bleeter' end
function accountOf() return true end
function imageAllowed() return true end
function maxImages() return 4 end
function indexPost() end
Core = {
    GetPlayer = function() return { citizenid = 'test-character' } end,
    Log = function() end,
}
V = {
    Setting = function(_, fallback) return fallback end,
    Callback = function(_, handler) POST = handler end,
}
INSERTS = {}
MySQL = { insert = { await = function(sql, args)
    INSERTS[#INSERTS + 1] = { sql = sql, args = args }
    return 42
end } }
PED = 7
PED_READS = 0
function GetPlayerPed()
    PED_READS = PED_READS + 1
    return PED
end
function GetEntityCoords() return { x = 123.45, y = -67.89, z = 20 } end
function publish(data)
    local answer
    POST(1, function(value) answer = value end, data)
    return answer
end
""")
lua.execute(source[start:end])
g = lua.globals()


def publish(payload):
    return g.publish(lua.table_from(payload))


def check(condition, description):
    if not condition:
        raise AssertionError(description)
    print('  ok  ' + description)


print('Bleeter location post')
answer = publish({'app': 'bleeter', 'kind': 'text', 'body': '',
                  'shareLocation': True, 'x': 9999, 'y': 9999})
insert = g.INSERTS[1]
check(answer['ok'] is True, 'a location can be the only attachment')
check(float(insert['args'][7]) == 123.45 and float(insert['args'][8]) == -67.89,
      'coordinates come from the server ped, not the submitted payload')
check(g.PED_READS == 1, 'the ped is read once, at publication time')

print('Ordinary post')
answer = publish({'app': 'bleeter', 'kind': 'text', 'body': 'Hello'})
insert = g.INSERTS[2]
check(answer['ok'] is True and 'loc_x' not in insert['sql'],
      'ordinary posts retain the existing insert path')
check(g.PED_READS == 1, 'ordinary posts do not request a position')

print('Missing ped')
g.PED = 0
answer = publish({'app': 'bleeter', 'kind': 'text', 'body': '', 'shareLocation': True})
check(answer['error'] == 'nowhere' and len(g.INSERTS) == 2,
      'an unavailable position cannot create a misleading post')

print('No implicit sharing')
answer = publish({'app': 'bleeter', 'kind': 'text', 'body': '', 'x': 123.45})
check(answer['error'] == 'empty', 'coordinates without explicit consent do not make a post')

print('Snapmatic')
answer = publish({'app': 'snap', 'kind': 'photo', 'images': lua.table_from(['photo-fixture']),
                  'body': '', 'shareLocation': True})
check(answer['ok'] is True and 'loc_x' not in g.INSERTS[3]['sql'],
      'Snapmatic ignores Bleeter location sharing')

print('all social location cases pass')
