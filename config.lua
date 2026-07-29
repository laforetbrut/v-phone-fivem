-- ╔════════════════════════════════════════════════════════════════════════════╗
-- ║                                                                            ║
-- ║    iFruit                                                                  ║
-- ║    v-phone  ·  the one file you edit                                       ║
-- ║                                                                            ║
-- ║    Nothing in here needs anything but this resource restarted:              ║
-- ║        refresh                                                             ║
-- ║        restart v-phone                                                     ║
-- ║                                                                            ║
-- ╚════════════════════════════════════════════════════════════════════════════╝
--
--  READ THIS MUCH AND YOU CAN CONFIGURE THE REST
--  ─────────────────────────────────────────────
--
--    ·  Everything that CAN be detected IS, and the setting for it reads `auto`. A stock
--       qb-core, ESX or ox server needs nothing in this file changed to start.
--
--    ·  A setting you do not recognise is a setting you can leave alone. There is no
--       default below that is wrong for an ordinary server.
--
--    ·  `nil` and `false` are different answers. `nil` means "work it out for me";
--       `false` means "off, and do not work anything out".
--
--    ·  Anything that costs money, grants access, or writes to a database is checked
--       again on the SERVER. Nothing here is enforced by the interface alone, so a
--       modified client cannot buy, unlock or award itself anything.
--
--    ·  Prices are whole dollars. Distances are metres. Times are seconds unless the
--       comment beside them says otherwise.
--
--
--  TWO THINGS WORTH KNOWING BEFORE YOU CHANGE ANYTHING
--  ──────────────────────────────────────────────────
--
--  **The phone is a shell, not a feature.** Every app is a thin view over whatever already
--  owns its data: the bank app asks your banking script for a balance, it does not keep
--  one. The moment an app holds its own copy of something there are two sources of truth
--  and one of them is wrong. Messages, contacts and the phone's own settings are the only
--  things it owns outright.
--
--  **Every table it creates begins with `vphone_`,** so it can never collide with a table
--  another resource owns. A server upgraded from an older build has its data moved to
--  those names at boot - see bridge/server/migrate.lua.
--
--
--  WHAT IS WHERE
--  ─────────────
--  Line numbers, so any section is one jump away. **Regenerate this rather than editing
--  it**: every entry was wrong by up to a thousand lines the last time it was checked by
--  hand, which is what a hand-maintained index does. tools/check.py could own it.
--
--    79    COMPATIBILITY          3653  HOW LONG THE PHONE KEEPS THINGS
--    426   SETTINGS               3715  HOME SCREEN WIDGETS
--    562   LICENCE NAMES          3756  THE UPDATE CHECK
--    622   HOW A NUMBER IS DISPLAYED 3788  A PHONE HEARD RINGING
--    1736  WRITING A POSITION     3844  COMMANDS
--    2324  PAID CHARGING          3866  THE SDK EXAMPLE APP
--    2414  ADMIN                  4038  EXTERNAL CHARGING
--    2420  LOGGING                4060  POLICE FORENSICS
--    2430  911                    4062  THE HEALTH RECORD
--    2669  BANK PRO               4102  HOSPITALS
--    3335  THE CLOCK              4130  PROPERTY
--    3351  THE NETS UNDER THE PHONE 4161  GARAGES
--    3396  ONLYFRUITS             4180  BANK
--
--  IF SOMETHING DOES NOT BEHAVE
--  ────────────────────────────
--  Each of these prints what the phone actually decided, which beats guessing:
--
--    /phonecompat   which framework, inventory, banking and voice script were detected
--    /phonevoice    whether a call can carry audio, and why a weak signal does or does
--                   not break it up
--    /phonecharge   why the phone believes it is or is not charging
--    /phoneapps     what this character has installed, and what the store is offering
--
Config = {}

-- ══════════════════════════════════════════════════════════════
--  COMPATIBILITY
-- ══════════════════════════════════════════════════════════════
-- **This phone runs on your framework, not the other way round.**
--
-- Everything in this section is `auto` by default, which means "look at what is running
-- and use it". Naming something explicitly always wins over the detection, and `off`
-- switches an integration out entirely. You should be able to drop this resource on a
-- qb-core, qbx_core, ox_core or ESX server and have it work without editing a line -
-- and to bend every one of those decisions here when you do need to.

--- `auto` | `qb` | `ox` | `esx` | `standalone`
--- Standalone works: the phone falls back to the licence identifier and has no job.
Config.Framework = 'auto'

-- Moving an earlier build's data to the `vphone_` prefix at boot.
--
-- **Off by default, on purpose.** A fresh install has no legacy tables and needs none of
-- this, and nothing surprising should happen to your database the first time you start a
-- resource. Turn it on ONLY if you are upgrading a server that ran v-phone 1.0.0 to 1.0.4.
--
--   false   (default) never migrate. Fresh installs, and anyone who would rather move
--           their own data, want this. The phone creates its `vphone_` tables and starts.
--   'auto'  rename a legacy table ONLY if its columns match this resource's own schema.
--           A table that merely shares a name - another script's `phone_contacts` - fails
--           the check and is never touched. Safe to leave on while upgrading.
--   true    trust the names and rename without the column check. Only if you are certain
--           every legacy-named table on the server is this phone's.
Config.MigrateLegacyTables = false

--- The inventory item a player must carry, when `Config.Settings.requireItem` is on.
Config.PhoneItem = 'phone'

--- The item that recharges a phone, and how much it gives back.
---
--- Configurable for the same reason the handset is: a server that already calls this something
--- else should be able to say so rather than being told what its own items are named. The name
--- was hardcoded, which meant an existing `battery_pack` or `powerbank_v2` simply did not work
--- and nothing said why.
---
--- `powerbank` is registered as well whatever you set, so an existing item keeps working.
--- How much charge it returns is `Config.Settings.powerbankCharge`.
Config.PowerbankItem = 'powerbank'

-- ══════════════════════════════════════════════════════════════
-- Two notifications for one payment
-- ══════════════════════════════════════════════════════════════
-- A paycheck lands and you are told twice: once by the phone, once by your framework's own
-- notification in the corner of the screen.
--
-- **The phone cannot switch the other one off, and no setting here will.** That is not a
-- missing feature, it is how FiveM works: an event handler belongs to the resource that
-- registered it, nothing can unregister another resource's, and `GetCoreObject()` hands every
-- resource its OWN copy of the core table - so overwriting `Notify` here would only ever
-- change it for this phone. Anything claiming otherwise in this file would be a lie.
--
-- What DOES work is routing the framework's notification INTO the phone, which is one line in
-- a file you already own. The phone publishes the export for exactly this:
--
--     exports['v-phone']:Notify(source, 'bank', title, body)
--     exports['v-phone']:NotifyMoney(source, 250, 'Overtime')
--
-- **Everything through the phone** - qb-core, in `qb-core/client/functions.lua`, inside
-- `QBCore.Functions.Notify`. Replace the body with a phone banner and every script on the
-- server that notifies is suddenly notifying on the handset:
--
--     function QBCore.Functions.Notify(text, texttype, length)
--         local body = type(text) == 'table' and (text.text or text.caption) or text
--         TriggerServerEvent('v-phone:compat:notify', tostring(body or ''), texttype)
--     end
--
-- **Only the paycheck** - if you would rather keep the corner notification for everything else,
-- find the paycheck loop in `qb-core/server/main.lua` and delete only its `Notify` line. The
-- phone already announces the deposit through `Config.Bank`.
--
-- Either way it is a change in qb-core, not here, and it survives a v-phone update precisely
-- because it is not in v-phone.
Config.Compat = {
    -- ── Which script answers what ──────────────────────────────
    -- Each of these is `auto`, `off`, or the exact resource name to use.
    inventory = 'auto',   -- ox_inventory, qs-inventory, ps-inventory, qb-inventory, origen_inventory, codem-inventory
    banking   = 'auto',   -- qs-banking, Renewed-Banking, qb-banking, okokBanking, esx_banking
    garage    = 'auto',   -- qs-advancedgarages, jg-advancedgarages, qb-garages, cd_garage, okokGarage
    housing   = 'auto',   -- qs-housing, ps-housing, qb-houses, ox_property, loaf_housing, esx_property
    voice     = 'auto',   -- pma-voice, saltychat, mumble-voip
    notify    = 'auto',   -- ox_lib, qb, esx, chat, custom
    -- ── Whose phone numbers ────────────────────────────────────
    -- **The setting to reach for on a server that already has players.**
    --
    -- qb-core writes a phone number into `charinfo` when a character is created, and ox_core
    -- keeps one in `characters.phoneNumber`. On `auto` the phone ADOPTS that number, which is
    -- the friendly default: every script that already knows how to reach a player still can,
    -- and nobody's number changes under them.
    --
    -- But an adopted number is in the framework's format, not yours. If you have set
    -- `Config.NumberFormat` to something you actually want - `5555-####-####`, a French
    -- shape, whatever - `auto` means your existing players keep their old-looking numbers
    -- forever and only brand new characters get the new shape.
    --
    --   auto       adopt the framework's number if there is one, otherwise mint our own,
    --              and write ours back so the framework agrees. The default.
    --   framework  the same adoption, stated explicitly.
    --   phone      **ignore the framework's numbers entirely.** Every character is minted a
    --              number in `Config.NumberFormat`, and it is NOT written back into charinfo.
    --              Pick this when the phone's numbering is the one that matters.
    --
    -- Switching to `phone` affects characters from then on. It cannot retroactively change a
    -- number already stored - so for players whose framework number was adopted on an earlier
    -- boot, run `/phoneadmin renumber all confirm` once. That mints everybody a number in the
    -- current format. Anybody who saved an old number in their contacts keeps the old one:
    -- a contact is a row on somebody else's phone, and rewriting other people's address books
    -- to follow a staff action would be worse than the problem it solved.
    numbers   = 'auto',   -- auto | framework | phone

    -- ── Standing in for qb-phone ───────────────────────────────
    -- A stock qb-core server has eighteen resources that talk to qb-phone: job mail, police
    -- dispatch, invoices. Drop v-phone in without the stock phone and they all talk to
    -- nobody. On (the default) v-phone answers them itself.
    --
    -- `auto` stands down if the REAL qb-phone is running, so the two never double up. Set
    -- true to answer regardless, false to stay out of it entirely.
    --
    -- One thing this cannot cover on its own: `exports['qb-phone']:sendNewMailToOffline`.
    -- An export belongs to a resource NAME, so that call needs the twenty-line resource in
    -- compat/qb-phone - see COMPATIBILITY.md.
    qbPhone   = 'auto',   -- auto | true | false

    -- qb mail can carry a button that fires a client event; qb-drugs uses one to hand over
    -- the delivery location. v-phone's Mail has no buttons, so the event is fired back at
    -- the recipient instead.
    --
    -- Off by default, and deliberately: that payload arrives from a CLIENT, so switching
    -- this on lets a player's own client name the event that gets fired at it. It is fired
    -- only ever back at the sender, never at anybody else, but it is still their choice of
    -- event name. Turn it on if you run qb-drugs and want deliveries to work.
    qbPhoneMailButtons = false,

    -- The phone charges inside a property you have a key to, decided per housing script
    -- (Quasar included) in bridge/client/charging.lua. Off leaves only vehicles and the
    -- public chargers in Config.Chargers.
    chargeAtProperty = true,

    -- And in any vehicle, which is the other one the server can see for itself. Off makes
    -- a car journey drain the battery like walking does, so a long drive has a cost - and
    -- it leaves properties and the public chargers as the only ways to fill up.
    chargeInVehicle = true,

    -- With `notify = 'custom'`, the client event the phone fires instead. It receives
    -- (message, kind) where kind is inform | success | error.
    notifyEvent = 'myserver:notify',

    -- The channel range phone calls use, when the voice script is channel based. Twenty-four
    -- channels are reserved from here up, so two calls in the same minute never share one.
    --
    -- On pma-voice these are CALL channels, which are a namespace of their own: they cannot
    -- collide with the radio channels your job scripts use, and a player on a radio stays on
    -- it while taking a call. Do not confuse the two - see bridge/shared/compat.lua.
    voiceChannel = 700,

    -- How many channels calls may spread over, starting at `voiceChannel` above. This is
    -- also the ceiling on CONCURRENT calls server-wide, because a call id is its channel and
    -- no two live calls may share one - two conversations on one pma-voice channel hear each
    -- other. It was hardcoded at 24, which refused the twenty-fifth call on a busy night for
    -- no reason: a pma-voice channel is just an integer. Raise it if you run a big server;
    -- keep the range clear of any radio channels your other scripts use.
    voiceChannels = 256,

    -- ══════════════════════════════════════════════════════════
    --  WHICH APPS EXIST ON THIS SERVER
    -- ══════════════════════════════════════════════════════════
    -- `false` removes an app completely: no home screen icon, no store listing, no search
    -- result, and its server callbacks answer "off". That last part is the reason to use this
    -- rather than editing `Config.Apps` - an app removed here cannot be reached at all, by a
    -- player, by a script, or by a modified client.
    --
    -- **Every one of these defaults to on and every one of them works out of the box.** They
    -- read your framework through the bridge - qb-core, qbx, ESX, ox, and whatever banking,
    -- garage, housing or inventory script you run - so none of them needs a companion resource.
    -- You are switching apps off because your server has no use for them, not to make them work.
    --
    -- Commented out means "on". Uncomment the line and set it to false to remove the app.
    apps = {
        -- ── The four that cannot be removed ────────────────────
        -- phone, messages, contacts and store are not listed on purpose. A phone with no
        -- dialler is a brick, and a phone with no store cannot get anything back.

        -- ── Emergency ─────────────────────────────────────────
        -- 911. Ships in every phone and is in the contact list as well, so switching it off is a
        -- decision worth making deliberately: it is the app a player reaches for once.
        -- emergency = false,
        -- alerts    = false,  -- the government broadcast, received by everybody

        -- ── Money ─────────────────────────────────────────────
        bank     = true,   -- accounts, transfers, statements, the card
        bankpro  = true,   -- the business side: payroll, company transfers, movements
        -- calc  = false,  -- the calculator

        -- ── Getting around ────────────────────────────────────
        maps     = true,   -- waypoints, saved places, what is nearby
        garage   = true,   -- your vehicles, and where they are
        property = true,   -- your houses, and a route to one
        taxi     = true,   -- hail a ride, or drive one
        repair   = true,   -- reach a mechanic, and the callout queue on the other side
        export   = true,   -- the market board: prices, favourites and price alerts

        -- ── Work and paperwork ────────────────────────────────
        jobs     = true,   -- open positions, and your own contract
        wallet   = true,   -- licences and ID
        health   = true,   -- the medical record
        mdt      = true,   -- the police terminal, for whoever holds the job
        -- notes     = false,
        -- reminders = false,

        -- ── Talking ───────────────────────────────────────────
        mail     = true,   -- email, attachments, domains
        cipher   = true,   -- the encrypted messenger
        -- bleeter = false,  -- the public feed
        -- snap    = false,  -- photos
        -- hush    = false,  -- anonymous confessions

        -- ── Camera and media ──────────────────────────────────
        camera   = true,   -- photos and video
        gallery  = true,   -- what the camera took
        music    = true,   -- library, playlists, and the deck it hands off to

        -- ── The paid and the optional ─────────────────────────
        charging = true,   -- FruitCharge: find and pay a public charger
        zuber    = true,   -- food delivery
        lottery  = true,   -- the weekly draw

        -- ── A note on the ones you will not find here ─────────
        -- The chargers and dead zones (`ch_*`, `dz_*`) are places on the map, not apps. They
        -- live in Config.Charging and Config.DeadZones.
    },

    -- The same switches under their old names. These were the author's own v-* module
    -- names, and setting one to true used to make the phone believe that resource was
    -- RUNNING - which is why four apps reported themselves as not installed while the
    -- bridge behind them worked perfectly. Kept only so an existing config keeps working;
    -- `apps` above is the one to use.
    modules = nil,

    -- Jobs that unlock the MDT app. Empty hides it from everybody.
    policeJobs = { 'police', 'sheriff', 'bcso', 'sast' },

    -- ox_core has no single "job": it has groups. These are the ones that are clearly
    -- not a job, so the phone does not report somebody's admin group as their employer.
    ignoredGroups = { admin = true, mod = true, support = true, group = true },

    -- ── Tables to read ─────────────────────────────────────────
    -- The phone reads these directly when no export offers the same data.
    --
    -- `auto` picks the right name for the framework that is running:
    --   qb   player_vehicles / properties
    --   ox   vehicles / ox_property / character_licenses
    --   ESX  owned_vehicles / owned_properties / user_licenses
    --
    -- Name one to override it. Set one to `false` if your server has no such table: the
    -- app hides rather than erroring.
    tables = {
        vehicles   = 'auto',
        properties = 'auto',
        licences   = 'auto',
        -- Where your housing script keeps each house, so the Property app can put a waypoint
        -- on one. `auto` looks for the tables the common scripts use and reads whichever
        -- exists; `false` stops it looking at all.
        --
        -- Only needed for a script whose OWN export will not give up a position - Quasar keeps
        -- its coordinates behind an escrowed core, so the phone reads the row instead. If your
        -- table is named something unusual, name it here; if the position is not in a database
        -- at all, `Config.Property.houses` is the manual list.
        houses     = 'auto',
    },

    -- **Which grade counts as a boss on ox_core.** ox has no boss flag - a group's grade list
    -- decides - so nothing is guessed unless you say so. nil leaves Bank Pro's `minGrade` as the
    -- route on such a server. On qb this is ignored (`isboss` answers it) and on ESX the grade
    -- NAMED `boss` answers it, which is the ESX convention.
    bossGrade = nil,

    -- ── Your own wiring ────────────────────────────────────────
    -- The escape hatch. Any hook you fill is used INSTEAD of the detection above, so a
    -- server with a bespoke banking script wires it in one function rather than forking
    -- the resource.
    --
    --     balances = function(src) return { cash = 100, bank = 5000 } end,
    --
    -- **`onDuty`** is worth calling out. qb tracks duty itself; ESX and ox do not, so everybody
    -- holding a job is treated as on it - the safe direction, because the other one is an app
    -- that never works at all there. A server that DOES track duty answers here, and the taxi
    -- queue, 911's responders and Bank Pro all follow the same answer:
    --
    --     onDuty = function(src, job) return exports['esx_service']:IsInService(src, job.name) end
    --
    -- Return nil for "no opinion" and the framework's own answer stands.
    --
    hooks = {
        balances = nil,       -- (src) -> { cash, bank }
        transactions = nil,   -- (src, citizenid) -> { { label, amount, at }, ... }
        vehicles = nil,       -- (citizenid) -> { { plate, model, garage, state }, ... }
        properties = nil,     -- (citizenid) -> { { label, address }, ... }
        licences = nil,       -- (src, citizenid) -> { { type, label }, ... }
        -- Who the character is, for the Wallet app's identity card. Only needed if your
        -- framework keeps none of it where the bridge looks.
        identity = nil,       -- (citizenid, src) -> { first, last, dob, sex, nationality, id }
        -- What a garage key is called and where it is. Only needed if your garage script
        -- keeps neither in a readable config - Quasar's escrowed build, for instance.
        garage = nil,         -- (key) -> { label, x, y }
        -- What a vehicle is CALLED, from its spawn code. qb-core's own shared list is read
        -- when it is there, so this is only for a server whose vehicle names live elsewhere.
        vehicleLabel = nil,   -- (model) -> 'Grotti Brioso R/A'
        jobs = nil,           -- () -> { { name, label, grades }, ... }
        status = nil,         -- (src) -> { hunger, thirst, ... }
        -- Charge a player. Return true ONLY if the money genuinely left them: the store
        -- treats false as "not paid" and does not grant the app.
        removeMoney = nil,    -- (src, amount, account) -> boolean
        -- Pay a player. Return true ONLY if the money genuinely arrived: a transfer whose
        -- credit reports false is refunded to the sender rather than lost.
        addMoney = nil,       -- (src, amount, account, reason) -> boolean
        -- CLIENT side: true when the local player is inside a property they can charge
        -- in. Only fill this if your housing script is none of the supported ones.
        atHome = nil,         -- () -> boolean, runs on the client
        -- Put money into a JOB or society account - what a paid charger charges goes here.
        -- qb-banking, Renewed-Banking, okokBanking and esx_addonaccount are handled; fill
        -- this only if your banking script is none of them. Return true only if it landed.
        society = nil,        -- (account, amount, reason) -> boolean
        -- Read a job or society balance, and take money out of one. Bank Pro needs both.
        -- Return nil from the balance hook for "cannot be read" - zero is a real answer and
        -- the app says something different for each.
        societyBalance = nil, -- (account) -> number or nil
        societyRemove = nil,  -- (account, amount, reason) -> boolean
        -- A SAVINGS balance, if your banking script keeps one. Read only: the bank app draws
        -- the figure and never offers to move it, because the phone cannot verify a movement
        -- it did not make.
        --
        -- The bridge tries the obvious method names on the detected banking script first, so
        -- this is only needed when yours is called something else - or when it is escrowed and
        -- its exports cannot be guessed. Return nil for "there is no such account", which is
        -- what makes the card disappear instead of showing a zero somebody does not have.
        savings = nil,        -- (src) -> number or nil
    },

    -- Print what the phone decided at boot, and log every social/phone write. Useful
    -- once, noisy for ever after.
    log = false,
}

-- ══════════════════════════════════════════════════════════════
--  SETTINGS
-- ══════════════════════════════════════════════════════════════
-- Upstream these live in an admin panel. Here they are plain values, and every one of
-- them can also be set from server.cfg without touching this file:
--
--     set phone_battery false
--     set phone_requireItem false
--
-- The convar name is `phone_` followed by the key.
Config.Settings = {
    enabled         = true,
    -- On: the player carries Config.PhoneItem, or they have no phone. This is the default
    -- because a phone every character owns for free is not an item, it is a menu.
    -- `set phone_requireItem false` gives everybody one again.
    --
    -- Note it cuts both ways: a character with no handset cannot be CALLED either, which
    -- is the point, but it also means messages sent to them wait until they hold one.
    requireItem     = true,
    numberFormat    = '555-####',
    maxLength       = 500,     -- an SMS
    retentionDays   = 30,      -- how long messages are kept, 0 for ever
    ringSeconds     = 30,
    maxMinutes      = 60,
    battery         = true,
    -- A real day of USE, which is what a player measures it against. 48 hours idle with
    -- the phone in a pocket, halved to 24 with the screen on - so somebody who plays a long
    -- session and keeps checking it still ends the night with charge, and somebody who
    -- never puts it away eventually has to find a charger. The old 8/3 pair emptied a
    -- phone in under three hours of use, which read as broken rather than as a mechanic.
    -- 72 hours idle, and the screen costs 1.5x rather than 2x, so a phone that is actually
    -- being looked at lasts about 48 hours of use. 48/2x gave exactly 24 and that is the
    -- number to clear, not to land on.
    --
    -- The arithmetic, so it can be checked rather than trusted: the drain tick runs every 20
    -- seconds, 180 times an hour, and takes 100/(hours*180) percent each time. At 72 that is
    -- 1.39% an hour closed and 2.08% with the screen on - 72 hours and 48 hours to empty.
    hoursToEmpty    = 72,
    screenDrain     = 1.5,
    chargeMinutes   = 45,
    powerbankCharge = 45,
    autoDark        = true,
    darkFrom        = 20,
    darkTo          = 6,
    voicemail       = true,
    voicemailMax    = 200,
    anonymous       = false,
    customWallpaper = true,
    -- The Camera app, on. It shipped off, which meant a phone with a camera icon that
    -- opened onto "the camera is disabled on this server" - a bad thing to hand somebody
    -- out of the box, and it hid a real bug for a long time: the flag was never sent to
    -- the page at all, so switching it on changed nothing and looked like a config error.
    --
    -- A photo needs somewhere to live. Either Config.Media (server-side capture and upload,
    -- the better option, and the API key stays on the server) or `phone_cameraUpload` with
    -- screenshot-basic. With neither, the app opens and taking a shot says so plainly.
    camera          = true,
    cameraUpload    = '',
    social          = true,
    socialMaxLength = 280,
    socialFeedSize  = 50,
    socialRetentionPosts    = 60,
    socialRetentionComments = 60,
    socialRetentionStories  = 1,
    socialRetentionMessages = 30,
    socialHush      = true,
    socialDailyLikes = 30,
}

-- Open / close the phone.
--
-- **Every player can change this for themselves.** It is registered with
-- `RegisterKeyMapping`, so it appears in the game's own Settings -> Key Bindings -> FiveM
-- list under "iFruit". Whatever a player binds there wins over this value and survives a
-- restart, which is why the operator only needs to pick a sensible starting point.
--
-- F2 by default: F1 is taken by more resources than any other key, and F3 is a common radio.
--
-- Holding the item is still required (`Config.Settings.requireItem`), so the key opens a
-- phone you own and says so plainly when you do not. Set this to `false` for no binding at
-- all, and the phone then opens only by using the item. The `/vphone` command exists either
-- way, which is what you want while testing.
Config.Key = 'F2'

-- ── In hand ────────────────────────────────────────────────────
-- A phone you are using is a phone you are holding: a prop in the hand and an animation
-- to match, while you stay free to walk and drive. Open on foot and you browse one-handed;
-- open in a car and the prop still shows. A call raises it to the ear.
Config.Hold = {
    prop   = 'prop_amb_phone',           -- base-game phone prop, attached to the right hand
    bone   = 28422,                      -- SKEL_R_Hand
    pos    = vec3(0.0, 0.0, 0.0),
    rot    = vec3(0.0, 0.0, 0.0),
    dict   = 'cellphone@',
    browse = 'cellphone_text_read_base', -- one-handed, looking at the screen
    call   = 'cellphone_call_listen_base', -- to the ear
    -- Disabled while the phone is up so a click on the screen does not fire a gun, and the
    -- mouse drives the cursor instead of spinning the camera. Movement, sprint, jump and
    -- every vehicle control are left untouched, so you keep walking and driving.
    -- 199 and 200 are the pause menu (P and Escape). The page already treats Escape as
    -- "go back": it closes a sheet, then the app, then the phone. Without these two the
    -- game acts on the same keypress as well, so Escape closed a sheet AND opened the GTA
    -- menu over the top. Blocking them leaves Escape meaning one thing while the phone is
    -- out, and they are restored the moment it goes away.
    block  = { 1, 2, 24, 25, 47, 257, 263, 264, 45, 140, 141, 142, 143, 37, 44, 68, 69, 70, 91, 92,
               199, 200 },
}

-- ── Numbers ────────────────────────────────────────────────────
-- A number is how contacts, calls and messages address each other. Never the citizen id:
-- that is a database key, and a player should not be trading it.
--
-- `#` is replaced by a random digit. Anything else is kept, so a server can use its own
-- shape. Los Santos numbers in GTA are 555-xxxx, which is what this ships as.
-- Every `#` becomes a digit; everything else is kept exactly as written. So all of these
-- work, and any shape you can spell this way works:
--
--     '555-####'            555-0142        the GTA shape, and the default
--     '5555-####-####'      5555-0142-9930
--     '(###) ###-####'      (415) 555-0142
--     '+33 # ## ## ## ##'   +33 6 12 34 56 78
--     '##########'          4155550142
--
-- Three things to keep in mind, each of which the server checks at boot and names:
--
--   * at least four `#`, or a busy server runs out of numbers
--   * 20 characters at most, because that is the column - a longer format would be truncated
--     and two different numbers could end up stored as the same string
--   * it must not overlap `Config.Booth.numberFormat`. A payphone is recognised by the SHAPE
--     of its number and nothing else, so a character holding a booth-shaped number is a
--     character nobody can ring. Those draws are refused rather than handed out.
--
-- Changing this affects new characters. To renumber the ones you already have, see
-- `/phoneadmin renumber` and `Config.Compat.numbers` above.
Config.NumberFormat = '555-####'

-- ══════════════════════════════════════════════════════════════
--  LICENCE NAMES
-- ══════════════════════════════════════════════════════════════
-- What the Wallet calls each licence.
--
-- A licence arrives from your framework as an identifier - `driver`, `cdl`, `fish` - because
-- that is what the script that issues it stores. Most of them carry no label at all, so the
-- Wallet had nothing to show but the identifier, and a wallet listing `cdl` and `fish` is not
-- a wallet.
--
-- The key is the identifier your framework uses. The value is either:
--
--   * a plain label, used exactly as written - the quick way, and right for a server that runs
--     in one language
--   * a locale key (anything starting `ph.`), looked up in the player's own language - add
--     `['ph.lic_cdl'] = ...` to each of your locale files and a bilingual server gets both
--
-- An identifier that is not listed here falls back to whatever label the issuing script gave
-- it, and then to the identifier itself with its separators tidied - so `weapon_license` reads
-- as `Weapon License` even when nobody has configured it.
Config.Licences = {
    -- The ones qb-core, Qbox and ESX hand out between them. Rename freely; delete what your
    -- server does not use - an entry for a licence nobody holds costs nothing either way.
    driver   = 'Driving licence',
    cdl      = 'Heavy goods licence',
    truck    = 'Heavy goods licence',
    motorcycle = 'Motorcycle licence',
    boat     = 'Boating licence',
    pilot    = 'Pilot licence',
    weapon   = 'Firearms licence',
    business = 'Business licence',
    fish     = 'Fishing permit',
    hunting  = 'Hunting permit',
    mining   = 'Mining permit',
    taxi     = 'Taxi licence',
    press    = 'Press card',
    law      = 'Bar licence',

    -- ── Identifiers other servers use ──────────────────────────
    -- Nothing above is authoritative: these are simply the identifiers seen most often. A
    -- server whose licence script numbers them - `bike`, `fly2`, `boat2`, `assurance1` - is not
    -- unusual, and an unlisted identifier shows as a tidied version of itself. Add yours here
    -- and the Wallet uses the name you wrote.
    bike     = 'Motorcycle licence',
    fly      = 'Pilot licence',
    fly2     = 'Helicopter licence',
    boat2    = 'Master mariner licence',
    hunt     = 'Hunting permit',
    lawyer   = 'Bar licence',
    detective = 'Private investigator licence',
    primes   = 'Bounty hunter licence',
    racing_organizer = 'Race organiser permit',
    racing_driver = 'Racing licence',
    -- Insurance tiers, which several French-speaking servers issue as licences.
    assurance0 = 'Basic health cover',
    assurance1 = 'Health cover, tier 1',
    assurance2 = 'Health cover, tier 2',
    assurance3 = 'Health cover, tier 3',
}

