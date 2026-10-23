fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'BGarage'
description 'Garage with NUI: fuel, engine and body status, and in-game location management'
version '1.5.0'

shared_script 'config.lua'
-- Qbox users: uncomment the next line so vehicle mods can be saved and restored through ox_lib
-- shared_script '@ox_lib/init.lua'

client_script 'client.lua'
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua',
}

ui_page 'html/index.html'
files {
    'html/index.html',
    'html/style.css',
    'html/app.js'
}
