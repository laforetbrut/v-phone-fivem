# API

Everything another resource can call. The implementation is one file,
[`server/api.lua`](server/api.lua), plus the exports the phone's own modules publish.

Three rules hold throughout:

1. **A citizen id or a number identifies a person, never a source.** A source changes
   every time somebody reconnects, and an integration written against one breaks
   quietly. Where a source is genuinely what you have, the export takes one.
2. **Nothing trusts its caller with identity.** You may send a message *as* a service
   you name, because a script that pays wages has to. You may not read somebody's
   conversations, because nothing needs to.
3. **Every call returns something checkable.** Failure is `false, reason`, never a
   silent nil.


## Resolving somebody, and reaching them

### `WhoIs(target)`

```lua
local cid = exports['v-phone']:WhoIs(source)        --> 'ABC12345' or nil
local cid = exports['v-phone']:WhoIs('555-0142')
local cid = exports['v-phone']:WhoIs('ABC12345')
```

A source id, a phone number or a citizen id, resolved to a citizen id. Every other export here
takes a citizen id, and this is the resolution the phone uses internally - so nothing has to
guess which of the three it is holding.

### `SendServiceMedia(who, label, body, imageUrl)`

```lua
exports['v-phone']:SendServiceMedia(cid, 'Benny s',
    'Your car is ready.', 'https://i.imgur.com/abc.png')
```

`SendServiceMessage` with a picture attached. Answers `true, id` or `false, reason`. The URL goes
through the same host gate a player's own picture does; a host the operator has not allowed loses
the attachment and keeps the text.

### `LeaveVoicemail(toNumber, fromNumber, body)`

```lua
exports['v-phone']:LeaveVoicemail('555-0142', '555-0100', 'Call me back.')
```

Answers `true`, or `false` and one of `'off'`, `'nonumber'`, `'empty'`. The recipient is bannered
if they are connected and reads it in the app if they are not, exactly as a voicemail left by a
player behaves.

### `AddReminder(citizenid, atEpoch, text, note)`

```lua
exports['v-phone']:AddReminder(cid, os.time() + 7200,
    'Impound fee due', 'Bay 3, Davis')
```

Answers the row id, or `false` and a reason. It goes off through the phone's own sweep, so it
survives a restart and arrives whether or not the app is open. Bounded by the same caps a
player's own reminder is.

### `RefreshApp(source, appId)`

```lua
exports['v-phone']:RefreshApp(source, 'my_dispatch')
```

Tells a player's open app to redraw itself. A dropped-in app lives in an iframe and receives this
through the SDK's `refresh` event - `Phone.on('refresh', ...)`. Answers true if the player was
told; it does nothing if that app is not the one on screen.


## Server exports

### People and numbers

```lua
local phone = exports['v-phone']

phone:GetNumber(citizenid)              --> '555-0182' | nil
phone:FindByNumber(number)              --> citizenid | nil   (offline included)
phone:CitizenOfNumber(number)           --> citizenid | nil   (offline included)
phone:IsOnline(number)                  --> boolean
phone:IsOnCall(src)                     --> boolean
phone:IsPhoneOpen(src)                  --> boolean
phone:GetOnlineNumbers()                --> { [citizenid] = number }
phone:SetNumber(citizenid, number)      --> true | false, 'taken' | 'args'
```

### Messages

```lua
-- From one character to a number, exactly as if they had typed it.
phone:SendMessage(fromCitizenid, toNumber, body)      --> true | false, reason

-- From a NAME rather than a number: a shop, a dispatch, a fixer handing out work.
-- Nobody can call back a service that cannot answer.
--
-- `who` is whichever identifier you happen to hold - a source id, a phone number or a
-- citizen id. All three work, so you never have to convert one into another first.
phone:SendServiceMessage(who, 'LS Customs', 'Your car is ready.')
phone:SendSMS(who, 'Unknown', 'Bring the package to the docks.')   -- the same call

-- It lands in the thread, raises the badge, buzzes the phone, plays that app's tone and
-- is heard by anybody standing next to them. The sender name is capped at twelve
-- characters, which is what the column holds; a longer one is shortened and the console
-- says so once so you find out from a log line rather than from a player.

-- What was said, oldest first. Each row is
--   { id, mine, body, kind, attachment, at, seen }
-- `mine` is from the point of view of the citizen id you asked about.
--
-- Reading does NOT mark the thread read. A script asking what was said has not read it
-- on the player's behalf, and quietly clearing somebody's unread badge would be a side
-- effect nobody asked for and nobody could see.
phone:GetMessages(citizenid, otherNumber, limit)      --> { ... }

phone:UnreadCount(citizenid)            --> number
```

### Calls

```lua
-- Ring somebody, as though this player had dialled it themselves.
phone:Call(source, '5550142')                          --> true, callId | false, reason
phone:Call(source, '5550142', { anonymous = true })    -- withhold the number
phone:Call(source, '5550142', { video = true })

-- This goes THROUGH the phone's own dialler rather than around it, so every rule a
-- player meets applies: the caller needs a phone and a signal, the other end must be
-- connected and not already on a call, Do Not Disturb is honoured, and anybody standing
-- near the ringing phone hears it ring.
--
-- Errors: busy, busy_them, offline, dnd, nonumber, nophone, unreachable, self, noplayer.

-- Hang up. From either end, and on a conference this removes one person rather than
-- ending it for everybody.
phone:EndCall(source)                                  --> true | false, 'nocall'

phone:IsOnCall(source)                                 --> boolean
```

### Contacts

```lua
phone:AddContact(citizenid, name, number, favourite)  --> true | false, 'exists'
phone:RemoveContact(citizenid, number)                --> boolean
phone:GetContacts(citizenid)                          --> { { name, number, favourite } }
```

### Blocked numbers

A player's own list of people who cannot reach them. A blocked number cannot call, cannot add
them to a call, and cannot text - and is told none of it: a call reports the phone as off, and
a text is written to the sender's own thread and delivered nowhere.