-- ══════════════════════════════════════════════════════════════
--  HOW A NUMBER IS DISPLAYED
-- ══════════════════════════════════════════════════════════════
-- Grouping for READING, which is a different question from `Config.NumberFormat` above.
--
-- A number minted as `##########` is stored as `4155550142` and that is what every script
-- reading it gets. But ten digits in a row is not something a person can read back over voice,
-- so the phone can put a separator in **visually** while the stored value is untouched.
--
-- Nothing here changes what is in the database, what is dialled, what is copied to the
-- clipboard, or what any export answers. It is presentation and only presentation.
Config.NumberDisplay = {
    -- Insert a separator every N characters. 0 turns grouping off entirely.
    --
    -- A trailing group of ONE is merged into the one before it, so ten digits at three read
    -- `415-555-0142` rather than `415-555-014-2`. A single orphaned digit looks like a bug
    -- rather than a convention, and "every three" is what somebody means rather than what
    -- they would want literally applied to the last character.
    groupEvery = 3,

    separator = '-',

    -- **A number that already carries its own punctuation is left exactly as it is.**
    --
    -- If `Config.NumberFormat` is `555-####` then the operator has already decided what the
    -- number looks like, and regrouping `555-0142` would produce `555--01-42`. So grouping
    -- only ever applies to a number that is a bare run of letters and digits. Turn this off
    -- to regroup regardless, which strips the existing punctuation first.
    onlyWhenPlain = true,

    -- Whose numbers. `own` is your own number, on the lock screen, in Settings, in Contacts
    -- and where an app asks you to confirm it. `all` extends it to every number the phone
    -- draws - a caller, a contact, a bank card.
    scope = 'own',   -- own | all
}

-- ── Required contacts ─────────────────────────────────────────
-- These entries are injected into every player's Phone and Contacts applications.
-- They cannot be renamed or deleted by a player. Use real numbers handled by your
-- server; an empty list simply disables the feature.
--
-- Available fields: name, number, favourite, photo, email, address, birthday, note.
Config.RequiredContacts = {
    -- **911 is in every phone, and calling it opens the 911 app.**
    --
    -- `app = 'emergency'` is what makes the difference: the contact is not a number somebody
    -- answers, it is the door to the app that raises an alert. Tapping call on it opens 911
    -- rather than dialling into silence - which is what a real emergency number does, and what
    -- a player pressing the one number they know by heart expects.
    --
    -- `system = true` is implied for everything in this list: a required contact cannot be
    -- edited or deleted, so it is still there on the night it is needed.
    { name = '911', number = '911', favourite = true, app = 'emergency',
      note = 'Police, ambulance, fire - raises an alert with your position.' },

    -- More lines, if your server has numbers people should not have to remember. A plain entry
    -- with no `app` is an ordinary contact: calling it dials the number.
    -- { name = 'Taxi dispatch', number = '555-0100' },

    -- Garages are NOT listed here. When doc-mechanicmdt is on the server the Repair app
    -- already asks it for them - names, opening state, ratings and the callout queue -
    -- and Contacts shows that same list under a Garages heading. A second copy in this
    -- file would be a second set of names to keep in step with the first.
    -- { name = 'Mechanic', number = '555-0200', favourite = false },
}

-- ── Messages ───────────────────────────────────────────────────
Config.Messages = {
    maxLength   = 250,      -- characters
    pageSize    = 40,       -- messages loaded per conversation
    retentionDays = 30,     -- 0 keeps everything for ever

    -- ── Written with no signal ─────────────────────────────────
    -- A text typed in a dead spot used to be lost: the server refuses without bars, the page
    -- said "no signal", and what somebody had written was gone. Every real phone keeps it and
    -- sends it when the bars come back.
    --
    -- **The outbox belongs to the handset, not to the network.** It lives on the player's own
    -- machine and is written to their KVP, so it survives a reconnect the way an unsent text
    -- survives turning a phone off and on. Nothing is queued on the server: the server is the
    -- network, and the network is what is missing.
    --
    -- Only MESSAGES. A bank transfer or a taxi callout made in a tunnel and quietly settled
    -- twenty minutes later would be a worse surprise than being told it did not happen.
    outbox = {
        enabled = true,

        -- How many may wait at once. This is a phone's outbox, not a mail server: somebody who
        -- has written twenty texts underground has written enough.
        max = 20,

        -- How many times one may be retried before it is given up on and the player told.
        --
        -- Only refusals that could plausibly pass later are retried at all - no signal, a rate
        -- limit. A number that does not exist does not start existing, so that answer is
        -- final the first time.
        tries = 6,
    },

    -- ── GIFs ───────────────────────────────────────────────────
    -- A picture chosen from a shelf instead of pasted as a link. It is sent as an ordinary
    -- image message, so anything that already understands an image - the thread, the
    -- conversation list, the export API, forensics - understands this too.
    --
    -- **The library is yours to edit.** Every entry is a plain link to a public CDN, exactly
    -- like `Config.WallpaperHosts` above: no account, no key, nothing phoned home. Add your
    -- own categories, remove ones you would rather not have on your server, point them at
    -- your own host if you host your own.
    --
    -- Links rot. `python tools/gif-pack.py --check` says which of these have stopped
    -- answering, and `--write` rebuilds the whole list from scratch.
    gifs = {
        enabled = true,

        -- How many of the ones somebody actually used are kept at the front of the picker.
        -- Recents are per character and stored with the rest of that character's app data.
        recent = 12,

        -- ── Search ─────────────────────────────────────────────
        -- Off unless the operator has an API key of their own. When it is on, the phone shows
        -- a search field over the shelf below.
        --
        -- **The key is read on the server and never reaches the page.** The phone asks the
        -- server for "cats", the server asks the provider, and only the pictures come back.
        -- A key handed to a NUI page is a key published: the page is a browser, and anything
        -- shipped to a browser can be read out of it.
        --
        -- Put the key in a server convar rather than in this file if you can:
        --     set vphone_gifKey "..."
        -- The file is the fallback for servers that do not use convars.
        search = {
            provider = 'tenor',     -- tenor | giphy
            key      = '',          -- empty means the search field is simply not shown
            limit    = 24,
        },

        -- The shelf itself. Category keys are looked up as `ph.gif_<key>` in the locales and
        -- fall back to the key, so a category you invent shows its own name without needing
        -- a translation first.
        packs = {
            { key = 'hello', gifs = {
                'https://media.tenor.com/6wDQsQ-l15oAAAAM/lizard-wave.gif',
                'https://media.tenor.com/JU01jvKaGe8AAAAM/h2di-bear-wave.gif',
                'https://media.tenor.com/-gy6QqbevJsAAAAM/byeeeee.gif',
                'https://media.tenor.com/voCtc5JOpV0AAAAM/hola.gif',
                'https://media.tenor.com/92MplgQwb80AAAAM/cat-meme-wave-emoji.gif',
                'https://media.tenor.com/RAMLS3DEhBsAAAAM/hi-hello.gif',
            } },
            { key = 'yes', gifs = {
                'https://media.tenor.com/Y0P12w6gXTYAAAAM/yes-sir.gif',
                'https://media.tenor.com/Q57oQ1ZhTpkAAAAM/spongebob-thumbsup.gif',
                'https://media.tenor.com/fQNpnuaHvcoAAAAM/yesonavax.gif',
                'https://media.tenor.com/ZzHXw1AChVQAAAAM/funny-yes.gif',
                'https://media.tenor.com/eLYYNHG9bOEAAAAM/yes.gif',
                'https://media.tenor.com/6pW81ZZj-1MAAAAM/yes-wink.gif',
            } },
            { key = 'no', gifs = {
                'https://media.tenor.com/59D5FDlZ8QYAAAAM/nope-brennan-huff.gif',
                'https://media.tenor.com/UNJpp7xMZw8AAAAM/absolutely-not-david-rose.gif',
                'https://media.tenor.com/DMwkzZwkeW4AAAAM/its-always-sunny-in-philadelphia-danny-devito.gif',
                'https://media.tenor.com/U4nwKcWlsfUAAAAM/no-no-no-meme.gif',
                'https://media.tenor.com/miR4wugcxz4AAAAM/wendy-conrad-your-happy-workplace.gif',
                'https://media.tenor.com/10i4quIbVEoAAAAM/absolutely-not-nope.gif',
            } },
            { key = 'haha', gifs = {
                'https://media.tenor.com/rL4hulhuEIYAAAAM/funny-laughing.gif',
                'https://media.tenor.com/SqcnSSG9bR8AAAAM/laughing-hysterically-laughing.gif',
                'https://media.tenor.com/b_fyEAmO4oYAAAAM/laughing-laughing-hysterically.gif',
                'https://media.tenor.com/WGdyB0HjFVIAAAAM/lmao-meme.gif',
                'https://media.tenor.com/VqWZm3PIj0UAAAAM/lmfao.gif',
                'https://media.tenor.com/B02qN3SZx0cAAAAM/kahkaha-komik.gif',
            } },
            { key = 'love', gifs = {
                'https://media.tenor.com/h4xoDN1uoh4AAAAM/love-love-you.gif',
                'https://media.tenor.com/nQA0BABq2jcAAAAM/i-love-you-gif-by-good-vibes-club-love.gif',
                'https://media.tenor.com/yn-a32f7FhkAAAAM/love-big-heart.gif',
                'https://media.tenor.com/nSy6cX3Fpf0AAAAM/shannon-irenes-pics.gif',
                'https://media.tenor.com/Ga2qH3V9UnoAAAAM/grupa-pingwina-pingwin.gif',
                'https://media.tenor.com/vj-A8Cp8l8sAAAAM/cute-kawaii.gif',
            } },
            { key = 'sad', gifs = {
                'https://media1.tenor.com/m/WPVDmrCGWlMAAAAC/soucis.gif',
                'https://media.tenor.com/WPVDmrCGWlMAAAAM/soucis.gif',
                'https://media.tenor.com/vLhEp8uCJq4AAAAM/dean-winchester-jensen-ackles.gif',
                'https://media.tenor.com/OxfxlNNDIv4AAAAM/baby-puoting.gif',
                'https://media.tenor.com/jDXNIPAp7h4AAAAM/sad-dog-sad-face.gif',
                'https://media.tenor.com/n5_sc1mZeW4AAAAM/sad-crying.gif',
            } },
            { key = 'angry', gifs = {
                'https://media.tenor.com/vui2TXEoHasAAAAM/the-shining-jack-nicholson.gif',
                'https://media.tenor.com/BqTqDtZurg8AAAAM/mad-angry.gif',
                'https://media.tenor.com/kxQa7QwKt-MAAAAM/gachiakuta-zanka-mad.gif',
                'https://media.tenor.com/E_dGt94zz18AAAAM/megumi-megumi-fushiguro.gif',
                'https://media.tenor.com/B42KQtAgI9IAAAAM/shibuya-station-haru.gif',
                'https://media.tenor.com/e8VVRoYhy74AAAAM/omori-aubrey.gif',
            } },
            { key = 'wow', gifs = {
                'https://media.tenor.com/rKLBka9zl5UAAAAM/yeah-excellent.gif',
                'https://media.tenor.com/b5wsBjj47BgAAAAM/shocked-plastique-tiara.gif',
                'https://media.tenor.com/8dGugqxC4sAAAAAM/shocked-surprised.gif',
                'https://media.tenor.com/kn7SlZ31CHEAAAAM/jt-futurama.gif',
                'https://media.tenor.com/VWEN3FFupVkAAAAM/stunned-rdcworld1.gif',
                'https://media.tenor.com/0B45HGy7R18AAAAM/finn-wolfhard-surprised-face.gif',
            } },
            { key = 'ok', gifs = {
                'https://media1.tenor.com/m/juQyVDrXZSsAAAAC/ok-okay.gif',
                'https://media.tenor.com/juQyVDrXZSsAAAAM/ok-okay.gif',
                'https://media.tenor.com/XCZpSf7vWYsAAAAM/okrealsam-ok-real-sam.gif',
                'https://media.tenor.com/BbCxxH64TBcAAAAM/havana-mahoney-sts.gif',
                'https://media.tenor.com/_sUJ-vcM3C4AAAAM/cash-sign-lloyd-ostertag.gif',
                'https://media.tenor.com/OifIck4oXcUAAAAM/crash-landing-on-you-cloy.gif',
            } },
            { key = 'please', gifs = {
                'https://media.tenor.com/XhK036RdGdUAAAAM/jerry-beg.gif',
                'https://media.tenor.com/l9Qh626faNgAAAAM/puss-in-boots-shrek.gif',
                'https://media.tenor.com/pdgnDeta63YAAAAM/oggy-and-the-cockroaches-joey.gif',
                'https://media.tenor.com/guT_aX7923MAAAAM/cat-cute.gif',
                'https://media.tenor.com/MLzzYNBYgUMAAAAM/begging-pretty-please.gif',
                'https://media.tenor.com/4IckGuTqWeYAAAAM/spongebob-squarepants-begging.gif',
            } },
            { key = 'waiting', gifs = {
                'https://media.tenor.com/lJurJjK0ZcgAAAAM/so-bored.gif',
                'https://media.tenor.com/pdkCOdMH2MkAAAAM/waiting-waiting-patiently.gif',
                'https://media.tenor.com/lwEsb6h8inQAAAAM/i-am-waiting-waiting.gif',
                'https://media.tenor.com/b_4MO5WiulkAAAAM/ill-waiting.gif',
                'https://media.tenor.com/G4MU0XavB_gAAAAM/shots-dead.gif',
                'https://media.tenor.com/onjjYkqW-mYAAAAM/ateu.gif',
            } },
            { key = 'bye', gifs = {
                'https://media1.tenor.com/m/YqEHtON6HioAAAAC/nope-done.gif',
                'https://media.tenor.com/uYtTfRovjnIAAAAM/leaving-work-office.gif',
                'https://media.tenor.com/jqnwErfOmjQAAAAM/farewell-so-long-farewell.gif',
                'https://media.tenor.com/BPeHQcyK-PsAAAAM/farewell-so-long-farewell.gif',
                'https://media.tenor.com/ug8Q28zOsfoAAAAM/bye-byebye.gif',
                'https://media.tenor.com/r80iIC3mTEAAAAAM/sad-goodbye.gif',
            } },
            { key = 'dance', gifs = {
                'https://media.tenor.com/iZ8Lzt3GRakAAAAM/sisters-amy-poehler.gif',
                'https://media.tenor.com/biJT5MNqaGIAAAAM/plongus-mcnyale.gif',
                'https://media.tenor.com/Lty_QiyKuGsAAAAM/shbt.gif',
                'https://media.tenor.com/LCxY8-T5tc8AAAAM/happy-dance-party.gif',
                'https://media.tenor.com/ZSJUq8mj2jkAAAAM/madonna-madonna-louise.gif',
                'https://media.tenor.com/qfSQK9wmLqUAAAAM/dropteeth-big-bird.gif',
            } },
            { key = 'money', gifs = {
                'https://media.tenor.com/UuHswEH6oxUAAAAM/smol-smolcat.gif',
                'https://media.tenor.com/qy51r4zbQBUAAAAM/money-bags.gif',
                'https://media.tenor.com/8-RgyxeBIG0AAAAM/money-show.gif',
                'https://media.tenor.com/YpkZWDSvM2UAAAAM/currency-cash.gif',
                'https://media.tenor.com/G5c6HZ1c9pcAAAAM/broke-make-it-rain.gif',
                'https://media.tenor.com/wYwyA0dnxxkAAAAM/levy-daniel-levy.gif',
            } },
            { key = 'police', gifs = {
                'https://media1.tenor.com/m/wNnalIwS0ygAAAAC/polis-police.gif',
                'https://media.tenor.com/wNnalIwS0ygAAAAM/polis-police.gif',
                'https://media.tenor.com/8g4NTHFm9rYAAAAM/police-cops.gif',
                'https://media.tenor.com/Wx3bGh80AWkAAAAM/siren-cat.gif',
                'https://media.tenor.com/G_93pif7k8YAAAAM/busted-police.gif',
                'https://media.tenor.com/A7xgbELh5NsAAAAM/pink-alert.gif',
            } },
            { key = 'car', gifs = {
                'https://media1.tenor.com/m/5OPXGb_gisgAAAAC/cat-driving-focused.gif',
                'https://media.tenor.com/5OPXGb_gisgAAAAM/cat-driving-focused.gif',
                'https://media.tenor.com/7l0jZbo5vaUAAAAM/cat-dog.gif',
                'https://media.tenor.com/WJCo609LMNEAAAAM/hamster-and-gretel-disney.gif',
                'https://media.tenor.com/6sjRkt015mMAAAAM/birthday.gif',
                'https://media.tenor.com/Uc2_BwjPXxYAAAAM/duck-with.gif',
            } },
            { key = 'cheers', gifs = {
                'https://media.tenor.com/uHnBTpPvCx0AAAAM/cheers-red-city-radio.gif',
                'https://media.tenor.com/XIer_fPZ3rUAAAAM/cheers-gif-happy-birthday.gif',
                'https://media.tenor.com/YHSJcphBVHIAAAAM/cheers-heather-mcmahan.gif',
                'https://media.tenor.com/XHZdHOmVT9oAAAAM/cheers-mimosa.gif',
                'https://media.tenor.com/UvaepeJOMO8AAAAM/bia-drinking-beer.gif',
                'https://media.tenor.com/reT9aDxX1iMAAAAM/cheers-gabriella-demartino.gif',
            } },
            { key = 'shrug', gifs = {
                'https://media1.tenor.com/m/LNh-Ey5hATAAAAAC/elmo-shrug.gif',
                'https://media.tenor.com/LNh-Ey5hATAAAAAM/elmo-shrug.gif',
                'https://media.tenor.com/F9vttl6vl4oAAAAM/whatever-shrug.gif',
                'https://media.tenor.com/XonaUFJ5xBkAAAAM/colin-farrell-shrugs.gif',
                'https://media.tenor.com/w4E6pW0KnFEAAAAM/eh-meh.gif',
                'https://media.tenor.com/BdN0MtOuilcAAAAM/colin-bridgerton-bridgerton.gif',
            } },
        },
    },
}

-- ── Cipher ────────────────────────────────────────────────────
-- Optional end-to-end encrypted roleplay messenger. The server stores routing metadata
-- and encrypted envelopes, never the clear text or a player's private key.
Config.Cipher = {
    maxLength = 700,
    pageSize = 80,
    pinAttempts = 5,
    burnSeconds = { 0, 300, 3600, 86400 },
}

-- ── Calls ──────────────────────────────────────────────────────
-- The phone does NO audio. v-voice owns the Mumble channel; the phone only decides who is
-- talking to whom, and it decides it on the server so that ringing somebody does not
-- depend on the caller knowing where they are.
Config.Calls = {
    ringSeconds = 30,       -- unanswered calls give up after this
    maxMinutes  = 30,       -- hard ceiling on one call, so a forgotten call is not for ever
    -- On speaker, how far the call carries to the people around you. Short: it is a
    -- phone in a hand, not a PA system.
    --
    -- **Two-way.** Somebody within this range hears the call AND is heard by the far end -
    -- which is what a speakerphone is, and is not a choice the phone makes: on pma-voice they
    -- join the call channel, and a call channel wires every member to every other one in both
    -- directions. `/phonevoice` says whether that can work on this server at all.
    --
    -- Somebody who is on their OWN call is never pulled in.
    speakerRange = 8.0,

    -- ── Group calls ────────────────────────────────────────────
    -- A call with more than two people on it. Anyone already talking is asked for; when they
    -- answer they join the conversation everybody else is already having.
    --
    -- **The audio is free, and that is worth knowing before changing anything here.** A call
    -- on pma-voice IS a channel, and a channel wires every member to every other member in
    -- both directions - it has always been a conference, it simply never had more than two
    -- people put on it. Everything below is about who may be put on one, not about how they
    -- are heard.
    group = {
        enabled = true,

        -- How many people can be on one call at once, INCLUDING the two who started it.
        -- Clamped to 2..12 in code: one is not a call, and a dozen voices on one channel is
        -- already past the point where anybody can follow it.
        max = 5,

        -- Only the person who PLACED the call may add to it, the way an iPhone conference
        -- works. `false` lets anybody already on the call invite somebody else, which is
        -- friendlier and is also how a call turns into a crowd nobody chose to be in.
        hostOnly = true,

        -- One invitation at a time. Without it, a single tap-through could set every phone
        -- in a contact list ringing at once, and each of those rings is heard by the room.
        oneAtATime = true,
    },

    -- ── A call on a bad line ───────────────────────────────────
    -- **This is the switch for "calls break up on a weak signal".** `badSignal.enabled`.
    -- One bar is not "slightly worse than four bars" - it is a call that keeps breaking up. The
    -- phone shows it: the voice cuts in and out, the screen stutters, and the call can drop.
    --
    -- The VOICE is what matters here. Muting the player's own transmission for a moment is
    -- what a real drop-out sounds like from both ends, and it is done through the voice script
    -- rather than faked in the interface - a visual-only glitch on a call you can still hear
    -- perfectly reads as a broken phone rather than as a broken signal.
    badSignal = {
        enabled = true,

        -- At or below this many bars the line starts breaking up. 1 is "only the worst
        -- reception"; 2 includes a weak signal. 0 switches the whole thing off.
        atBars = 1,

        -- How often a cut-out happens, as a chance per second at `atBars`. A weaker signal is
        -- proportionally worse: at 1 bar with a threshold of 2, the chance is doubled.
        chancePerSecond = 0.18,

        -- How long one cut-out lasts, in milliseconds. Randomised between the two, because a
        -- drop-out of exactly the same length every time reads as a metronome.
        minMs = 250,
        maxMs = 900,

        -- Mute the player's own voice for the duration, so the far end hears the break too.
        -- This is the honest half of the effect; turn it off and the glitch is decoration.
        muteVoice = true,

        -- **How loud the other person is, per bar of signal.** 1.0 is normal, 0.0 is silent.
        --
        -- This is what makes one bar sound like one bar. Drop-outs alone were not enough and the
        -- reason is worth understanding: a perfectly clear call with an occasional gap in it does
        -- not read as bad reception, it reads as the other person pausing. Real bad reception is
        -- degraded the WHOLE time, and the drop-outs land on top of it.
        --
        -- Only bars at or below `atBars` are ever looked up here, so raising `atBars` to 2 without
        -- adding a `[2]` entry gives two-bar calls the drop-outs and none of the muffling.
        --
        -- Needs `MumbleSetVolumeOverrideByServerId`, which is present on any current FiveM build.
        -- On a build without it the phone falls back to leaving and rejoining the voice channel,
        -- which still cuts out but cannot hold a level - `/phonevoice` says which one is in use.
        --
        -- Set `volumeAtBars = false` for drop-outs and no muffling. Removing the block entirely
        -- does NOT do that: these same defaults are applied in code, because this file is not
        -- replaced by an update and a server upgrading into the setting would otherwise never see
        -- the half of the effect that makes it work.
        volumeAtBars = {
            [1] = 0.20,   -- one bar: audible that somebody is talking, hard work to follow
            [2] = 0.55,   -- two bars: muffled, but a conversation
        },

        -- The level DURING a drop-out. 0.0 is a real cut; a little above it leaves a trace of the
        -- other person, which some servers prefer to total silence.
        cutVolume = 0.0,

        -- The screen stutter that goes with it, and the static. Off leaves the call silent for
        -- a moment with no explanation, which reads as a bug.
        flicker = true,
        static = true,
        -- And a short buzz of the controller, which is the only part that reaches somebody whose
        -- handset is in their pocket - where most of a call is spent.
        vibrate = true,

        -- A call on a line this bad can drop entirely: a chance per second, checked only while
        -- the signal is at or below `atBars`. 0 never drops - the call just keeps breaking up.
        dropChancePerSecond = 0.008,
    },
}

