fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qb-phone'
author 'vyrriox'
description 'Name holder: gives v-phone the qb-phone export name. All logic lives in v-phone.'
version '1.0.0'

-- Read by v-phone's bridge to tell this apart from the real qb-phone. Without it the bridge
-- would see a started resource called qb-phone, assume the genuine article is running, and
-- stand down - leaving nobody answering at all.
vphone_compat 'yes'

dependencies {
    'v-phone',
}

server_script 'server.lua'