Two things are worth knowing before you build on it. Everything in `Config.RequiredContacts` is
unblockable, 911 included. And an entry stores the CHARACTER as well as the number, so
`/phoneadmin renumber` neither breaks a block nor turns it into a mute on whoever is handed
that number next. Group messages are deliberately not filtered.

```lua
-- Everything a character has blocked. `c` is absent when nobody held the number at the time.
phone:GetBlocked(citizenid)              --> { { n = '555-0142', c = 'ABC12345' | nil }, ... }

-- Would a call or a text get through? Pass whichever of the two you have; both is better.
phone:IsBlocked(citizenid, fromNumber, fromCitizenid)  --> boolean

-- Block or unblock on a character's behalf - a staff tool acting on a report, without asking
-- the victim to go and do it themselves. Neither needs the character to be online.
phone:BlockNumber(citizenid, number)     --> true | false, 'args' | 'off' | 'required'
phone:UnblockNumber(citizenid, number)   --> true when it was there
```

### Mail

```lua
phone:SendMail(toCitizenid, 'hr@lscustoms.com', 'Your shift', 'You start at 18:00.')
--> true | false, 'nomailbox'
```

### Notifications

```lua
phone:Notify(src, app, title, body)                   --> boolean
phone:NotifyCitizen(citizenid, app, title, body)      --> true | false, 'offline'
phone:NotifyAll(app, title, body)                     --> true
```

`app` is an app id, which decides the icon: `phone`, `messages`, `mail`, `bank`,
`bleeter`, or your own registered app.

### Battery and signal

```lua
phone:GetBattery(src)                   --> 0..100
phone:SetBattery(src, percent)          --> boolean
phone:AddBattery(src, delta)            --> boolean
phone:GetSignal(src)                    --> 0..4
phone:HasSignal(src)                    --> boolean
phone:SetScreenOn(src, on)
```

### Apps

```lua
-- Ship an app from your own resource. The phone serves your page in an iframe and
-- gives it the SDK; see DEVELOPERS.md for the page side.
phone:RegisterApp('mycompany', {
    label    = 'My Company',
    icon     = 'briefcase',
    page     = 'https://cfx-nui-my-resource/html/app.html',
    category = 'work',
    job      = 'mycompany',      -- optional: only this job sees it
    optional = true,             -- a download rather than shipped
})
phone:UnregisterApp('mycompany')
phone:GetApps(src)               --> what this player may see

-- Put an optional app on somebody's phone without making them find it in the store.
phone:InstallApp(citizenid, 'mdt')      --> true | false, 'exists'
phone:UninstallApp(citizenid, 'mdt')    --> true | false, 'missing'
```

### Social

```lua
phone:SocialHandle(citizenid, 'bleeter')                 --> '@handle' | nil
phone:SocialPostAs(citizenid, 'text', 'Body', imageUrl)  --> boolean
```

### Diagnostics

```lua
phone:GetPhoneInfo()
--> {
--     version = '1.0.2', framework = 'qb', frameworkResource = 'qb-core',
--     inventory = 'ox_inventory', numberFormat = '555-####',
--     apps = { 'phone', 'messages', ... }, social = true,
--   }
```

Useful in a `/phonedebug` command: it says what the phone decided at boot, which is the
first question when an integration is not behaving.

#### Console commands

```
vphone_update       ask GitHub whether a newer release exists, and print the answer
vphone_media_test   post a one-pixel PNG to the configured upload endpoint, and print the
                    status the host answers with
```

Both are server console only. `vphone_media_test` exists because a failed upload reports
`write EPIPE`, which is the host closing the connection part way through the body: no status
code, no message, and a rejected key, an exhausted quota and an oversized file all look exactly
alike. The command takes screencapture out of the middle and asks the endpoint directly, with a
file small enough that size cannot be the answer. **401 or 403 is the key. 413 is the size. 429
is the quota. No answer at all means the host hung up on a one-pixel file, which is the key.**

### 911

Raising an emergency alert from another script: a till under robbery, a fire that started
itself, a player who went down with nobody around. The alert lands on the phones of everybody
working that service, with a position they can navigate to.

Which services exist, who answers for them, and the duty and grade rules are all
`Config.Emergency`. These exports do not bypass any of it — an alert for a service nobody is
working reaches nobody, and says so.

```lua
-- Somewhere specific.
local id, reached = phone:CreateAlert({
    service = 'police',                          -- an id from Config.Emergency.services
    reason  = 'Store robbery',                   -- shown as the alert's title
    detail  = '24/7 on Route 68',                -- optional second line
    coords  = vector3(1959.0, 3740.0, 32.3),
})

-- Or about a player, which fills in the position and the callback number for you.
local id, reached = phone:CreateAlert({
    service = 'ems',
    reason  = 'Player down',
    source  = playerId,
    anonymous = false,                            -- true hides the name and number
})

-- `source` is who the alert is ABOUT. It is not the caller, and the difference matters: an
-- alert raised against a robber must not tell the robber when a unit takes it or closes it,
-- must not show them the police response on their own 911 screen, and must not count against
-- the number of live calls they are allowed to make.
--
-- When a script genuinely has a caller — somebody pressed a panic button, an operator relayed
-- a call — name them.
local id, reached = phone:CreateAlert({
    service = 'police',
    reason  = 'Panic button',
    source  = suspectId,                          -- where to send help
    callerSource = clerkId,                       -- who called, and who gets told
})
-- `callerCid = 'ABC12345'` does the same for somebody who is offline.
```

`id` is the alert, `reached` is how many responders received it — **worth checking**. A script
that raised an alert nobody received may want to do something else as well, and `reached == 0`
is the only way to know. On failure it returns `false` and a reason.

```lua
phone:GetEmergencyQueue('police')    --> the live queue, newest first
phone:CloseAlert(id)                 --> true when it was there to close
phone:GetEmergencyServices()         --> { { id, label, jobs }, ... }
```

> **`GetAlerts` is registered twice, and this is not the one that answers.** The civil-alerts
> section further down exports the same name from a file loaded later, so a dispatch board
> written against `phone:GetAlerts('police')` receives civil alerts, or `nil`. Use
> `GetEmergencyQueue`. Both names are kept because retiring either would break whichever
> integration currently works.

