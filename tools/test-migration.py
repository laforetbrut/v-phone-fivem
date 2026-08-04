# -*- coding: utf-8 -*-
"""The widening pass, under real Lua, against a fake information_schema.

    python tools/test-migration.py


There is no database here, so `MySQL` is stood up as a table that records what it was asked to
run. That is enough to check the three things that can go wrong and would only be discovered on
somebody's live server:

  - a column that is already 64 is left alone (the pass must be idempotent)
  - NOT NULL survives a MODIFY, which replaces the whole definition
  - a DEFAULT survives it too, and is quoted

And one thing that must NOT happen: no DROP of any kind.
"""
import io
import os

import lupa

ROOT = r'C:\Users\Jimmy\Documents\github\fivem-autres\v-phone'
src = io.open(os.path.join(ROOT, 'bridge', 'server', 'migrate.lua'), encoding='utf-8').read()

start = src.index('local ID_COLUMNS')
end = src.index('\nend\n', src.index('function Bridge.WidenIdColumns()')) + len('\nend\n')

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute('Bridge = {}')
lua.execute('''
RAN = {}
ROWS = {}
MySQL = {
    query = {
        await = function(sql, params)
            -- The SELECT is the schema question; anything else is an ALTER being recorded.
            if sql:find('information_schema') then return ROWS end
            RAN[#RAN + 1] = sql
            return true
        end,
    },
}
function setRows(t) ROWS = t end
''')
lua.execute(src[start:end])

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


def run(rows):
    lua.execute('RAN = {}')
    g.setRows(lua.table_from([lua.table_from(r) for r in rows]))
    n = g.Bridge.WidenIdColumns()
    ran = [str(g.RAN[i]) for i in range(1, len(g.RAN) + 1)]
    return n, ran


print('nothing to do')
n, ran = run([])
check(n == 0 and not ran, 'a database that is already right runs no ALTER', '%d statement(s)' % len(ran))

print('')
print('a narrow NOT NULL column')
n, ran = run([{'TABLE_NAME': 'vphone_contacts', 'COLUMN_NAME': 'citizenid',
               'IS_NULLABLE': 'NO', 'COLUMN_DEFAULT': None}])
check(n == 1, 'one column widened')
sql = ran[0] if ran else ''
check('MODIFY COLUMN `citizenid` VARCHAR(64)' in sql, 'it MODIFIES to 64', sql[:70])
check('NOT NULL' in sql, 'NOT NULL survives the redefinition')
check('DROP' not in sql.upper(), 'nothing is dropped')
check('`vphone_contacts`' in sql, 'the right table')

print('')
print('a nullable column with a default')
n, ran = run([{'TABLE_NAME': 'vphone_fundraise_gifts', 'COLUMN_NAME': 'donor',
               'IS_NULLABLE': 'YES', 'COLUMN_DEFAULT': ''}])
sql = ran[0] if ran else ''
check('NULL' in sql and 'NOT NULL' not in sql, 'it stays nullable', sql[:80])
check("DEFAULT ''" in sql, 'the default survives, quoted')

print('')
print('several at once, and a failure does not stop the rest')
lua.execute('''
MySQL.query.await = function(sql, params)
    if sql:find('information_schema') then return ROWS end
    RAN[#RAN + 1] = sql
    if sql:find('vphone_bad') then error('simulated: cannot widen') end
    return true
end
''')
n, ran = run([
    {'TABLE_NAME': 'vphone_bad', 'COLUMN_NAME': 'citizenid', 'IS_NULLABLE': 'NO',
     'COLUMN_DEFAULT': None},
    {'TABLE_NAME': 'vphone_notes', 'COLUMN_NAME': 'citizenid', 'IS_NULLABLE': 'NO',
     'COLUMN_DEFAULT': None},
])
check(len(ran) == 2, 'both were attempted', '%d attempted' % len(ran))
check(n == 1, 'one succeeded and one was reported, rather than the pass aborting', 'done=%s' % n)

print('')
print('%d failure(s)' % len(fails))
raise SystemExit(1 if fails else 0)