-- ── Apps ───────────────────────────────────────────────────────
-- SEED DATA ONLY: apps live in `world_apps` (owned by v-world) and are enabled, gated and
-- reordered from the admin panel -> Editor -> Apps.
--
-- `owner` is the module the app is a view of, and an app whose owner is stopped is not
-- shown: an app that opens onto nothing is worse than an app that is not there.
-- `owner` is the resource that answers for the app; the home screen hides an app whose owner
-- is not running. Bank, Garage, Property, Wallet and Jobs used to name modules of the
-- author's own suite here - v-banking, v-vehicles and friends - which do not exist on a
-- qb-core, qbx, ESX or ox server. They read the bridge from server files shipped in THIS
-- resource, so v-phone is the honest owner. Whether they appear is `Config.Compat.apps`.
Config.Apps = {
    -- `required` cannot be removed: a phone with no Phone app is a brick, and a phone
    -- with no store cannot get anything back.
    -- `optional` is NOT installed to begin with - it has to be downloaded, which is the
    -- only honest way to make a store mean something.
    -- `category` is what the store sorts by.
    -- The order below IS the home screen on a phone nobody has rearranged yet, and it is
    -- grouped the way a real one ships: the four you reach for without thinking in the
    -- dock, then communication and travel, capture and media, life and work, the small
    -- tools, anything a job unlocks, the downloads, and the store and settings last.
    -- A player who rearranges their apps overrides this; it is only ever the default.
    { id = 'phone',    label = 'app.phone',    icon = 'phone',    owner = 'v-phone',    slot = 1, dock = true,
      required = true, category = 'essentials' },
    { id = 'messages', label = 'app.messages', icon = 'messages', owner = 'v-phone',    slot = 2, dock = true,
      required = true, category = 'essentials' },
    { id = 'contacts', label = 'app.contacts', icon = 'contacts', owner = 'v-phone',    slot = 3, dock = true,
      required = true, category = 'essentials' },
    -- Reaching the emergency services. `required`, like the Phone app: a phone you cannot
    -- call for help with is a phone missing the one thing it is for in an emergency, and a
    -- player who deleted it will discover that at the worst possible moment.
    { id = 'emergency', label = 'app.emergency', icon = 'emergency', owner = 'v-phone', slot = 4,
      required = true, category = 'essentials' },
    -- Public alerts from the authorities. Installed by DEFAULT and not optional: an alert
    -- system only works if everybody already has it when the alert goes out - an app a player
    -- has to hear about, find in the store and install first is an app that is not there on
    -- the day the city floods. See Config.Alerts.
    --
    -- `required`, and it was missing: the comment above said "installed by default and not
    -- optional" and the entry only left `optional` out, which makes an app installed by default
    -- and perfectly removable. So the home screen offered a minus badge on it and a player could
    -- delete the alert system - the one app on this phone that exists to reach somebody who is
    -- not looking at it.
    { id = 'alerts',   label = 'app.alerts',   icon = 'alerts',   owner = 'v-phone', slot = 4,
      required = true, category = 'essentials' },
    -- Bank shares slot 5 with Mail rather than every later app being renumbered to make room
    -- for the one above. `slot` is a sort key and ties break on the app id, so `bank` still
    -- comes before `mail` - which is the order that was already here.
    { id = 'bank',     label = 'app.bank',     icon = 'bank',     owner = 'v-phone',    slot = 5,
      category = 'finance' },
    { id = 'mail',     label = 'app.mail',     icon = 'mail',     owner = 'v-phone',    slot = 5,
      category = 'work' },
    { id = 'maps',     label = 'app.maps',     icon = 'map',      owner = 'v-world',    slot = 6,
      category = 'travel' },
    { id = 'camera',   label = 'app.camera',   icon = 'camera',   owner = 'v-phone',    slot = 7,
      category = 'utilities' },
    { id = 'gallery',  label = 'app.gallery',  icon = 'images',   owner = 'v-phone',    slot = 8,
      category = 'utilities' },
    -- Owned by the phone, not by a radio script. The library, the playlists, the queue and
    -- the favourites are all the phone's own; a deck is only needed to make sound come out,
    -- and the app says so when there is none.
    { id = 'music',    label = 'app.music',    icon = 'music',    owner = 'v-phone',    slot = 9,
      category = 'entertainment' },
    { id = 'garage',   label = 'app.garage',   icon = 'garage',   owner = 'v-phone',    slot = 10,
      category = 'travel' },
    { id = 'property', label = 'app.property', icon = 'house',    owner = 'v-phone',    slot = 11,
      category = 'utilities' },
    -- Police only by default. The operator can open it up, or gate something else the
    -- same way, from Editor -> Phone apps.
    { id = 'wallet',   label = 'app.wallet',   icon = 'wallet',   owner = 'v-phone',    slot = 12,
      category = 'finance' },
    { id = 'jobs',     label = 'app.jobs',     icon = 'jobs',     owner = 'v-phone',    slot = 13,
      category = 'work' },
    { id = 'health',   label = 'app.health',   icon = 'heart',    owner = 'v-status',   slot = 14,
      category = 'health' },
    { id = 'notes',    label = 'app.notes',    icon = 'note',     owner = 'v-phone',    slot = 15,
      category = 'utilities' },
    { id = 'reminders', label = 'app.reminders', icon = 'check',  owner = 'v-phone',    slot = 16,
      category = 'utilities' },
    { id = 'calc',     label = 'app.calc',     icon = 'calc',     owner = 'v-phone',    slot = 17,
      category = 'utilities' },
    { id = 'mdt',      label = 'app.mdt',      icon = 'shield',   owner = 'v-police',   slot = 18,
      -- Job apps get their own aisle: it is only in the store at all for the people
      -- who hold the job, so it has no business sitting under Work next to Jobs.
      job = 'police', category = 'duty' },
    -- The company account. In the store rather than on the home screen: most characters do
    -- not run a business, and an app that answers "you are not a boss" to almost everybody
    -- does not belong installed by default. See Config.BankPro.
    { id = 'bankpro',  label = 'app.bankpro',  icon = 'bankpro',  owner = 'v-phone', slot = 18,
      optional = true, category = 'finance' },
    { id = 'bleeter',  label = 'app.bleeter',  icon = 'bleet',    owner = 'v-phone', slot = 19,
      optional = true, category = 'social' },
    { id = 'snap',     label = 'app.snap',     icon = 'snap',     owner = 'v-phone', slot = 20,
      optional = true, category = 'social' },
    { id = 'hush',     label = 'app.hush',     icon = 'hush',     owner = 'v-phone', slot = 21,
      optional = true, category = 'social' },
    -- Photographs somebody pays to see: a page, followers, subscriptions and tips.
    --
    -- `optional`, so it is NOT on a new phone and has to be found in the store, and it is the
    -- one shipped app with a price on it. Charged once, against the character: removing it and
    -- installing it again later is free, because a player pays for an app rather than for a
    -- download. The debit goes through `Bridge.RemoveMoney`, which fails closed - no money, no
    -- app - and 100 is a number to change, not a rule.
    { id = 'onlyfruits', label = 'app.onlyfruits', icon = 'sparkles', owner = 'v-phone', slot = 22,
      optional = true, category = 'social', price = 100, account = 'bank' },
    -- FruitBrawl: a duel against somebody else on the server. A DOWNLOAD at $200 - the
    -- dearest app in the catalogue, and the only one that needs a second person to be worth
    -- anything, which is the reason it is priced where somebody has to want it.
    { id = 'brawl', label = 'app.brawl', icon = 'shield', owner = 'v-phone',
      optional = true, category = 'entertainment', price = 200, account = 'bank' },
    -- FlappyFruit: one button, one fruit, and a scoreboard the whole server shares. A
    -- DOWNLOAD at $50 - cheap on purpose, because the thing it sells is a name on a board
    -- that other people read, and a board nobody is on is not worth anything to the first
    -- person who buys it.
    { id = 'flappy', label = 'app.flappy', icon = 'sparkles', owner = 'v-phone',
      optional = true, category = 'entertainment', price = 50, account = 'bank' },
    -- Fruitee: donation pages. A DOWNLOAD, and a paid one - $750 from the bank. It is kept
    -- out of `Config.Home.installed` below, which is what actually decides shipped or sold;
    -- the price here is what the store charges once somebody goes looking for it.
    --
    -- The debit runs through `Bridge.RemoveMoney`, which fails closed: no money, no app. 750
    -- is a number to change, not a rule.
    { id = 'fruitee', label = 'app.fruitee', icon = 'heart', owner = 'v-phone',
      optional = true, category = 'finance', price = 750, account = 'bank' },
    { id = 'store',    label = 'app.store',    icon = 'store',    owner = 'v-phone',    slot = 22,
      required = true, category = 'essentials' },
    { id = 'settings', label = 'app.settings', icon = 'settings', owner = 'v-phone',    slot = 23, dock = true,
      required = true, category = 'essentials' },
    -- Downloaded rather than shipped, so it lands after the built-ins instead of
    -- pushing the home screen around on the day a server enables it.
    { id = 'cipher',   label = 'app.cipher',   icon = 'cipher',   owner = 'v-phone',    slot = 24,
      optional = true, category = 'social', version = '1.0' },
    -- FruitCharge: finds public chargers, and pays a paid one from the phone. A DOWNLOAD, and
    -- a paid one - $200 from the bank - because a paid charger with no way to pay it is a dead
    -- end, and this is the way. Standing at a paid charger without it pushes the store. See
    -- Config.PaidCharging.requireApp.
    { id = 'charging', label = 'app.charging', icon = 'charging', owner = 'v-phone',    slot = 25,
      optional = true, category = 'utilities', price = 200, account = 'bank', version = '1.0' },
    -- Zuber: food, ordered from the phone. A free download, because a delivery app nobody
    -- installs is a delivery app no restaurant gets orders from. See Config.Zuber.
    { id = 'zuber',    label = 'app.zuber',    icon = 'zuber',    owner = 'v-phone',    slot = 26,
      optional = true, category = 'utilities', version = '1.0' },
    -- Taxi: hail a ride, or drive one. A free download. See Config.Taxi.
    { id = 'taxi',     label = 'app.taxi',     icon = 'taxi',     owner = 'v-phone',    slot = 27,
      optional = true, category = 'travel', version = '1.0' },
    -- Export: the market price of everything worth selling. A DOWNLOAD, and a PAID one at
    -- $1,000 - knowing what your haul is worth before you drive across the map is worth a
    -- morning's work, and a price board that anybody can read for nothing is a price board
    -- nobody has an edge from. Bought once and remembered against the character, so removing
    -- it and installing it again later is free. See Config.Export.
    { id = 'export',   label = 'app.export',   icon = 'export',   owner = 'v-phone',    slot = 29,
      optional = true, category = 'finance', price = 1000, account = 'bank', version = '1.0' },
    -- Repair: reaching a mechanic. A FREE download, because a player who has broken down needs
    -- it at the moment they break down, and an app that costs money is one they do not have
    -- installed yet. Not on the home screen by default: most characters never call one out.
    -- See Config.Repair.
    { id = 'repair',   label = 'app.repair',   icon = 'repair',   owner = 'v-phone',    slot = 29,
      optional = true, category = 'travel', version = '1.0' },
    -- Lottery: the weekly draw, from the phone. A DOWNLOAD and a paid one - $250, the price of
    -- one ticket - so buying the app is the same decision as buying a line, which is the joke.
    -- See Config.Lottery.
    { id = 'lottery',  label = 'app.lottery',  icon = 'lottery',  owner = 'v-phone',    slot = 28,
      optional = true, category = 'entertainment', price = 250, account = 'bank', version = '1.0' },
}

-- Rich FruitStore catalogue. These are presentation/search hints, not duplicated game
-- logic: every feature below is already backed by the app or the module that owns it.
-- A server may change any wording without touching the renderers.
Config.AppMetadata = {
    phone = {
        features = { 'Clavier et appels', 'Favoris', 'Historique', 'Messagerie vocale', 'Contacts intégrés' },
        keywords = { 'appel', 'numéro', 'favoris', 'répondeur' },
    },
    messages = {
        features = { 'Conversations privées', 'Groupes', 'Photos et GIF', 'Position', 'Réactions et transfert' },
        keywords = { 'sms', 'groupe', 'image', 'localisation', 'emoji' },
    },
    contacts = {
        features = { 'Fiches détaillées', 'Favoris', 'Contacts serveur', 'Photos', 'Partage FruitDrop' },
        keywords = { 'annuaire', 'numéro', 'email', 'adresse', 'anniversaire' },
    },
    bank = {
        features = { 'Solde en direct', 'Comptes', 'Transactions', 'Carte bancaire' },
        keywords = { 'argent', 'compte', 'carte', 'transaction' },
    },
    mail = {
        features = { 'Adresse personnalisée', 'Boîte de réception', 'Messages enregistrés', 'Envoi multiple' },
        keywords = { 'email', 'courrier', 'boîte', 'travail' },
    },
    alerts = {
        features = { 'Alertes officielles', 'Notification sur tous les téléphones',
                     'Archives consultables', 'Diffusion pour les autorités' },
        keywords = { 'alerte', 'gouvernement', 'police', 'urgence', 'population' },
    },
    export = {
        features = { 'Cours en direct', 'Favoris', 'Alertes de prix',
                     'Historique et tendance', 'Marché export et import' },
        keywords = { 'export', 'import', 'cours', 'prix', 'marché', 'vendre', 'bourse' },
    },
    repair = {
        features = { 'Garages ouverts et notes', 'Demande de dépannage géolocalisée',
                     'Suivi en direct', 'Appeler le garage', 'Avis clients' },
        keywords = { 'mécano', 'garage', 'dépannage', 'panne', 'remorquage', 'réparation' },
    },
    maps = {
        features = { 'Lieux de la ville', 'Filtres', 'Itinéraire GPS', 'Repères instantanés' },
        keywords = { 'gps', 'garage', 'commerce', 'station', 'itinéraire' },
    },
    camera = {
        features = { 'Capture en jeu', 'Mode paysage', 'Aperçu instantané', 'Accès direct aux Photos' },
        keywords = { 'photo', 'capture', 'paysage' },
    },
    gallery = {
        features = { 'Albums', 'Filtres photo', 'Fond d’écran', 'FruitDrop', 'Suppression sécurisée' },
        keywords = { 'photo', 'album', 'filtre', 'partage', 'fond écran' },
    },
    music = {
        features = { 'Bibliothèque', 'Favoris', 'File d’attente', 'Recherche', 'Sorties audio' },
        keywords = { 'musique', 'radio', 'playlist', 'artiste', 'album' },
    },
    garage = {
        features = { 'Véhicules personnels', 'État en direct', 'Garage actuel', 'Informations du véhicule' },
        keywords = { 'voiture', 'véhicule', 'plaque', 'garage' },
    },
    property = {
        features = { 'Propriétés', 'Locataires', 'Loyer', 'Paiement à distance' },
        keywords = { 'maison', 'appartement', 'loyer', 'logement' },
    },
    wallet = {
        features = { 'Identité', 'Permis', 'Licences', 'Documents officiels' },
        keywords = { 'carte', 'identité', 'permis', 'licence' },
    },
    jobs = {
        features = { 'Emploi actuel', 'Offres disponibles', 'Salaire', 'Échelle des grades' },
        keywords = { 'travail', 'emploi', 'salaire', 'grade' },
    },
    health = {
        features = { 'Signes vitaux', 'Activité', 'Pas et distance', 'Dossier médical', 'Tendances' },
        keywords = { 'santé', 'faim', 'soif', 'stress', 'médical' },
    },
    notes = {
        features = { 'Notes persistantes', 'Création rapide', 'Modification', 'Suppression' },
        keywords = { 'texte', 'mémo', 'brouillon', 'écriture' },
    },
    reminders = {
        features = { 'Listes de rappels', 'Validation rapide', 'Stockage persistant' },
        keywords = { 'tâche', 'liste', 'rappel', 'todo' },
    },
    calc = {
        features = { 'Calculs rapides', 'Décimales', 'Opérations en chaîne', 'Grand affichage tactile' },
        keywords = { 'calcul', 'math', 'addition', 'division' },
    },
    mdt = {
        features = { 'Recherche citoyen', 'Dossiers', 'Mandats actifs', 'Accès métier sécurisé' },
        keywords = { 'police', 'citoyen', 'mandat', 'mdt' },
    },
    bleeter = {
        features = { 'Fil public', 'Publication', 'Photos', 'Mentions J’aime', 'Compte séparé' },
        keywords = { 'réseau', 'bleet', 'publication', 'social' },
    },
    snap = {
        features = { 'Fil photo', 'Légendes', 'Galerie iFruit', 'Mentions J’aime' },
        keywords = { 'photo', 'snapmatic', 'publication', 'social' },
    },
    hush = {
        features = { 'Profils privés', 'Découverte', 'Match mutuel', 'Échange protégé du numéro' },
        keywords = { 'rencontre', 'profil', 'match', 'social' },
    },
    cipher = {
        features = { 'Chiffrement de bout en bout', 'Identité anonyme', 'Messages éphémères', 'Empreinte de sécurité' },
        keywords = { 'privé', 'chiffré', 'illégal', 'anonyme', 'sécurité' },
    },
    charging = {
        features = { 'Bornes de recharge sur la carte', 'Point de passage vers une borne',
                     'Paiement des bornes payantes', 'Acceptation automatique',
                     'Plafond de prix' },
        keywords = { 'recharge', 'borne', 'batterie', 'payant', 'electrique' },
    },
    brawl = {
        features = { 'Duel contre un autre joueur', 'Quatre coups, choix simultanés',
                     "Endurance et lecture de l'adversaire", 'Défi par numéro ou file rapide',
                     'Palmarès et classement du serveur' },
        keywords = { 'combat', 'duel', 'bagarre', 'versus', 'multijoueur', 'pvp' },
    },
    flappy = {
        features = { 'Un bouton, une seule règle', 'Classement partagé du serveur',
                     "Pseudo d'arcade", 'Record personnel', 'Physique fluide à 120 Hz' },
        keywords = { 'jeu', 'arcade', 'flappy', 'score', 'classement', 'oiseau' },
    },
    -- Fruitee. It is bought from the store, so this is the page somebody reads before paying
    -- 750 for it. French, like every other entry here: the features are the operator's own
    -- wording and are not translated.
    fruitee = {
        features = { 'Page de dons personnalisée', 'Objectif et barre de progression',
                     'Montants suggérés', 'Dons anonymes et messages',
                     'Retrait vers la banque' },
        keywords = { 'don', 'cagnotte', 'collecte', 'tipeee', 'financement', 'charité' },
    },
    lottery = {
        features = { 'Cagnotte en direct', 'Grille tactile 1-35', 'Flash (grille aléatoire)',
                     'Paiement banque ou liquide', 'Tirage suivi en direct',
                     'Historique des tirages', 'Vos gains passés' },
        keywords = { 'loterie', 'loto', 'tirage', 'cagnotte', 'jackpot', 'grille', 'numeros' },
    },
    store = {
        features = { 'Catalogue complet', 'Recherche avancée', 'Installation', 'Mises à jour', 'Fiches détaillées' },
        keywords = { 'application', 'téléchargement', 'installation', 'catalogue' },
    },
    settings = {
        features = { 'Apparence', 'Clear Glass', 'Sécurité', 'Sons', 'Accessibilité', 'Organisation des apps' },
        keywords = { 'réglages', 'thème', 'face id', 'code', 'fond écran' },
    },
}

-- ── The home screen, in one place ──────────────────────────────
-- `Config.Apps` above is the CATALOGUE: everything that exists. This is the LAYOUT: what
-- a phone opened for the first time actually has, and in what order. It is separate
-- because the two questions are separate, and because an operator changing their mind
-- about the default home screen should not have to edit twenty entries to do it.
--
-- Whatever is written here wins over the `slot`, `dock`, `optional` and `required` fields
-- of the catalogue, so this table is the single answer to "what does a new phone look
-- like". A player who rearranges their apps overrides it in turn; it is only the start.
Config.Home = {
    -- The dock, left to right. Four fits comfortably; five is tight; more is a mess.
    -- These are always installed, whatever `installed` below says.
    dock = { 'phone', 'messages', 'contacts', 'settings' },

    -- Installed on a new phone, in this order, filling the grid after the dock.
    -- **Anything in the catalogue and NOT listed here has to be downloaded from the
    -- FruitStore.** That is how the store is made to mean something: remove a line to
    -- turn an app into a download, add one to ship it.
    --
    -- Bleeter, Snapmatic, Hush and Cipher are deliberately absent: a social account is
    -- something a character chooses to open, not something their phone arrives with.
    installed = {
        'emergency',  -- first on the grid, and `required` below: it is never a download
        'bank', 'mail', 'maps', 'camera', 'gallery', 'music',
        'garage', 'property', 'wallet', 'jobs', 'health',
        'notes', 'reminders', 'calc',
        'mdt',        -- gated to the police by `job` in the catalogue; absent for everyone else
        'store',
    },

    -- Cannot be removed by the player. A phone with no Phone app is a brick, and a phone
    -- with no store can never get anything back.
    -- 911 is in here rather than only in the catalogue: this list WINS over the catalogue's
    -- own `required` field (see the loop below), so an app left out of it is removable
    -- whatever its entry says. Switch the app off with `Config.Emergency.enabled` - a player
    -- does not get to delete the one app they will need while they are being shot at.
    required = { 'phone', 'messages', 'contacts', 'store', 'settings', 'emergency' },

    -- Not offered at all: not on the home screen, not in the store, not searchable.
    -- Use this to switch an app off entirely rather than deleting its catalogue entry,
    -- which would lose its metadata and its translations.
    hidden = {},
}

