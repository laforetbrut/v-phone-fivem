"""Exercise VineMarket's server authorization and privacy under Lua 5.4."""
from pathlib import Path
import sys

from lupa import lua54

ROOT = Path(__file__).resolve().parent.parent
lua = lua54.LuaRuntime(unpack_returned_tuples=True)
lua.execute(r"""
Config = { Marketplace = { enabled = true, maxActive = 8, maxPrice = 100000000 } }
Money = { player = 1000, society = 0, failCredit = false, failRefund = false,
    failDebit = false, failReverse = false, throwCredit = false }
Bridge = {
    RemoveMoney = function(_, amount, account)
        if account ~= 'bank' or Money.failDebit or Money.player < amount then return false end
        Money.player = Money.player - amount
        return true
    end,
    AddMoney = function(_, amount, account)
        if account ~= 'bank' or Money.failRefund then return false end
        Money.player = Money.player + amount
        return true
    end,
    AddSociety = function(_, amount)
        if Money.throwCredit then error('simulated credit exception') end
        if Money.failCredit then return false end
        Money.society = Money.society + amount
        return true
    end,
    RemoveSociety = function(_, amount)
        if Money.failReverse then return false end
        Money.society = Money.society - amount
        return true
    end,
}
Players = {
    [1] = { citizenid = 'seller', name = 'Local seller', source = 1 },
    [2] = { citizenid = 'buyer', name = 'Local buyer', source = 2 },
    [3] = { citizenid = 'outsider', name = 'Local outsider', source = 3 },
}
Installed = { [1] = true, [2] = true, [3] = true }
Core = {
    GetPlayer = function(src) return Players[src] end,
    GetPlayerByCitizenId = function(cid)
        for _, p in pairs(Players) do if p.citizenid == cid then return p end end
    end,
}
PhoneHasApp = function(src) return Installed[src] end
PhoneLinkAllowed = function(url) return url == 'https://example.invalid/photo.png' end
PhoneStartPrivateCall = function(src, number)
    PrivateCall = { src = src, number = number }
    return true, 51
end
LP = function(_, key) return key end
exports = { ['v-phone'] = {
    GetNumber = function(_, cid) return cid == 'seller' and '555-2222' or '555-1111' end,
    Notify = function() end,
} }
CreateThread = function(fn) fn() end
Calls = {}
Callbacks = {}
V = { Callback = function(name, fn) Callbacks[name] = fn end }
Row = { id = 9, seller_cid = 'seller', seller_name = 'Local seller',
    kind = 'vehicles', deal = 'sale', title = 'Sultan RS', description = 'Clean car',
    price = 48000, period = 'once', area = 'Vinewood', image = '',
    show_phone = 0, status = 'active', created_at = os.time(),
    expires_at = os.time() + 86400 }
TestNow = os.time()
os.time = function() return TestNow end
Thread = { id = 31, listing_id = 9, buyer_cid = 'buyer', seller_cid = 'seller',
    title = 'Sultan RS', status = 'active', expires_at = Row.expires_at }
LastInsert = nil
LastQuery = nil
InsertFail = false
ActivationFail = false
MySQL = {
    query = { await = function(sql, args)
        LastQuery = { sql = sql, args = args }
        if sql:find('CREATE TABLE') then return {} end
        if sql:find('FROM vphone_market_listings') then return { Row } end
        if sql:find('FROM vphone_market_messages') then
            return { { id = 1, sender_cid = 'seller', body = 'Available', created_at = os.time() } }
        end
        if sql:find('FROM vphone_market_threads') then return {} end
        return {}
    end },
    single = { await = function(sql, args)
        if sql:find('FROM vphone_market_listings') then
            return args[1] == Row.id and Row or nil
        end
        if sql:find('FROM vphone_market_threads') then
            return args[1] == Thread.id and (args[2] == 'buyer' or args[2] == 'seller')
                and Thread or nil
        end
    end },
    scalar = { await = function(sql)
        if sql:find('COUNT') then return 0 end
        if sql:find('SELECT id FROM vphone_market_threads') then return Thread.id end
    end },
    insert = { await = function(sql, args)
        LastInsert = { sql = sql, args = args }
        if InsertFail then return nil end
        return 47
    end },
    update = { await = function(sql, args)
        if sql:find('vphone_market_listings') then
            if sql:find("SET status = 'active'") then return ActivationFail and 0 or 1 end
            if sql:find("status = 'closed'") and sql:find("status = 'pending'") then return 1 end
            return args[1] == Row.id and args[2] == Row.seller_cid and 1 or 0
        end
        return 1
    end },
}
function Run(src, data)
    TestNow = TestNow + 10
    local result
    Callbacks['v-phone:marketplace'](src, function(value) result = value end, data)
    return result
end
""")
lua.execute((ROOT / 'server' / 'marketplace.lua').read_text(encoding='utf-8'))
g = lua.globals()
checks = []