Each alert in `GetEmergencyQueue` carries `id`, `service`, `reason`, `detail`, `at`, `state`
(`open` / `taken` / `closed`), `anonymous`, `takenBy`, and — unless the caller asked to stay
anonymous — `caller` and `number`. **Coordinates are deliberately not in it.** An alert list
that carried positions would be a way to read every emergency on the map from anywhere.

The map pin a responder sees is a separate thing, sent only to people already filtered to that
service, and how it behaves is entirely `Config.Emergency.blip` — automatic or on request, a
point or a search radius, flashing until answered, cleared or kept when the alert is taken. A
responder who presses *Take me there* gets a waypoint to the exact spot regardless. None of
that is reachable from these exports on purpose: a script decides **whether** to raise an
alert, the config decides what the service then sees.

`CloseAlert` is the full close, not a quiet delete: the pin comes off every map and the caller
is told, exactly as if a responder had closed it. A script that resolves whatever it raised
should call this rather than leaving everyone who was alerted still believing in it.

### External charging

For a vehicle script (an electric car), a solar backpack, a wall socket prop. While it is
on, the phone charges as if at a charger. `rate` is a multiplier: 1.0 is a wall charger,
2.0 twice as fast, capped by `Config.ExternalCharging.maxRate`.

```lua
phone:SetCharging(src, true, 1.5)   -- plugged in
phone:SetCharging(src, false)       -- unplugged
phone:IsCharging(src)               --> boolean
```

### Payphones

Talk time is held per character, in seconds, and spent by the booth's own meter. Use these
for a shop that sells calling cards, a reward, or an admin command.

```lua
phone:GetBoothCredit(src)            --> seconds of talk time
phone:AddBoothCredit(src, 600)       --> new balance, after adding ten minutes
phone:AddBoothCredit(src, -120)      --> and a negative takes time away
```

`AddBoothCredit` clamps to `Config.Booth.card.maxCredit` and pushes the new balance to any
booth panel the player has open, so the meter never shows a figure the server has moved on
from.

A booth's number is a pure function of where the box stands, so anything that knows the
coordinates can name the box - a dispatch logging which payphone a tip came from, for
instance. And because a payphone can never be rung, `IsBoothNumber` is the test to run
before you try:

```lua
phone:BoothNumberAt(215.5, -810.2, 30.7)   --> '311-4827', always the same for that box
phone:IsBoothNumber('311-4827')            --> true
phone:IsBoothNumber('555-0142')            --> false
```

### Admin

Every action is also behind `/phoneadmin` and the qb-core admin menu, gated by
`Config.Admin.ace`. Call them from your own admin menu on any framework.

```lua
phone:AdminReadPhone(citizenid)     --> { name, number, battery, unread, online, open, handles }
phone:OpenPhoneFor(src)             --> true | false, 'offline'   (support: see their screen)
phone:WipePhone(citizenid)          --> true, rowsRemoved        (IRREVERSIBLE)
```

### Network outages

The phone decides signal from the player's real position, and the worst ceiling always
wins. An outage is a ceiling with an operator behind it instead of a map, so it obeys the
same rule: a global outage at zero bars cannot be escaped by standing somewhere the map
calls perfect reception.

Bars rather than on/off, because *one bar* is a more interesting outage than *no phone*:
calls drop, messages fail, and players have to move to be heard.

```lua
phone:AddOutage(bars, minutes, reason)                         --> id   (whole server)
phone:AddOutage(0, 20, 'heist', { x = 250.0, y = -1000.0, z = 30.0, radius = 120.0 })
phone:ClearOutage(id)     -- or 'all'                          --> how many went
phone:GetOutages()                                             --> a list, with seconds left
```

`minutes = 0` means *until somebody clears it*, which is what a heist jammer wants.
**Nothing is persisted**: a restart clears every outage, deliberately, so an outage nobody
remembers setting can never survive a crash.

### A handset out of service

Not an outage - the network is fine, this phone is not. A phone that was smashed, a phone
confiscated at booking, a phone that has to be dead for a scene. Keyed by citizen id, so it
survives the player reconnecting, which is the point of confiscating something.

```lua
phone:BrickPhone(citizenid, minutes, reason)   -- 0 minutes: until unbricked
phone:UnbrickPhone(citizenid)
phone:IsPhoneBricked(citizenid)                --> boolean
```

A bricked phone refuses to open at all rather than opening onto features that quietly fail:
a phone that answers nothing reads as a broken script, and the player reports it as a bug
instead of playing the scene.

### Import / export

For a character transfer, a backup, or a support restore. Export is a plain table; import
writes it back under a citizen id. Contacts, notes, app data, preferences and the mailbox
travel; the phone number does not, because a number belongs to the server that minted it.

```lua
local data = phone:ExportPhone(citizenid)          -- a table you can store as JSON
phone:ImportPhone(otherCitizenid, data, true)      -- true replaces existing rows first
```

### Apps that ship with the phone

Each of these is here because another resource plausibly wants to read or drive one of the
phone's own apps. None of them is required for the phone to work.

```lua
local phone = exports['v-phone']

-- Is an app installed on this character's phone? The store, the paid apps and the
-- always-required floor all resolve through this, so it is the honest answer rather
-- than a look at the config.
phone:PhoneHasApp(src, 'lottery')            --> boolean

-- Can this player use their phone at all: the item, and enough charge.
phone:PhoneUsable(src)                       --> boolean

-- The number of whoever is on this source, without going through the citizen id.
phone:NumberOf(src)                          --> '555-0182' | nil
```

#### Export

```lua
-- The market board as the phone last read it - for a price sign in the world, a news ticker, or
-- a shop that wants to show the going rate. `market` is 'export' or 'import'; omit it for the
-- first one the operator listed.
--
-- Answers under BOTH providers, unlike the other apps' exports: under doc-shops this is a cached
-- copy of that resource's own answer, and saying so is more useful than nil to a script that
-- only wants a number.
phone:GetExportMarket('export')              --> { at, shop, doc, categories = { { key, label, items = { { name, label, price, min, max, previous, percent, history } } } } } | nil

-- One item's price, which is the question most callers actually have. The item's whole row
-- comes back as a second return value.
phone:GetExportPrice('gold', 'export')       --> price, item | nil
```

