fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'FreshBan'
description 'Panel de bannissement et de moderation pour FiveM (Fresh&Dev)'
author 'Fresh&Dev'
version '2.0.0'

shared_scripts {
    'config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
}

dependencies {
    'oxmysql',
}
