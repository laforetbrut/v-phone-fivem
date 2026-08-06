fx_version 'cerulean'
game 'gta5'
lua54 'yes'

-- **Required by `server/s3.js`, and only by it.**
--
-- The S3 uploader is built on `fetch`, `FormData` and `Blob` as globals, which arrived in
-- Node 18, and on `node:crypto`. Without this line FiveM picks its older default runtime and
-- the file loads but throws `fetch is not defined` the first time somebody takes a photograph
-- - a failure that looks like a broken camera rather than a missing declaration.
--
-- Costs nothing on a server that never turns the camera on: the script registers exports and
-- does nothing until Config.Media asks for them.
node_version '22'

name 'v-phone'
author 'vyrriox'
description 'iFruit - a complete smartphone for FiveM. 37 apps, framework agnostic: qb-core, qbx_core, ox_core, ESX or standalone.'
version '1.6.4'
repository 'https://github.com/laforetbrut/v-phone-fivem'

-- The only hard requirement. Every framework, inventory, banking and voice script is
-- detected at runtime and every one of them is optional. See config.lua -> Config.Compat.
dependencies {
    'oxmysql',
}

shared_scripts {
    -- The bridge goes first: it defines V, the locale helper and the compatibility
    -- shims the rest of the resource is written against.
    'bridge/shared/v.lua',
    'bridge/shared/locale.lua',
    'bridge/shared/compat.lua',

    -- French first: it is the default language and the fallback for a key missing from
    -- another locale file, so it is the base table the others are read against.
    'locales/fr.lua',
    'locales/en.lua',
    'config.lua',
    -- Payphones. Loaded after config.lua because a booth's number is derived from the
    -- format the config names, and both the client and the server have to derive it the
    -- same way. See bridge/shared/booth.lua.
    'bridge/shared/booth.lua',
    -- Drop-in apps. `_loader.lua` defines PhoneApp(); the entries under it are the app
    -- folders this resource ships with.
    --
    -- **These are named, not globbed, and that is on purpose.** `apps/*/app.lua` looks
    -- tidier and cost nineteen warnings on every single restart:
    --
    --     Warning: could not find shared_script `apps/*/app.lua` (defined in fxmanifest.lua)
    --
    -- Two separate reasons, and both are permanent. A glob that matches nothing warns - and
    -- most of the per-extension patterns matched nothing, because an app folder that ships no
    -- stylesheet and no images is the normal case. And a glob does not resolve at all when
    -- the resource is installed as a junction or a symlink to a git checkout, which is how
    -- anybody developing against it runs it. Nineteen warnings that mean nothing teach an
    -- operator to ignore the console, which is where the warnings that DO mean something go.
    --
    -- The cost is two lines per app folder instead of zero. See DEVELOPERS.md.
    'apps/_loader.lua',
    'apps/example/app.lua',
}