#### Repair

```lua
-- The callouts waiting at a garage - for a dispatch board, a whiteboard in the workshop, or a
-- sign in the world. Pass a job name for one garage, or nothing for every garage.
--
-- nil on a server running doc-mechanicmdt: the callouts are ITS rows, and a second function
-- answering the same question from a different table is how the two start disagreeing.
phone:GetRepairCalls('mechanic')             --> { { id, name, message, x, y, status, handled_by, created_at }, ... } | nil
```

#### Alerts

```lua
-- What is standing right now: the public alerts the authorities have broadcast and not yet let
-- expire. For a dispatch board, a news ticker or a sign in the world.
--
-- nil on a server running doc-civilalerte: the alerts are ITS rows, and a second function
-- answering the same question from a different table is how the two start disagreeing.
-- This is the name that wins: `server/alerts.lua` is loaded after `server/emergency.lua`,
-- which exports `GetAlerts` too. For the 911 queue call `GetEmergencyQueue` instead.
phone:GetAlerts()                            --> { { id, category, title, message, job, jobLabel, author, at, until_, active }, ... } | nil

-- Broadcast one from a script rather than from a phone: a weather system, a scripted disaster,
-- a console command of your own. It reaches every phone in the city, exactly as an officer's
-- would. `minutes` and `category` are whitelisted against Config.Alerts; `author` and
-- `authority` are the two lines the card prints underneath the headline.
--
-- No job check, on purpose: a resource calling this is already server-side and already trusted.
phone:RaiseAlert({ category = 'meteo', title = 'Storm warning',
                   message = 'Heavy rain until dawn.', minutes = 180,
                   authority = 'Weather Service', author = '' })
                                             --> alert | nil, reason
```

#### Lottery

```lua
-- The public state: jackpot, next draw, the prize tiers and the last few results. On a server
-- running doc-lottery this passes ITS own GetLotteryInfo through untouched, so a news script or
-- a dispatch board reads one shape whichever provider is live.
phone:GetLotteryState()                      --> { jackpot, status, drawLabel, drawAt, history, tiers, ticketPrice } | nil

-- Draw now, for a console command or a script of your own. Returns nil plus a reason when a
-- draw is already running or there is no open session.
phone:RunLotteryDraw('my-script')            --> true | nil, reason
```

#### Taxi

```lua
phone:GetTaxiRides()                         --> { { id, name, passengers, destination, x, y, z, state }, ... }
phone:GetTaxiDrivers()                       --> how many drivers are on duty
```

#### Zuber

```lua
phone:GetZuberRestaurants()                  --> the config provider's restaurants
phone:GetZuberOrders(restaurantId)           --> that restaurant's orders in flight
-- Omit the argument for every order in flight. Config-provider orders only: on a server
-- running doc-restaurant the orders are ITS rows and this answers an empty table.

-- Move an order along from your own kitchen script: 'accepted', 'cooking', 'delivering',
-- 'completed', 'cancelled'. The customer is notified and the app's tracker follows.
phone:SetZuberStatus(orderId, 'cooking')     --> boolean
```

#### Music

```lua
phone:IsPlayingMusic(src)                    --> boolean
phone:PauseMusic(src)
phone:StopMusic(src)
```

#### Social

```lua
-- The verified tick. Granted and revoked by staff in the phone's own menu; these are here so a
-- whitelist script can do it as part of something bigger.
phone:SetVerified('bleeter', handle, true)   --> boolean
phone:VerifiedHandles('bleeter')             --> { handle, ... }
```

#### Paid charging

```lua
phone:GetChargeSession(src)                  --> { point, rate, paid, since } | nil
phone:SetChargePaid(src, true)               --> boolean
```

#### Staff: holding another character's phone

```lua
-- What `/phoneadmin hold` uses. While a staff member holds a phone, every read and every
-- purchase is made AS the held character - see server/adminview.lua.
phone:AdminViewOpen(staffSrc, targetSrc)       --> boolean   (both are SOURCES)
phone:AdminViewTarget(staffSrc)                --> citizenid | nil
phone:AdminViewClose(staffSrc)
```

#### qb-phone compatibility

```lua
-- The mail entry point a stock qb-core server's scripts already call. Kept under its old name
-- so those scripts work unchanged.
phone:QbMail(citizenid, { sender = 'LSPD', subject = '...', message = '...' })

-- From a client script, addressed to the caller's own character - the recipient is always
-- the source, which is why this one takes no citizen id:
TriggerServerEvent('qb-phone:server:sendNewMail',
                   { sender = 'LSPD', subject = '...', message = '...' })
```

## Client exports

```lua
local phone = exports['v-phone']

phone:IsOpen()          --> boolean
phone:Open()
phone:Close()
phone:GetNumber()       --> the local player's number
phone:OnCall()          --> boolean
```

**Focus.** `PhoneOwnsFocus()` is a plain global rather than an export, because it has to be
readable from another resource's own client file without a round trip:

```lua
-- True while the phone, a payphone panel or the forensics terminal holds the cursor. Read it
-- before taking NUI focus yourself: two resources both believing they own the cursor is how a
-- player ends up unable to close either.
if PhoneOwnsFocus and PhoneOwnsFocus() then return end
```


## Commands

```
/refreshphone     tear down a stuck phone: prop, animation, NUI focus, control guard
/refresh-phone    same, the other spelling
/phoneadmin ...   staff actions, behind Config.Admin.ace
```

### /phoneadmin