-- Apply the layout to the catalogue. Order of business: drop what is hidden, then let
-- `dock` and `installed` decide slots, and let anything they do not mention become a
-- download. Written as a loop rather than by hand so the two tables cannot drift.
do
    local hidden, required, dock, order = {}, {}, {}, {}
    for _, id in ipairs(Config.Home.hidden or {}) do hidden[id] = true end
    for _, id in ipairs(Config.Home.required or {}) do required[id] = true end
    for i, id in ipairs(Config.Home.dock or {}) do dock[id] = i end
    for i, id in ipairs(Config.Home.installed or {}) do order[id] = i end

    local kept = {}
    for _, app in ipairs(Config.Apps) do
        if not hidden[app.id] then
            local metadata = Config.AppMetadata[app.id] or {}
            app.developer = app.developer or 'iFruit Studio'
            app.version = app.version or '2.0.0'
            app.features = app.features or metadata.features or {}
            app.keywords = app.keywords or metadata.keywords or {}

            app.required = required[app.id] or false
            if dock[app.id] then
                -- The dock comes first and is never a download.
                app.dock = true
                app.optional = false
                app.slot = dock[app.id]
            else
                app.dock = false
                -- Listed means shipped; unlisted means the store has it.
                app.optional = order[app.id] == nil
                -- Dock slots are 1..n, so the grid starts after them and a download
                -- lands past everything shipped rather than in the middle of it.
                app.slot = order[app.id]
                    and (#(Config.Home.dock or {}) + order[app.id])
                    or (100 + #kept)
            end
            kept[#kept + 1] = app
        end
    end
    Config.Apps = kept
end

-- What the store groups by. The order here is the order of the sections.
Config.Categories = { 'social', 'finance', 'utilities', 'travel', 'work', 'duty',
                      'entertainment', 'health', 'essentials' }

-- ── Social ─────────────────────────────────────────────────────
-- Bleeter, Snapmatic and Hush. They used to live in a separate resource because they need
-- something the rest of the phone avoids - data SHARED between players - but a phone that
-- cannot show its own social apps without a second resource running is not a phone, it is
-- half of one. The model lives here now, and the apps are views of it.
--
-- The brands are Rockstar's own: Bleeter and Snapmatic ship in the game.
Config.Social = {
    -- How far back the Explore grid looks, in hours. A week by default: long enough that a
    -- quiet server still has a grid, short enough that it is not a hall of fame.
    exploreHours = 168,

    -- How far back "trending" looks, in hours. A window rather than all time: trending that
    -- never changes is a list of whatever was posted in the server's first week.
    trendingHours = 48,

    enabled = true,

    handleMin = 3,
    handleMax = 20,

    -- ── What a player may write ────────────────────────────────
    postMax    = 280,       -- a bleet
    captionMax = 160,       -- a Snapmatic caption or a story line
    commentMax = 280,
    dmMax      = 500,
    bioMax     = 160,
    feedSize   = 50,        -- newest N per feed

    -- ── How long any of it lives ───────────────────────────────
    -- Every one of these is in DAYS and 0 means "for ever". They are swept once at boot
    -- and then once an hour, so a server left running for weeks trims itself instead of
    -- growing a table nobody looks at. Each kind expires on its own clock, because a
    -- throwaway story and a conversation are not the same thing.
    retention = {
        posts    = 60,      -- bleets and Snapmatic photos
        comments = 60,      -- 0 follows the post they belong to, which is deleted with it
        stories  = 1,       -- a day, the way a story is supposed to work
        messages = 30,      -- direct messages between two handles
        likes    = 0,       -- kept while the post is
    },

    -- Stories are the one thing measured in hours rather than days, because a day is the
    -- whole of their life. `retention.stories` is the sweep; this is what a viewer sees.
    storyHours = 24,

    -- ── Hush ───────────────────────────────────────────────────
    hush = {
        enabled = true,

        -- Likes a day WITHOUT the premium pass. Three, deliberately: the ceiling is what makes
        -- a like mean something, and it is also what the pass below sells. Set it to 25 and
        -- turn the pass off for a server that does not want the money in it at all.
        dailyLikes = 3,

        -- Super likes per day. The cap IS the feature: a signal anybody can send at will says
        -- nothing at all. One is what Tinder gives away.
        dailySuper = 1,

        -- How long a pass is remembered before that profile can come round again. 0 means
        -- never show them twice.
        passDays = 7,

        -- ── Hush Premium ───────────────────────────────────────
        -- A day pass, bought from inside the app. The money goes through the bridge, so
        -- qb-core, qbx_core, ox_core and ESX all work without a branch - and so does anything
        -- wired through `Config.Compat.hooks.removeMoney`.
        --
        -- **It fails closed.** If the debit cannot be confirmed the pass is not granted.
        --
        -- Buying again while one is running EXTENDS it. Somebody who pays twice gets two days.
        premium = {
            enabled = true,
            price = 50,          -- per pass. `set phone_socialHushPrice 75` overrides it live
            account = 'bank',    -- 'bank' or 'cash'
            hours = 24,          -- how long one lasts

            -- What it buys.
            likes = 25,          -- instead of dailyLikes above
            superLikes = 5,      -- instead of dailySuper above
            seeLikes = true,     -- see WHO liked you, not just how many
            rewindLikes = true,  -- undo a like, not only a pass
        },
    },

    -- Avatars, Snapmatic shots and Hush photos are URLs other clients will fetch, so the
    -- hosts are an operator decision - the same rule, and the same list, as wallpapers.
    imageHosts = {
        'i.imgur.com', 'imgur.com',
        'cdn.discordapp.com', 'media.discordapp.net',
        'i.ibb.co', 'raw.githubusercontent.com',
    },
}

-- ── Look ───────────────────────────────────────────────────────
-- The chrome is the phone's; the accent, panel and radius come from v-ui, so a server that
-- themes the framework purple gets a purple phone rather than an orange rectangle in a
-- purple world.
Config.Wallpapers = { 'ifruit', 'aurora', 'lagoon', 'dune', 'grid', 'night', 'ember' }
Config.DefaultWallpaper = 'ifruit'

-- iOS 27's transparency slider, as a starting value: 0 is ultra clear glass, 100 is
-- fully tinted. Players move it themselves in Settings; this is only where they begin.
Config.DefaultGlass = 42

-- ── Custom wallpapers ──────────────────────────────────────────
-- A player may point the phone at an image on the web. That is a URL a client will fetch,
-- so the hosts it may fetch from are an OPERATOR decision, exactly as they are for music.
-- It ships narrow on purpose: an open list is a way to make somebody's client load
-- anything at all.
Config.WallpaperHosts = {
    'i.imgur.com', 'imgur.com',
    'cdn.discordapp.com', 'media.discordapp.net',
    'i.ibb.co', 'raw.githubusercontent.com',
    -- The GIF picker's own hosts. A picture chosen from the shelf is sent as an ordinary
    -- image message and passes the same gate as a pasted link, so a shelf pointing at a host
    -- that is not on this list would be a grid of pictures that refuse to send. Take these
    -- out and the shelf goes with them, which is a supported way to turn the feature off.
    'tenor.com', 'giphy.com',
}

-- How a linked image is fitted. `cover` fills the screen and crops; `contain` shows all of
-- it with bars. Both are offered because neither is right for every picture.
Config.WallpaperFit = 'cover'

-- The device itself. Players with small screens want it smaller, and left-handers want it
-- on the other side; neither is worth making them live without.
-- How big the handset is drawn, for everyone. 1.0 is the ONLY value that renders exactly:
-- the phone is laid out in pixels at 372x784, so any other size is a `transform: scale()`
-- over an already-drawn image and the text goes soft. There is no player-facing slider for
-- that reason. Change this if you want a different fixed size and accept the softness.
Config.DeviceSize = 1.0        -- 0.75 .. 1.15, but only 1.0 is pixel-exact
Config.DeviceSide = 'right'    -- right | left

-- ── Mail ───────────────────────────────────────────────────────
-- Addresses are chosen once and belong to the character. The domains are the game's own
-- companies, because inventing a webmail brand would break the world every other module
-- is set in.
Config.Mail = {
    -- The domains offered when a player creates their address. Add, remove or reorder
    -- freely: the first one is simply what the picker starts on, and the server accepts an
    -- address only if its domain is in this list. Existing addresses are never touched by a
    -- change here, so removing a domain stops new sign-ups on it without breaking anyone.
    domains  = { 'ls.com', 'eyefind.info', 'lifeinvader.com', 'bilkinton.com' },

    -- ── Domains only certain jobs may sign up on ───────────────
    -- A public service needs an address that cannot be impersonated. `@lspd.gov` is worth
    -- nothing if any player can take `chief@lspd.gov` before the actual chief does.
    --
    -- The key is the domain, the value is the list of jobs allowed on it. A reserved domain
    -- does NOT need to be in `domains` above and should not be: that list is what everybody
    -- is offered, and this one is only offered to whoever qualifies. Both are checked on the
    -- server, so a client asking for a domain it was never shown is refused.
    --
    -- **An address already created survives the player losing the job.** A dismissed officer
    -- keeping their `@lspd.gov` address is a roleplay matter to settle in character, not a
    -- mailbox for a script to delete behind them - and revoking it would silently break every
    -- thread they are part of. Take the job away and they simply cannot make a NEW one.
    -- Two shapes, because two different things get asked for:
    --
    --   a list of jobs          any grade of that job qualifies
    --   a job -> minimum grade  only from that grade upwards
    --
    -- Mix them freely in the same table, and mix them inside one domain: a list entry means
    -- "any grade", a `job = n` entry means "grade n or higher". So a domain every officer may
    -- use and one only command staff may use are both expressible, and so is a domain the whole
    -- of one force shares with only the chiefs of another.
    reserved = {
        -- ['lspd.gov']    = { 'police', 'sheriff', 'bcso' },
        -- ['ems.gov']     = { 'ambulance', 'ems' },
        -- ['ls.gov']      = { 'judge', 'mayor', 'government' },
        -- ['weazel.news'] = { 'reporter', 'journalist' },

        -- Command staff only. Grade 4 and above of the police, any grade of `chief`.
        -- ['command.lspd.gov'] = { police = 4, 'chief' },
    },

    -- ── How many addresses one character may hold ──────────────
    -- One is the classic mailbox. More is what somebody actually wants: a personal address and
    -- a work one, kept apart, switched between in the app.
    --
    -- There is no "active address" stored anywhere. The page names which of its addresses it is
    -- acting as on every request, and the server checks that the address belongs to the caller
    -- - which is both simpler than a stored pointer and stricter, because there is no state to
    -- get out of step with the truth.
    maxAccounts = 3,

    -- ── A domain a player buys ─────────────────────────────────
    -- The state's domains are yours to define in `reserved` above. This is the other half: a
    -- player registering a domain of their own, for a company or a newspaper, by paying for it.
    --
    -- Owning a domain lets THAT player create addresses on it. It does not let them hand
    -- addresses to other people - that is a company directory, a bigger feature than this, and
    -- pretending to offer it would be worse than not.
    custom = {
        enabled = false,       -- off by default: a server should decide to sell something
        price   = 25000,
        account = 'bank',      -- which account the money comes out of
        minLen  = 4,
        maxLen  = 24,

        -- Words a player may not register, checked as a whole label and as any dot-separated
        -- part of one. The point is that a bought domain must never be able to READ like a
        -- public service: `police.ls` and `ls-police.com` are both refused by this list.
        --
        -- A domain already in `domains` or `reserved` is refused regardless of this list, so
        -- there is no need to repeat them here.
        blocked = {
            'gov', 'gouv', 'police', 'lspd', 'bcso', 'sheriff', 'ems', 'ambulance',
            'sams', 'fib', 'iaa', 'state', 'etat', 'mairie', 'city', 'justice',
            'court', 'tribunal', 'prison', 'admin', 'staff', 'ifruit', 'phone',
        },
    },

    -- Attach an image to a mail: one picked from the phone's own gallery, or a link.
    --
    -- The URL faces every recipient's client, so it goes through the same host allowlist as a
    -- wallpaper or an avatar - `Config.Media.hosts`. Off refuses both, and an existing mail
    -- that carries one still shows it.
    images = true,
    maxSubject = 80,
    maxBody    = 2000,
    maxTo      = 10,       -- a group mail, not a mailing list
    localMin   = 3,
    localMax   = 20,
}

-- ── Sounds ─────────────────────────────────────────────────────
-- Ringtones and alerts are played by the page, not by the game, so a player can point one
-- at their own MP3. The built-ins are synthesised in the browser - no audio ships with the
-- resource, and nothing is fetched unless somebody chose a link.
--
-- A custom tone is a URL a client will fetch, so the hosts are an operator decision, the
-- same rule as wallpapers and avatars.
Config.Sounds = {
    -- `signal` and `note` are the two that only exist as shipped files; everything else
    -- has a synthesised fallback of the same name.
    -- The soft three come FIRST, because the first entry is what a phone nobody has
    -- touched rings with, and a handset should be pleasant before it is loud.
    ringtones = { 'drift', 'still', 'cascade',
                  'classic', 'chime', 'pulse', 'radar', 'signal', 'none' },
    alerts    = { 'breeze', 'hush', 'soften', 'ping', 'pop', 'tick', 'note', 'none' },

    -- Use the WAV files in `sounds/` rather than synthesising the tones in the browser.
    -- They are generated, not sampled: `python tools/make-sounds.py` rebuilds all of
    -- them, so changing a melody is changing a table in that script.
    --
    -- Off falls back to the oscillators, which is also what happens automatically if a
    -- file is missing. A phone always rings.
    files = true,

    allowCustom = true,
    hosts = {
        'cdn.discordapp.com', 'media.discordapp.net',
        'raw.githubusercontent.com', 'github.com',
        'files.catbox.moe', 'i.imgur.com',
    },
}

-- ── AirDrop ────────────────────────────────────────────────────
-- Send a contact, your number or a photo to a nearby phone. Both ends must have
-- Bluetooth on in the control centre, and be within range - the same two conditions the
-- real thing needs to see a device at all.
Config.Airdrop = { range = 12.0, offerTtl = 30 }

-- ── Battery ────────────────────────────────────────────────────
-- Eight real-world hours from full to flat, which is roughly what a phone does. The
-- number is a setting because "how long is a session here" is a server's answer, not
-- ours.
--
-- **It only drains while the player is connected.** A phone genuinely goes flat in a
-- drawer, but so does the ability to charge it: coming back from a week away to a dead
-- phone and no way to have prevented it is a punishment for logging off.
Config.Battery = {
    -- These are the fallbacks the code uses when Config.Settings has no answer; keep them
    -- in step with it or the two disagree the moment somebody clears a setting.
    hoursToEmpty = 72.0,    -- idle, phone closed: three days
    screenMultiplier = 1.5, -- with the screen on, so about two days of actual use
    chargeMinutes = 45.0,   -- flat to full at a charger
    lowAt = 20,             -- first warning
    criticalAt = 5,

    -- ── How quickly the phone notices where it is ──────────────
    -- Two different questions, on two different clocks, because they move at two different
    -- speeds.
    --
    -- `stateSeconds` is how often SIGNAL and CHARGING are re-checked. Both are step changes
    -- tied to a position: you walk into a dead zone, or you put the phone on a charger, and the
    -- status bar should say so almost at once. It used to share the drain tick below, which
    -- meant "no service" could take twenty seconds to appear - long enough to read as broken.
    -- It is a handful of distance checks per player, so this is cheap.
    stateSeconds = 2,
    -- `drainSeconds` is the battery arithmetic and the row written to the database. A battery
    -- level genuinely moves this slowly - a percent every few minutes - and checking it faster
    -- would be arithmetic nobody can see, plus a write per player per tick.
    drainSeconds = 20,
}

-- ══════════════════════════════════════════════════════════════
--  WRITING A POSITION
-- ══════════════════════════════════════════════════════════════
-- Every table in this file that names a place accepts BOTH ways of writing it:
--
--     { label = 'LSIA', x = -1037.0, y = -2737.0, z = 20.2, radius = 8.0 }
--     { label = 'LSIA', coords = vector3(-1037.0, -2737.0, 20.2), radius = 8.0 }
--
-- `vector3(...)` is what every other script and every coordinate-copying tool in FiveM hands
-- you, so pasting one straight in has to work - retyping it into three fields is a step whose
-- only possible outcome is a typo. `vec3` and `vector4` are accepted too, as is a plain
-- `{ x, y, z }` array, and `pos` is accepted as a spelling of `coords`.
--
-- Normalised ONCE, here, into `x`/`y`/`z`, so nothing downstream has to know that any of this
-- happened: the whole resource keeps reading the three fields it always read.
local function normalisePlaces(list)
    if type(list) ~= 'table' then return list end
    for _, row in ipairs(list) do
        if type(row) == 'table' then
            local v = row.coords or row.pos or row.position
            if v ~= nil and row.x == nil then
                local kind = type(v)
                -- **A vector is not a table, and it is not forgiving.** A real CFX `vector3`
                -- raises "attempt to index a vector value" for any key it does not have - so
                -- `v.w` on a vector3, and `v[1]` on any vector, are errors rather than nil.
                -- The first version of this read `tonumber(v.x) or tonumber(v[1])`, which
                -- survived only because `or` short-circuits; the `v.w` on the heading line had
                -- nothing to short-circuit past and took the whole config down with it.
                --
                -- So the three shapes are handled separately, and each is only asked for what
                -- it actually has.
                if kind == 'vector4' then
                    row.x, row.y, row.z = v.x, v.y, v.z
                    if row.heading == nil then row.heading = v.w end
                elseif kind == 'vector3' or kind == 'vector2' then
                    row.x, row.y = v.x, v.y
                    -- vector2 has no z. Left nil here and defaulted below, like a map pin.
                    if kind == 'vector3' then row.z = v.z end
                elseif kind == 'table' then
                    -- A plain table: either { x = , y = , z = } or a pasted { 1.0, 2.0, 3.0 }.
                    -- Indexing a table for a key it lacks is nil, not an error, so both reads
                    -- are safe here and only here.
                    row.x = tonumber(v.x) or tonumber(v[1])
                    row.y = tonumber(v.y) or tonumber(v[2])
                    row.z = tonumber(v.z) or tonumber(v[3])
                    if row.heading == nil then row.heading = tonumber(v.w) or tonumber(v[4]) end
                end
            end
            -- z is optional for a place that is only ever a map pin - a hospital, a waypoint.
            if row.x ~= nil and row.z == nil then row.z = 0.0 end
        end
    end
    return list
end

-- Charging happens at these, and also in any vehicle and inside a property you hold a key
-- to. Those two are code, because they follow the player rather than a coordinate.
-- SEED DATA ONLY: chargers live in `world_chargers` and are edited from the admin panel.
--
-- Positions may be written either way - see `normalisePlaces` above.
--
-- A charger can COST money. Give a row a `price` and the phone asks before it charges - see
-- Config.PaidCharging below. `account` overrides where that money goes, so the airport's
-- kiosks can pay the airport and the hospital's can pay the hospital.
Config.Chargers = {
    { id = 'ch_lsia',      label = 'LSIA, arrivals hall',    x = -1037.0, y = -2737.0, z = 20.2, radius = 8.0,
      -- The paid example. Delete `price` and this charger is free like the rest.
      price = 40, account = 'airport' },
    { id = 'ch_legion',    label = 'Legion Square kiosk',    x = 195.0,   y = -933.0,  z = 30.7, radius = 6.0 },
    { id = 'ch_pillbox',   label = 'Pillbox Hill Medical',   x = 306.0,   y = -595.0,  z = 43.3, radius = 8.0 },
    { id = 'ch_paleto',    label = 'Paleto Bay, sheriff',    x = -448.0,  y = 6013.0,  z = 31.7, radius = 6.0 },
    { id = 'ch_sandy',     label = 'Sandy Shores, clinic',   x = 1839.0,  y = 3672.0,  z = 34.3, radius = 8.0 },
    -- Both spellings work. This one is written the way a coordinate arrives from every other
    -- FiveM tool, so the file itself shows that pasting one straight in is fine.
    { id = 'ch_vespucci',  label = 'Vespucci boardwalk',
      coords = vector3(-1223.0, -1493.0, 4.4), radius = 6.0 },
}
normalisePlaces(Config.Chargers)

-- ══════════════════════════════════════════════════════════════
--  THE LOOK  (one place that changes the colour of the phone)
-- ══════════════════════════════════════════════════════════════
-- **This is the half of the theme that was missing.**
--
-- The stylesheet declared five colour tokens and then wrote every other value out by hand -
-- about a hundred and thirty times - so changing "the green" changed four things and the phone
-- stayed green. Every one of those is a token now, which fixed the stylesheet; this fixes the
-- part an operator can reach, because editing CSS in a resource you did not write is not a
-- theme, it is a fork.
--
-- Anything left as nil keeps the phone's own value. Set one colour and only that changes.
--
-- **These are the system colours, not the app tints.** An app's own tile keeps its identity -
-- Zuber is black, the Lottery is green, the taxi is yellow - because those are brands rather
-- than theme, and re-tinting them would make every icon on the home screen the same colour.
Config.Theme = {
    -- The colour of every control that is "the accent": links, switches, the selected tab, the
    -- send button. This is the one most servers will set and nothing else.
    --
    --     accent = '#FF7A1A',
    accent = nil,

    -- The rest of the system palette. Each is used for what its name says: green for confirm
    -- and money in, red for destructive and money out, orange for warnings, and so on.
    --
    --     green = '#30D158',   red = '#FF453A',    orange = '#FF9F0A',
    --     yellow = '#FFD60A',  indigo = '#5E5CE6', pink = '#FF375F',
    --     teal = '#40C8E0',    purple = '#BF5AF2', grey = '#8E8E93',
    green = nil,
    red = nil,
    orange = nil,
    yellow = nil,
    indigo = nil,
    pink = nil,
    teal = nil,
    purple = nil,
    grey = nil,

    -- Whether the phone starts in dark mode. nil leaves it to the player's own setting, which
    -- is where it belongs - this is only the default for somebody who has never chosen.
    dark = nil,
}

-- ══════════════════════════════════════════════════════════════
--  PLACES  (what the Maps app lists, and routes to)
-- ══════════════════════════════════════════════════════════════
-- **This is where the pins go.** The Maps app used to read one source - a v-world module most
-- servers do not run - so on everybody else's server it drew "nothing on the map yet" and there
-- was nowhere to put anything. Now it lists these, and v-world's own rows as well when that
-- resource IS running: the two are merged rather than one replacing the other.
--
-- A player taps a place and their GPS is set to it. That is all the app does with a pin, and it
-- is deliberately all: a waypoint is something they can then ignore, which a marker drawn on
-- their screen is not.
--
-- ── The categories ────────────────────────────────────────────
-- `key` is what a place refers to, `label` is what a player reads, and `icon` is the tile.
--
-- The label may be one of this resource's own phrases - the `ph.` ones below, which read in the
-- player's language - or your own words, written straight in and passed through untouched. That
-- is how a server adds "Docks" or "Cartel" without editing a locale file.
Config.PlaceCategories = {
    { key = 'garage',   label = 'ph.place_garage',   icon = 'garage' },
    { key = 'shop',     label = 'ph.place_shop',     icon = 'store' },
    { key = 'fuel',     label = 'ph.place_fuel',     icon = 'charging' },
    { key = 'bank',     label = 'ph.place_bank',     icon = 'bank' },
    { key = 'hospital', label = 'ph.place_hospital', icon = 'heart' },
    { key = 'police',   label = 'ph.place_police',   icon = 'shield' },
    { key = 'job',      label = 'ph.place_job',      icon = 'jobs' },
    { key = 'leisure',  label = 'ph.place_leisure',  icon = 'music' },
}

-- ── The pins ──────────────────────────────────────────────────
-- One row per place.
--
--   label   what a player reads. Your own words, or a `ph.` phrase.
--   kind    a `key` from the categories above. An unknown one still shows, under its own name -
--           a pin nobody can find is worse than a pin in a category you forgot to declare.
--   coords  where it is. `vector3(x, y, z)` or `x = ..., y = ...` - both are accepted.
--   enabled false hides one without deleting it, for a place that is closed this month.
--
-- The list below is a starting point of real Los Santos locations, not a prescription: delete
-- the ones your server does not use and add your own. Nothing here is referenced by any other
-- part of the phone, so this list is yours entirely.
Config.Places = {
    -- Garages and mechanics
    { label = 'Los Santos Customs',   kind = 'garage', coords = vector3(-337.2, -136.8, 39.0) },
    { label = "Benny's Original",     kind = 'garage', coords = vector3(-205.6, -1310.5, 31.3) },
    { label = 'Hayes Autos',          kind = 'garage', coords = vector3(487.9, -1316.5, 29.2) },

    -- Shops
    { label = '24/7 Strawberry',      kind = 'shop',   coords = vector3(25.7, -1347.3, 29.5) },
    { label = '24/7 Grapeseed',       kind = 'shop',   coords = vector3(1698.4, 4924.4, 42.1) },
    { label = 'LTD Mirror Park',      kind = 'shop',   coords = vector3(1163.4, -323.8, 69.2) },
    { label = 'Ammu-Nation Pillbox',  kind = 'shop',   coords = vector3(252.9, -50.0, 69.9) },

    -- Fuel
    { label = 'Xero Gas, Grove St',   kind = 'fuel',   coords = vector3(265.7, -1261.3, 29.3) },
    { label = 'RON, Route 68',        kind = 'fuel',   coords = vector3(1039.9, 2671.1, 39.6) },
    { label = 'LTD, Little Seoul',    kind = 'fuel',   coords = vector3(-707.5, -914.4, 19.2) },

    -- Money
    { label = 'Fleeca, Legion Square', kind = 'bank',  coords = vector3(149.2, -1040.2, 29.4) },
    { label = 'Fleeca, Route 68',      kind = 'bank',  coords = vector3(-2957.7, 481.6, 15.7) },
    { label = 'Pacific Standard',      kind = 'bank',  coords = vector3(235.0, 216.5, 106.3) },

    -- Emergency
    { label = 'Pillbox Hill Medical',  kind = 'hospital', coords = vector3(298.6, -584.7, 43.3) },
    { label = 'Sandy Shores Medical',  kind = 'hospital', coords = vector3(1839.6, 3672.9, 34.3) },
    { label = 'Mission Row PD',        kind = 'police',   coords = vector3(441.0, -982.1, 30.7) },
    { label = 'Sandy Shores Sheriff',  kind = 'police',   coords = vector3(1853.2, 3686.6, 34.3) },
    { label = 'Paleto Bay Sheriff',    kind = 'police',   coords = vector3(-448.6, 6013.3, 31.7) },

    -- Work
    { label = 'City Hall',             kind = 'job',    coords = vector3(-544.6, -204.2, 38.2) },
    { label = 'Docks',                 kind = 'job',    coords = vector3(852.4, -3140.0, 5.9) },
    { label = 'Weazel News',           kind = 'job',    coords = vector3(-598.5, -929.4, 23.9) },

    -- Somewhere to be
    { label = 'Vanilla Unicorn',       kind = 'leisure', coords = vector3(127.5, -1298.9, 29.2) },
    { label = 'Bahama Mamas',          kind = 'leisure', coords = vector3(-1387.7, -618.3, 30.8) },
    { label = 'Vespucci Beach',        kind = 'leisure', coords = vector3(-1223.0, -1493.0, 4.4) },
}
normalisePlaces(Config.Places)

-- ══════════════════════════════════════════════════════════════
--  THE FRUITSTORE  (downloading takes time, and updates exist)
-- ══════════════════════════════════════════════════════════════
-- An app used to appear the instant it was tapped, which made the store the one part of the
-- phone where the network did not exist - everything else here refuses without bars.
Config.Store = {
    -- ── Where the money goes ───────────────────────────────────
    -- What a player spends on a paid app used to leave the economy: debited from them and
    -- credited to nobody. Name a society or business account here and it arrives somewhere -
    -- the state, a tech company somebody roleplays, whatever the server's fiction is.
    --
    -- `account` is the account name your banking script knows, exactly as `Config.Chargers`
    -- and Bank Pro use it. Empty means nowhere, which is what happened before and stays the
    -- default: a server that has not thought about it should not suddenly start feeding an
    -- account it did not create.
    --
    -- `percent` is how much of the price arrives. 100 is all of it. Rounded DOWN, so the house
    -- never rounds up. A credit that fails - a misspelled account, a banking script that is
    -- not running - does NOT cancel the sale: the player still gets the app they paid for,
    -- because an operator's typo is not the player's problem.
    revenue = {
        account = '',
        percent = 100,
    },

    -- ── Ratings and reviews ────────────────────────────────────
    -- What the store showed before was a hash of each app's own id - the same 4.5 stars and
    -- the same few thousand ratings on every server, for ever. These are what your players
    -- actually think.
    --
    -- One review per character per app, and writing a second one EDITS the first rather than
    -- adding a second opinion from the same person.
    reviews = {
        enabled = true,

        -- May somebody rate an app they do not have? Off, and it should stay off: a rating is
        -- a claim about having used something, and a store where anybody can score anything is
        -- a store whose scores answer nothing. Removing an app later keeps the review - you
        -- did use it.
        requireInstalled = true,

        -- How long a review may be. A store review is a paragraph, not an essay.
        maxLength = 300,
    },

    download = {
        enabled = true,

        -- **How long a full download takes, per signal bar.**
        --
        -- The rate is read EVERY SECOND, not once at the start, so this is not a fixed duration
        -- somebody is sentenced to: a player who starts a download underground and drives into
        -- town watches it speed up, and finishes early. That is both what a real phone does and
        -- the kinder behaviour.
        --
        -- Zero bars does not fail - it HOLDS. Somebody walking through a tunnel expects to come
        -- out the other side and find it still going.
        secondsAtBars = {
            [4] = 10,   -- full signal
            [3] = 15,
            [2] = 30,
            [1] = 60,   -- one bar
        },

        -- Used for a bar count that is not in the table above, which should not happen.
        seconds = 10,
    },

    -- ── Updates ────────────────────────────────────────────────
    -- Every app in `Config.Apps` may carry a `version`. The store compares it against the
    -- version the character actually installed and offers an update when they differ.
    --
    -- **An app installed before it had a version reads as up to date**, not as needing an
    -- update on day one - the difference between a badge people act on and a badge everybody
    -- learns to dismiss. Bump an app's `version` when you change it and everybody is offered
    -- the new one; leave it alone and nobody is bothered.
    --
    -- An update is never charged for. What was paid for was the app.
    updates = true,
}

-- ══════════════════════════════════════════════════════════════
--  EXPORT  (what your haul is worth, before you drive across the map)
-- ══════════════════════════════════════════════════════════════
-- A free download. Free because it is a price board: charging somebody to find out what their
-- goods are worth is charging them for the information they need to decide whether to bother.
--
-- Two providers, one app, and a player never learns which one answered:
--
--   * **doc-shops**, when that resource is started. Its markets, its items, its fluctuating
--     prices and its history. It publishes `GetMarketData(market)` as a **server export**, which
--     is what makes the alerts possible at all: the phone's own server reads the board directly,
--     on a timer, so an alert can fire while the app is closed and the player is in a field
--     somewhere. **Nothing in doc-shops is edited, wrapped or replaced.**
--   * **`items` below** otherwise, which is what makes the app worth having on an ESX, ox or
--     standalone server: the phone's own board, its own fluctuation, its own history.
--
-- **The app never sells anything.** It says what a thing is worth and where the price is going;
-- selling happens at the shop, in front of the person buying it. An app that moved goods would
-- be a second inventory system nobody asked for.
Config.Export = {
    enabled = true,

    -- 'auto' uses doc-shops when it is started and the board below when it is not.
    -- 'doc-shops' or 'config' pin it, for a server that wants to be sure which is live.
    provider = 'auto',

    -- Which boards the app shows, in this order. doc-shops keeps two - what it pays you for
    -- goods, and what it charges to import them - and they move together, because its import
    -- price is the export price plus a margin.
    --
    -- One entry gives a single board with no switcher, which is the right shape for a server
    -- that only sells.
    markets = {
        { key = 'export', label = 'ph.export_m_export' },
        { key = 'import', label = 'ph.export_m_import' },
    },

    -- ── Watching the board ─────────────────────────────────────
    -- How often the SERVER re-reads the prices, in seconds. This is what alerts are checked
    -- against, so it is the shortest delay between a price moving and a phone buzzing.
    --
    -- doc-shops fluctuates every twenty minutes, so there is nothing to gain from asking every
    -- second - and each read is a database query on its side. Two minutes notices a change
    -- within a tenth of the time it takes to happen.
    pollSeconds = 120,

    -- How many points of history the phone keeps per item, for the line on an item's page.
    -- doc-shops keeps five of its own; anything beyond that is what the phone has watched
    -- since it started.
    history = 24,

    -- ── Favourites ─────────────────────────────────────────────
    -- The items a player wants at the top. Capped because it is a list on a phone screen: a
    -- hundred favourites is the whole board again with extra steps.
    maxFavourites = 24,

    -- ── Alerts ─────────────────────────────────────────────────
    -- "Tell me when it goes above 900." Three kinds, and they answer different questions:
    --
    --   above   a price to sell at        - the one everybody sets first
    --   below   a price to buy at         - the same thing from the import side
    --   move    a percentage swing        - "tell me when something happens", for people who
    --                                       do not know what the number should be
    --
    -- Set to false to remove a kind from the app entirely.
    alerts = { above = true, below = true, move = true },

    -- How many an ordinary player may have standing at once.
    maxAlerts = 12,

    -- Seconds before the SAME alert may fire again. Without this, a price that sits just over
    -- the line buzzes on every poll for as long as it stays there - which is how somebody ends
    -- up muting the app and missing the one that mattered.
    alertCooldown = 1800,

    -- An alert fires once and then goes quiet until the price crosses back. Off makes it fire
    -- every time the condition holds, subject to the cooldown above - louder, and honest about
    -- being louder.
    alertRearm = true,

    -- Does an alert survive being fired? Off deletes it, which suits "tell me once, when my
    -- haul is finally worth selling".
    alertKeep = true,

    notify = true,

    -- ── The board, when doc-shops is not there ─────────────────
    -- Ignored entirely under doc-shops, which has its own items, categories and prices.
    --
    --   name      the item name your inventory uses
    --   label     what a player reads
    --   category  a key from `categories` below
    --   min/max   the range the price wanders between, inclusive
    --
    -- Prices move on `fluctuateSeconds`, the same way doc-shops moves its own: a new value in
    -- the range rather than a drift, because a market that only ever creeps is one nobody
    -- watches.
    -- Where item pictures come from, for the board below. Every inventory in FiveM lays them
    -- out the same way - one PNG per item name - so this is the folder and the app adds
    -- `<item>.png`. A trailing slash is optional; it is added if you forget it.
    --
    --     imageBase = 'nui://qs-inventory/html/images/',
    --     imageBase = 'nui://ox_inventory/web/images/',
    --     imageBase = 'https://your-cdn.example/items/',
    --
    -- An item may also carry its own `image` for the one that does not follow the pattern.
    -- Empty leaves every row with its initial, which is what they looked like before there
    -- were any pictures.
    --
    -- **Ignored under doc-shops**, which builds its own URLs and knows which inventory that
    -- server runs - guessing at it from here would be worse information, not better.
    imageBase = 'nui://qs-inventory/html/images/',

    categories = {
        metal   = 'ph.export_c_metal',
        food    = 'ph.export_c_food',
        chem    = 'ph.export_c_chem',
        luxury  = 'ph.export_c_luxury',
        general = 'ph.export_c_general',
    },

    items = {
        { name = 'copper',      label = 'Copper',        category = 'metal',   min = 55,   max = 140 },
        { name = 'iron',        label = 'Iron',          category = 'metal',   min = 40,   max = 110 },
        { name = 'aluminium',   label = 'Aluminium',     category = 'metal',   min = 70,   max = 180 },
        { name = 'steel',       label = 'Steel',         category = 'metal',   min = 90,   max = 220 },
        { name = 'gold',        label = 'Gold',          category = 'luxury',  min = 600,  max = 1400 },
        { name = 'diamond',     label = 'Diamond',       category = 'luxury',  min = 1200, max = 3200 },
        { name = 'wheat',       label = 'Wheat',         category = 'food',    min = 20,   max = 60 },
        { name = 'fish',        label = 'Fish',          category = 'food',    min = 35,   max = 95 },
        { name = 'meat',        label = 'Meat',          category = 'food',    min = 45,   max = 120 },
        { name = 'sulfur',      label = 'Sulphur',       category = 'chem',    min = 80,   max = 200 },
        { name = 'petrol',      label = 'Petrol',        category = 'chem',    min = 110,  max = 260 },
        { name = 'plastic',     label = 'Plastic',       category = 'general', min = 25,   max = 70 },
        { name = 'glass',       label = 'Glass',         category = 'general', min = 30,   max = 85 },
        { name = 'rubber',      label = 'Rubber',        category = 'general', min = 28,   max = 78 },
    },

    -- Twenty minutes, which is doc-shops' own interval - so a server that switches provider
    -- does not also change how often the board moves under its players.
    fluctuateSeconds = 1200,
}

-- ══════════════════════════════════════════════════════════════
--  REPAIR  (reaching a mechanic, from the side of the road)
-- ══════════════════════════════════════════════════════════════
-- A free download. Free on purpose: somebody who has broken down needs this at the moment they
-- break down, and an app that costs money is one they have not installed yet.
--
-- Two providers, one app, and a player never learns which one answered:
--
--   * **doc-mechanicmdt**, when that resource is started. Its garages, its opening states, its
--     ratings, its callout queue and its invoice rule - reached through the same six server
--     callbacks its own phone app used. **Nothing in doc-mechanicmdt is edited, wrapped or
--     replaced.** Update it, and this keeps working.
--   * **`garages` below** otherwise, which is what makes the app worth having on an ESX, ox or
--     standalone server: the phone's own garages, its own callout table, its own reviews.
--
-- **Both sides of the call are here.** A driver asks for a callout and follows it; a mechanic
-- holding the job gets the queue, takes a job, and can ring the person who asked. That second
-- half is what doc-mechanicmdt's own phone app did not have - it had a tablet for it, which is
-- no use to a mechanic who is out on a job.
Config.Repair = {
    enabled = true,

    -- 'auto' uses doc-mechanicmdt when it is started and the list below when it is not.
    -- 'doc-mechanicmdt' or 'config' pin it, for a server that wants to be sure which is live.
    provider = 'auto',

    -- ── The garages (config provider only) ─────────────────────
    -- Ignored entirely under doc-mechanicmdt, which has its own list, its own names and its own
    -- open/closed switch that the staff throw from their tablet.
    --
    --   job      the job name your framework uses. This is what makes somebody staff here.
    --   label    what the customer reads
    --   coords   where it is: the route button, and the distance in the list
    --   open     false for a garage that exists but is not taking callouts yet
    garages = {
        { job = 'mechanic',  label = 'Los Santos Customs',
          coords = vector3(-359.96, -125.28, 38.7), open = true },
        { job = 'mechanic2', label = 'Route 68 Garage',
          coords = vector3(563.54, 2737.71, 42.06), open = true },
        { job = 'mechanic3', label = "Benny's Original Motorworks",
          coords = vector3(-237.06, -1326.69, 31.3), open = true },
    },

    -- ── Who is staff ───────────────────────────────────────────
    -- The mechanic side of the app: the callout queue, taking a job, ringing the client.
    --
    -- **Under doc-mechanicmdt this list must MIRROR its `Config.AuthorizedJobs`.** It decides
    -- for itself who may see its queue - which is right, they are its callouts - but it does
    -- not publish that decision, so the phone cannot ask "am I staff?" and works it out from
    -- here. Get it wrong and the tab appears for somebody whose queue then comes back empty:
    -- annoying, never dangerous, because the refusal is doc-mechanicmdt's and it is final.
    jobs = { 'mechanic', 'mechanic2', 'mechanic3', 'mechanic4', 'mechanic5', 'mechanic6' },

    -- Minimum grade to work the queue, and whether being clocked on is required. Mirror
    -- doc-mechanicmdt's `Config.CallsMinGrade` when it is the provider.
    minGrade = 0,
    requireDuty = true,

    -- ── Calling ────────────────────────────────────────────────
    -- Ringing a garage rings a mechanic who is actually on duty there - the phone picks one,
    -- because a garage is not a person and a number nobody answers is worse than no button.
    -- Off removes the call button and leaves the callout form.
    callGarage = true,

    -- A mechanic can ring the person who asked for the callout, from the job itself.
    --
    -- **This is the "they can call you back" half**, and it is safe here in a way the taxi one
    -- is not: the callout row names the client's citizen id, so the phone can PROVE the pairing
    -- before it hands over a number rather than trusting that the caller was really assigned.
    -- Still gated on the job, still logged.
    callClient = true,

    -- What the callout form fills in for you. The player can edit both before sending - the
    -- number especially, since it is how the garage rings back, and somebody roleplaying a
    -- burner will want to change it.
    prefillName = true,
    prefillNumber = true,

    -- ── The callout ────────────────────────────────────────────
    -- Your position travels with the request. This is the whole point of asking from a phone
    -- rather than over the radio, and it is why there is no "where are you?" field.
    shareLocation = true,

    maxMessage = 300,

    -- Seconds between two callouts from one person. One active callout per garage is enforced
    -- anyway; this stops somebody cycling through every garage in the city in ten seconds.
    cooldown = 60,

    -- How often the tracker and the queue refresh themselves while open, in seconds. 0 stops
    -- the polling entirely and leaves the refresh button - which is the honest setting for a
    -- server that would rather not have a screen asking every few seconds.
    refreshSeconds = 15,

    -- ── Reviews ────────────────────────────────────────────────
    ratings = true,

    -- Only somebody who has actually been a customer may leave a review. Under
    -- doc-mechanicmdt this is ITS rule and it is not negotiable there: it requires an invoice
    -- from that garage. In config mode it means a completed callout.
    requireCustomer = true,

    maxReview = 300,

    -- How many reviews a garage's page shows. The average and the vote count are always shown;
    -- this is only how many written ones are read.
    reviewsShown = 20,
}

-- ══════════════════════════════════════════════════════════════
--  PLUGGING IN  (charging on purpose, rather than by accident)
-- ══════════════════════════════════════════════════════════════
-- **Being somewhere that charges is not the same as charging.**
--
-- By default the phone fills up the moment a player sits in any car or walks into a house they
-- hold a key to. That is convenient and it is not what a phone does: a car and a house are
-- places with a cable in them, and somebody has to pick the cable up.
--
-- Turn this on and a charging place instead offers a switch in FruitCharge - "Put on charge" -
-- and the battery only moves once it is thrown. Walk away and it lets go, so the switch is
-- thrown once per stop rather than once per session.
--
-- **On.** Set `enabled = false` for the old behaviour, where sitting down charges the phone.
Config.PlugIn = {
    enabled = true,

    -- Which places need the switch. Anything left false charges the old way, so an operator can
    -- have exactly the mix they want rather than all of it or none.
    --
    --   vehicle    sitting in any car. The one most worth switching on: a long drive topping
    --              the phone up by itself is why batteries never run out on most servers.
    --   property   inside a home you hold a key to.
    --   charger    a public charger from Config.Chargers. Left false because walking to one is
    --              already a deliberate act - and a PAID one has asked for money by then, so a
    --              second tap on top mostly reads as the app not having understood the first.
    --   external   another resource calling `SetCharging` - an electric car, a scripted socket.
    --              Left false because that resource has already decided; second-guessing it
    --              breaks the one promise that export makes.
    sources = {
        vehicle  = true,
        property = true,
        charger  = false,
        external = false,
    },

    -- Getting out of the car, or leaving the property, unplugs the phone - and getting back in
    -- means opening FruitCharge and plugging in again.
    --
    -- **This is the safety, not a convenience.** Off, the switch stays thrown until the player
    -- turns it off themselves, so walking back to the same car resumes charging without touching
    -- anything - which is the automatic behaviour again, wearing a button. Leave it on unless you
    -- specifically want that.
    unplugOnLeave = true,

    -- Tell them. A phone that quietly stopped charging is a phone that is flat later for no
    -- reason the player can point at, and they were not in the app when it happened.
    notifyOnUnplug = true,
}

-- ══════════════════════════════════════════════════════════════
--  PAID CHARGING
-- ══════════════════════════════════════════════════════════════
-- A public charger that takes money.
--
-- The phone asks, the player accepts or refuses, and one payment buys the whole stop: they
-- charge for as long as they like and pay again only if they LEAVE the zone and come back.
-- Nothing here is per-minute, on purpose - a meter that ticks while somebody is stood at a
-- kiosk is a thing to watch rather than a thing to forget about.
--
-- The offer is sent from the server, from the ped's real position, and accepting is checked
-- again there: a client cannot claim to be at a charger it is not standing at.
Config.PaidCharging = {
    -- Off leaves every charger free, whatever prices the rows above carry.
    enabled = true,

    -- What a stop costs at a charger whose row names no `price` of its own. 0 means the
    -- default is free and only the rows that say otherwise charge.
    price = 0,

    -- Which purse pays: 'cash' or 'bank'. A kiosk that takes a card is 'bank'.
    money = 'cash',

    -- Where the money GOES: a job or society account name. The phone credits it through
    -- your banking script (qb-banking, Renewed-Banking, okokBanking, esx_addonaccount) or
    -- through Config.Compat.hooks.society.
    --
    -- '' pays nobody: the money leaves the player and the operator is scenery. A charger
    -- row's own `account` wins over this, so different sites can pay different owners.
    account = '',

    -- A refusal is remembered this long, so walking past a charger you have already said no
    -- to does not ask again every few seconds. Seconds.
    refusedFor = 90,

    -- How long the offer stands before it expires on its own. Seconds.
    offerSeconds = 45,

    -- How often the server looks for a player standing at a paid charger. The offer cannot
    -- arrive faster than this, so it is the responsiveness of the whole feature - and it is
    -- a handful of distance checks per player, which is nothing.
    --
    -- Kept in step with `Config.Battery.stateSeconds`: the status bar notices the charger in
    -- two seconds, so an offer that took four read as the phone hesitating.
    checkSeconds = 2,

    -- Charge nothing when the battery is already this full. Somebody who walks past with a
    -- nearly-full phone is not a customer, and being asked anyway is just noise. 101 asks
    -- always; 100 skips only a phone that is completely full.
    skipAbove = 95,

    -- ── The FruitCharge app ────────────────────────────────────
    -- Paying a paid charger goes through the app: it lists the chargers, sets a waypoint to
    -- one, and is where the accept / refuse lives - plus an auto-accept for a regular who does
    -- not want to be asked every time.
    --
    -- `requireApp` gates PAID chargers on having the app installed. A free charger never needs
    -- it. Standing at a paid one without it sends a notification that opens the FruitStore
    -- rather than an offer, because there is nothing to accept an offer WITH.
    requireApp = true,
    appId = 'charging',

    -- Whether the app offers the auto-accept option at all. Off removes it from the app, for a
    -- server that wants every charge to be a deliberate tap.
    autoAccept = true,
    -- The highest price the app will auto-pay without asking, when a player turns auto-accept
    -- on. It stops a habit set at a $40 kiosk from quietly clearing a $5,000 one. A player can
    -- set their own lower ceiling in the app; this is the hard cap over it. 0 means no cap.
    autoAcceptMax = 500,

    -- How long between two "get the app" nudges at the same charger, so walking past one you
    -- have not bought the app for does not notify every few seconds. Seconds.
    appPromptFor = 120,
}

-- Where the network does not reach. `bars` is the CEILING inside the zone: 0 means no
-- service at all. Real places, chosen because they are places a story would put you.
-- SEED DATA ONLY: edited from the admin panel -> Editor -> Dead zones.
Config.DeadZones = {
    { id = 'dz_chiliad',   label = 'Mount Chiliad',          x = 501.0,   y = 5604.0,  z = 797.0, radius = 700.0, bars = 0 },
    { id = 'dz_raton',     label = 'Raton Canyon',           x = -1500.0, y = 4400.0,  z = 40.0,  radius = 500.0, bars = 0 },
    { id = 'dz_zancudo',   label = 'Fort Zancudo',           x = -2100.0, y = 3200.0,  z = 32.0,  radius = 900.0, bars = 0 },
    { id = 'dz_humane',    label = 'Humane Labs',            x = 3600.0,  y = 3700.0,  z = 30.0,  radius = 400.0, bars = 0 },
    { id = 'dz_wilderness',label = 'Chiliad Wilderness',     x = -700.0,  y = 5000.0,  z = 100.0, radius = 900.0, bars = 1 },
    { id = 'dz_senora',    label = 'Grand Senora Desert',    x = 1400.0,  y = 2800.0,  z = 60.0,  radius = 800.0, bars = 1 },
    { id = 'dz_tunnel_ls', label = 'Los Santos tunnels',     x = 800.0,   y = -1300.0, z = -40.0, radius = 260.0, bars = 0 },
    { id = 'dz_mine',      label = 'Davis Quartz',           x = 2900.0,  y = 2800.0,  z = 40.0,  radius = 350.0, bars = 1 },
}
normalisePlaces(Config.DeadZones)

-- ══════════════════════════════════════════════════════════════
--  ADMIN
-- ══════════════════════════════════════════════════════════════
-- Staff actions on a player's phone, from the console, an ACE-gated command, or the
-- qb-core admin menu. Every one of them is also an export (see API.md), so an admin menu
-- of any framework can drive them.
-- ══════════════════════════════════════════════════════════════
--  LOGGING
-- ══════════════════════════════════════════════════════════════
-- What the resource says on the way up.
--
-- Everything here is OFF, and the reason is worth stating: a resource that prints twenty
-- lines at every start teaches an operator to scroll past its output, and then the one line
-- that mattered scrolls past too. Problems always print - a framework that was named but is
-- not running, a table that could not be read, a callback with no handler. These switches
-- only govern the lines that are merely true.
-- ══════════════════════════════════════════════════════════════
--  911
-- ══════════════════════════════════════════════════════════════
-- Alerting the emergency services from the phone.
--
-- **These are alerts, not calls.** A player picks a service, picks a reason, and the people
-- working that service get it on their own phones with a position they can navigate to. If
-- they want to speak to the caller they ring the number back - which is why the number
-- travels with the alert unless the caller asked to stay anonymous.
--
-- Another script can raise one too: a shop till under robbery, a fire, a downed player.
-- `exports['v-phone']:CreateAlert{ ... }` - see API.md.
Config.Emergency = {
    enabled = true,

    -- ── Who may send one ───────────────────────────────────────
    -- A phone is needed. Signal and battery are NOT, by default, and that is deliberate: the
    -- one call that has to work is the one made from a tunnel by somebody whose phone is
    -- nearly dead. A server that wants dead zones to bite sets these to true.
    requireItem = true,
    requireSignal = false,
    requireBattery = false,

    -- Seconds between two alerts from the same character. The queue belongs to people who
    -- are working; a button that can be held down is a queue nobody can read.
    cooldown = 90,
    -- How many of your OWN alerts may be open at once, whatever the cooldown allows. The
    -- cooldown paces somebody in a panic; this stops one character filling a service's screen.
    -- 0 removes the limit.
    maxOpenPerPlayer = 3,

    -- Let the caller hide their name and number. The service still gets the position and the
    -- reason - an anonymous tip is a real thing, and a service that can always identify the
    -- caller is one nobody uses to report their own employer.
    anonymous = true,
    -- Whether a responder may ring an anonymous caller back. Off, and it must stay off unless
    -- you mean it: a number that can be called is a number, and the promise made on the button
    -- was that they would not get one.
    anonymousCallback = false,

    -- ── The queue ──────────────────────────────────────────────
    -- An alert nobody accepted drops out of the live list after this. It is not deleted: it
    -- moves to the history below, so a service can see what they missed.
    expireMinutes = 20,
    -- How many closed and expired alerts stay in memory, per service. This is the store; the
    -- two numbers below are how much of it each side is SHOWN.
    history = 30,
    -- What a caller sees of their own past alerts, and what a responder sees under the live
    -- queue. A caller wants to know their last shout was picked up, not to scroll a diary; a
    -- service wants a short tail of what was just dealt with, not the whole shift.
    callerHistory = 3,
    dispatchHistory = 10,
    -- Close a taken alert by itself after this many minutes, for a service that forgets. 0 is
    -- never, which is the honest default: an alert closing itself while somebody is driving to
    -- it is worse than a queue with an old row in it.
    autoCloseMinutes = 0,

    -- Alerts live in memory, like outages and paid charging stops. An alert is about right
    -- now; a server that restarts has no shift to hand over.

    -- Who may do what to an alert, once it is on the board.
    dispatch = {
        -- Anybody in the service may close one, not only whoever took it. On, because a
        -- responder who logs off mid-shift would otherwise leave a row nobody can clear.
        closeAnyone = true,
        -- Let a second responder take an alert that somebody already took. Off: "taken" means
        -- somebody is on their way, and two units on one call is a dispatch decision.
        takeOver = false,
        -- Tell the rest of the service when one of them takes or closes an alert.
        notifyService = true,
        -- Show the history section under the live queue at all.
        showPast = true,
    },

    -- ── What a responder gets ──────────────────────────────────
    -- The sound is generated by tools/make-sounds.py - a two-tone dispatch signal, chosen to
    -- be bearable on the fiftieth call of an evening rather than alarming on the first.
    sound = true,
    -- Which one, and how loud. Any name in `sounds/ui_*.wav`; `alertVolume` is 0 to 1 and
    -- deliberately ignores the player's ring volume - being on duty is a promise to be
    -- reachable. Set `sound = false` if you disagree with that.
    alertSound = 'alert911',
    alertVolume = 0.85,
    -- Vibrate as well, ignoring Do Not Disturb. Somebody on duty asked to be reachable.
    vibrate = true,
    -- Raise the handset out of a pocket for an incoming alert, the way a message does.
    peek = true,

    -- ── The blip on the map ────────────────────────────────────
    -- `auto` is the one that matters: the alert appears on the map of EVERY responder in that
    -- service the moment it is raised, with no button pressed. That is the difference between
    -- a dispatch board and a service that has to be reading their phone to notice.
    --
    -- Off, the coordinates stay on the server until a responder asks for them with "Take me
    -- there" - which is stricter, and slower, and some servers want it.
    blip = {
        enabled = true,
        auto = true,
        sprite = 280,
        colour = 1,
        scale = 0.9,
        alpha = 255,
        -- A flashing blip is how a responder finds it on a busy map. It stops flashing once
        -- somebody takes the alert, so what is flashing is what nobody has answered.
        flash = true,
        -- How long an automatic blip lives if nothing happens to it. It expires because a
        -- blip is the thing that accumulates: an evening of alerts is an unreadable map.
        seconds = 300,
        -- What happens to it when the alert moves on.
        clearOnTaken = false,   -- keep it: whoever took it is still driving there
        clearOnClosed = true,
        -- Once an alert is taken, keep its blip only on the map of the responder who took it.
        -- The rest of the service is no longer going, so their map is no longer about it.
        onlyTaker = true,
        -- Set a GPS route to it as well. Off by default: a route the player did not ask for
        -- overwrites the one they were following.
        route = false,
        -- Draw the alert as a circle of this radius (metres) instead of a point. Use it for a
        -- service that should search rather than be given the doorstep. 0 is a point.
        radius = 0,
        -- And the waypoint set by the "Take me there" button, which is separate: that one is
        -- always the exact spot, because a responder pressed a button asking to go there.
        waypointOnLocate = true,
    },

    -- ── What the CALLER is told ────────────────────────────────
    -- The other half of an alert. Somebody who shouted for help and heard nothing back has no
    -- way to tell "on their way" from "nobody is coming", and will shout again - which is how
    -- a queue fills with the same emergency four times.
    notifyCaller = {
        taken = true,
        closed = true,
        -- Name the responder who took it. Off gives "somebody is on their way" instead, for a
        -- server where knowing which officer is coming is itself information.
        name = true,
        sound = true,
        vibrate = true,
    },

    -- ── The services ───────────────────────────────────────────
    -- One entry per service the phone offers. `jobs` is what the framework calls the job;
    -- everything else is what the player sees.
    --
    --   onDutyOnly   only people currently on duty are alerted and see the queue
    --   minGrade     and only at this grade or above. 0 is everybody in the job.
    --   reasons      the buttons a caller picks from. Locale keys or plain text - a key that
    --                exists is translated, anything else is shown as written, so a server can
    --                put its own wording here without touching the locale files.
    --
    -- **Anything above can be overridden per service by naming it in the entry**, and the
    -- entry wins. A fire brigade that should be reachable every ninety seconds while the
    -- police line is paced at five minutes is two numbers, not two configs:
    --
    --     cooldown, maxOpenPerPlayer, anonymous, anonymousCallback, allowOther, maxText,
    --     expireMinutes, autoCloseMinutes, sound, alertSound, alertVolume, vibrate, peek,
    --     blip (merged key by key over the one above), notifyCaller (likewise), dispatch
    --
    -- So a service that must never be anonymous, whose blip is a searchable area rather than
    -- a doorstep, and which nobody may take over, is:
    --
    --     anonymous = false,
    --     blip = { radius = 60.0, colour = 5 },
    --     dispatch = { takeOver = false },
    services = {
        {
            id = 'police',
            label = 'ph.911_s_police',
            icon = 'shield',
            tint = '#0A84FF',
            jobs = { 'police', 'bcso', 'sheriff', 'sast' },
            onDutyOnly = true,
            minGrade = 0,
            blip = { sprite = 60, colour = 38 },
            reasons = {
                'ph.911_r_violence', 'ph.911_r_theft', 'ph.911_r_shots',
                'ph.911_r_vehicle', 'ph.911_r_suspicious', 'ph.911_r_traffic',
            },
        },
        {
            id = 'ems',
            label = 'ph.911_s_ems',
            icon = 'heart',
            tint = '#FF453A',
            jobs = { 'ambulance', 'ems', 'doctor' },
            onDutyOnly = true,
            minGrade = 0,
            blip = { sprite = 61, colour = 1 },
            reasons = {
                'ph.911_r_injured', 'ph.911_r_unconscious', 'ph.911_r_crash',
                'ph.911_r_overdose', 'ph.911_r_birth',
            },
        },
        {
            id = 'fire',
            label = 'ph.911_s_fire',
            icon = 'warning',
            tint = '#FF9F0A',
            -- Most servers run the fire brigade out of the ambulance job. Two entries can
            -- name the same job: the alert goes to whoever holds it either way.
            jobs = { 'fire', 'ambulance' },
            onDutyOnly = true,
            minGrade = 0,
            blip = { sprite = 436, colour = 47 },
            reasons = { 'ph.911_r_fire', 'ph.911_r_smoke', 'ph.911_r_trapped', 'ph.911_r_leak' },
        },
        -- Emergency services only, on purpose. A breakdown is not a 911 call, and a queue that
        -- mixes a tow with a shooting is a queue nobody reads at the top. A server that wants
        -- roadside assistance here anyway only has to uncomment this - the locale keys it needs
        -- already ship:
        --
        --     {
        --         id = 'mechanic',
        --         label = 'ph.911_s_mechanic',
        --         icon = 'wrench',
        --         tint = '#5E5CE6',
        --         jobs = { 'mechanic', 'tow' },
        --         onDutyOnly = true,
        --         minGrade = 0,
        --         blip = { sprite = 446, colour = 5 },
        --         reasons = { 'ph.911_r_breakdown', 'ph.911_r_tow', 'ph.911_r_stuck' },
        --     },
    },

    -- A reason of the caller's own, written on the spot. Off leaves only the buttons above,
    -- which is the setting for a server tired of reading essays.
    allowOther = true,
    maxText = 200,
}

-- The 911 app cannot be removed by a player, so switching the module off is what has to take
-- it off the phone. Done here rather than in the layout loop above, which runs before this
-- table exists: an operator who set `enabled = false` would otherwise be left with an app that
-- opens onto a refusal and that nobody is allowed to delete.
if Config.Emergency.enabled == false then
    for i = #Config.Apps, 1, -1 do
        if Config.Apps[i].id == 'emergency' then table.remove(Config.Apps, i) end
    end
end

-- ══════════════════════════════════════════════════════════════
--  BANK PRO
-- ══════════════════════════════════════════════════════════════
-- The company account, on the phone, for the character who runs the business.
--
-- The Bank app is a person's money; this is a business's. **There are no phone numbers in it**
-- - a company is paid by ACCOUNT and an employee by who they are, never by whichever number
-- somebody happens to be carrying.
--
-- Not installed by default: it is in the store, and a business owner installs it. Nothing here
-- decides who may open it beyond what is set below, and the account is always derived from the
-- job the framework says the character holds - the page never names one.
Config.BankPro = {
    enabled = true,

    -- **No cash, ever.** Bank Pro moves money between BANK accounts only - the company's, an
    -- employee's, another person's, another company's. Nothing here puts a note in or takes one
    -- out of a pocket: cash is handled in person, not through an app, and that is deliberate.

    -- Which jobs get a company account. Empty means every job does, which is the only sane
    -- default for a resource that cannot know what jobs a server has.
    --
    --     jobs = { 'mechanic', 'realestate', 'taxi' },
    jobs = {},

    -- Only the boss. `isboss` is what qb marks a boss grade with, and it is the right test:
    -- an employee should not be able to empty the till from their phone.
    --
    -- A server that does not use the flag sets `requireBoss = false` and a `minGrade` instead.
    requireBoss = true,
    minGrade = -1,          -- -1 disables the grade route entirely

    -- The society account name is this plus the job name: `mechanic` by default, or
    -- `society_mechanic` on a server whose banking script prefixes them.
    accountPrefix = '',

    -- The boss moving company money into their OWN bank account (never cash). Off leaves
    -- payments and transfers only, which is what some servers want: money leaves a business by
    -- paying somebody, not by the boss helping themselves.
    allowWithdraw = true,

    -- The boss moving money from their OWN bank account INTO the company (never cash). Off
    -- removes the deposit button entirely.
    allowDeposit = true,

    -- Paying an employee from the company account, into their bank. They must actually hold
    -- the job, and be online - paying somebody who is not connected means writing behind their
    -- back, and every framework does that differently.
    employees = true,

    -- Paying ANYONE who does not work here: a contractor, a supplier, a private individual -
    -- a "joueur lambda". Straight into their bank account. A business pays people who are not
    -- on its payroll, and restricting payment to employees was the app deciding how a business
    -- is run.
    --
    -- Still a list of characters, never a typed citizen id: an app that accepts one is an app
    -- that pays whoever you can guess.
    payAnyone = true,

    -- How close a non-employee has to be standing, in metres, to be offered.
    --
    -- This is what keeps the list short and honest. Without it the app showed EVERY connected
    -- character - a server-wide roster of people the boss has never met, with the one they
    -- actually wanted buried in it - and paying somebody is a thing you do while looking at
    -- them. Employees are never distance-filtered: payday should not be a walk round the map.
    payRadius = 15.0,

    -- ── Which companies appear, and what they are called ───────
    -- **This list IS the whitelist.** Only what is written here can be reached by a transfer,
    -- and only what is written here is shown - so a server with forty jobs does not put forty
    -- rows of `mechanic2`, `bobcat`, `farming` in front of a business owner. Empty means no
    -- company-to-company transfers at all, which is a valid way to run it.
    --
    -- A free-text destination is deliberately impossible: it would be a way to move a
    -- business's money into a name nobody has ever heard of.
    --
    -- Two ways to write an entry, and they can be mixed:
    --
    --     payees = {
    --         -- just the account, named from your framework's job label
    --         'ambulance',
    --         -- or the account AND the name to show, which is the one that always wins
    --         { account = 'mechanic',   label = 'Los Santos Customs' },
    --         { account = 'mechanic2',  label = "Benny's Original Motorworks" },
    --         { account = 'realestate', label = 'Dynasty 8' },
    --     }
    --
    -- The order you write them in is the order they appear.
    payees = {},

    -- The same names, written apart from the list, for a server that would rather keep the two
    -- separate. `payees` entries that carry their own `label` win over this.
    --
    --     payeeLabels = { mechanic = 'Los Santos Customs', realestate = 'Dynasty 8' },
    payeeLabels = {},

    -- How many movements the history shows. Capped at 50, because that is what fits and what a
    -- boss actually reads - the bank's own statement is the place for a full audit.
    historyLimit = 50,

    minAmount = 1,
    maxAmount = 0,          -- 0 for no ceiling
}

-- ══════════════════════════════════════════════════════════════
--  ALERTS  (what the government broadcasts, and everybody receives)
-- ══════════════════════════════════════════════════════════════
-- Installed by default, on every phone, and it cannot be bought or sold: an alert system is
-- only worth having if it is already there when the alert goes out.
--
-- Two providers, one app, and a player never learns which one answered:
--
--   * **doc-civilalerte**, when that resource is started. Its alerts, its table, its history,
--     its permissions and its Discord relay - reached through the same server callback and the
--     same two net events its own iframe used. **Nothing in doc-civilalerte is edited, wrapped
--     or replaced.** Update it, and this keeps working.
--   * **`categories` and `emitters` below** otherwise. That is what makes the app worth having
--     on an ESX, ox or standalone server, where doc-civilalerte does not exist: the phone's own
--     table, its own permission check, its own broadcast.
--
-- **Nobody chooses to receive these.** A public alert is not a subscription - the point of the
-- word is that it reaches people who were not looking - so there is no opt-out beyond muting
-- the app's notifications the way any app can be muted from Settings.
Config.Alerts = {
    enabled = true,

    -- 'auto' uses doc-civilalerte when it is started and the settings below when it is not.
    -- 'doc-civilalerte' or 'config' pin it, for a server that wants to be certain which is
    -- live rather than depending on a resource's start order.
    provider = 'auto',

    -- ── Who may broadcast ──────────────────────────────────────
    -- **The server decides this, every time, from this list.** The composer is only shown to
    -- somebody who passes it, but that is courtesy: the check runs again when the alert is
    -- sent, so a player who reaches the event another way is refused there.
    --
    --   job      the job name your framework uses
    --   grade    the minimum grade level
    --   onDuty   true means they must be clocked on to broadcast
    --
    -- **Under doc-civilalerte this list must MIRROR its `Config.Emitters`.** doc-civilalerte
    -- decides for itself who may send - which is right, it owns the alerts - but it does not
    -- publish that decision, so the phone cannot ask "may I?" and has to work it out from
    -- here. Get it wrong and the only symptom is a composer offered to somebody whose alert
    -- is then refused: annoying, never dangerous.
    emitters = {
        { job = 'police',       grade = 11, onDuty = true },
        { job = 'sheriff',      grade = 11, onDuty = true },
        { job = 'gouvernement', grade = 5,  onDuty = true },
        { job = 'incendie',     grade = 8,  onDuty = true },
        { job = 'ambulance',    grade = 9,  onDuty = true },
    },

    -- ── The kinds of alert ─────────────────────────────────────
    -- `key` is what is stored and what the server checks against; everything else is how the
    -- card looks. **The keys below are doc-civilalerte's own**, so an alert broadcast by it
    -- arrives already knowing which colour and which name it wears. An unknown key still
    -- shows - a category nobody configured is not a reason to hide a public warning - it just
    -- arrives grey, wearing its key.
    --
    -- The order written here is the order the composer offers them.
    -- `loud` overrides `ring` for one category. Left out means "whatever `ring` says", which is
    -- how a server that wants everything to klaxon writes nothing extra at all.
    categories = {
        { key = 'population',  label = 'ph.alert_c_population',  color = '#EF4444', icon = 'warning' },
        { key = 'incendie',    label = 'ph.alert_c_fire',        color = '#F97316', icon = 'fire' },
        { key = 'catastrophe', label = 'ph.alert_c_disaster',    color = '#DC2626', icon = 'house' },
        { key = 'recherche',   label = 'ph.alert_c_wanted',      color = '#F59E0B', icon = 'search' },
        -- Roadworks and the weather are information, not evacuation orders. They arrive as an
        -- ordinary notification with the phone's own text tone.
        { key = 'route',       label = 'ph.alert_c_road',        color = '#EAB308', icon = 'car',
          loud = false },
        { key = 'meteo',       label = 'ph.alert_c_weather',     color = '#3B82F6', icon = 'weather',
          loud = false },
        { key = 'officiel',    label = 'ph.alert_c_official',    color = '#94A3B8', icon = 'shield',
          loud = false },
    },

    -- ── How long an alert stands ───────────────────────────────
    -- An expired alert is not deleted: it drops out of the active list into the archive, which
    -- is where "what did they say last week" is answered. Only these durations are accepted -
    -- a value that is not on the list falls back to the default rather than being refused,
    -- because losing a written alert to a rejected dropdown is the worse failure.
    durations = {
        { minutes = 30,   label = 'ph.alert_d_30m' },
        { minutes = 60,   label = 'ph.alert_d_1h' },
        { minutes = 180,  label = 'ph.alert_d_3h' },
        { minutes = 720,  label = 'ph.alert_d_12h' },
        { minutes = 1440, label = 'ph.alert_d_24h' },
    },
    defaultDuration = 60,

    -- ── Limits, enforced on the server ─────────────────────────
    maxTitle = 60,
    maxMessage = 2000,

    -- Seconds one person must wait between two broadcasts. This is the only thing standing
    -- between a compromised account and every phone in the city buzzing on a loop.
    cooldown = 30,

    -- How many alerts the archive holds, and how long the table keeps them. 0 days never
    -- purges, which is a choice a server can make - it just means the table grows forever.
    history = 50,
    purgeAfterDays = 7,

    -- ── The notification ───────────────────────────────────────
    -- A public alert raises a banner on every phone in the city, whether the app is open or
    -- not. Muteable per app from Settings like any other, because a player who cannot silence
    -- a broadcast has no phone, they have an alarm clock.
    notify = true,
    -- Buzz as well as show. Off leaves the banner silent.
    vibrate = true,

    -- **Does it RING?**
    --
    -- On, a public alert gets the same treatment `/phoneadmin alert` gets: the klaxon at full
    -- volume whatever the player's ring setting says, the pad shaking, and the handset coming
    -- out of a pocket. That is the whole point of a civil warning - it has to reach somebody who
    -- is not looking at their phone - and it is deliberately the one thing in this app that
    -- steps past a player's own volume, which is why it is a switch rather than simply always on.
    --
    -- A category may override it below with `loud = false`. A flood and a roadworks notice are
    -- not the same event, and a phone that klaxons for both is one people mute before the flood.
    ring = true,

    -- **The strongest form: a card that takes the whole screen** and has to be acknowledged -
    -- the same one `/phoneadmin alert` can draw, wearing the alert's own category name and
    -- icon. Only ever shown for an alert that is already loud, so a category marked
    -- `loud = false` never takes anybody's screen.
    --
    -- Off by default, and deliberately: a card that must be dismissed is right for an
    -- evacuation and wrong for the fourth wanted notice of the evening. A screen people have to
    -- clear is a screen they learn to clear without reading, which costs you the one that
    -- mattered.
    fullScreen = false,

    -- ── Deleting ───────────────────────────────────────────────
    -- Who may take an alert down: whoever wrote it, always, and staff. `staffAce` is the
    -- permission that counts as staff - the phone's own admin ace by default, so nothing new
    -- has to be granted.
    --
    -- Under doc-civilalerte this is ITS rule, not this one: it checks the citizen id against
    -- the row and its own admin permission, and it is right to.
    allowAuthorDelete = true,
    staffAce = 'vphone.admin',
}

-- ══════════════════════════════════════════════════════════════
--  ZUBER  (food, ordered from the phone)
-- ══════════════════════════════════════════════════════════════
-- A download, free, and it works two ways without the player ever being told which:
--
--   * **doc-restaurant**, when that resource is running. Its restaurants, its menus, its
--     prices, its promotions, its loyalty scheme, its reviews and its orders - reached through
--     the same server callbacks its own phone app used, from client/zuber.lua. **Nothing in
--     doc-restaurant is edited, wrapped or replaced.** Update it, and this keeps working.
--   * **`restaurants` below** otherwise. That is what makes the app worth having on an ESX, ox
--     or standalone server, where doc-restaurant does not exist: its own menu, its own orders
--     table, its own money path.
--
-- There is no courier side, on purpose. doc-restaurant already delivers with its own staff,
-- statuses and commission, and a second thing moving those statuses is how two systems start
-- disagreeing about who is bringing the food.
Config.Zuber = {
    enabled = true,

    -- Show menu lines the restaurant has switched off, greyed and unbuyable.
    --
    -- Off: they are not sent to the phone at all. A row nobody can order is a row you scroll
    -- past, and three of them reading "Indisponible" looks like a broken app rather than like a
    -- kitchen that ran out. Turn it on for a menu that keeps its shape whatever is in stock.
    showSoldOut = false,

    -- 'auto' uses doc-restaurant when it is started and the list below when it is not.
    -- 'doc-restaurant' or 'config' pin it, for a server that wants to be sure which is live.
    provider = 'auto',

    -- ── Config-provider settings ───────────────────────────────
    -- **Ignored entirely in doc-restaurant mode, and that is load-bearing.** doc-restaurant's
    -- total IS the sum of its item prices: the government tax is taken OUT of that - it splits
    -- TTC into HT plus tax and pays each side - and it charges no delivery fee of any kind. So
    -- neither of these is added there, and the app shows its sum unaltered.
    --
    -- Which purse pays: 'bank' or 'cash'. A delivery app is a card, so 'bank'.
    account = 'bank',
    -- Added to a DELIVERY order, never to a collection. 0 for none.
    deliveryFee = 25,

    -- **doc-restaurant mode only.** Its government tax is INSIDE the price it charges: it splits
    -- the total into HT plus tax and pays the restaurant and the government separately. The app
    -- shows that split as a breakdown line - "of which tax" - and never adds it to the total,
    -- because the customer has already paid it.
    --
    -- Set this to the same number as doc-restaurant's own `Config.TaxRate`, which lives in its
    -- resource and cannot be read from here. 0 hides the line.
    docTaxRate = 5,
    -- On the food, as a percentage. Your government tax, if you run one.
    taxPercent = 0,
    minOrder = 1,
    maxOrder = 5000,          -- 0 for no ceiling
    maxPerLine = 20,          -- the most of one dish in a single order

    -- Pay the restaurant's society account for the food. The `account` on a restaurant below
    -- wins, then its `job`. Off means the money leaves the customer and nobody is credited.
    paySociety = true,

    -- Tell the restaurant's on-duty staff that an order came in. A notification, not a queue:
    -- this app has no kitchen screen, and half-building one next to whatever the server already
    -- runs is worse than a notification that says "two items, go and look".
    notifyStaff = true,

    -- How long an order takes, in minutes, when a restaurant does not say. Also the span the
    -- automatic status steps are spread across.
    etaMinutes = 12,

    -- Walk an order through accepted -> preparing -> delivering -> completed on a timer.
    --
    -- On by default because a server with no restaurant script has no kitchen staff, and an
    -- order that stays "pending" for ever is worse than one that cooks itself. A server that
    -- DOES have staff drives it with `exports['v-phone']:SetZuberStatus(id, status)` instead,
    -- and taking over cancels the timer - so an order is never moved twice.
    autoStatus = true,

    -- A sound and a notification on the customer's phone at each step.
    sound = true,

    -- ── Dish pictures ──────────────────────────────────────────
    -- doc-restaurant hands back a FILE NAME for each dish - `burger.png`, or whatever the item's
    -- own `image` field says - because its own page knew which inventory the server runs. This
    -- phone does not, so the folder is named here and the file name is appended.
    --
    -- Point it at your inventory's image folder. The usual ones:
    --
    --     'nui://qb-inventory/html/images'      qb-inventory
    --     'nui://ox_inventory/web/images'       ox_inventory
    --     'nui://qs-inventory/html/images'      Quasar
    --     'nui://lj-inventory/html/images'      lj-inventory
    --
    -- Empty means no pictures at all, and the app falls back to its own glyph - which is what it
    -- did before, and is better than a grid of broken images.
    imageBase = 'nui://qb-inventory/html/images',

    -- ── The customer's side ────────────────────────────────────
    -- **There is no tip.** It could not be honest on both providers: doc-restaurant's own order
    -- callback does not read one, so a tip offered there was shown, added to the total on screen,
    -- and charged to nobody. A tip that works on one provider and lies on the other is worse than
    -- no tip, so it was removed rather than hidden behind a switch.

    -- How many past orders the history shows, and how many favourites are kept.
    history = 20,
    favourites = 20,

    -- ── What the app offers ────────────────────────────────────
    -- Each of these removes a piece of the app rather than hiding a button that still works.
    -- All on by default; a server that wants a plain menu-and-basket turns the rest off.
    features = {
        search = true,        -- the search across every restaurant's menu
        favourites = true,    -- the star on a restaurant
        history = true,       -- the Orders tab
        reorder = true,       -- and the one tap that repeats a past order
        tracker = true,       -- the live status bar at the top
        loyalty = true,       -- the loyalty card and its redeemable tiers (doc-restaurant)
        reviews = true,       -- reading reviews (doc-restaurant only)
        ratings = true,       -- and leaving one (doc-restaurant only)
        route = true,         -- "take me there"
        note = true,          -- the free-text instructions on an order
    },

    -- Only these restaurants may be ordered from, by id. Empty means all of them. Use it to run
    -- a soft launch, or to keep a place on the map that is not open for delivery yet.
    only = {},

    -- Sort the list by distance from the player instead of open-then-name. Off by default: the
    -- nearest restaurant is rarely the one somebody wants, and a list that reorders itself as
    -- you walk is a list you cannot learn.
    sortByDistance = false,

    -- Show a restaurant that is closed, greyed out and unbuyable. Off hides it entirely -
    -- shorter, but somebody looking for a place that opens at six is told it does not exist.
    showClosed = true,

    -- Keep the basket when the app is closed and reopened. Off empties it, which is what a
    -- server that treats a basket as a session wants.
    keepBasket = false,

    -- ── The restaurants (config provider only) ─────────────────
    -- Two examples, both real GTA places. Delete them and write your own; leave the list empty
    -- and the app says there is nowhere to order from, which is honest.
    --
    -- Per restaurant:
    --   id         your own key, used in the order and never shown
    --   label      what the customer reads
    --   job        the job whose staff are notified, and whose society account is paid
    --   account    a society account name, when it is not the job name
    --   coords     for the "take me there" button. `vector3(...)` or `{ x =, y = }`
    --   tint       the colour of its card
    --   tags       short words under the name: cuisine, price, whatever you like
    --   open       true, false, or `{ from = 11, to = 2 }` in server hours (crossing midnight
    --              is fine, which is the normal case for a late-night place)
    --   eta        minutes, when this place is faster or slower than the default
    --   delivery / takeaway   which it offers
    --   menu       every line: item, label, price, category, and `enabled = false` to show a
    --              dish as unavailable rather than removing it
    restaurants = {
        {
            id = 'burgershot',
            label = 'Burger Shot',
            job = 'burgershot',
            coords = vector3(-1183.9, -890.6, 13.9),
            tint = '#E4572E',
            tags = { 'Burgers', 'Fast food' },
            open = { from = 10, to = 4 },
            eta = 10,
            delivery = true,
            takeaway = true,
            menu = {
                { item = 'burger_bleeder',  label = 'Bleeder',            price = 14, category = 'mains' },
                { item = 'burger_torpedo',  label = 'Torpedo',            price = 16, category = 'mains' },
                { item = 'burger_moneyshot',label = 'Money Shot',         price = 19, category = 'mains' },
                { item = 'fries',           label = 'Fries',              price = 6,  category = 'starters' },
                { item = 'onion_rings',     label = 'Onion rings',        price = 7,  category = 'starters' },
                { item = 'milkshake',       label = 'Milkshake',          price = 8,  category = 'desserts' },
                { item = 'ecola',           label = 'eCola',              price = 4,  category = 'drinks' },
            },
        },
        {
            id = 'uwu',
            label = 'UwU Cafe',
            job = 'uwu',
            coords = vector3(-583.5, -1062.4, 22.3),
            tint = '#D46BAE',
            tags = { 'Coffee', 'Pastries' },
            open = { from = 7, to = 20 },
            eta = 8,
            delivery = true,
            takeaway = true,
            menu = {
                { item = 'coffee',          label = 'Filter coffee',      price = 5,  category = 'drinks' },
                { item = 'latte',           label = 'Latte',              price = 7,  category = 'drinks' },
                { item = 'matcha',          label = 'Matcha',             price = 8,  category = 'drinks' },
                { item = 'croissant',       label = 'Croissant',          price = 5,  category = 'starters' },
                { item = 'pancakes',        label = 'Pancakes',           price = 12, category = 'mains' },
                { item = 'cheesecake',      label = 'Cheesecake',         price = 9,  category = 'desserts' },
            },
        },
    },
}

-- ══════════════════════════════════════════════════════════════
--  TAXI  (hail a ride, or drive one)
-- ══════════════════════════════════════════════════════════════
-- A free download that works two ways, and the player is never told which:
--
--   * **doc-taxijob**, when it is running. Its drivers, its calls, its fares, its ratings and
--     its tips, reached through the same server callbacks its own phone app used. **Nothing in
--     doc-taxijob is edited, wrapped or replaced.** Update it and this keeps working.
--   * **the settings below** otherwise - so the app is worth having on an ESX, ox or standalone
--     server, with its own ride queue, its own fare arithmetic and its own money.
Config.Taxi = {
    enabled = true,

    -- 'auto' uses doc-taxijob when it is started and the settings below when it is not.
    -- 'doc-taxijob' or 'config' pin it.
    provider = 'auto',

    -- **The driver job.** In doc-taxijob mode this must MATCH its own `Config.JobName`: its
    -- config lives in its own client and cannot be read from here, so this is how the phone
    -- knows whether the person holding it is a driver. Get it wrong and a driver simply never
    -- sees the queue, which reads as a broken app rather than as a wrong job name.
    job = 'taxi',

    -- **May a driver ring the passenger they accepted?** doc-taxijob mode only.
    --
    -- It hands the driver the passenger's name and player id when a fare is accepted, and no
    -- number, so there was no way to say "I am outside" without leaving the game. With this on,
    -- the phone resolves that player id to their number - our own data, not doc-taxijob's - and
    -- offers a Call button on the accepted fare.
    --
    -- The honest limit, since it is worth knowing before switching it on: the pairing between a
    -- driver and a passenger lives in doc-taxijob's memory, and reading it would mean modifying
    -- doc-taxijob. So the server can only check that the ASKER is an on-duty driver of this job -
    -- it cannot prove they were really assigned that passenger. Every lookup is logged with both
    -- citizen ids. Set false on a server where that trade is not worth making.
    docCallClient = true,

    -- **May a passenger settle a doc-taxijob fare from the phone?** doc-taxijob mode only.
    --
    -- It used to raise an invoice for the fare through doc-billing. With that gone nothing charges
    -- the passenger, and its only passenger-to-driver money path is its TIP callback - capped at
    -- its own `Config.MaxTip`, 500 by default, which would take half a long fare in silence and
    -- then refuse the real tip. So the fare is taken here instead, through this resource's own
    -- money path, which is also what makes it work on ESX and ox rather than qb-core alone.
    --
    -- The honest limit, worth knowing before switching it on: the AMOUNT comes from the passenger's
    -- own client, because doc-taxijob tells the passenger what the ride cost and tells this server
    -- nothing. A passenger inflating it only overcharges themselves; one deflating it underpays
    -- their driver, which is what walking away already does. The pairing, the single settlement and
    -- the `maxFare` ceiling are all enforced on the server, and every payment is logged.
    docSettle = true,

    -- ── Config-provider settings ───────────────────────────────
    -- Ignored in doc-taxijob mode: fares, ratings and tips are its own there.
    --
    -- Only drivers who are clocked on are called out, and only from this grade up.
    onDutyOnly = true,
    minGrade = 0,

    -- Which purse pays: 'cash' or 'bank'. A taxi is cash on most servers, which is why it is
    -- the default here and not in the apps that move real money.
    account = 'cash',

    -- The fare: a flat charge plus a rate per kilometre ACTUALLY covered - the distance is
    -- measured between where the ride started and where the driver ended it, not estimated.
    basePrice = 50,
    pricePerKm = 15,
    maxFare = 0,              -- 0 for no ceiling

    -- Where the money goes when the driver logged off mid-fare. Better the company than nobody.
    paySociety = true,
    society = nil,            -- defaults to the job name above

    -- How many people one booking may be for, and how long a booking waits for a driver before
    -- it gives up. Seconds.
    maxPassengers = 4,
    expireSeconds = 300,

    -- Seconds between two bookings from the same character, so a button cannot be held down.
    cooldown = 60,

    -- May somebody on the taxi job book a taxi? Off stops a driver appearing in their own queue.
    driversMayCall = false,

    -- Rating a finished ride, once, by the passenger who took it. The driver is told.
    rating = true,

    -- The tip, added when the passenger settles up. Bounded here as well as in the app.
    tip = {
        enabled = true,
        presets = { 0, 10, 20 },   -- as a percentage of the fare
        max = 500,
    },

    -- How many finished rides stay in memory before the oldest are dropped.
    history = 40,

    -- ── What the app offers ────────────────────────────────────
    -- Each of these removes a piece of the app rather than leaving a button that apologises.
    features = {
        driver = true,        -- the Driver tab, for somebody holding the job
        rating = true,        -- rating a finished ride
        tip = true,           -- the tip when settling up
        estimate = true,      -- the fare estimate before booking
        destination = true,   -- the "where to" field on a booking
        note = true,          -- the free-text note for the driver
        route = true,         -- "take me there", for a driver picking a fare
    },
}

-- ══════════════════════════════════════════════════════════════
--  LOTTERY  (the weekly draw)
-- ══════════════════════════════════════════════════════════════
-- Two providers, one app, and the page cannot tell which answered.
--
--   * **doc-lottery**, when it is running. Its sessions, its jackpot, its tickets, its draw and
--     its prize tiers. It publishes exactly what its own phone app used - two QB *server
--     callbacks* - and a server callback is registered on the framework rather than on the
--     resource, so any client may call one. That is the whole integration: doc-lottery is not
--     edited, wrapped or replaced, and nothing here writes to one of its tables.
--   * **this config** otherwise, with its own sessions, tickets, draw and money path - which is
--     what makes the app worth installing on an ESX, ox or standalone server.
--
-- The numbers below MIRROR doc-lottery's defaults on purpose. A player who moves between two
-- servers should not have to relearn the game, and an operator comparing the two files should
-- find the same values in the same shape.
Config.Lottery = {
    enabled = true,

    -- 'auto' uses doc-lottery when it is started and the settings below when it is not.
    -- 'doc-lottery' or 'config' pin it.
    provider = 'auto',

    -- ── The ticket ──────────────────────────────────────────────
    -- Config-provider settings. In doc-lottery mode every one of these comes from ITS config
    -- instead, sent with its own answer - so changing them here would only make this app lie
    -- about a price somebody else is charging.
    ticketPrice = 250,
    numberCount = 5,        -- how many numbers on a line
    numberMin = 1,
    numberMax = 35,
    maxCombinations = 7,    -- lines per player per draw

    -- Which purse pays. Bank only, and deliberately: a ticket is a traceable purchase and the
    -- prize is paid back into an account, so taking cash for one would be the only step in the
    -- chain with no record of it. Change it to 'cash' if your server wants the opposite.
    account = 'bank',

    -- ── The prizes ──────────────────────────────────────────────
    -- The prize depends on HOW MANY numbers matched, not on an exact line. Real odds for 5
    -- numbers out of 35, which is why the tiers are shaped like this:
    --   2/5 -> 1 in 6.9        3/5 -> 1 in 63
    --   4/5 -> 1 in 1,574      5/5 -> 1 in 324,632   (the jackpot grows until it falls)
    -- One correct number pays nothing: at 1 ticket in 2.7 it is not a prize, it is a rebate.
    --
    --   payer = 'gov'     -> a fixed amount, paid by the society account below
    --   payer = 'jackpot' -> a percentage of the pot
    rewards = {
        [2] = { payer = 'gov',     amount  = 500 },
        [3] = { payer = 'gov',     amount  = 750 },
        [4] = { payer = 'jackpot', percent = 10 },
        [5] = { payer = 'jackpot', percent = 100 },
    },

    -- The society account that funds the fixed tiers, and takes the state's half of each
    -- ticket. Nil pays the small tiers out of thin air, which is fine on a server with no
    -- government account and dishonest on one that has.
    govAccount = 'gouvernement',

    -- How each ticket is split. The rest goes to the government account.
    jackpotShare = 50,      -- percent of the ticket price added to the pot

    -- ── The jackpot ─────────────────────────────────────────────
    jackpotStart = 10000,   -- a fresh session starts here
    jackpotNoWinner = 1000, -- added when nobody wins, so the pot visibly grows

    -- ── The draw ────────────────────────────────────────────────
    -- Drawn automatically on these days at this time. Staff can always draw by hand.
    autoDraw = {
        enabled = true,
        days = { 3, 6 },    -- 1 = Sunday ... 3 = Tuesday, 6 = Friday
        hour = 21,
        minute = 30,
    },

    -- The server clock is usually UTC while the time announced to players is local. 2 in
    -- summer (CEST), 1 in winter (CET), 0 for a server already on the players' time.
    timezoneOffset = 2,

    -- No catch-up: a draw whose slot passed while the server was down is MISSED and has to be
    -- run by hand. Minutes after the scheduled time in which the automatic draw may still fire.
    -- Silently drawing four hours late is worse than not drawing: players stop trusting a time.
    autoDrawWindow = 5,

    -- ── The show ────────────────────────────────────────────────
    -- The draw, on the phone, as it happens. doc-lottery already draws its own panel in the
    -- corner of the screen; this is the SECOND screen - the app follows the balls live if it
    -- happens to be open, and notifies either way. It never takes focus.
    live = true,
    ballSeconds = 3,        -- config provider only: seconds between two balls
    countdownSeconds = 60,  -- config provider only: warning before the balls start

    -- Notify every player when a draw is about to start, and when it is over.
    announce = true,

    -- Tell a player what THEIR ticket did, privately, after the draw. The public result stays
    -- anonymous - counts per tier and no names - exactly as doc-lottery does it.
    tellWinners = true,

    -- ── Staff ───────────────────────────────────────────────────
    -- Who may draw by hand, top up the jackpot or open a session from the staff menu. An ace,
    -- checked on the server. Empty falls back to Config.Admin.ace.
    ace = nil,

    -- How many past draws the app shows.
    history = 5,
}

-- ══════════════════════════════════════════════════════════════
--  THE CLOCK
-- ══════════════════════════════════════════════════════════════
-- What the status bar, the lock screen and the control centre show.
--
-- It reads the PLAYER'S OWN MACHINE by default, which means somebody connecting from another
-- country sees their time and not the city's - two characters standing next to each other
-- disagree about what time it is. Naming a zone here gives everybody the same clock.
--
-- Any IANA name: 'Europe/Paris', 'America/New_York', 'Australia/Sydney'. Empty keeps the
-- player's own machine. A name the browser does not recognise falls back to the machine
-- rather than stopping the clock.
Config.Clock = {
    timezone = 'Europe/Paris',
}

-- ══════════════════════════════════════════════════════════════
--  THE NETS UNDER THE PHONE
-- ══════════════════════════════════════════════════════════════
-- Nothing here adds a feature. Every switch is a way of not being stuck with a cursor you
-- cannot get rid of, which is the one bug a phone must not have: a player who cannot close it
-- cannot play, and their only remaining move is to reconnect.
--
-- Leave these on. They are here as switches only because a server that finds one of them
-- fighting its own scripts should be able to turn that one off rather than the phone.
-- See bridge/client/safety.lua.
Config.Watchdog = {
    -- Once a second: if the cursor is held and nothing on this phone wants it, let it go.
    -- Two consecutive checks, so the frame between opening and being open is not mistaken
    -- for a stuck phone.
    enabled = true,

    -- Dying with the phone open used to leave it open, over a death screen that cannot be
    -- clicked through. Off if your server deliberately keeps the phone usable while down.
    closeOnDeath = true,

    -- Print a line to F8 each time the watchdog releases a stale cursor hold. Off, because it
    -- is a normal housekeeping event, not a fault - a line every time was read as the phone
    -- resetting itself inside other resources' menus, which it was not.
    debug = false,
}

Config.Log = {
    -- The boot summary: framework detected, which app groups are on, the bank, the payphones,
    -- the admin command, each app folder loaded. Useful exactly once, when setting a server up.
    -- `set phone_verbose true` in server.cfg turns it on without editing this file.
    boot = false,

    -- The PAGE's tracing, in the browser console (F8): what each layer paints and its computed
    -- style, which inputs decided the camera, whether a keypress reached the page, when free
    -- look goes on and off. Perhaps forty lines every time an app opens.
    --
    -- Off, and it has to stay off on anything but a machine you are debugging on. It is
    -- genuinely useful when a screen renders wrong and useless noise the rest of the time -
    -- and F8 is also where a player's own errors appear, so filling it hides those.
    --
    -- `setr phone_debug true` turns it on without editing this file. `setr`, not `set`: the
    -- page reads it client-side and a plain `set` never reaches a client.
    debug = false,
}

-- ══════════════════════════════════════════════════════════════
--  ONLYFRUITS
-- ══════════════════════════════════════════════════════════════
-- Photographs somebody pays to see.
--
-- A creator takes a picture with the phone's camera, puts a price on it and posts it. Other
-- people follow for free, subscribe by the month, buy one picture, or tip. The money is real:
-- it leaves a bank account and arrives in a balance the creator withdraws.
--
-- Every price below is a CEILING, not a price. What something costs is the creator's decision;
-- these are the bounds the server refuses to go outside, so a modified client cannot post a
-- picture at nine million and wait for somebody to mis-tap.
-- ══════════════════════════════════════════════════════════════
-- FruitBrawl: the duel
-- ══════════════════════════════════════════════════════════════
-- Two players, four choices a round, both revealed at once.
--
-- Everything below is balance. The numbers that decide who beats whom live in
-- `server/brawl.lua` as a written-out table rather than here, on purpose: a fighting game's
-- balance is a set of specific numbers, and a config that let each of them be changed
-- independently would let a server make an action that beats everything.
Config.Brawl = {
    enabled = true,

    -- Health each, and how long a fight therefore runs. At 100 with the shipped damage a duel
    -- is roughly eight to fourteen rounds, which is long enough to read somebody and short
    -- enough to want another.
    health = 100,

    -- Stamina: the ceiling, and what each fighter starts on. This is the whole economy - Heavy
    -- costs 3, Grab 2, Jab 1, and Block gives 2 back. Raise the ceiling and the game becomes
    -- less about recovering; lower it and Block dominates.
    stamina = 6,
    startStamina = 4,

    -- Seconds to choose. Somebody who does not choose covers up, which is both the safe
    -- default and the honest one: a fighter who has stopped deciding is guarding.
    roundSeconds = 10,

    -- How long a challenge waits before it lapses.
    inviteSeconds = 45,

    -- ── Money on the fight ─────────────────────────────────────
    -- Both stakes are taken BEFORE the first round and held by the match; the winner takes the
    -- pot and a draw gives each side their own back. Nothing is promised out of a balance that
    -- might not be there when the fight ends - a bet settled afterwards against an empty
    -- account is a bet one side simply does not pay.
    --
    -- The debit and the payout go through the same bridge as every other app, so this works
    -- the same on qb-core, on ESX and with doc-banking.
    --
    -- `false` removes the whole thing: no stake buttons, and the callbacks ignore any amount
    -- sent to them.
    stakes = true,

    -- The most one fighter may put up. The pot is therefore twice this. The app offers four
    -- amounts - nothing, a quarter, a half and the maximum - rather than a number box, because
    -- a box only invites somebody to type a fortune and be refused.
    --
    -- Fights against the practice bot are never for money, whatever this says: betting against
    -- a machine the server controls is not a bet.
    maxStake = 100,
}

-- ══════════════════════════════════════════════════════════════
-- FlappyFruit: the arcade board
-- ══════════════════════════════════════════════════════════════
-- One row per character holding their best, and a board the whole server reads.
--
-- **The game runs in a browser, so the score is written by the player's own machine.** There is
-- no version of this where that is not true, and the settings below do not pretend otherwise:
-- they make the cheap lies fail. A ceiling, so nobody is ever first with a number nothing could
-- produce; a time check, so a score has to have taken as long as it would take to play; and a
-- cooldown, so the board cannot be hammered. What that catches is somebody opening the console.
-- What nothing server-side can catch is somebody slowing the game down on their own computer.
--
-- It is a scoreboard, not a bank - no money moves on it - which is why it is allowed to be only
-- this careful. If you ever pay out for a high score, put the payout behind a staff check.
Config.Arcade = {
    enabled = true,

    -- How many rows the board shows. Anybody below it is still told their own rank.
    boardSize = 25,

    -- The ceiling on a single score. Set it a good way above what a very good player reaches,
    -- not just above: this is here to make an absurd number impossible, not to cap skill.
    maxScore = 9999,

    -- The shortest time ONE point can honestly take, in milliseconds. In FlappyFruit a point is
    -- one gate, and the gates arrive at a fixed rate, so the fastest possible run is exactly
    -- that rate - about 1500 ms at the shipped speed. This is set below it on purpose: a
    -- browser that dropped frames reports slightly less elapsed time than it lived through, and
    -- an honest player must never be told their run was impossible.
    --
    -- Raise it and you catch more fakes and start refusing real runs. Lower it and the opposite.
    msPerPoint = 900,

    -- Seconds between two submissions from one character.
    submitCooldown = 3,

    -- How long an arcade name may be. It is NOT the character's name, deliberately: somebody
    -- who wants to be `xX_Fruit_Xx` on an arcade board is doing what an arcade board is for.
    -- The row still carries the citizenid, so staff can always tell who a name belongs to.
    nickMin = 2,
    nickMax = 12,
}

-- ══════════════════════════════════════════════════════════════
-- Fruitee: donation pages
-- ══════════════════════════════════════════════════════════════
-- Somebody opens a page - a name, a picture, a few lines about what the money is for, and a
-- target - and other people give to it. Bought from the store rather than shipped: see the
-- catalogue entry's `price`, and `Config.Home.installed` for which apps come with the handset.
--
-- The money goes through the same bridge as every other app, so it works the same on qb-core,
-- on ESX and with doc-banking.
Config.Fundraise = {
    enabled = true,

    -- The floor and the ceiling on ONE gift. The ceiling is the important one: a gift amount
    -- is the only number in this phone that a player types and the server then spends, so it
    -- is bounded rather than trusted. A page's suggested tiers are suggestions and are never
    -- read as a price.
    minGift = 1,
    maxGift = 100000,

    -- The largest target a page may set. 0 for no limit. A goal is only ever a display, so
    -- this is about a page saying something ridiculous rather than about money.
    goalMax = 1000000,

    -- How many suggested amounts a page may offer. 0 turns tiers off and leaves only the
    -- "other amount" field.
    maxTiers = 4,

    -- May a giver leave a message, and may they give without their name? Both are per page as
    -- well - the owner chooses on their own page - and these two switches are the server
    -- saying whether the choice exists at all.
    messages = true,
    anonymous = true,

    -- Seconds between two gifts from the same character. Buying a picture is protected by a
    -- primary key; giving is not, because giving the same page 50 twice is a real thing. This
    -- is what stops a double click being a double gift.
    giftCooldown = 3,

    -- ── The two cuts ───────────────────────────────────────────
    -- Every gift is split three ways and the app names all three: what Fruitee keeps, what the
    -- state takes, and what is left for the page. Thirty percent in total by default, which is
    -- the figure the two lines below have to add up to if you want to keep it.
    --
    -- **The percentage is always taken. The account only says where it lands.**
    --
    -- The rate is printed on the screen somebody reads before giving, so it has to be true. A
    -- rate that silently did nothing because a field further down was blank would be the app
    -- lying about money. With no account named the cut is a SINK: it leaves the economy, which
    -- is a thing plenty of servers want. Set a percentage to 0 to not take it at all.
    --
    -- Both come off the same gross rather than one off what is left after the other, so 5 and
    -- 25 take exactly 30 and not 28.75.
    --
    -- `account` is a society or job account your framework already knows: qb-banking and
    -- doc-banking take a job account name, ESX a society.
    taxes = {
        -- The app's own cut. Small, and it is the one that usually has no account: an app
        -- taking a fee is not a company anybody can visit.
        platform   = { percent = 5,  account = '' },
        -- The state's. Point it at whatever your server calls the treasury.
        government = { percent = 25, account = '' },
    },

    -- Photographs taken with the phone's own camera only, for the cover and the avatar. The
    -- default is off, which means the ordinary host gate every other picture in the phone
    -- passes. Turn it on for a server that wants no links to the open internet on its pages.
    inGameOnly = false,

    -- How long a page stays LISTED, in real days. 0 keeps them for ever. A page past its day
    -- is hidden from the browse list, never deleted, and its own author always sees it - a
    -- page that vanished from under somebody with no explanation is a support ticket.
    pageDays = 0,

    -- The least an owner may withdraw at once.
    payoutMin = 1,

    -- What a page can be about. Shown as a chip on the card and as a filter in the list.
    -- Every one of these needs a `ph.fund_cat_<name>` line in locales/, in both languages.
    categories = { 'community', 'medical', 'business', 'memorial', 'event', 'other' },
}

Config.OnlyFruits = {
    enabled = true,

    -- The most a single picture may cost, and the most a monthly subscription may.
    maxPrice = 5000,
    maxSubPrice = 10000,

    -- The most one tip may be. Tips are the easiest thing in an app like this to lose a
    -- fortune to by typing a zero too many, which is the only reason there is a cap at all.
    maxTip = 10000,

    -- How long a subscription lasts, in real days. Subscribing again EXTENDS what is left
    -- rather than replacing it, so paying early is never paying for nothing.
    subDays = 30,

    -- Does a subscription also open the individually PRICED pictures, or only the
    -- subscriber-only ones? Off is the honest default: a picture with a price on it was put
    -- up to be bought, and a subscription that silently included everything would make every
    -- price on the page a lie.
    subsUnlockPaid = false,

    -- What the platform keeps, as a percentage of every sale, subscription and tip, rounded
    -- down so the house never rounds up. 0 for none.
    --
    -- This is taken off what the CREATOR receives. It is not the same thing as the tax below:
    -- the fee is the app's own cut and simply disappears, the tax arrives in an account.
    feePercent = 0,

    -- ── Tax ────────────────────────────────────────────────────
    -- A share of every sale, subscription and tip, into an account the operator names - the
    -- state, a revenue service, whatever the server calls it.
    --
    -- Taken from the SAME gross amount as the fee, not from what is left after it, so setting
    -- both to 10 takes exactly 20 in total rather than 19. Two percentages that quietly
    -- compound are two percentages nobody can predict from the config file.
    --
    -- Empty account, or zero percent, means no tax. A credit that fails leaves the money with
    -- the creator rather than destroying it: unpaid tax is recoverable, vanished money is not.
    tax = {
        account = '',
        percent = 0,
    },

    -- ── What a creator may do ──────────────────────────────────
    -- How long a picture stays up, in real days. 0 keeps them for ever. A picture past its
    -- day is not deleted - it stops being listed, which means a creator who lowers this and
    -- raises it again gets their back catalogue back instead of having burned it.
    postDays = 0,

    -- The most pictures one creator may have listed at once, and the most they may post in a
    -- day. Both 0 for no limit. These are the two knobs that decide whether the app is a
    -- portfolio or a firehose.
    maxPosts = 100,
    maxPerDay = 20,

    -- A handle has to be long enough to be somebody. Three is the shortest that is not a
    -- land-grab; twenty is what the column holds.
    minHandle = 3,

    -- Turn off the parts a server does not want. Everything else still works: with
    -- subscriptions off, pictures are still sold one at a time; with tips off, the button is
    -- not drawn and the callback refuses.
    subscriptions = true,
    tips = true,

    -- The least a creator may withdraw at once. Stops a payout of 3 being a database write.
    payoutMin = 1,
}

-- ══════════════════════════════════════════════════════════════
--  HOW LONG THE PHONE KEEPS THINGS
-- ══════════════════════════════════════════════════════════════
-- A phone that never forgets is a database that only grows. Every message, call, post, comment
-- and bank line stays until something removes it, and on a server that has been up for months
-- that is the table everybody's Messages app has to read through.
--
-- Everything here is in DAYS. 0 means keep for ever.
--
-- **These supersede the old per-feature keys and do not override them.** A server that set
-- `Config.Messages.retentionDays = 90` two versions ago still keeps ninety days: leaving a
-- value here as `nil` means "whatever that feature already said". Set one and it wins.
--
-- **Nothing is deleted in one statement.** A `DELETE` over a million rows takes a lock and
-- holds it, and every player opening Messages waits behind it - which on a busy server is what
-- the first prune after a long uptime looks like from the outside. The sweep works in batches
-- with a pause between them: slower on the clock, invisible to everybody.
Config.Retention = {
    enabled = true,

    -- How often to sweep, in minutes, and how long after the server starts to do the first
    -- one. Not at boot: a server starting up has a hundred things to do and this is none of
    -- them.
    everyMinutes = 60,
    firstRunSeconds = 300,

    -- Rows per batch, and the most one pass will remove before leaving the rest for the next
    -- one. A pass that stops early is not a failure - it carries on in an hour, and nothing
    -- was going to be read in the meantime anyway.
    batchSize = 500,
    maxPerPass = 20000,

    -- ── What, and for how long ─────────────────────────────────
    messages       = 30,   -- texts, including pictures sent in them
    calls          = 30,   -- the call log
    voicemail      = 30,

    socialPosts    = 30,   -- Bleeter and Snapmatic
    socialComments = 30,
    socialMessages = 30,   -- social direct messages
    socialStories  = 1,    -- a story's whole life is a day
    socialNotifs   = 14,

    mail           = 30,   -- a letter nobody saved. Saved mail is kept whatever its age,
                           -- because saving it is somebody saying to keep it.

    bank           = 60,   -- the phone's own statement lines
    alerts         = 7,
    reviews        = 0,    -- store reviews are kept: a rating with a shelf life is a rating
                           -- that quietly resets, and nobody would understand why.

    -- Fruitee's gift log. Kept, on purpose: the money history of a donation page is the last
    -- thing an operator wants swept by accident. The PAGES are never touched by retention at
    -- all - a page is somebody's fundraiser and its balance is money they can still withdraw.
    fundGifts      = 0,

    -- Rows whose only job is to point at something else - a like on a deleted post, a delivery
    -- for a letter that is gone. Swept after their parents, never before: until the parent is
    -- gone they are not orphans, they are the reason it still works.
    orphans = true,
}

-- ══════════════════════════════════════════════════════════════
--  HOME SCREEN WIDGETS
-- ══════════════════════════════════════════════════════════════
-- The strip above the app grid. A player picks what goes there from the phone itself: hold the
-- home screen to enter arrange mode, then use the widget button.
--
-- Everything is on by default. Turning one off here removes it from the picker AND stops the
-- server ever building it, so a widget an operator does not want is not a widget somebody can
-- put back with a modified page.
--
-- **A widget only appears for a player who has its app.** That is checked per request, not
-- stored, so uninstalling an app takes its widget with it.
--
-- Half of these never touch the server. `weather`, `calendar`, `messages`, `music`, `battery`
-- and `store` are drawn from what the phone already knows, and a strip built only from those
-- makes no request at all.
Config.Widgets = {
    enabled = true,

    -- What a phone that has never been arranged shows. Two, exactly as every build before
    -- widgets could be chosen - an update that rearranges somebody's home screen is a
    -- regression however good the new tiles are.
    default = { 'weather', 'calendar' },

    -- ── Free, no server request ────────────────────────────────
    weather   = true,    -- the in-game weather and clock
    calendar  = true,    -- the real date
    messages  = true,    -- how many unread, and who from. Never the message itself
    music     = true,    -- what is playing, and where it comes out
    battery   = true,    -- the ring, and whether it is charging
    store     = true,    -- a download in progress, or updates waiting

    -- ── Answered by one shared request ─────────────────────────
    bank      = true,    -- the balance, masked until the player unmasks it in Settings
    vitals    = true,    -- hunger, thirst, stress
    garage    = true,    -- how many vehicles, and where the interesting one is
    reminders = true,    -- what is due next
    export    = true,    -- the biggest mover on the market
    alerts    = true,    -- the newest public alert standing over the city
}

-- ══════════════════════════════════════════════════════════════
--  THE UPDATE CHECK
-- ══════════════════════════════════════════════════════════════
-- Asks GitHub, shortly after the server starts, whether a newer release has been published, and
-- prints one block in the console if so. Nothing is downloaded and nothing is changed; it is a
-- notice, and acting on it stays the operator's decision.
--
-- **Only the console ever sees it.** Telling a player which version the server runs tells
-- anybody looking for a known bug exactly which one to look for, so the answer stops at the
-- console. Nothing here is reachable from a client.
--
-- The version and the repository both come from `fxmanifest.lua`, so a fork is checked against
-- its own releases without editing anything, and a copy with the repository line removed is not
-- checked at all.
Config.UpdateCheck = {
    enabled = true,

    -- Seconds after boot before asking. A server starting up has better things to do.
    firstRunSeconds = 20,

    -- Ask again every N hours, or 0 for once per start. Most servers restart often enough that
    -- once is plenty; a machine that stays up for weeks might want 12.
    everyHours = 0,

    -- Announce prereleases too. Off: a prerelease is published for people who asked for it.
    prerelease = false,

    -- Override the repository to watch. Normally left nil, which means the `repository` line in
    -- fxmanifest.lua. Only github.com is understood.
    repository = nil,
}

-- ══════════════════════════════════════════════════════════════
--  A PHONE HEARD RINGING
-- ══════════════════════════════════════════════════════════════
-- A ringing phone is a sound in the room, not a private notification. Somebody standing next to
-- a player whose phone goes off should hear it - that is how a phone gives its owner away, and
-- it is worth having for exactly that reason.
Config.RingOut = {
    enabled = true,

    -- How far it carries, in metres. GTA's own phone ring is a quiet sound; much past ten
    -- metres and it is inaudible anyway, so this mostly decides who gets told about it.
    range = 12.0,

    -- A phone on Do Not Disturb, or with its ring volume at zero, makes no sound for its owner
    -- and makes none here either. Silencing a phone that still rings out loud would be worse
    -- than not having the feature.
    respectSilent = true,

    -- The game sound used, and the set it lives in.
    --
    -- `Remote_Ring` in Michael's phone set is what every script that does this reaches for, and
    -- it is QUIET - GTA meant it for your own ear, not for a room. If nobody around a ringing
    -- phone can hear anything, try another pair here before assuming the feature is broken:
    -- `phonedebug ringout` plays whatever is set on your own ped so you can hear it immediately,
    -- without needing a second player and an incoming call to test with.
    --
    -- Pairs worth trying: { 'Remote_Ring', 'Phone_SoundSet_Michael' },
    --                     { 'Remote_Ring', 'Phone_SoundSet_Default' },
    --                     { 'Menu_Accept', 'Phone_SoundSet_Default' }.
    sound = 'Remote_Ring',
    soundSet = 'Phone_SoundSet_Michael',

    -- Repeat interval in milliseconds. The sound is about a second and a half long; a gap much
    -- longer than that reads as a phone that rang once rather than one that is ringing.
    everyMs = 1400,

    -- A message is a sound in the room too.
    --
    -- Ring-out shipped for CALLS only, so standing next to somebody whose phone buzzed with a
    -- text gave nothing away - which is the half of "a phone is a sound in the room" that was
    -- missing, and what issue #6 was actually reporting: the reporter's own reproduction is a
    -- message, not a call.
    --
    -- Unlike the ring this does not loop. One arrival, one tone.
    messages = true,

    -- The tone per kind of arrival. `message` is the fallback for any kind with no entry, so
    -- adding a kind here is optional and leaving one out is not a mistake.
    --
    -- `Text_Arrive_Tone` in the default set is GTA's own text sound and it is louder than
    -- `Remote_Ring`, which is the one nobody can hear. Each entry is { sound, soundSet }.
    sounds = {
        message = { 'Text_Arrive_Tone', 'Phone_SoundSet_Default' },
    },
}

-- ══════════════════════════════════════════════════════════════
--  COMMANDS
-- ══════════════════════════════════════════════════════════════
-- **Three words, and everything is under one of them.**
--
--   phone            open or close the phone
--   phone refresh    unstick it: drop the cursor, close everything, reload
--   phone close      put it away
--   phone open       take it out
--
--   phonedebug       list what can be asked
--   phonedebug diag      which server files loaded, and which bridge providers answer
--   phonedebug voice     whether a call can carry audio, and why a weak signal does or
--                        does not break it up
--   phonedebug charge    why the phone believes it is or is not charging
--   phonedebug music     why there is no sound
--
--   phoneadmin       list the staff actions
--   phoneadmin ...   26 of them - type it and the chat suggestions narrow as you go
--
-- Typing a group name on its own lists what it can do, so nothing here has to be memorised.
-- `phonedebug` needs `set phone_debug true` for `diag`; the rest are staff-gated on the server.
-- ══════════════════════════════════════════════════════════════
--  THE SDK EXAMPLE APP
-- ══════════════════════════════════════════════════════════════
-- `apps/example/` is the worked example for anybody writing an app for this phone: one folder,
-- one `app.lua` that declares itself, one `index.html` that loads the kit. Reading it is how you
-- learn the shape.
--
-- **Off, because it is documentation and not a feature.** It was appearing in the FruitStore as an
-- app called "Example" with a placeholder description, and taking the featured card at the top of
-- the store with it - a developer's file in front of every player.
--
-- Set true while you are building against it. Nothing else needs changing: the folder stays where
-- it is either way.
Config.SdkExample = false

Config.Commands = {
    -- The older names - `/vphone`, `/refreshphone`, `/refresh-phone` - still work. They are in
    -- players' keybinds and in other servers' scripts, so removing them silently would be a
    -- change nobody asked for. Set false once your players have learned the new ones.
    legacy = true,
}

Config.Admin = {
    -- The ACE permission a command or menu action is checked against. `command.PLAYERID`
    -- style aces and qb-core's `qbadmin.menu` / god group are both accepted; this is the
    -- one the phone registers its own commands under.
    ace = 'vphone.admin',

    -- Register the `/phoneadmin` command set. Off leaves only the exports, for a server
    -- that drives everything from its own menu.
    commands = true,

    -- **How long a held phone stays held**, in seconds, without being used.
    --
    -- The clock exists to stop a session somebody forgot about lasting all night. It is NOT a
    -- limit on how long a task may take: every read and every write pushes it back, so a session
    -- in use never runs out underneath the person using it.
    --
    -- When it does run out the staff member's phone is told and the banner goes. The next call
    -- they make is REFUSED rather than performed as themselves - a silent fall back to their own
    -- character is how somebody once signed a player up to an app and got the profile.
    viewSeconds = 600,

    -- Print, at boot, the one line an operator needs to add the phone's staff menu to
    -- qb-adminmenu.
    --
    -- It does not add entries to that menu itself, and it never could: qb-adminmenu builds
    -- its menu from locals in its own client file, and nothing outside that file can reach
    -- them. The phone's staff menu is its own, opened by `/phoneadmin` with no arguments,
    -- drawn through ox_lib or qb-menu - whichever is running.
    qbAdminMenu = true,

    -- What staff may do. Turn any of these off to hide it from the command and the menu.
    actions = {
        openRemote   = true,   -- open a player's phone on their screen (support)
        -- Grant or revoke the verified badge on a Bleeter or Snapmatic account. Off leaves
        -- nobody able to hand one out, including through the export.
        verify       = true,
        setBattery   = true,
        setNumber    = true,
        wipe         = true,   -- delete every trace of a character's phone data
        sendMessage  = true,   -- send them a service message
        readInfo     = true,   -- number, battery, unread count, social handles
        -- Cut the network: globally, or inside a circle. `/phoneadmin outage`.
        -- Also reachable from another script through the AddOutage export, for a heist
        -- that jams a block or a storm that drops the whole map to one bar.
        outage       = true,
        -- Take one handset out of service. Not an outage - the network is fine, the phone
        -- is not - for a phone that was smashed, confiscated or is dead for a scene.
        brick        = true,
        -- Install or remove an app on a character's phone.
        apps         = true,
        -- A banner on their phone, which is not the same thing as a text message: it does
        -- not persist, and it does not come from a number.
        notify       = true,
        -- **Hold another character's phone on your own screen, as them.** Their messages,
        -- their contacts, their bank, their apps - and anything done while holding it is done
        -- as them. It is the support tool, and it is also the most powerful thing in this
        -- list: every session is logged with both names, and it expires on its own.
        --
        -- Off leaves staff with the read-only routes: `info`, `contacts`, `apps`, and the
        -- police forensics terminal.
        view         = true,
        -- **Speak into every phone in the city.** `/phoneadmin voice`. See Config.Admin.voice
        -- below - this is the switch that hides the command entirely.
        voice        = true,
    },

    -- ── Speaking into every phone ──────────────────────────────
    -- `/phoneadmin voice [seconds]` opens the staff member's microphone into every handset on
    -- the server, and `/phoneadmin voice stop` closes it early.
    --
    -- **How it works, and where the limit is.** pma-voice has no listen-only channel: joining
    -- a call channel makes every member a mutual voice target, so sixty players on one would
    -- all be open-mic to each other. Making it one-way is therefore done on each LISTENER's
    -- machine - every listener turns every other listener down to zero and keeps only the
    -- broadcaster, with `MumbleSetVolumeOverrideByServerId`, the same native the bad-line
    -- effect uses. It is local and instant, and it is restored on a timer that runs whether or
    -- not the broadcast ends cleanly.
    --
    -- On saltychat, or with no voice script at all, this is SILENT and says so rather than
    -- reporting a broadcast that nobody heard.
    voice = {
        enabled = true,

        -- The channel it runs on. Deliberately outside `Config.Compat.voiceChannel` and the
        -- 256 above it, so a broadcast can never land in the middle of somebody's phone call.
        channel = 690,

        -- How long one broadcast may last, in seconds, and what it lasts when no length is
        -- given. The ceiling is not a courtesy: this is an open microphone into every player's
        -- game, and one left running is one nobody can escape.
        seconds = 60,
        maxSeconds = 300,

        -- Draw a banner on every phone while it is live, so a player knows why a voice is
        -- coming out of their handset rather than thinking their game has broken.
        banner = true,

        -- Buzz the pad when it starts. The phone rings for this the way it rings for an
        -- emergency alert, because a voice arriving out of nowhere with no warning is worse
        -- than one announced.
        ring = true,

        -- Whether a player on their OWN call is included.
        --
        -- Off leaves them alone, which is the kinder default: joining somebody to a broadcast
        -- channel mid-conversation drops them out of it, and ending the broadcast would set
        -- their channel to zero - hanging up on them from across the map. They still get the
        -- banner, so they know they missed something.
        interruptCalls = false,
    },

    -- How long a held phone stays held before it lets go on its own. Seconds.
    --
    -- It expires because forgetting is the realistic failure: a staff member walks away with
    -- somebody else's phone still open on their screen, and the next thing they type goes out
    -- under that character's name.
    viewSeconds = 600,

    -- ── The emergency alert ────────────────────────────────────
    -- A loud broadcast to every phone on the server: an earthquake, a wildfire, a citywide
    -- evacuation.
    --
    -- It arrives as a notification, and two things about it are true of nothing else on this
    -- phone: the buzz ignores Do Not Disturb and the sound ignores the player's own ring
    -- volume. That is exactly why it is behind the staff ace and its own switch. A channel
    -- that overrides somebody's silence has to be hard to reach, or it will be used for
    -- things that are not emergencies and then muted along with everything else.
    emergency = true,

    -- Accept the bare `command` ace as proof of being staff.
    --
    -- OFF, and it used to be on. `IsPlayerAceAllowed(src, 'command')` is true for anybody
    -- granted ANY command at all, which on many servers includes moderators, trusted
    -- players and donors - none of whom were meant to be able to wipe a character's phone
    -- or cut the network for everybody. Turn it back on only if your staff genuinely have
    -- no other ace, and prefer `add_ace group.admin vphone.admin allow` instead.
    aceCommandFallback = false,

    -- Draw the alert as a card over the WHOLE screen as well as sounding it.
    --
    -- Off. It used to be the only behaviour, and a screen-filling warning triangle is a lot of
    -- screen for something a phone announces - what makes an alert impossible to miss is the
    -- hard buzz and the tone that ignores the volume setting, both of which happen either way.
    -- On for a server that wants the takeover.
    emergencyFullScreen = false,

    -- Wiping is destructive. Require a second confirmation in the command flow.
    confirmWipe = true,
}

-- ══════════════════════════════════════════════════════════════
--  EXTERNAL CHARGING
-- ══════════════════════════════════════════════════════════════
-- Another script can charge the phone: an electric car, a solar backpack, a wall socket
-- prop. It calls `exports['v-phone']:SetCharging(src, on, rate)` and the phone treats the
-- player as if they were at a charger for as long as `on` is true. See API.md.
Config.ExternalCharging = {
    -- The default rate an external charger applies when it does not name one. 1.0 is the
    -- same speed as a wall charger; 2.0 is twice as fast.
    defaultRate = 1.0,
    -- How long one `SetCharging(src, true)` is believed for, in seconds.
    --
    -- A charging script runs a loop and says so again every few seconds, so this costs it
    -- nothing. What it buys is that a script which crashes, is stopped, or misses its own
    -- "unplug" path cannot leave a phone charging for the rest of the session - which is
    -- exactly what "the phone charges for ever" looks like from the player's side.
    leaseSeconds = 120,

    -- A ceiling, so a misbehaving script cannot charge a phone in one tick.
    maxRate = 4.0,
}

-- ══════════════════════════════════════════════════════════════
--  POLICE FORENSICS
-- ══════════════════════════════════════════════════════════════
--  THE HEALTH RECORD
-- ══════════════════════════════════════════════════════════════
-- Blood group, allergies, conditions, medication, next of kin, organ donor. A player writes
-- their own; this is about who else may see it.
Config.HealthRecord = {
    -- Let a player hand their record to somebody standing next to them, over FruitDrop. Their
    -- own record and nobody else's, and the other person has to accept it.
    share = true,

    -- ── Jobs that may READ a record without being handed it ────
    -- A paramedic treating an unconscious player cannot ask them for their blood group. So a
    -- job on this list gets a fourth tab in the Health app listing everybody nearby, and can
    -- open the record of any of them.
    --
    -- Same two shapes as `Config.Mail.reserved`: a list means any grade of that job, a
    -- `job = n` entry means grade n or higher, and both may be mixed.
    --
    --   readers = { 'ambulance', 'ems' }        every medic
    --   readers = { ambulance = 3 }             only from grade 3
    --   readers = { 'ambulance', police = 6 }   medics, plus police command
    --
    -- **This is a real privacy decision, so it ships EMPTY.** A record holds a person's
    -- medical history; who may read it without being handed it is not something to default on
    -- somebody's behalf.
    readers = {},

    -- How close a reader has to be, in metres. A record is read at the patient's side, not
    -- from across the city - and this is checked on the server, from real positions, so a
    -- modified client cannot ask about somebody it is nowhere near.
    readRange = 5.0,

    -- Tell the patient their record was read, and by whom.
    --
    -- ON, and deliberately: a record that can be read silently is a record whose owner has no
    -- way of knowing it happened. Turn it off only if your server has decided that medics
    -- reading records is routine enough not to mention.
    notifyOwner = true,
}

-- ══════════════════════════════════════════════════════════════
--  HOSPITALS
-- ══════════════════════════════════════════════════════════════
-- The Health app's third tab. A list you control: what your server calls its hospitals, and
-- where they are, because that is a map decision rather than something a phone can work out.
--
-- Tapping one sets a waypoint. Leave `x` and `y` off an entry and it is still listed with its
-- address, it simply cannot be pointed at - useful for a clinic somebody has to be told
-- about but that has no door on the map.
--
-- The defaults are the five medical centres GTA ships, at the coordinates FiveM scripts
-- generally use for their doors. They are a starting point: check them against your own map
-- and your own MLOs, because an interior replaced by an MLO often moves the entrance.
-- Set this to `{}` and the tab disappears.
Config.Hospitals = {
    { label = 'Pillbox Hill Medical Center', address = 'Strawberry Avenue, Pillbox Hill',
      x = 298.6,  y = -584.7 },
    { label = 'Mount Zonah Medical Center',  address = 'Roy Lowenstein Boulevard, Rockford Hills',
      x = -449.7, y = -340.8 },
    { label = 'Central Los Santos Medical',  address = 'Elgin Avenue, Davis',
      x = 341.0,  y = -1397.3 },
    { label = 'Sandy Shores Medical Center', address = 'Alhambra Drive, Sandy Shores',
      x = 1839.6, y = 3672.9 },
    { label = 'Paleto Bay Care Center',      address = 'Paleto Boulevard, Paleto Bay',
      x = -247.8, y = 6331.4 },
}
normalisePlaces(Config.Hospitals)

-- ══════════════════════════════════════════════════════════════
--  PROPERTY
-- ══════════════════════════════════════════════════════════════
-- The Property app lists the houses a character owns and points at them on the map. It
-- reads your housing script through the bridge - qb-houses, ps-housing, Quasar's, ESX's -
-- and needs nothing here to do that.
--
-- What it CANNOT know is where somebody goes to buy one, because that is a decision you
-- made when you placed the estate agent. So you say it here, and the app's second tab sends
-- players there.
Config.Property = {
    -- The estate agent. `x` and `y` are what the button sets a waypoint to; leave them out
    -- and the tab still explains where to go, it just cannot mark it.
    --
    -- The default is Dynasty 8's office on Portola Drive, which is where GTA's own property
    -- signs point and where most servers put theirs.
    agent = {
        label = 'Dynasty 8',
        address = 'Portola Drive, Rockford Hills',
        x = -718.06,
        y = 261.28,
    },

    -- Houses whose position your housing script does not expose - Quasar keeps its own
    -- behind an escrowed core - so the app can still point at them. Keyed by the house id or
    -- name the script uses.
    --
    --     houses = { ['1'] = { label = 'Mirror Park 12', x = 1234.5, y = -567.8 } },
    houses = {},
}

-- ══════════════════════════════════════════════════════════════
--  GARAGES
-- ══════════════════════════════════════════════════════════════
-- Only needed to OVERRIDE. The Garage app reads your garage script's own config for the
-- name and position of each garage - qb-garages and its forks all keep
-- `Config.Garages.<key> = { label = ..., takeVehicle = vector3(...) }`, and that is read
-- straight from the file - so most servers need nothing here.
--
-- Fill it in when the script keeps its garages somewhere unreadable (an escrowed build), or
-- when you want your own names. Anything listed here wins over what the script says.
--
--     Config.Garages = {
--         motelgarage = { label = 'Motel Parking', x = 274.29, y = -334.15 },
--     }
--
-- `x` and `y` are what the "Locate" button sets a waypoint to. Leave them out and the app
-- still shows the name, it just cannot point at it.
Config.Garages = {}

-- ══════════════════════════════════════════════════════════════
--  BANK
-- ══════════════════════════════════════════════════════════════
-- The bank app reads the balance your framework already keeps - qb-core, qbx, ESX, ox, or
-- whatever banking script is running - through the bridge. Nothing here needs a companion
-- resource, and nothing here invents an account: the phone is a window onto the money the
-- server already believes in.
--
-- What it ADDS is the phone part: a statement, transfers between characters, and a list of
-- saved beneficiaries. Those are the phone's own, kept in its own tables, because no
-- framework has them.
Config.Bank = {
    enabled = true,

    -- Transfers, character to character, from the bank balance. Off leaves the app a
    -- read-only statement, which is what a server with its own banking UI usually wants.
    transfers = true,

    -- The bounds of one transfer. `max = 0` means no ceiling.
    minAmount = 1,
    maxAmount = 100000,

    -- A cut the bank takes, as a percentage of the amount, rounded down. 0 for none. The
    -- sender pays it on top: sending 1000 at 1.5% costs 1015 and delivers 1000, so the
    -- number the recipient was promised is the number they get.
    feePercent = 0,

    -- How much one character may send per real day, 0 for no limit. Counted on the phone's
    -- own ledger, so it cannot be walked around by closing the app.
    dailyLimit = 0,

    -- Paying somebody who is not connected. On: the money leaves the sender now and is
    -- held by the phone until that character next looks at their bank, then credited once.
    -- Off: the transfer is refused with "they are not connected".
    --
    -- On is the honest default. The alternative is a transfer that silently does nothing
    -- because the recipient logged off between choosing them and pressing send.
    offlineTransfers = true,

    -- Saved beneficiaries per character.
    maxFavourites = 25,

    -- ── Being told when money arrives ──────────────────────────
    -- A banking app that says nothing when you are paid is not a banking app. The phone
    -- listens to the framework's own money events, so a salary, a society payout or a shop
    -- refund raises a banner with the bank's icon on it.
    --
    -- Instant and with a reason attached on qb-core, qbx_core and ESX, which all announce
    -- their money changes. ox_core has no equivalent event - see `pollSeconds`.
    notify = {
        enabled = true,

        -- Ignore anything smaller, so a one dollar tip is not a notification.
        minAmount = 1,

        -- Announce money LEAVING too. Off by default: most servers already have a HUD that
        -- flashes spending, and a phone buzzing at every purchase gets muted.
        outgoing = false,

        -- Write a statement line for money the phone did not move itself.
        --   'auto'  only when no dedicated banking script is running (the default: with one
        --           present that line already exists in its history, which the statement
        --           merges, so writing a second would show every salary twice)
        --   true    always      false   never
        record = 'auto',

        -- The fallback for a framework with no money event, ox_core in practice: sample the
        -- balance every N seconds and announce what changed. 0 is off, and off is right on
        -- qb, qbx and ESX where the events above are instant and carry a reason. The
        -- minimum is 15 seconds; it costs one balance read per online player per interval.
        pollSeconds = 0,
    },

    -- How many statement lines the app shows, and how long the phone keeps its own.
    historyLimit = 50,
    retentionDays = 60,       -- 0 keeps them for ever

    -- ── What a movement is called ──────────────────────────────
    -- The framework passes on whatever the resource that moved the money wrote, and plenty of
    -- them write an identifier rather than a sentence: doc-shop sells produce with the reason
    -- `shop-sell`, so the banner read "+836 - shop-sell" while the bank's own history for the
    -- same movement read "Vente produits". One movement, described twice, once in a language
    -- and once not.
    --
    -- The phone already translates the codes it knows, and tidies the ones it does not into
    -- words - `car_wash` reads "Car wash" rather than `car_wash`. This is for the rest: the
    -- codes only YOUR scripts use. The key is the reason with its separators normalised to
    -- underscores and its case dropped, so one entry covers `shop-sell`, `SHOP_SELL` and
    -- `Shop.Sell`. The value is the finished string, in whatever language your server runs.
    --
    --     reasonLabels = {
    --         ['weed_sale']   = 'Vente de rue',
    --         ['laundry_out'] = 'Blanchiment',
    --     },
    reasonLabels = {},
}

-- ══════════════════════════════════════════════════════════════
-- A warrant terminal: police walk to a point on the map and, with the target's number,
-- read what is on that phone. Everything that is stored in the clear - texts, contacts,
-- the call log, mail, social posts and DMs - is theirs to read.
--
-- Cipher is different, and honestly so. Its messages are end-to-end encrypted: the key
-- lives on the sender's and recipient's devices, never on the server, so NOBODY on the
-- server can read the content - not the operator, not the police. The terminal shows the
-- metadata that IS recoverable (who spoke to whom, when, how often, the key fingerprints)
-- and, if you opt into lawful intercept below, a deliberately hard crack of the content.
Config.Police = {
    enabled = true,

    -- Who may use the terminal. Same list style as the MDT app. Empty means no one.
    jobs = { 'police', 'sheriff', 'bcso', 'sast' },

    -- A minimum rank on that job, 0 for any. Keeps a cadet out of the wiretap room.
    minGrade = 0,

    -- An item the officer must carry to start a session, or nil for none. A "forensic
    -- kit", a warrant, a laptop - whatever your server calls it.
    item = nil,

    -- How the terminal is opened.
    --
    -- `key` is ALWAYS live, and that is deliberate. The target-script route was the only way
    -- in when one was running, and on a server where the zone did not register - a target
    -- version whose signature moved, a job check somewhere in the middle - the terminal was
    -- simply unreachable with nothing on screen to say so. Walking up and pressing a key is
    -- the route that cannot fail quietly.
    key = 38,              -- E. Any control id from the FiveM list.
    marker = true,         -- draw the small marker at each point
    helpText = true,       -- and the "[E] Forensic terminal" prompt when you are in range
    useTarget = true,      -- also register an ox_target/qb-target zone when one is running

    -- The terminals. Interact within `radius` - by key press, and by target when a target
    -- script is running.
    points = {
        { label = 'Mission Row - Digital Forensics', x = 484.6, y = -996.5, z = 30.7, radius = 1.5 },
        { label = 'Sandy Shores Sheriff - Tech Bench', x = 1853.0, y = 3689.5, z = 34.3, radius = 1.5 },
        { label = 'Paleto Bay Sheriff - Evidence',    x = -448.5, y = 6012.0, z = 31.9, radius = 1.5 },
    },

    -- A session lasts this long before the officer must re-authorise at the terminal, so
    -- a warrant is not a permanent tap. Seconds.
    sessionSeconds = 300,

    -- Log every lookup to the server console (and to your framework log if it has one),
    -- so a wiretap leaves a paper trail an admin can audit.
    log = true,

    cipher = {
        -- Lawful intercept. OFF by default, on purpose: leaving it off keeps Cipher a
        -- true end-to-end secret that the police tool can describe but never read, which
        -- is the promise the app makes to players.
        --
        -- ON changes the deal: the phone keeps a recoverable copy of each Cipher message
        -- so the terminal CAN crack the content - slowly, and not always. Turn this on
        -- only if your server wants an encrypted app the police can eventually break.
        intercept = false,

        -- The crack, when intercept is on. Deliberately expensive.
        --
        -- With `minigame` on - the default - reading a message is WORK: the officer is given a
        -- cryptanalysis bench and has to break it. The old behaviour was a twenty second wait
        -- and a dice roll, which meant the outcome had nothing to do with the officer and the
        -- terminal sat there saying "processing" at somebody who could do nothing about it.
        --
        -- Set `minigame = false` to go back to the wait and the roll, and `successChance`
        -- becomes meaningful again.
        minigame = true,
        crackSeconds = 20,       -- the roll route only: real seconds of "processing"
        successChance = 0.6,     -- the roll route only: and it can still fail

        -- ── The bench ────────────────────────────────────────────
        crack = {
            -- Which benches, in order. Each is a different real technique and each is
            -- generated fresh per message, so a solution cannot be memorised:
            --   'substitution' - frequency analysis against a monoalphabetic cipher
            --   'xorkey'       - align the key bytes until the known header decodes
            --   'rotors'       - satisfy a system of modular constraints on four rotors
            -- Fewer entries is an easier crack. An empty list makes the crack free.
            stages = { 'substitution', 'xorkey', 'rotors' },

            -- Seconds on the clock per stage. Expiry loses the attempt, not the message.
            seconds = 150,

            -- Attempts per message, per officer. Spent when the clock runs out or a stage is
            -- given up - never by a wrong guess, because guessing is how you solve these.
            attempts = 3,

            -- The floor under which a solve is not believed. Three stages cleared in two
            -- seconds is a script, not an officer, and the server refuses it: the page can be
            -- replaced but the clock is kept here. Seconds, per stage.
            minSeconds = 4,

            -- How many of the substitution's letter mappings are given away. Lower is harder;
            -- 0 is a genuine cold frequency attack, which is very hard on one short phrase.
            hints = 4,

            -- The cover phrases the substitution bench uses. Never the seized message - the
            -- content is what the crack is FOR, so it cannot also be the puzzle. Letters and
            -- spaces only; case does not matter.
            phrases = {
                'MEET ME BEHIND THE PIER AT MIDNIGHT',
                'THE SHIPMENT LANDS ON THE NORTH DOCK',
                'BURN THE LEDGER AND LEAVE THE CITY',
                'THE KEY IS UNDER THE THIRD PLANTER',
                'NOBODY TALKS AND EVERYBODY WALKS',
                'THE COURIER WEARS A GREY JACKET',
                'PAYMENT CLEARS AFTER THE HANDOVER',
                'NEW PLATES ARE IN THE BLUE CRATE',
            },
        },
    },
}
normalisePlaces(Config.Police.points)

-- ══════════════════════════════════════════════════════════════
--  MEDIA  (photos and video hosting)
-- ══════════════════════════════════════════════════════════════
-- Where the camera's photos and the social apps' videos are hosted. By default the phone
-- keeps photo URLs a player pastes and nothing else; turn this on to capture and upload
-- to a CDN so a photo taken in game has a real link.
--
-- The upload runs on the SERVER through the `screencapture` resource, so the API key
-- never reaches a client. Install it: https://github.com/itschip/screencapture
Config.Media = {
    -- Off leaves the camera taking local gallery photos only, and hides video recording.
    --
    -- `set phone_media true` in server.cfg overrides this either way. Prefer it: this is the
    -- one feature whose configuration carries a secret, and the convar lets you switch it on
    -- in the same file that holds the key, without editing a tracked file to do it.
    enabled = false,

    -- 'fivemanage' is the one wired here. 'custom' posts to `endpoint` with `headers`,
    -- for any host that takes a multipart file and answers with a URL.
    provider = 'fivemanage',

    -- The upload endpoint. Fivemanage's v3 file API takes both images and video.
    endpoint = 'https://api.fivemanage.com/api/v3/file',

    -- Your API key. Prefer the convar so it stays out of the repo:
    --     set phone_media_key "fm_xxxxxxxx"
    -- A value here is used only when the convar is unset.
    apiKey = '',

    -- The multipart field name the endpoint expects. Fivemanage uses `file`.
    formField = 'file',

    -- Image encoding for photos: 'webp' (small), 'jpg', or 'png'.
    imageEncoding = 'webp',

    -- ── Video recording: OFF ───────────────────────────────────
    -- `video = nil` removes it entirely: the Video tab is not drawn, the record button does
    -- not exist, and the server refuses a recording request even if one arrives.
    --
    -- Turned off because it does not work well enough to ship. screencapture records in the
    -- player's own browser and streams it to the server, and on a real connection that means
    -- a visible stall while it runs plus a `stream-finalize` failure often enough to be the
    -- normal outcome rather than an edge case - the clip is lost after the player has already
    -- stood still for fifteen seconds.
    --
    -- Photographs are unaffected: they are a single frame and they work.
    --
    -- To try it again, restore the table below. Nothing else has to change - every part of the
    -- feature is still here and reads this switch.
    --
    --  video = {
    --      maxSeconds = 15,       -- hard ceiling, 1..30
    --      maxWidth = 1280,
    --      maxHeight = 720,
    --  },
    video = nil,

    -- ── Auto-deletion ──────────────────────────────────────────
    -- The phone tracks every file it uploaded in `vphone_media` and removes it after this
    -- many days: the row goes, and the file is deleted from the host if `deleteEndpoint`
    -- is set. 0 keeps everything for ever.
    --
    -- Fivemanage also has its own retention; this is the phone's own clock on top of it,
    -- so a server keeps control even if it changes host.
    autoDeleteDays = 30,

    -- How the host deletes a file, if it can. `{id}` and `{url}` are filled in. Left
    -- empty, the phone only forgets the file (drops the row) and leaves the host to its
    -- own retention. Fivemanage v3 deletes by id.
    deleteEndpoint = 'https://api.fivemanage.com/api/v3/file/{id}',
    deleteMethod = 'DELETE',

    -- Extra headers for a 'custom' provider. For Fivemanage the Authorization header is
    -- added from the key automatically.
    headers = {},
}

-- ══════════════════════════════════════════════════════════════
--  FACETIME  (experimental live video feed)
-- ══════════════════════════════════════════════════════════════
-- A FaceTime call is always a real voice call. With `videoFeed` on, it ALSO streams a
-- live picture between the two phones: each side captures its front camera a few times a
-- second, shrinks the frame to something tiny, and relays it to the other phone through
-- the server. It is the same trick the paid phones use.
--
-- **Experimental, and off by default, for good reasons:**
--   * it needs `screenshot-basic`,
--   * it moves image data through the network every frame, so it costs bandwidth - the
--     defaults are deliberately small (a thumbnail, a few frames a second),
--   * screenshot-basic itself warns against sending screenshots through events, which is
--     why the frame is shrunk hard in the page before it is ever sent, and why the server
--     caps the size and the rate and drops anything larger.
--
-- Leave it off and FaceTime stays the clean voice-call-with-a-video-layout from 1.1.2.
Config.FaceTime = {
    videoFeed = false,     -- opt in to the live picture

    fps = 6,               -- frames per second each side sends, capped at 12
    width = 220,           -- the frame is scaled to this before sending
    height = 300,
    quality = 0.4,         -- JPEG quality 0.1..0.9; lower is smaller and blurrier

    -- The server drops a relayed frame larger than this many KILOBYTES, so a client
    -- cannot turn the relay into a flood. A 220x300 q0.4 JPEG is well under this.
    maxFrameKb = 24,
}

-- ══════════════════════════════════════════════════════════════
--  PAYPHONES  (call boxes and prepaid cards)
-- ══════════════════════════════════════════════════════════════
-- The phone boxes that are ALREADY on the map, made to work.
--
-- There is no coordinate list here on purpose. Every booth in Los Santos is one of a
-- handful of props, so the client looks for those props around the player instead of
-- trusting a list somebody has to maintain. Add an MLO with a booth in it and it works;
-- move one with a map edit and it moves with it.
--
-- **A booth places calls. It never receives them.** That is the whole character of a
-- payphone, and it is enforced in three independent places: a booth number is never put
-- in the online table, it is never written to `vphone_characters`, and both the call and
-- the SMS paths refuse a booth-shaped number outright. See server/booth.lua.
--
-- Paying for the call is a prepaid card: an inventory item the player feeds into the box,
-- which turns into seconds of talk time held against their character. Emergency numbers
-- are free, because a payphone that will not call an ambulance is a prop, not a phone.
Config.Booth = {
    enabled = true,

    -- The props that count as a phone box. These are the base-game booths; add your own
    -- model names here if your map ships others.
    -- The `b` suffixes are the ones actually scattered around Los Santos - the plain
    -- `prop_phonebox_01` is rarer than its variant, which is why a player can stand at a
    -- box on the street and have nothing happen if only the base names are listed. Both
    -- forms are here; a model that is not on the map simply never matches.
    models = {
        'prop_phonebox_01', 'prop_phonebox_01b',
        'prop_phonebox_02', 'prop_phonebox_02b',
        'prop_phonebox_03', 'prop_phonebox_03b',
        'prop_phonebox_04', 'prop_phonebox_04b',
        'prop_ld_phonebox',
    },

    -- How close the player must be to use the box, in metres.
    radius = 1.6,

    -- Walk away and the call drops, the way a handset on a cord would. Metres from the
    -- box; keep it a little above `radius` so leaning away is not a hang-up.
    leashDistance = 3.5,

    -- What a booth number looks like. `#` becomes a digit, and every booth derives its
    -- OWN digits from where it stands, so the box outside the Vanilla Unicorn always has
    -- the same number and a player can recognise it.
    --
    -- **This must not overlap `Config.NumberFormat`.** The literal part ("311-" here) is
    -- what marks a number as a booth, and the phone refuses to mint a player number that
    -- would look like one.
    --
    -- More `#` means fewer boxes sharing digits. Four gives 10,000 numbers against the
    -- hundred-odd booths in Los Santos, so a collision is unlikely but not impossible; two
    -- boxes on opposite sides of the city showing the same number is the only consequence,
    -- since neither can be called back either way. Use five or six if that bothers you.
    numberFormat = '311-#####',

    -- The anim the player plays while on the box. A booth has its own handset, so no
    -- phone prop is attached.
    anim = { dict = 'cellphone@', clip = 'cellphone_call_listen_base' },

    -- The operator's name, struck into the plate at the top of the panel. Los Santos has two
    -- payphone operators, Badger and Whiz, and plenty of unbranded boxes - put your own city's
    -- telco here if you have one.
    brand = 'Badger',

    -- ── Paying for the call ────────────────────────────────────
    -- Seconds of talk time. `0` makes every booth call free and hides the card entirely,
    -- which is a fine way to run this if you do not want an economy attached to it.
    costPerMinute = 60,        -- seconds of credit spent per minute of call
    minimumSeconds = 30,       -- refuse to connect a call there is not this much credit for

    -- Numbers that never cost anything and never need a card. Only useful if something on
    -- your server actually answers them.
    freeNumbers = { '911', '112', '999' },

    -- The prepaid card. An ordinary inventory item; the box eats one and pays out seconds.
    -- Set `item = nil` to run booths on free calls only.
    card = {
        item = 'prepaid_card',
        seconds = 600,         -- talk time one card is worth
        maxCredit = 7200,      -- a character cannot bank more than this, so cards are not a wallet
    },

    -- Log every booth call to the server console, the way the forensics terminal logs a
    -- lookup. A payphone is the classic untraceable call, so an admin trail is worth having.
    log = false,

    -- ── Rules of the box ───────────────────────────────────────
    -- Let a player use a box from the driver's seat. Off is the honest default: you cannot
    -- reach a handset on a cord through a car window.
    allowInVehicle = false,

    -- The longest number the keypad will accept. Raise it if your server uses long numbers
    -- or extensions.
    maxDialLength = 20,

    -- Seconds a player must wait between calls from a box, counted from when the last one
    -- ENDED. 0 is no limit. Useful against someone using a payphone to spam a number they
    -- cannot be traced on.
    cooldownSeconds = 0,

    -- Hide the box's number from the person being called, so the call shows as withheld.
    -- OFF by default: the number is what makes a payphone call interesting to receive, and
    -- with it hidden the recipient has nothing at all to go on.
    anonymous = false,

    -- Slack, in metres, on the SERVER's check that the player is really at the box they
    -- claim to be at. It exists because the prop's origin is not where a player stands to
    -- use it. Tighten it to be strict, raise it only if a map edit puts the prop origin
    -- oddly far from its front.
    reachTolerance = 2.5,

    -- ── How the player reaches the box ─────────────────────────
    interact = {
        -- `off` is the default: a marker on the box and an [E] prompt, which works the
        -- moment a player walks up to one and needs nothing installed.
        --
        -- `auto` hands the box to whichever target script is running instead. That is the
        -- prettier integration, but it is not self-evident: qb-target only shows its eye
        -- while the player HOLDS Left Alt, so somebody standing at a phone box wondering
        -- why nothing happens is the normal outcome rather than a bug. Choose it when your
        -- players already know the targeting key.
        --
        -- Naming a script forces that one and falls back to the marker if it is not running.
        target = 'off',           -- off | auto | ox_target | qb-target | qtarget

        key = 38,                 -- the control id for the prompt. 38 is E.
        icon = 'fas fa-phone',    -- the target script's icon
        label = nil,              -- override the prompt text; nil uses the translation

        scanDistance = 12.0,      -- how far out the marker mode looks for a box
        -- How often the marker mode re-runs its spatial search, in milliseconds. Finding a
        -- box costs one query per model, so this is deliberately not every frame; the props
        -- do not move. Drawing stays on the frame, which is what it has to be.
        scanInterval = 500,

        marker = {
            enabled = true,
            type = 2,             -- 2 is the small downward chevron
            colour = { r = 60, g = 130, b = 200, a = 140 },
            scale = { x = 0.18, y = 0.18, z = 0.12 },
            height = 1.35,        -- metres above the prop's origin
            bob = false,          -- float it up and down
        },
    },

    -- ── On the map ─────────────────────────────────────────────
    -- Blips for the boxes, added as the player comes near them. OFF by default and on
    -- purpose: there are around a hundred payphones in Los Santos and blipping all of them
    -- turns the map into confetti. `shortRange` keeps them off the main map and on the
    -- minimap only, which is the version most servers actually want.
    blip = {
        enabled = false,
        sprite = 64,              -- 64 is the telephone icon
        colour = 3,
        scale = 0.6,
        shortRange = true,
        label = nil,              -- nil uses the translation

        -- **Only show a box's blip while the player is within this many metres of it.**
        -- Beyond it the blip is removed, and it comes back on the next approach.
        --
        -- `0` keeps every box the player has walked past, for ever, which is the setting
        -- for a server that wants a permanent payphone map. A value here is what you want
        -- if you would rather the map stayed readable: 150 shows the boxes on your street,
        -- 500 shows the ones in your district.
        --
        -- This is a real distance cull, and it is not the same thing as `shortRange`.
        -- `shortRange` is a GTA flag that hides a blip from the big paused map and leaves
        -- it on the minimap at any distance; this removes the blip outright.
        distance = 0,

        -- How often, in milliseconds, the blips are re-checked against `distance`. Only
        -- matters when `distance` is set. Cheap - it walks a handful of known positions,
        -- it does not search the world.
        refresh = 2000,
    },
}

-- ══════════════════════════════════════════════════════════════
--  MUSIC  (playback, playlists and the deck the phone hands off to)
-- ══════════════════════════════════════════════════════════════
-- The Music app is a library, a playlist manager and a remote. What it is NOT is an audio
-- engine: FiveM has no way to stream a URL from a phone UI, so the sound itself always comes
-- from a music resource the server already runs.
--
-- **Read this before reporting that a track does not play.**
--
-- The two rcore scripts this ships support - the car radio and the DJ deck - expose only UI
-- exports in their public API. There is no documented export in either that takes a URL and
-- plays it. So the phone does the honest thing: it keeps your library and playlists, puts the
-- track's URL on your clipboard, and opens the right deck for where you are standing. You
-- paste and press play. That is a real, working integration with what those scripts actually
-- publish, and it is the whole of what they publish.
--
--   rcore_radiocar   https://store.rcore.cz/package/4342933   in a vehicle
--   xDiskJockey      https://store.rcore.cz/package/4357520   on foot
--
-- If your music script CAN be driven programmatically, fill in `hooks` below and the phone
-- will drive it instead - no paste, no deck, the track just plays. That path is the one to
-- use with a script you wrote yourself or one with a richer API.
Config.Music = {
    enabled = true,

    -- Which deck the phone hands a track to.
    --   auto          the car radio when the player is in a vehicle that has one,
    --                 the DJ deck otherwise
    --   rcore_radiocar / xdiskjockey    always that one
    --   hooks         never open a deck; use the `hooks` below only
    --   off           the app stays hidden entirely
    provider = 'auto',

    -- Put the track's URL on the clipboard when handing off to a deck, so it is a paste away
    -- rather than something to retype. Off if you find it intrusive.
    copyUrl = true,

    -- Drive a music resource directly, for a script that supports it. Each hook runs on the
    -- CLIENT. Return true from `play` and the phone treats the track as playing and never
    -- opens a deck.
    --
    --     Config.Music.hooks.play = function(track, output)
    --         -- track = { url, title, artist, volume }, output = 'headphones' | 'speaker'
    --         return exports['my-music']:PlayUrl(track.url, track.volume)
    --     end
    hooks = {
        play = nil,      -- function(track, output) -> boolean
        stop = nil,      -- function() -> boolean
        volume = nil,    -- function(level 0..1) -> boolean
    },

    -- ── What a player may add ──────────────────────────────────
    maxLibrary = 120,          -- saved tracks per character
    maxPlaylists = 20,         -- playlists per character
    maxTracksPerPlaylist = 100,

    -- How far a phone SPEAKER carries, in metres. The car radio uses the same ceiling.
    --
    -- A limit rather than whatever the page asks for: a phone speaker is a phone speaker, and
    -- the obvious abuse is one player broadcasting across a district. 12 m is about right for
    -- a handset on a table.
    speakerRange = 12.0,

    -- Where a track URL may point. Same idea as the wallpaper hosts: an operator decision,
    -- not the player's. An empty list allows any host, which is the permissive setting.
    allowCustomUrl = true,
    hosts = {
        'youtube.com', 'www.youtube.com', 'youtu.be', 'music.youtube.com',
        'soundcloud.com', 'www.soundcloud.com',
        'open.spotify.com',
        'files.catbox.moe', 'cdn.discordapp.com', 'media.discordapp.net',
    },

    -- ── Playlists every character starts with ──────────────────
    -- Read-only: a player can play them and copy a track out of them, but not edit or delete
    -- them, so a server's own selections stay intact. Their own playlists sit alongside.
    --
    -- `icon` is any icon the phone already ships (music, radio, star, heart, disc...).
    -- Leave `tracks` empty and the playlist is a heading a player can fill from the library.
    -- **A word on what you put here.** These links get streamed on your server, in public.
    -- Music that is licence-free stays up; a rip of a commercial radio station is taken down
    -- sooner or later and the entry quietly stops working. The first two lists below are
    -- royalty-free on purpose - NoCopyrightSounds is free for streams as long as the artist,
    -- the track and NCS are credited (https://ncs.io). The third is the in-game sound, and it
    -- carries the risk that comes with it.
    --
    -- Whether a PLAYLIST link works, as opposed to a single video, depends on the deck your
    -- server runs. Single-video URLs are the safe bet; try a playlist and keep it if it plays.
    defaultPlaylists = {
        {
            id = 'ls_classics',
            name = 'Free To Play',
            icon = 'music',
            tint = '#34C759',
            tracks = {
                { title = 'NCS 10 Year Mix (3 hours)', artist = 'NoCopyrightSounds',
                  url = 'https://www.youtube.com/watch?v=yUXJjIvhZz8' },
                { title = 'Gaming Music - No Copyright', artist = 'NCS and friends',
                  url = 'https://www.youtube.com/playlist?list=PL7ya7p5KV7zulnn3d17Qq0PGYLycMHZMx' },
                { title = 'Gaming, No Copyright', artist = 'Royalty free',
                  url = 'https://www.youtube.com/playlist?list=PLRPR8uJQx5tHxkGUSqu-Xvesjc0lDbdrX' },
            },
        },
        {
            id = 'late_night',
            name = 'Late Night Drive',
            icon = 'moon',
            tint = '#5856D6',
            tracks = {
                { title = 'NCS 10 Year Mix (3 hours)', artist = 'NoCopyrightSounds',
                  url = 'https://www.youtube.com/watch?v=yUXJjIvhZz8' },
            },
        },
        {
            id = 'los_santos',
            name = 'Los Santos Radio',
            icon = 'speaker',
            tint = '#FF9500',
            -- The in-game stations. Fun, and the entries most likely to go dead one day: these
            -- are uploads of commercial music, not licence-free tracks. Swap in your own
            -- mirrors if a link stops playing.
            tracks = {
                { title = 'Radio Los Santos', artist = 'GTA V',
                  url = 'https://www.youtube.com/playlist?list=PLgbI0QcBNn5jsj7Ju1BEgGbT0bn4bLOdS' },
                { title = 'West Coast Classics', artist = 'GTA V',
                  url = 'https://www.youtube.com/watch?v=UNzZIIbc0jY' },
            },
        },
    },
}

-- ══════════════════════════════════════════════════════════════
--  VEHICLE REMOTE  (lights, neons, doors and locks from the phone)
-- ══════════════════════════════════════════════════════════════
-- Your car, from your pocket. Open the Garage app, pick a vehicle you own that is parked
-- nearby, and flash the lights, change the underglow, pop a door or lock it.
--
-- **This needs no dependency at all.** Neons, lights, doors and locks are engine natives, so
-- this works identically on qb-core, qbx_core, ox_core, ESX and standalone, with any garage
-- or inventory script. What the framework decides is only WHICH vehicles are yours, and that
-- is read through the same bridge the Garage app already uses.
--
-- **jim-mechanic.** It ships a "Neon Controller" item that sets underglow and xenon colour.
-- It publishes no exports, so there is nothing to call into - and nothing to fight over
-- either: both write the same engine state. Leave `persist` off and the phone is a remote,
-- with jim-mechanic remaining the thing that SAVES a build. Turn it on and a colour set from
-- the phone is written to the vehicle's state so it survives a re-spawn, which is what you
-- want on a server with no mechanic script at all.
Config.VehicleRemote = {
    enabled = true,

    -- **How far the phone reaches, in metres.** Checked on the SERVER against the vehicle's
    -- real position, so a modified client cannot open its car from across the city.
    distance = 20.0,

    -- Only vehicles the framework says belong to this character. Off lets a player control
    -- any vehicle in range, which is a very different game - keep it on unless you mean it.
    requireOwnership = true,

    -- Refuse while the engine is running and somebody is in the driver's seat, so this
    -- cannot be used to lock a thief in or pop a door on a moving car.
    refuseWhileDriven = true,

    -- Seconds between commands from one player. Stops the buttons being held down.
    cooldownSeconds = 1,

    -- Which controls the app offers. Each one hides its own button.
    controls = {
        lights   = true,     -- flash / low beam / full beam
        neon     = true,     -- underglow on/off and colour
        doors    = true,     -- pop and shut each door
        locks    = true,     -- lock and unlock
        engine   = false,    -- remote start. OFF by default: it is the strongest of these
        horn     = true,     -- a short honk, to find it in a car park
        alarm    = false,    -- the full alarm, for the same reason and louder
    },

    -- The underglow palette the app offers. `name` is shown, `rgb` is what is applied.
    neonColours = {
        { name = 'White',   rgb = { 255, 255, 255 } },
        { name = 'Red',     rgb = { 255, 45, 85 } },
        { name = 'Orange',  rgb = { 255, 149, 0 } },
        { name = 'Yellow',  rgb = { 255, 214, 10 } },
        { name = 'Green',   rgb = { 52, 199, 89 } },
        { name = 'Cyan',    rgb = { 90, 200, 250 } },
        { name = 'Blue',    rgb = { 10, 132, 255 } },
        { name = 'Purple',  rgb = { 175, 82, 222 } },
        { name = 'Pink',    rgb = { 255, 55, 175 } },
    },

    -- Write a neon change to the vehicle's state bag so it survives the vehicle being
    -- re-created. Off by default: on a server running a mechanic script, that script owns
    -- what a build looks like, and two writers of the same value is one too many.
    persist = false,

    -- Log every remote command to the server console. A car that unlocks itself is worth
    -- being able to explain.
    log = false,
}

-- ══════════════════════════════════════════════════════════════
--  FRUITSTORE  (apps you add, free or paid)
-- ══════════════════════════════════════════════════════════════
-- Your own apps in the store, without writing a resource.
--
-- Anything listed here appears in FruitStore alongside the built-in apps. Give it a `page`
-- and the phone frames that URL as the app; leave it out and it is a listing for something
-- your own resource draws (see DEVELOPERS.md for a real drop-in app).
--
-- **Paid apps.** Set a `price` and the phone charges for it once, the first time it is
-- installed. What is bought is remembered against the character, so removing the app and
-- installing it again later is free - a player pays for an app, not for a download.
--
-- The charge goes through `Bridge.RemoveMoney`, which handles qb-core, qbx_core and ESX
-- directly and ox through its money item. **It fails closed:** if the debit cannot be
-- confirmed, the app is not granted. On any other money script, wire
-- `Config.Compat.hooks.removeMoney` and it is used instead.
Config.StoreApps = {
    -- {
    --     id = 'taxi_meter',              -- unique, [a-z0-9_-]
    --     label = 'Taxi Meter',           -- shown as-is, or a locale key like 'app.taxi'
    --     icon = 'car',                   -- any icon the phone ships
    --     accent = '#FFD60A',             -- the tint on its store page
    --     developer = 'Downtown Cab Co.', -- who "made" it, in character
    --     description = 'Fares, distance and a running total for the shift.',
    --     category = 'work',              -- one of Config.Categories
    --
    --     price = 250,                    -- 0 or nil for a free app
    --     account = 'bank',               -- 'bank' (default) or 'cash'
    --
    --     job = nil,                      -- restrict to one job, or a list: { 'taxi' }
    --     page = 'https://my-server.tld/taxi/index.html',   -- optional: framed as the app
    --
    --     features = { 'Live fare', 'Shift total' },
    --     permissions = { 'Location' },
    --
    --     -- What the store page shows above the description. Up to three.
    --     --
    --     -- Without these the page draws little abstract shapes standing in for a screen -
    --     -- honest placeholders, and they look like placeholders. A recording of the app
    --     -- actually running beats any drawing of one.
    --     --
    --     -- `.webm` and `.mp4` play as a muted, looping, inline clip - a store preview is a
    --     -- silent three-second loop, never something that asks permission. Anything else is
    --     -- treated as a still. Same allowed hosts as every other picture in the phone.
    --     previews = {
    --         'https://your-cdn.tld/taxi-meter/fare.webm',
    --         'https://your-cdn.tld/taxi-meter/shift.png',
    --     },
    -- },
}
