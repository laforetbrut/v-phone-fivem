fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'v-phone'
author 'vyrriox'
description 'iFruit - a complete iOS 27 style phone for FiveM. Framework agnostic: qb-core, qbx_core, ox_core, ESX or standalone.'
version '1.1.3'
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

    'locales/en.lua',
    'locales/fr.lua',
    'config.lua',
    -- Drop-in apps. `_loader.lua` defines PhoneApp(); the glob after it picks up every
    -- app folder, so adding an app is adding a folder and nothing else.
    'apps/_loader.lua',
    'apps/*/app.lua',
}

client_scripts {
    -- Works out whether the local player is somewhere the phone charges (a property it
    -- has a key to) and reports it up a state bag, per housing script.
    'bridge/client/charging.lua',
    'client/main.lua',
    -- The police forensics terminal: a point on the map and the NUI relays behind it.
    'client/police.lua',
    'apps/*/client.lua',      -- optional, per app folder
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

    'server/main.lua',
    -- Bleeter, Snapmatic and Hush. Player-shared data, which the rest of the phone
    -- avoids, so it keeps its own file.
    'server/social.lua',
    -- Everything another resource is meant to call. Loaded after the app it wraps, so
    -- every export it builds on already exists. See API.md.
    'server/api.lua',
    -- Staff actions and the /phoneadmin command, wrappers over the exports above.
    'server/admin.lua',
    -- The police forensics terminal: session auth and the read callbacks.
    'server/police.lua',
    -- Photo and video hosting through screencapture + a CDN, with auto-deletion.
    'server/media.lua',
    'apps/*/server.lua',      -- optional, per app folder
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
    -- Everything a dropped-in app ships. The page and whatever it loads beside it.
    'apps/*/*.html',
    'apps/*/*.css',
    'apps/*/*.js',
    'apps/*/*.png',
    'apps/*/*.jpg',
    'apps/*/*.jpeg',
    'apps/*/*.webp',
    'apps/*/*.gif',
    'apps/*/*.svg',
    'apps/*/*.json',
    'apps/*/*.woff',
    'apps/*/*.woff2',
    'apps/*/*.mp3',
    'apps/*/*.ogg',
    -- Nested assets are allowed too (images/, fonts/, data/...). Keeping this last means
    -- a complex app still remains a self-contained folder.
    'apps/*/**/*',
}