client_scripts {
    -- The nets under the phone: a NUI callback that always answers, a watchdog for a cursor
    -- held by nothing, and death/respawn. FIRST, because it wraps `RegisterNUICallback` and a
    -- file that registered one before this loaded would not be wrapped.
    'bridge/client/safety.lua',
    -- Works out whether the local player is somewhere the phone charges (a property it
    -- has a key to) and reports it up a state bag, per housing script.
    'bridge/client/charging.lua',
    -- Answers the qb-phone client events a stock qb-core server fires: police dispatch,
    -- invoices, transaction banners. Named explicitly rather than globbed - a `bridge/*/`
    -- glob does not resolve when the resource is installed as a junction to a git checkout.
    'bridge/client/qb-phone.lua',
    'client/main.lua',
    -- The police forensics terminal: a point on the map and the NUI relays behind it.
    'client/police.lua',
    -- The verification desks: blips, a marker and the interaction that raises the sheet
    -- selling the blue tick. Must load AFTER client/main.lua, which is where the phone's own
    -- open sequence lives and where `PhoneShowScreen` is published.
    'client/verify.lua',
    -- The staff menu. qb-adminmenu cannot be extended from outside, so the phone brings its
    -- own - see the comment at the top of the file.
    'client/admin.lua',
    -- Zuber's doc-restaurant side. A QB server callback is reachable from any client and from
    -- no server, so the integration lives here rather than in server/zuber.lua.
    'client/zuber.lua',
    -- The Taxi app's doc-taxijob side, for the same reason.
    'client/taxi.lua',
    -- The Lottery app's doc-lottery side, and the draw it broadcasts.
    'client/lottery.lua',
    -- The Alerts app's doc-civilalerte side, and the broadcast it listens for.
    'client/alerts.lua',
    -- The Repair app's doc-mechanicmdt side: its garages, its ratings and its callout queue.
    'client/repair.lua',
    -- The Export app's page routes and its price banner. doc-shops is read on the SERVER,
    -- so unlike the others there is no bridging here.
    'client/export.lua',
    -- Messages written where there is no signal, held by the handset until the bars come
    -- back. Registers `send`, so it must load AFTER client/main.lua - which no longer
    -- registers it - and the outbox is what the page reaches.
    'client/outbox.lua',
    -- `/phonedebug doctor`: reads the resource's own shipped files at runtime and checks
    -- that every seam between the config, the server, the client and the page joins up.
    'client/doctor.lua',
    -- Payphones: finds the call box props already on the map, and holds the player to one.
    'client/booth.lua',
    -- The vehicle remote: finds a car by plate and applies what the server allowed.
    'client/vehicle.lua',
    -- An app folder's optional `client.lua` goes here, one line each. No app shipped with
    -- the phone has one, so there is nothing to list - and a glob for a file that does not
    -- exist is a warning on every restart.
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',

    -- **The one file here that is not Lua, and it is not a preference.**
    --
    -- Uploading to an S3 bucket needs three things CfxLua cannot do: a request body that
    -- survives a NUL byte (PerformHttpRequest passes it to curl without a length, so it stops
    -- at the first one, and every encoded image contains them), TLS peer verification (that
    -- same path disables it, and this request carries the bucket secret), and HMAC-SHA256.
    -- Node has all three. Loaded whatever the provider is - it registers exports and does
    -- nothing until Config.Media asks for them.
    'server/s3.js',
    -- Framework detection, per-character storage and the integrations every app reads.
    -- migrate.lua runs first: it moves an earlier build's tables to the vphone_ prefix.
    'bridge/server/migrate.lua',
    'bridge/server/kv.lua',
    'bridge/server/framework.lua',
    'bridge/server/characters.lua',
    'bridge/server/integrations.lua',

    -- Staff holding another character's phone. Straight after framework.lua, which builds
    -- `Core`, and before everything that uses it: this file wraps `Core.GetPlayer`, and a file
    -- that took its own copy of that function first would keep the unwrapped one.
    'server/adminview.lua',
    -- Staff-imposed network outages and out-of-service handsets. Before main.lua, whose
    -- `signalAt` and `hasBars` both read it on every signal tick.
    'server/outage.lua',
    -- Paid public chargers: who has paid for the stop they are standing in. Before main.lua,
    -- whose `chargeRateAt` asks `PaidChargeOk` on every battery tick - the same arrangement
    -- as outage.lua above.
    'server/charging.lua',
    -- Who still shows a photograph. Before main.lua: the sweep asks it, and a reference
    -- check that loads after the thing that calls it is a nil global at the worst moment.
    'server/mediaref.lua',
    -- Emptying an app from the console. Nothing here deletes without `confirm`.
    'server/adminclean.lua',
    'server/main.lua',
    -- Home screen widgets. Straight after main.lua, whose `prefsOf` and `PhoneHasApp` decide
    -- who is entitled to what, and BEFORE every file that registers a builder with it.
    'server/widgets.lua',
    -- Payphones: prepaid credit, the card, and the metered call. Loaded after main.lua,
    -- whose call machinery it drives.
    'server/booth.lua',
    -- The vehicle remote: ownership and distance are decided here, never on the client.
    'server/vehicle.lua',
    -- Bleeter, Snapmatic and Hush. Player-shared data, which the rest of the phone
    -- avoids, so it keeps its own file.
    'server/social.lua',
    -- Everything another resource is meant to call. Loaded after the app it wraps, so
    -- every export it builds on already exists. See API.md.
    'server/api.lua',
    -- The bank app: statement, transfers, beneficiaries. After api.lua, whose
    -- SendServiceMessage tells a recipient that money arrived.
    'server/bank.lua',
    -- OnlyFruits: photographs somebody pays to see. After social.lua, whose image host
    -- gate it shares, and after bank.lua, because every purchase moves real money.
    'server/creator.lua',
    -- Fruitee: donation pages. After creator.lua because it borrows the same money shape, and
    -- before nothing in particular - it owns its own three tables.
    'server/fundraise.lua',
    -- FlappyFruit and its shared scoreboard. Owns one table and nothing else's.
    'server/arcade.lua',
    -- FruitBrawl: two players, one duel. After main.lua because it looks numbers up through
    -- the resource's own exports.
    'server/brawl.lua',
    -- The GIF shelf, and the search key that never reaches the page. After main.lua, whose
    -- `PhoneLinkAllowed` decides which hosts a picture may come from.
    'server/gifs.lua',
    -- Reminders, and the clock that makes them go off. Its own table and its own sweep; after
    -- main.lua because it announces through the same banner path everything else uses.
    'server/reminders.lua',
    -- Store ratings and reviews. Its own file because it owns its own table, and after
    -- main.lua whose `PhoneHasApp` decides who is entitled to review what.
    'server/reviews.lua',
    -- How long the phone keeps anything, in one place, swept in batches. Last, so every table
    -- it prunes has been created by the file that owns it.
    'server/retention.lua',
    -- Garage, Property, Wallet and Jobs: read-only views over the bridge's providers,
    -- which is what those apps needed instead of a companion resource nobody has.
    'server/apps.lua',
    -- Bank Pro: the company account. After bank.lua, which owns the personal one, and after
    -- api.lua for the notification a paid employee receives.
    'server/bankpro.lua',
    -- 911: alerting the emergency services. After main.lua, whose `PhoneUsable`, `HasSignal`
    -- and `GetBattery` exports it asks before letting an alert through.
    'server/emergency.lua',
    -- Zuber: the config provider's menu, orders and money. doc-restaurant's own side is driven
    -- from client/zuber.lua; nothing here touches it.
    'server/zuber.lua',
    -- Taxi: the config provider's ride queue, fares and ratings. doc-taxijob's own side is
    -- driven from client/taxi.lua and is not touched here either.
    'server/taxi.lua',
    -- Lottery: the config provider's sessions, tickets, draw and prizes. doc-lottery's own side
    -- is driven from client/lottery.lua, where its QB server callbacks are reachable.
    'server/lottery.lua',
    -- Alerts: the config provider's table, permissions and broadcast. doc-civilalerte's own
    -- side is driven from client/alerts.lua, where its QB server callback is reachable.
    'server/alerts.lua',
    -- Repair: the config provider's garages, callouts and reviews, plus the two things
    -- doc-mechanicmdt has no way to do - ringing a garage, and ringing the client back.
    'server/repair.lua',
    -- Export: the market board, watched on a timer so a price alert can fire while the app
    -- is closed. doc-shops publishes GetMarketData as a SERVER export, which is why it is here.
    -- An app takes time to download, and a weak signal makes it take longer. Server-driven
    -- so it keeps running with the phone in a pocket and a client cannot skip it.
    'server/downloads.lua',
    'server/export.lua',
    -- The half of the doctor only the server can answer: which callbacks really
    -- registered, and what the app registry actually charges.
    'server/doctor.lua',
    -- Standing in for qb-phone on a qb-core server. After api.lua: it is built on SendMail,
    -- SendServiceMessage and Notify.
    'bridge/server/qb-phone.lua',
    -- Staff actions and the /phoneadmin command, wrappers over the exports above.
    'server/admin.lua',
    -- The police forensics terminal: session auth and the read callbacks.
    'server/police.lua',
    -- Photo and video hosting through screencapture + a CDN, with auto-deletion.
    'server/media.lua',
    -- Music heard by other people: a positioned sound has to be broadcast, and a broadcast
    -- is the server's to make. After main.lua, whose requireItem it checks.
    'server/music.lua',
    -- Asks GitHub whether a newer release exists and says so in the console. Reads its version
    -- and its repository out of this file, talks to nothing else, and answers no client.
    'server/update.lua',
    -- An app folder's optional `server.lua` goes here, one line each.
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    -- The design system, shipped inside the resource so the phone has no UI dependency.
    'html/theme.css',
    'html/theme-vars.css',
    'html/theme.js',
    'html/app.js',
    -- The app SDK. Served to any resource that ships a phone app, which is why it
    -- is a file rather than a copied snippet.
    'html/sdk.js',
    -- Store previews: a short silent clip of each app running, plus the manifest that says
    -- which apps have one. A NUI page cannot list a directory, so the manifest is how the
    -- store knows without a request per app. tools/make-previews.js rebuilds both.
    --
    -- The glob is on the FILE name, not the directory - `apps/*/index.html` is the pattern
    -- that does not resolve through a junction, and the one below behaves like 'sounds/*.wav'
    -- directly beneath it.
    'html/previews/index.json',
    -- Two of each: `bank.webm` is the dark recording and `bank.light.webm` its light twin,
    -- because a store showing an app in a theme its owner does not use is showing them
    -- somebody else's phone. One glob covers both.
    'html/previews/*.webm',
    -- One still per clip. The front page can show a dozen apps at once and only the shop
    -- window at the top moves; a dozen videos decoding behind a running game is a frame-rate
    -- problem, not a design.
    'html/previews/*.jpg',
    -- Ringtones, alerts and interface sounds. Generated rather than sampled, so they
    -- are safe to ship: tools/make-sounds.py rebuilds every one of them.
    'sounds/*.wav',
    -- A dropped-in app's page and its assets, named per app. The fifteen glob patterns that
    -- used to be here produced fifteen warnings on every restart, because an app folder that
    -- ships no stylesheet, no fonts and no audio is the ordinary case rather than the
    -- exception - and a glob does not resolve through a junction at all.
    'apps/example/index.html',
}
