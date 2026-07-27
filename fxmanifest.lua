fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'v-phone'
author 'vyrriox'
description 'iFruit - a complete iOS 27 style phone for FiveM. Framework agnostic: qb-core, qbx_core, ox_core, ESX or standalone.'
version '1.4.4'
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
    'server/main.lua',
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
    -- Ringtones, alerts and interface sounds. Generated rather than sampled, so they
    -- are safe to ship: tools/make-sounds.py rebuilds every one of them.
    'sounds/*.wav',
    -- A dropped-in app's page and its assets, named per app. The fifteen glob patterns that
    -- used to be here produced fifteen warnings on every restart, because an app folder that
    -- ships no stylesheet, no fonts and no audio is the ordinary case rather than the
    -- exception - and a glob does not resolve through a junction at all.
    'apps/example/index.html',
}