```
info     [id|cid|number]                     number, battery, unread, online
who                                          everybody with a phone open right now
number   [id|cid]                             read it
contacts [id|cid]                             read the contact book
apps     [id|cid]                             what is installed
open     [id]                                open their phone on their screen
battery  [id] [0-100]
batteryall [0-100]                            every phone online
number   [id|cid] [number]                    set it
message  [id|cid] [text]                     a text message, from Staff
notify   [id|cid] [text]                     a banner, which does not persist
announce [text]                               that banner, to everybody online
app      [id|cid] give|take [appid]

outage   [bars 0-4] (minutes)                the whole server
outage   here [radius] [bars] (minutes)      a circle around you
outage   at [x] [y] [z] [radius] [bars] (minutes)
outage   clear [id|all]
outages                                      what is in force, and for how long

brick    [id|cid] (minutes)                  take one handset out of service
unbrick  [id|cid]
bricked                                      who is out of service

verify   [@handle] (off) (snap)              the verified badge
verified (snap)
wipe     [id|cid] confirm                    IRREVERSIBLE
```

Each subcommand has its own switch in `Config.Admin.actions`, so an action you do not want
staff to have can be removed entirely rather than trusted not to be typed.

**Permission.** `Config.Admin.ace` (default `vphone.admin`), or qb-core's `qbadmin.menu`:

```
add_ace group.admin vphone.admin allow
```

The bare `command` ace used to be accepted as well and no longer is. It is true for anybody
granted *any* command at all, which on many servers includes moderators, trusted players
and donors - none of whom were meant to be able to wipe a character's phone or cut the
network. `Config.Admin.aceCommandFallback = true` puts it back if your staff genuinely have
no other ace. Every refusal is printed to the server console with who tried it.

`refreshphone` is safe for any player to run: it only resets their own phone, for when it
sticks to the hand or an animation freezes. The server can trigger the same reset on a
player with `TriggerClientEvent('v-phone:client:forceReset', src)`.

## Server events

Listen rather than poll. All three carry citizen ids, so a listener survives a
reconnect.

```lua
AddEventHandler('v-phone:messageSent', function(fromCid, toCid, body, kind) end)
AddEventHandler('v-phone:phoneOpened', function(src, citizenid) end)
AddEventHandler('v-phone:phoneClosed', function(src, citizenid) end)
```

There are deliberately not more: an event nobody fires is worse than no event at all.

## State bags

```lua
Player(src).state.phoneOpen     -- replicated, true while the phone is up
LocalPlayer.state.invBusy       -- set by the phone so inventories stay shut
```

## Integration hooks

Anything the phone reads from your ecosystem can be replaced by a function of yours, in
`config.lua`. Yours wins over every detection.

```lua
Config.Compat.hooks.balances = function(src)
    return { cash = exports['my-bank']:GetCash(src), bank = exports['my-bank']:GetBank(src) }
end

Config.Compat.hooks.vehicles = function(citizenid, src)
    return exports['my-garage']:ListOwned(citizenid)
end
```

| Hook | Signature | Returns |
|---|---|---|
| `balances` | `(src)` | `{ cash, bank }` |
| `transactions` | `(src, citizenid)` | `{ { label, amount, at } }` |
| `vehicles` | `(citizenid, src)` | `{ { plate, model, garage, state } }` |
| `properties` | `(citizenid, src)` | `{ { label, address } }` |
| `licences` | `(src, citizenid)` | `{ { type, label } }` |
| `jobs` | `()` | `{ { name, label, grades } }` |
| `status` | `(src)` | `{ hunger, thirst }` |

See [COMPATIBILITY.md](COMPATIBILITY.md) for what each app reads when you fill none of
them, and [DEVELOPERS.md](DEVELOPERS.md) for writing an app that lives inside the phone.

---

# API (Version Française)

Tout ce qu'une autre ressource peut appeler. L'implémentation tient dans un fichier,
[`server/api.lua`](server/api.lua), plus les exports que publient les modules du
téléphone.

Trois règles valent partout :

1. **Un identifiant de personnage ou un numéro désigne une personne, jamais un source.**
   Un source change à chaque reconnexion, et une intégration écrite dessus casse en
   silence. Là où un source est vraiment ce dont vous disposez, l'export en prend un.
2. **Rien ne fait confiance à l'appelant sur l'identité.** Vous pouvez envoyer un
   message *au nom* d'un service que vous nommez, parce qu'un script qui verse des
   salaires en a besoin. Vous ne pouvez pas lire les conversations de quelqu'un, parce
   que rien n'en a besoin.
3. **Chaque appel renvoie quelque chose de vérifiable.** Un échec est `false, raison`,
   jamais un nil silencieux.

## Exports serveur

### Personnes et numéros

```lua
local phone = exports['v-phone']

phone:GetNumber(citizenid)              --> '555-0182' | nil
phone:FindByNumber(number)              --> citizenid | nil   (hors ligne compris)
phone:CitizenOfNumber(number)           --> citizenid | nil   (hors ligne compris)
phone:IsOnline(number)                  --> booleen
phone:IsOnCall(src)                     --> booleen
phone:IsPhoneOpen(src)                  --> booleen
phone:GetOnlineNumbers()                --> { [citizenid] = numero }
phone:SetNumber(citizenid, number)      --> true | false, 'taken' | 'args'
```

### Messages

```lua
-- D'un personnage vers un numero, exactement comme s'il l'avait tape.
phone:SendMessage(fromCitizenid, toNumber, body)      --> true | false, raison

-- Depuis un NOM plutot qu'un numero : une boutique, un dispatch, un contact qui
-- distribue du travail. Personne ne peut rappeler un service incapable de repondre.
--
-- `who` est l'identifiant que vous avez sous la main : identifiant de source, numero de
-- telephone ou citizen id. Les trois marchent, aucune conversion prealable.
phone:SendServiceMessage(who, 'LS Customs', 'Votre voiture est prete.')
phone:SendSMS(who, 'Inconnu', 'Apporte le colis aux docks.')       -- le meme appel

-- Le message arrive dans le fil, leve la pastille, fait vibrer le telephone, joue la
-- tonalite de cette application et s'entend a cote du joueur. Le nom d'expediteur est
-- limite a douze caracteres, ce que tient la colonne ; un nom plus long est raccourci et
-- la console le dit une fois, pour que vous l'appreniez d'une ligne de log et non d'un
-- joueur.

-- Ce qui a ete dit, du plus ancien au plus recent. Chaque ligne est
--   { id, mine, body, kind, attachment, at, seen }
-- `mine` est du point de vue du citizen id demande.
--
-- La lecture ne marque PAS le fil comme lu. Un script qui demande ce qui a ete dit ne
-- l'a pas lu a la place du joueur, et effacer sa pastille en silence serait un effet de
-- bord que personne n'a demande et que personne ne peut voir.
phone:GetMessages(citizenid, otherNumber, limit)      --> { ... }

phone:UnreadCount(citizenid)            --> nombre
```

