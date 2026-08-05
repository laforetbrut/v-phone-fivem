# -*- coding: utf-8 -*-
"""Cash is not announced, and bank money still is. Under real Lua.

    python tools/test-money-notify.py


The two gates lifted out of server/bank.lua and driven through every combination that reaches
them: qb's money type, ESX's account name, and the operator's switch in both positions. A fix
that silences the complaint by silencing EVERYTHING would pass a "no cash notification" check
and be a worse bug, so the bank cases are asserted just as hard.
"""
import io
import os

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = io.open(os.path.join(ROOT, 'server', 'bank.lua'), encoding='utf-8').read()

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute("Config = { Bank = { notify = { cash = false } } }")
lua.execute("NOTIFY = Config.Bank.notify")

# `cashOn`, and the ESX account gate, exactly as they are written in the file.
start = src.index('local function cashOn()')
lua.execute(src[start:src.index('\n', start)].replace('local function', 'function'))

start = src.index('local function esxAccountHeard(account)')
end = src.index('\nend\n', start) + len('\nend\n')
lua.execute(src[start:end].replace('local function', 'function'))

# The qb line, as a function of the same shape so the same table drives both.
lua.execute("""
function qbHeard(moneyType)
    return not (tostring(moneyType or '') ~= 'bank' and not cashOn())
end
""")

g = lua.globals()
fails = []


def check(ok, what, detail=''):
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', what, ('  (%s)' % detail) if detail else ''))
    if not ok:
        fails.append(what)


print('cash off, which is the default')
check(g.qbHeard('bank') is True, 'qb: bank money is announced')
check(g.qbHeard('cash') is False, 'qb: CASH is not')
check(g.qbHeard('crypto') is False, 'qb: nor anything else the framework invents')
check(g.qbHeard(None) is False, 'qb: nor a missing type')
check(g.esxAccountHeard('bank') is True, 'esx: the bank account is announced')
check(g.esxAccountHeard('money') is False, 'esx: `money` is cash, and is not')
check(g.esxAccountHeard('black_money') is False, 'esx: nor anything else')

print('')
print('cash on, for a server that wants a money HUD')
lua.execute("NOTIFY.cash = true")
check(g.qbHeard('bank') is True, 'qb: bank money still announced')
check(g.qbHeard('cash') is True, 'qb: and now cash as well')
check(g.esxAccountHeard('bank') is True, 'esx: bank still announced')
check(g.esxAccountHeard('money') is True, 'esx: and now cash as well')
check(g.esxAccountHeard('black_money') is False, 'esx: but still not a third account')

print('')
print('%d failure(s)' % len(fails))
raise SystemExit(1 if fails else 0)