def check(value, label):
    checks.append((bool(value), label))
    print(('ok  ' if value else 'FAIL') + label)


def run(src, table):
    return g.Run(src, lua.eval(table))


g.Installed[2] = False
check(run(2, "{ op = 'feed' }").error == 'notinstalled', 'uninstalled app is refused')
g.Installed[2] = True

feed = run(2, "{ op = 'feed', kind = 'vehicles', query = 'Sultan' }")
check(feed.ok and feed.listings[1].phone is None and feed.listings[1].seller_cid is None,
      'feed never exposes number or character id')
check('LOCATE(?, title)' in g.LastQuery.sql and g.LastQuery.args[3] == 'vehicles',
      'search and category use bound SQL arguments')

detail = run(2, "{ op = 'detail', id = 9 }")
check(detail.listing.phone is None and detail.listing.showPhone is False,
      'hidden listing reveals no seller number')
g.Row.show_phone = 1
check(run(2, "{ op = 'detail', id = 9 }").listing.phone == '555-2222',
      'explicit public choice reveals the number')
g.Row.show_phone = 0

check(run(2, "{ op = 'close', id = 9 }").error == 'missing',
      'buyer cannot close seller listing')
check(run(1, "{ op = 'close', id = 9 }").ok, 'seller can close own listing')
check(run(1, "{ op = 'contact', id = 9 }").error == 'self',
      'seller cannot open a buyer conversation with self')
contact = run(2, "{ op = 'contact', id = 9 }")
check(contact.ok and contact.thread == 31 and contact.seller_cid is None,
      'buyer gets opaque thread id only')
check(run(3, "{ op = 'thread', id = 31 }").error == 'missing',
      'outsider cannot read conversation')
thread = run(2, "{ op = 'thread', id = 31 }")
check(thread.ok and thread.messages[1].body == 'Available'
      and thread.messages[1].sender_cid is None,
      'buyer reads message without character id')

call = run(2, "{ op = 'call', id = 9 }")
check(call.ok and call.id == 51 and call.number is None
      and g.PrivateCall.number == '555-2222',
      'private call uses server lookup without returning the number')

g.Row.status = 'closed'
g.Thread.status = 'closed'
check(run(2, "{ op = 'detail', id = 9 }").error == 'missing',
      'closed listing is hidden from buyers')
check(run(2, "{ op = 'call', id = 9 }").error == 'missing',
      'closed listing cannot be called')
check(run(2, "{ op = 'send', id = 31, body = 'hello' }").error == 'closed',
      'closed listing cannot receive new messages')
g.Row.status = 'active'
g.Thread.status = 'active'

check(run(1, "{ op = 'create', kind = 'invalid', deal = 'sale', title = 'x',"
             " description = 'y', price = 10 }").error == 'invalid',
      'invalid category is rejected')
check(run(1, "{ op = 'create', kind = 'items', deal = 'sale', title = 'x',"
             " description = 'y', price = 10, image = 'file:///secret' }").error == 'image',
      'unsafe image URL is rejected')
new = run(1, "{ op = 'create', kind = 'items', deal = 'sale', title = 'x',"
             " description = 'y', price = 10 }")
check(new.ok and g.LastInsert.args[11] == 0,
      'new listings default to hiding the seller number')

check(run(1, "{ op = 'pricing' }").fee == 0, 'free posting is the default')
g.Config.Marketplace.postingFee = 120
check(run(1, "{ op = 'pricing' }").error == 'payment',
      'paid posting requires a configured account')