### Appels

```lua
-- Faire sonner quelqu'un, comme si ce joueur avait compose le numero lui-meme.
phone:Call(source, '5550142')                          --> true, callId | false, raison
phone:Call(source, '5550142', { anonymous = true })    -- masquer le numero
phone:Call(source, '5550142', { video = true })

-- Cela passe PAR le composeur du telephone plutot qu'a cote, donc toutes les regles que
-- rencontre un joueur s'appliquent : l'appelant a besoin d'un telephone et de reseau, le
-- destinataire doit etre connecte et pas deja en ligne, Ne pas deranger est respecte, et
-- qui se tient a cote du telephone qui sonne l'entend sonner.
--
-- Erreurs : busy, busy_them, offline, dnd, nonumber, nophone, unreachable, self, noplayer.

-- Raccrocher. Des deux cotes, et sur une conference cela retire une personne plutot que
-- de terminer l'appel pour tout le monde.
phone:EndCall(source)                                  --> true | false, 'nocall'

phone:IsOnCall(source)                                 --> booleen
```

### Contacts

```lua
phone:AddContact(citizenid, name, number, favourite)  --> true | false, 'exists'
phone:RemoveContact(citizenid, number)                --> booleen
phone:GetContacts(citizenid)                          --> { { name, number, favourite } }
```

### Numeros bloques

La liste des personnes qui ne peuvent plus joindre un joueur. Un numero bloque ne peut ni
appeler, ni ajouter a un appel, ni ecrire - et n en est pas informe : un appel indique que le
telephone est eteint, et un message est ecrit dans le fil de l expediteur et livre nulle part.

Deux points a connaitre. Tout ce qui est dans `Config.RequiredContacts` est inblocable, 911
compris. Et une entree retient le PERSONNAGE en plus du numero, donc `/phoneadmin renumber` ne
casse pas un blocage et ne le transforme pas en sourdine sur celui qui recoit ce numero
ensuite. Les messages de groupe ne sont volontairement pas filtres.

```lua
-- Tout ce qu un personnage a bloque. `c` est absent si personne ne detenait le numero alors.
phone:GetBlocked(citizenid)              --> { { n = '555-0142', c = 'ABC12345' | nil }, ... }

-- Un appel ou un message passerait-il ? Donnez celui des deux que vous avez ; les deux valent
-- mieux.
phone:IsBlocked(citizenid, fromNumber, fromCitizenid)  --> boolean

-- Bloquer ou debloquer au nom d un personnage - un outil staff agissant sur un signalement,
-- sans demander a la victime de le faire elle-meme. Aucun des deux n exige qu il soit connecte.
phone:BlockNumber(citizenid, number)     --> true | false, 'args' | 'off' | 'required'
phone:UnblockNumber(citizenid, number)   --> true s il y etait
```

### Mail

```lua
phone:SendMail(toCitizenid, 'rh@lscustoms.com', 'Votre service', 'Vous commencez a 18h.')
--> true | false, 'nomailbox'
```

### Notifications

```lua
phone:Notify(src, app, title, body)                   --> booleen
phone:NotifyCitizen(citizenid, app, title, body)      --> true | false, 'offline'
phone:NotifyAll(app, title, body)                     --> true
```

`app` est un identifiant d'application, qui decide de l'icone : `phone`, `messages`,
`mail`, `bank`, `bleeter`, ou votre propre application enregistree.

### Batterie et reseau

```lua
phone:GetBattery(src)                   --> 0..100
phone:SetBattery(src, percent)          --> booleen
phone:AddBattery(src, delta)            --> booleen
phone:GetSignal(src)                    --> 0..4
phone:HasSignal(src)                    --> booleen
phone:SetScreenOn(src, on)
```

### Applications

```lua
-- Livrez une application depuis votre propre ressource. Le telephone sert votre page
-- dans une iframe et lui donne le SDK ; voir DEVELOPERS.md pour le cote page.
phone:RegisterApp('mycompany', {
    label    = 'Mon Entreprise',
    icon     = 'briefcase',
    page     = 'https://cfx-nui-my-resource/html/app.html',
    category = 'work',
    job      = 'mycompany',      -- optionnel : seul ce metier la voit
    optional = true,             -- un telechargement plutot qu'une app livree
})
phone:UnregisterApp('mycompany')
phone:GetApps(src)               --> ce que ce joueur peut voir

-- Poser une application optionnelle sur le telephone de quelqu'un sans qu'il ait a la
-- chercher dans le magasin.
phone:InstallApp(citizenid, 'mdt')      --> true | false, 'exists'
phone:UninstallApp(citizenid, 'mdt')    --> true | false, 'missing'
```

### Social

```lua
phone:SocialHandle(citizenid, 'bleeter')                 --> '@pseudo' | nil
phone:SocialPostAs(citizenid, 'text', 'Contenu', imageUrl)  --> booleen
```

### Diagnostic

```lua
phone:GetPhoneInfo()
```

Utile dans une commande `/phonedebug` : il dit ce que le telephone a decide au
demarrage, ce qui est la premiere question quand une integration se comporte mal.

### Recharge externe

Pour un script de vehicule (voiture electrique), un sac solaire, une prise murale. Tant
que c'est actif, le telephone se recharge comme a une borne. `rate` est un multiplicateur :
1.0 est une borne murale, 2.0 deux fois plus vite, plafonne par `Config.ExternalCharging.maxRate`.

```lua
phone:SetCharging(src, true, 1.5)   -- branche
phone:SetCharging(src, false)       -- debranche
phone:IsCharging(src)               --> booleen
```

