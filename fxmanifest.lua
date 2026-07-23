fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'v-phone'
author 'vyrriox'
description 'iFruit - a complete iOS 27 style phone for FiveM. Framework agnostic: qb-core, qbx_core, ox_core, ESX or standalone.'
version '1.0.0'
repository 'https://github.com/laforetbrut/v-phone'

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
    'client/main.lua',
    'apps/*/client.lua',      -- optional, per app folder
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- Framework detection, per-character storage and the integrations every app reads.
    'bridge/server/kv.lua',
    'bridge/server/framework.lua',
    'bridge/server/characters.lua',
    'bridge/server/integrations.lua',

    'server/main.lua',
    -- Bleeter, Snapmatic and Hush. Player-shared data, which the rest of the phone
    -- avoids, so it keeps its own file.
    'server/social.lua',
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