g.Config.Marketplace.revenueAccount = 'society_newspaper'
g.Config.Marketplace.revenueLabel = 'The Daily Globe'
pricing = run(1, "{ op = 'pricing' }")
check(pricing.fee == 120 and pricing.label == 'The Daily Globe'
      and pricing.account is None, 'posting quote exposes fee and label only')

listing = "{ op = 'create', kind = 'items', deal = 'sale', title = 'x', description = 'y', price = 10 }"
g.InsertFail = True
check(run(1, listing).error == 'payment' and g.Money.player == 1000,
      'database insert failure does not debit the seller')
g.InsertFail = False
g.Money.failDebit = True
check(run(1, listing).error == 'nomoney' and g.Money.player == 1000,
      'failed debit never credits the beneficiary')
g.Money.failDebit = False
g.Money.failCredit = True
check(run(1, listing).error == 'noaccount' and g.Money.player == 1000
      and g.Money.society == 0, 'failed society credit refunds seller')
g.Money.failCredit = False
g.Money.throwCredit = True
check(run(1, listing).error == 'payment' and g.Money.player == 880
      and g.Money.society == 0,
      'unknown credit outcome is held for operator review without speculative refund')
g.Money.throwCredit = False
g.Money.player = 1000
g.ActivationFail = True
check(run(1, listing).error == 'payment' and g.Money.player == 1000
      and g.Money.society == 0, 'failed publication reverses both sides')
g.ActivationFail = False
check(run(1, listing).ok and g.Money.player == 880 and g.Money.society == 120,
      'paid publication debits once and credits configured society once')
retry = "{ op = 'create', requestId = 'post-unique-123', kind = 'items', deal = 'sale', title = 'x', description = 'y', price = 10 }"
first = run(1, retry)
again = run(1, retry)
check(first.ok and again.ok and first.id == again.id
      and g.Money.player == 760 and g.Money.society == 240,
      'retrying the same submission does not double charge')
check(run(1, "{ op = 'create', requestId = 'bad!', kind = 'items', deal = 'sale', title = 'x', description = 'y', price = 10 }").error == 'invalid',
      'malformed posting token is rejected')

source = (ROOT / 'server' / 'main.lua').read_text(encoding='utf-8')
def extract(name):
    start = source.index(f'local function {name}(')
    end = source.index('\nend\n', start) + len('\nend\n')
    return source[start:end].replace('local function', 'function', 1)


call_lua = lua54.LuaRuntime(unpack_returned_tuples=True)
call_lua.execute("""
CallsWritten = {}
MySQL = { insert = function(_, args) CallsWritten[#CallsWritten + 1] = args end }
cidOfNumber = function(value) return value end
callMembers = function() return { 1, 2 } end
callPeers = function(_, src) return { src == 1 and 2 or 1 } end
groupCfg = function() return { enabled = true } end
groupMax = function() return 5 end
CallOf = { [1] = 7, [2] = 7 }
Calls = { [7] = { a = 1, b = 2, aNum = '555-1111', bNum = '555-2222',
    private = true, anonymous = true, state = 'active',
    live = { [1] = { num = '555-1111', state = 'active' },
             [2] = { num = '555-2222', state = 'active' } } } }
""")
for function in ('logCall', 'rosterFor', 'canAddFrom', 'currentCallFor'):
    call_lua.execute(extract(function))
cg = call_lua.globals()
cg.logCall(cg.Calls[7], True)
check(cg.CallsWritten[1][2] == '' and cg.CallsWritten[2][2] == '',
      'both call history rows hide the other number')
check(cg.rosterFor(cg.Calls[7], 1)[2].number == ''
      and cg.rosterFor(cg.Calls[7], 2)[1].number == '',
      'each participant roster hides the peer number')
check(cg.currentCallFor(1).number == '' and cg.currentCallFor(2).number == ''
      and not cg.currentCallFor(1).canAdd,
      'call resync hides both numbers and disallows conference')
check("number = private and '' or toNumber" in source
      and "if c.private then resolve({ error = 'private' }) return end" in source
      and "and not c.private" in source,
      'outbound event, server conference and voicemail gates stay private')

failed = [label for ok, label in checks if not ok]
print(f'{len(checks) - len(failed)}/{len(checks)} passed')
sys.exit(1 if failed else 0)