### Cabines telephoniques

Le temps de communication est conserve par personnage, en secondes, et depense par le
compteur de la cabine. Utilisez ces exports pour une boutique qui vend des cartes, une
recompense, ou une commande admin.

```lua
phone:GetBoothCredit(src)            --> secondes de credit
phone:AddBoothCredit(src, 600)       --> nouveau solde, apres dix minutes ajoutees
phone:AddBoothCredit(src, -120)      --> et un negatif retire du temps
```

`AddBoothCredit` plafonne a `Config.Booth.card.maxCredit` et pousse le nouveau solde vers
toute cabine ouverte par le joueur : le compteur n'affiche donc jamais une valeur que le
serveur a deja depassee.

Le numero d'une cabine est une fonction pure de sa position : tout ce qui connait les
coordonnees peut nommer la borne - un dispatch qui journalise de quelle cabine vient un
tuyau, par exemple. Et comme une cabine ne peut jamais etre appelee, `IsBoothNumber` est le
test a lancer avant d'essayer :

```lua
phone:BoothNumberAt(215.5, -810.2, 30.7)   --> '311-4827', toujours le meme pour cette borne
phone:IsBoothNumber('311-4827')            --> true
phone:IsBoothNumber('555-0142')            --> false
```

### Admin

Chaque action est aussi derriere `/phoneadmin` et le menu admin qb-core, protegee par
`Config.Admin.ace`. Appelez-les depuis votre propre menu admin sur n'importe quel framework.

```lua
phone:AdminReadPhone(citizenid)     --> { name, number, battery, unread, online, open, handles }
phone:OpenPhoneFor(src)             --> true | false, 'offline'   (support : voir son ecran)
phone:WipePhone(citizenid)          --> true, rowsRemoved        (IRREVERSIBLE)
```

### Import / export

Pour un transfert de personnage, une sauvegarde, une restauration. L'export est une table
simple ; l'import la reecrit sous un citizen id. Contacts, notes, donnees d'app, preferences
et boite mail voyagent ; le numero non, car un numero appartient au serveur qui l'a cree.

```lua
local data = phone:ExportPhone(citizenid)          -- une table stockable en JSON
phone:ImportPhone(autreCitizenid, data, true)      -- true remplace les lignes existantes
```

### Applications livrees avec le telephone

Chacun de ces exports existe parce qu une autre ressource peut vouloir lire ou piloter une des
applications du telephone. Aucun n est necessaire au fonctionnement du telephone.

```lua
local phone = exports['v-phone']

-- L application est-elle installee sur ce telephone ? La boutique, les applications payantes et
-- le socle des applications obligatoires passent tous par la, donc c est la reponse reelle et
-- non une lecture du config.
phone:PhoneHasApp(src, 'lottery')            --> boolean

-- Ce joueur peut-il utiliser son telephone : l item, et assez de batterie.
phone:PhoneUsable(src)                       --> boolean

-- Le numero de la personne sur cette source, sans passer par le citizenid.
phone:NumberOf(src)                          --> '555-0182' | nil
```

#### Export

```lua
-- Le cours du marche tel que le telephone l a lu en dernier - pour un panneau de prix dans le
-- monde, un bandeau d information, ou un magasin qui veut afficher le tarif du jour. `market`
-- vaut 'export' ou 'import' ; omettez-le pour le premier que l operateur a liste.
--
-- Repond sous LES DEUX fournisseurs, contrairement aux exports des autres applications : sous
-- doc-shops c est une copie en cache de sa propre reponse, et le dire est plus utile qu un nil
-- pour un script qui ne veut qu un chiffre.
phone:GetExportMarket('export')              --> { at, shop, doc, categories = { { key, label, items = { { name, label, price, min, max, previous, percent, history } } } } } | nil

-- Le prix d un article, qui est la question que la plupart des appelants se posent vraiment. La
-- ligne complete de l article revient en deuxieme valeur de retour.
phone:GetExportPrice('gold', 'export')       --> prix, article | nil
```

#### Depannage

```lua
-- Les demandes en attente dans un garage - pour un tableau de bord, un tableau blanc dans
-- l atelier, ou un panneau dans le monde. Passez un nom de metier pour un garage, ou rien
-- du tout pour tous.
--
-- nil sur un serveur qui fait tourner doc-mechanicmdt : les demandes sont SES lignes, et une
-- seconde fonction repondant a la meme question depuis une autre table est le debut d un
-- desaccord entre les deux.
phone:GetRepairCalls('mechanic')             --> { { id, name, message, x, y, status, handled_by, created_at }, ... } | nil
```

#### Alertes

```lua
-- Ce qui est en cours : les alertes publiques diffusees par les autorites et pas encore expirees.
-- Pour un tableau de bord, un bandeau d information ou un panneau dans le monde.
--
-- nil sur un serveur qui fait tourner doc-civilalerte : les alertes sont SES lignes, et une
-- seconde fonction repondant a la meme question depuis une autre table est le debut d un
-- desaccord entre les deux.
-- C est ce nom qui l emporte : server/alerts.lua est charge apres server/emergency.lua, qui
-- exporte GetAlerts lui aussi. Pour la file du 911, appeler GetEmergencyQueue.
phone:GetAlerts()                            --> { { id, category, title, message, job, jobLabel, author, at, until_, active }, ... } | nil

-- Diffuser depuis un script plutot que depuis un telephone : un systeme meteo, une catastrophe
-- scriptee, une commande console a vous. Elle atteint tous les telephones de la ville, comme
-- celle d un officier. `minutes` et `category` sont verifies contre Config.Alerts ; `author` et
-- `authority` sont les deux lignes affichees sous le titre.
--
-- Aucun controle de metier, volontairement : une ressource qui appelle ceci est deja cote
-- serveur et deja de confiance.
phone:RaiseAlert({ category = 'meteo', title = 'Alerte orage',
                   message = 'Fortes pluies jusqu a l aube.', minutes = 180,
                   authority = 'Service meteo', author = '' })
                                             --> alerte | nil, raison
```

#### Loterie

```lua
-- L etat public : cagnotte, prochain tirage, rangs de gain et derniers resultats. Sur un serveur
-- qui fait tourner doc-lottery, son propre GetLotteryInfo est transmis tel quel : un script de
-- presse ou un tableau de bord lit une seule forme quel que soit le fournisseur actif.
phone:GetLotteryState()                      --> { jackpot, status, drawLabel, drawAt, history, tiers, ticketPrice } | nil

-- Lancer un tirage, pour une commande console ou un script a vous. Renvoie nil et une raison si
-- un tirage est deja en cours ou si aucune session n est ouverte.
phone:RunLotteryDraw('mon-script')           --> true | nil, raison
```

#### Taxi

```lua
phone:GetTaxiRides()                         --> { { id, name, passengers, destination, x, y, z, state }, ... }
phone:GetTaxiDrivers()                       --> nombre de chauffeurs en service
```

#### Zuber

```lua
phone:GetZuberRestaurants()                  --> les restaurants du fournisseur config
phone:GetZuberOrders(restaurantId)           --> les commandes en cours de ce restaurant
-- Sans argument, toutes les commandes en cours. Commandes du fournisseur config uniquement :
-- sur un serveur qui fait tourner doc-restaurant, les commandes sont SES lignes et ceci
-- renvoie une table vide.

-- Faire avancer une commande depuis votre propre script de cuisine : 'accepted', 'cooking',
-- 'delivering', 'completed', 'cancelled'. Le client est notifie et le suivi de l app suit.
phone:SetZuberStatus(orderId, 'cooking')     --> boolean
```

#### Musique

```lua
phone:IsPlayingMusic(src)                    --> boolean
phone:PauseMusic(src)
phone:StopMusic(src)
```

#### Reseaux sociaux

```lua
-- Le badge de verification. Accorde et retire par le staff dans le menu du telephone ; ces
-- exports sont la pour qu un script de liste blanche puisse le faire dans un ensemble plus large.
phone:SetVerified('bleeter', handle, true)   --> boolean
phone:VerifiedHandles('bleeter')             --> { handle, ... }
```

#### Recharge payante

```lua
phone:GetChargeSession(src)                  --> { point, rate, paid, since } | nil
phone:SetChargePaid(src, true)               --> boolean
```

#### Staff : tenir le telephone d un autre personnage

```lua
-- Ce que `/phoneadmin hold` utilise. Pendant qu un membre du staff tient un telephone, chaque
-- lecture et chaque achat se font AU NOM du personnage tenu - voir server/adminview.lua.
phone:AdminViewOpen(staffSrc, targetSrc)       --> boolean   (both are SOURCES)
phone:AdminViewTarget(staffSrc)                --> citizenid | nil
phone:AdminViewClose(staffSrc)
```

#### Compatibilite qb-phone

```lua
-- Le point d entree courrier que les scripts d un serveur qb-core appellent deja. Conserve sous
-- son ancien nom pour que ces scripts fonctionnent sans modification.
phone:QbMail(citizenid, { sender = 'LSPD', subject = '...', message = '...' })

-- Depuis un script client, adresse au personnage de l appelant - le destinataire est
-- toujours la source, c est pourquoi celui-ci ne prend pas de citizenid :
TriggerServerEvent('qb-phone:server:sendNewMail',
                   { sender = 'LSPD', subject = '...', message = '...' })
```

## Exports client

```lua
local phone = exports['v-phone']

phone:IsOpen()          --> booleen
phone:Open()
phone:Close()
phone:GetNumber()       --> le numero du joueur local
phone:OnCall()          --> booleen
```

**Le focus.** `PhoneOwnsFocus()` est une globale et non un export, parce qu elle doit etre lisible
depuis le fichier client d une autre ressource sans aller-retour :

```lua
-- Vrai tant que le telephone, une cabine ou le terminal scientifique detient le curseur. Lisez-la
-- avant de prendre le focus NUI vous-meme : deux ressources persuadees de detenir le curseur, et
-- le joueur ne peut plus fermer ni l une ni l autre.
if PhoneOwnsFocus and PhoneOwnsFocus() then return end
```


## Evenements serveur

Ecoutez plutot que d'interroger. Les trois portent des identifiants de personnage, une
ecoute survit donc a une reconnexion.

```lua
AddEventHandler('v-phone:messageSent', function(fromCid, toCid, body, kind) end)
AddEventHandler('v-phone:phoneOpened', function(src, citizenid) end)
AddEventHandler('v-phone:phoneClosed', function(src, citizenid) end)
```

Il n'y en a volontairement pas plus : un evenement que personne n'emet est pire que pas
d'evenement du tout.

## State bags

```lua
Player(src).state.phoneOpen     -- replique, vrai tant que le telephone est ouvert
LocalPlayer.state.invBusy       -- pose par le telephone pour que les inventaires restent fermes
```

## Points d'accroche

Tout ce que le telephone lit dans votre ecosysteme peut etre remplace par une fonction a
vous, dans `config.lua`. La votre l'emporte sur toute detection.

```lua
Config.Compat.hooks.balances = function(src)
    return { cash = exports['my-bank']:GetCash(src), bank = exports['my-bank']:GetBank(src) }
end
```

| Hook | Signature | Renvoie |
|---|---|---|
| `balances` | `(src)` | `{ cash, bank }` |
| `transactions` | `(src, citizenid)` | `{ { label, amount, at } }` |
| `vehicles` | `(citizenid, src)` | `{ { plate, model, garage, state } }` |
| `properties` | `(citizenid, src)` | `{ { label, address } }` |
| `licences` | `(src, citizenid)` | `{ { type, label } }` |
| `jobs` | `()` | `{ { name, label, grades } }` |
| `status` | `(src)` | `{ hunger, thirst }` |

Voir [COMPATIBILITY.md](COMPATIBILITY.md) pour ce que lit chaque application quand vous
n'en remplissez aucun, et [DEVELOPERS.md](DEVELOPERS.md) pour ecrire une application qui
vit dans le telephone.
