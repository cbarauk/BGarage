local RES = GetCurrentResourceName()
local standalone, meta, locations = {}, {}, {}
local QBCore, ESX, cached

-- ───────────── storage (JSON) ─────────────
local function load(file, default)
    local raw = LoadResourceFile(RES, file)
    if raw and raw ~= '' then
        local ok, data = pcall(json.decode, raw)
        if ok and data then return data end
    end
    return default
end

local function save(file, data)
    SaveResourceFile(RES, file, json.encode(data, { indent = true }), -1)
end

-- ───────────── custom thumbnails ─────────────
-- Reads data/thumbnails.json, a map of { ["model_name"] = "https://image-url", ... }
-- that overrides the default docs.fivem.net vehicle thumbnails. Useful for addon
-- cars that have no docs.fivem.net entry. The file is re-read on every garage open
-- so edits take effect live — no resource restart needed.
-- Keys are matched case-insensitively against the vehicle's model name.
local function loadThumbnails()
    local raw = LoadResourceFile(RES, 'data/thumbnails.json')
    if not raw or raw == '' then return {} end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then return {} end
    -- Normalise keys to lowercase so lookups are case-insensitive.
    local out = {}
    for k, v in pairs(data) do
        if type(k) == 'string' and type(v) == 'string' and v ~= '' then
            out[k:lower()] = v
        end
    end
    return out
end

local function seed()
    standalone = load('data/vehicles.json', {})
    meta       = load('data/meta.json', {})
    locations  = load('data/locations.json', nil)
    if not locations then
        locations = {}
        for i, l in ipairs(Config.DefaultLocations) do
            l.id = i
            locations[#locations + 1] = l
        end
        save('data/locations.json', locations)
    end
end

-- ───────────── framework bridge ─────────────
local function fw()
    if cached then return cached end
    local f = Config.Framework
    if f == 'auto' then
        if GetResourceState('qbx_core') == 'started' then f = 'qbox'
        elseif GetResourceState('qb-core') == 'started' then f = 'qb'
        elseif GetResourceState('es_extended') == 'started' then f = 'esx'
        else return 'standalone' end -- framework may not be running yet, so do not cache
    end
    cached = f
    print(('[BGarage] Using framework: %s'):format(f))
    return f
end

-- Unique id of the player's character
local function ident(src)
    if not src then return nil end
    local f = fw()
    if f == 'qb' then
        QBCore = QBCore or exports['qb-core']:GetCoreObject()
        local p = QBCore.Functions.GetPlayer(src)
        return p and p.PlayerData.citizenid
    elseif f == 'qbox' then
        local p = exports.qbx_core:GetPlayer(src)
        return p and p.PlayerData.citizenid
    elseif f == 'esx' then
        ESX = ESX or exports['es_extended']:getSharedObject()
        local p = ESX.GetPlayerFromId(src)
        return p and p.identifier
    end
    return GetPlayerIdentifierByType(src, 'license')
end

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local function clamp(n) return math.max(0, math.min(100, math.floor((tonumber(n) or 0) + 0.5))) end
local function notify(src, msg, kind) TriggerClientEvent('bgarage:notify', src, msg, kind or 'info') end

local function isQB() local f = fw() return f == 'qb' or f == 'qbox' end

-- Every vehicle the character owns, in one shape whatever the framework
local function listOwned(id)
    local out, f = {}, fw()
    if not id then return out end

    if isQB() then
        local rows = MySQL.query.await(
            ('SELECT plate, vehicle, fuel, engine, body, state, garage FROM `%s` WHERE citizenid = ?'):format(Config.QBTable), { id }) or {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                plate = trim(r.plate), model = r.vehicle,
                fuel = clamp(r.fuel or 100), engine = clamp((r.engine or 1000) / 10), body = clamp((r.body or 1000) / 10),
                state = (r.state == 1 and 'stored') or (r.state == 2 and 'impounded') or 'out',
                dbGarage = r.garage,
            }
        end
    elseif f == 'esx' then
        local rows = MySQL.query.await(
            ('SELECT plate, vehicle, stored FROM `%s` WHERE owner = ?'):format(Config.ESXTable), { id }) or {}
        for _, r in ipairs(rows) do
            local p = json.decode(r.vehicle or '{}') or {}
            out[#out + 1] = {
                plate = trim(r.plate), model = p.model,
                fuel = clamp(p.fuelLevel or 100), engine = clamp((p.engineHealth or 1000) / 10), body = clamp((p.bodyHealth or 1000) / 10),
                state = (r.stored == 1 or r.stored == true) and 'stored' or 'out',
            }
        end
    else
        for _, v in ipairs(standalone[id] or {}) do
            out[#out + 1] = { plate = v.plate, model = v.model, label = v.label, fuel = v.fuel, engine = v.engine, body = v.body, state = v.state }
        end
    end
    return out
end

-- ───────────── locations ─────────────
local function findLocation(id)
    for _, l in ipairs(locations) do if l.id == id then return l end end
end

local function locationByName(name)
    if not name or name == '' then return nil end
    for _, l in ipairs(locations) do
        if l.name:lower() == tostring(name):lower() then return l.id end
    end
end

local function hasAccess(l, id) return not l.private or l.owner == id end

-- A location can have several drive-out bays. Older data only has a single `spawn`.
local function spawnsOf(l)
    if type(l.spawns) == 'table' and #l.spawns > 0 then return l.spawns end
    if l.spawn then return { l.spawn } end
    return {}
end

-- Bays are reserved the moment a car is pulled out, so two players pulling at the same time
-- get different bays even before the first vehicle has finished spawning.
local reserved = {}

local function pickSpawn(l)
    local now = GetGameTimer()
    local taken = {}
    local ok, vehs = pcall(GetAllVehicles) -- needs OneSync; without it only the reservation protects a bay
    if ok and type(vehs) == 'table' then
        for _, e in ipairs(vehs) do
            if DoesEntityExist(e) then taken[#taken + 1] = GetEntityCoords(e) end
        end
    end
    local r = Config.SpawnClearRadius or 2.5
    for i, sp in ipairs(spawnsOf(l)) do
        local key = ('%s:%s'):format(l.id, i)
        if not (reserved[key] and reserved[key] > now) then
            local clear = true
            for _, c in ipairs(taken) do
                local dx, dy = sp.x - c.x, sp.y - c.y
                if (dx * dx + dy * dy) < r * r and math.abs(sp.z - c.z) < 3.0 then clear = false break end
            end
            if clear then
                reserved[key] = now + (Config.SpawnReserveMs or 6000)
                return sp
            end
        end
    end
end

local function describe(l)
    return { id = l.id, name = l.name, slots = l.slots, private = l.private, coords = l.coords, spawn = spawnsOf(l)[1], spawns = spawnsOf(l), zone = l.zone }
end

local function visibleLocations(id)
    local out = {}
    for _, l in ipairs(locations) do
        if hasAccess(l, id) then out[#out + 1] = describe(l) end
    end
    return out
end

-- Used by the admin menu (/bgarage manage): admins see every location, private ones included
local function allLocations()
    local out = {}
    for _, l in ipairs(locations) do out[#out + 1] = describe(l) end
    return out
end

local function transferInfo()
    return { enabled = Config.AllowTransfers ~= false, fee = math.max(0, math.floor(tonumber(Config.TransferFee) or 0)) }
end

local function recoverInfo()
    return { enabled = Config.AllowRecover ~= false, fee = math.max(0, math.floor(tonumber(Config.RecoverFee) or 0)) }
end

-- Validates what the client sends so a bad payload can never be saved
local function num(v) v = tonumber(v) if v and v == v and v > -1e6 and v < 1e6 then return v end end

local function cleanZone(z)
    if type(z) ~= 'table' or type(z.points) ~= 'table' or #z.points < 3 or #z.points > 32 then return end
    local pts = {}
    for _, p in ipairs(z.points) do
        local x, y = type(p) == 'table' and num(p.x), type(p) == 'table' and num(p.y)
        if not x or not y then return end
        pts[#pts + 1] = { x = x, y = y }
    end
    local minZ, maxZ = num(z.minZ), num(z.maxZ)
    if not minZ or not maxZ or maxZ <= minZ then return end
    return { points = pts, minZ = minZ, maxZ = maxZ }
end

local function cleanSpawn(p)
    if type(p) ~= 'table' then return end
    local x, y, z, w = num(p.x), num(p.y), num(p.z), num(p.w)
    if not (x and y and z and w) then return end
    return { x = x, y = y, z = z, w = w }
end

local function cleanSpawns(list)
    if type(list) ~= 'table' or #list < 1 or #list > (Config.MaxSpawns or 8) then return end
    local out = {}
    for _, p in ipairs(list) do
        local s = cleanSpawn(p)
        if not s then return end
        out[#out + 1] = s
    end
    return out
end

-- Centre of the zone, used for the map blip and waypoint
local function zoneCentre(zone, w)
    local sx, sy = 0, 0
    for _, p in ipairs(zone.points) do sx, sy = sx + p.x, sy + p.y end
    return { x = sx / #zone.points, y = sy / #zone.points, z = zone.minZ + 1.0, w = w or 0.0 }
end

local function canManage(src) return not Config.AdminOnly or IsPlayerAceAllowed(src, 'bgarage.manage') end

-- Adds favourite, mileage, the cached display label, and which BGarage location each stored vehicle belongs to
local function decorate(list)
    for _, v in ipairs(list) do
        local m = meta[v.plate] or {}
        v.favourite = m.favourite == true
        v.mileage = m.mileage or 0
        v.label = v.label or m.label -- QB/ESX have no label column; use the one cached from the last park
        if v.state == 'stored' then
            v.garage = (m.garage and findLocation(m.garage) and m.garage)
                or locationByName(v.dbGarage)
                or (locations[1] and locations[1].id)
        end
    end
    return list
end

local function owned(id) return decorate(listOwned(id)) end

local function find(list, plate)
    for _, v in ipairs(list) do if v.plate == plate then return v end end
end

local function payload(src, garageId)
    local id = ident(src)
    local admin = canManage(src)
    return {
        garage    = findLocation(garageId),
        -- no garage open means the admin menu, which lists every location
        garages   = (not garageId and admin) and allLocations() or visibleLocations(id),
        vehicles  = owned(id),
        canManage = admin,
        transfer  = transferInfo(),
        recover   = recoverInfo(),
        thumbnails = loadThumbnails(),
    }
end

local function refresh(src, garageId) TriggerClientEvent('bgarage:update', src, payload(src, garageId)) end

local function broadcastLocations()
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        TriggerClientEvent('bgarage:locations', src, visibleLocations(ident(src)))
    end
end

local function saveMeta() save('data/meta.json', meta) end

-- ───────────── writes back to the framework ─────────────
local function persistPark(id, v, l, data)
    local f = fw()
    if isQB() then
        local sql = ('UPDATE `%s` SET state = 1, garage = ?, fuel = ?, engine = ?, body = ?%s WHERE TRIM(plate) = ? AND citizenid = ?')
            :format(Config.QBTable, type(data.props) == 'table' and ', mods = ?' or '')
        local args = { l.name, data.fuel, data.engine * 10, data.body * 10 }
        if type(data.props) == 'table' then args[#args + 1] = json.encode(data.props) end
        args[#args + 1] = v.plate
        args[#args + 1] = id
        MySQL.update.await(sql, args)
    elseif f == 'esx' then
        local row = MySQL.single.await(('SELECT vehicle FROM `%s` WHERE TRIM(plate) = ? AND owner = ?'):format(Config.ESXTable), { v.plate, id })
        local existing = row and json.decode(row.vehicle or '{}') or {}
        local obj = type(data.props) == 'table' and data.props or existing
        obj.plate, obj.model = existing.plate or obj.plate, existing.model or obj.model
        obj.fuelLevel, obj.engineHealth, obj.bodyHealth = data.fuel + 0.0, data.engine * 10.0, data.body * 10.0
        MySQL.update.await(('UPDATE `%s` SET stored = 1, vehicle = ? WHERE TRIM(plate) = ? AND owner = ?'):format(Config.ESXTable),
            { json.encode(obj), v.plate, id })
    else
        for _, r in ipairs(standalone[id] or {}) do
            if r.plate == v.plate then
                r.fuel, r.engine, r.body, r.state = data.fuel, data.engine, data.body, 'stored'
            end
        end
        save('data/vehicles.json', standalone)
    end
end

-- Marks the vehicle as out and returns its saved mods, if the framework keeps them
local function persistOut(id, plate)
    local f = fw()
    if isQB() then
        local row = MySQL.single.await(('SELECT mods FROM `%s` WHERE TRIM(plate) = ? AND citizenid = ?'):format(Config.QBTable), { plate, id })
        MySQL.update.await(('UPDATE `%s` SET state = 0 WHERE TRIM(plate) = ? AND citizenid = ?'):format(Config.QBTable), { plate, id })
        return row and json.decode(row.mods or '{}') or nil
    elseif f == 'esx' then
        local row = MySQL.single.await(('SELECT vehicle FROM `%s` WHERE TRIM(plate) = ? AND owner = ?'):format(Config.ESXTable), { plate, id })
        MySQL.update.await(('UPDATE `%s` SET stored = 0 WHERE TRIM(plate) = ? AND owner = ?'):format(Config.ESXTable), { plate, id })
        return row and json.decode(row.vehicle or '{}') or nil
    end
    for _, r in ipairs(standalone[id] or {}) do if r.plate == plate then r.state = 'out' end end
    save('data/vehicles.json', standalone)
end

-- Takes money from the player. Returns true if it was paid (or there is nothing to pay).
-- `account` defaults to Config.TransferAccount. Recover uses Config.RecoverAccount.
local function charge(src, amount, reason, account)
    if amount <= 0 then return true end
    account = account or Config.TransferAccount or 'bank'
    local f = fw()
    if f == 'qb' then
        QBCore = QBCore or exports['qb-core']:GetCoreObject()
        local p = QBCore.Functions.GetPlayer(src)
        return p ~= nil and p.Functions.RemoveMoney(account, amount, reason) == true
    elseif f == 'qbox' then
        local p = exports.qbx_core:GetPlayer(src)
        return p ~= nil and p.Functions.RemoveMoney(account, amount, reason) == true
    elseif f == 'esx' then
        ESX = ESX or exports['es_extended']:getSharedObject()
        local p = ESX.GetPlayerFromId(src)
        if not p then return false end
        if account == 'cash' then account = 'money' end
        local acc = p.getAccount(account)
        if not acc or acc.money < amount then return false end
        p.removeAccountMoney(account, amount, reason)
        return true
    end
    return true -- standalone has no money system
end

-- QBCore and Qbox keep the garage name in the database, so keep it in step. ESX and standalone only use meta.
local function persistTransfer(id, v, l)
    if isQB() then
        MySQL.update.await(('UPDATE `%s` SET garage = ? WHERE TRIM(plate) = ? AND citizenid = ?'):format(Config.QBTable), { l.name, v.plate, id })
    end
end

-- ───────────── trunk contents ─────────────
local function inventoryKind()
    local k = Config.Inventory or 'auto'
    if k ~= 'auto' then return k end
    if GetResourceState('ox_inventory') == 'started' then return 'ox' end
    for _, r in ipairs({ 'qb-inventory', 'ps-inventory', 'lj-inventory' }) do
        if GetResourceState(r) == 'started' then return 'qb' end
    end
    return 'none'
end

-- Adds up stacks of the same item and returns a sorted { name, label, count } list
local function mergeItems(raw, labelOf)
    local byName, out = {}, {}
    for _, it in pairs(raw or {}) do
        if type(it) == 'table' and it.name then
            local count = tonumber(it.count or it.amount) or 0
            if count > 0 then
                local key = tostring(it.name):lower()
                local e = byName[key]
                if not e then
                    e = { name = key, label = it.label or (labelOf and labelOf(key)) or tostring(it.name), count = 0 }
                    byName[key] = e
                    out[#out + 1] = e
                end
                e.count = e.count + count
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.label):lower() < tostring(b.label):lower() end)
    while #out > 200 do out[#out] = nil end
    return out
end

local function trunkOx(plate)
    local raw
    -- an inventory that is currently loaded in memory is the freshest copy
    local ok, res = pcall(function() return exports.ox_inventory:GetInventoryItems('trunk' .. plate) end)
    if ok and type(res) == 'table' then raw = res end
    if not raw then
        local row
        pcall(function()
            row = MySQL.single.await(('SELECT data FROM `%s` WHERE TRIM(name) = ? LIMIT 1'):format(Config.OxInventoryTable or 'ox_inventory'), { 'trunk' .. plate })
        end)
        raw = row and row.data and json.decode(row.data) or {}
    end
    return mergeItems(raw, function(name)
        local okItem, item = pcall(function() return exports.ox_inventory:Items(name) end)
        return okItem and type(item) == 'table' and item.label or nil
    end)
end

local function trunkQB(plate)
    local row
    pcall(function()
        row = MySQL.single.await(('SELECT items FROM `%s` WHERE TRIM(identifier) = ? LIMIT 1'):format(Config.QBInventoryTable or 'inventories'), { 'trunk-' .. plate })
    end)
    if not row then
        pcall(function()
            row = MySQL.single.await(('SELECT items FROM `%s` WHERE TRIM(plate) = ? LIMIT 1'):format(Config.QBTrunkTable or 'trunkitems'), { plate })
        end)
    end
    return mergeItems(row and row.items and json.decode(row.items) or {})
end

-- Returns supported, items
local function readTrunk(plate)
    local kind = inventoryKind()
    if kind == 'ox' then return true, trunkOx(plate) end
    if kind == 'qb' then return true, trunkQB(plate) end
    return false, {}
end

-- ───────────── events ─────────────
RegisterNetEvent('bgarage:getData', function(garageId)
    local src = source
    local id = ident(src)
    local l = findLocation(garageId)
    if not l then return end
    if not id then return notify(src, 'Your character is not loaded yet.', 'error') end
    if not hasAccess(l, id) then return notify(src, 'This garage is private.', 'error') end
    TriggerClientEvent('bgarage:open', src, payload(src, garageId))
end)

RegisterNetEvent('bgarage:requestLocations', function()
    local src = source
    TriggerClientEvent('bgarage:locations', src, visibleLocations(ident(src)))
end)

-- Register the vehicle a player is sitting in as theirs.
--   - Standalone: anyone (it's the only way to get ownership).
--   - QB / ESX: admin-only (bgarage.manage ace), because it bypasses the framework's
--     purchase flow. Useful for addon cars that aren't sold through a dealership.
-- The model hash is taken from v.props.model (set by qb-core / ox_lib) with v.modelHash
-- as a fallback, so addon cars whose GXT name differs from their spawn name still spawn.
RegisterNetEvent('bgarage:register', function(v)
    local src = source
    local id = ident(src)
    if not v or not v.plate or not id then return end
    local plate = trim(v.plate)
    local f = fw()

    if f == 'standalone' then
        for _, list in pairs(standalone) do
            for _, r in ipairs(list) do
                if r.plate == plate then return notify(src, 'That vehicle is already registered.', 'error') end
            end
        end
        standalone[id] = standalone[id] or {}
        table.insert(standalone[id], { plate = plate, model = v.model, label = v.label, fuel = v.fuel, engine = v.engine, body = v.body, state = 'out' })
        save('data/vehicles.json', standalone)
        return notify(src, ('%s (%s) registered to you.'):format(v.label or v.model, plate), 'success')
    end

    -- QB and ESX bypass the framework's purchase flow, so require admin
    if not canManage(src) then
        return notify(src, 'Only admins can register vehicles in QB/ESX mode. Buy the vehicle through your dealership instead.', 'error')
    end

    -- Ensure the props table carries the correct model hash for spawning later
    local props = type(v.props) == 'table' and v.props or {}
    if type(props.model) ~= 'number' and type(v.modelHash) == 'number' then
        props.model = v.modelHash
    end

    if isQB() then
        local exists = MySQL.single.await(('SELECT 1 FROM `%s` WHERE TRIM(plate) = ? LIMIT 1'):format(Config.QBTable), { plate })
        if exists then return notify(src, 'That plate is already in the vehicle database.', 'error') end
        MySQL.insert.await(
            ('INSERT INTO `%s` (citizenid, plate, vehicle, fuel, engine, body, state, garage, mods) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)'):format(Config.QBTable),
            { id, plate, v.model, v.fuel, v.engine * 10, v.body * 10, '', json.encode(props) }
        )
    elseif f == 'esx' then
        local exists = MySQL.single.await(('SELECT 1 FROM `%s` WHERE TRIM(plate) = ? LIMIT 1'):format(Config.ESXTable), { plate })
        if exists then return notify(src, 'That plate is already in the vehicle database.', 'error') end
        local obj = props -- ESX stores the whole vehicle blob in one JSON column
        obj.plate = plate
        obj.model = obj.model or v.model
        obj.fuelLevel = v.fuel
        obj.engineHealth = v.engine * 10
        obj.bodyHealth = v.body * 10
        MySQL.insert.await(
            ('INSERT INTO `%s` (owner, plate, vehicle, stored, type) VALUES (?, ?, ?, 0, ?)'):format(Config.ESXTable),
            { id, plate, json.encode(obj), 'car' }
        )
    else
        return notify(src, 'Cannot register vehicles in this framework.', 'error')
    end

    -- cache the label so future lists show the proper name without re-deriving
    if v.label then meta[plate] = meta[plate] or {}; meta[plate].label = v.label; saveMeta() end
    notify(src, ('%s (%s) registered to you.'):format(v.label or v.model, plate), 'success')
end)

RegisterNetEvent('bgarage:park', function(data, garageId)
    local src = source
    local id = ident(src)
    local l = findLocation(garageId)
    if not l or type(data) ~= 'table' or not id then return end

    local list = owned(id)
    local v = find(list, trim(data.plate))
    if not v then return notify(src, 'You do not own this vehicle.', 'error') end
    if v.state == 'impounded' then return notify(src, 'This vehicle is impounded.', 'error') end

    data.fuel, data.engine, data.body = clamp(data.fuel), clamp(data.engine), clamp(data.body)
    persistPark(id, v, l, data)

    local m = meta[v.plate] or {}
    m.garage = garageId
    m.mileage = (m.mileage or 0) + math.max(0, math.min(tonumber(data.driven) or 0, 500))
    if data.label then m.label = data.label end -- cache the display name for next time
    meta[v.plate] = m
    saveMeta()

    TriggerClientEvent('bgarage:parked', src)
    notify(src, ('%s parked at %s.'):format(data.label or v.label or v.model or v.plate, l.name), 'success')
end)

RegisterNetEvent('bgarage:drive', function(plate, garageId)
    local src = source
    local id = ident(src)
    local l = findLocation(garageId)
    if not l or not id then return end

    local v = find(owned(id), plate)
    if not v then return end
    if v.state ~= 'stored' or v.garage ~= garageId then
        return notify(src, 'This vehicle is not parked here.', 'error')
    end

    -- Choose a free bay before touching the database, so a busy garage leaves the car stored
    local spawn = pickSpawn(l)
    if not spawn then
        return notify(src, #spawnsOf(l) == 0 and 'This garage has no drive-out bay set up.'
            or 'All bays are busy. Wait a moment and try again.', 'error')
    end

    local props = persistOut(id, plate)
    if meta[plate] then meta[plate].garage = nil saveMeta() end
    TriggerClientEvent('bgarage:spawn', src, { plate = v.plate, model = v.model, fuel = v.fuel, engine = v.engine, body = v.body }, spawn, props)
end)

RegisterNetEvent('bgarage:transfer', function(plate, toId, garageId, label)
    local src = source
    if Config.AllowTransfers == false then return notify(src, 'Vehicle transfers are disabled.', 'error') end
    local id = ident(src)
    local dest = findLocation(tonumber(toId))
    if not id or not dest then return end
    if not hasAccess(dest, id) then return notify(src, 'That garage is private.', 'error') end

    local list = owned(id)
    local v = find(list, trim(plate))
    if not v then return notify(src, 'You do not own this vehicle.', 'error') end
    if v.state ~= 'stored' then return notify(src, 'Only parked vehicles can be transferred.', 'error') end
    if v.garage == dest.id then return notify(src, 'That vehicle is already parked there.', 'error') end

    local fee = transferInfo().fee
    if not charge(src, fee, 'bgarage-transfer') then
        return notify(src, ('You need $%d to transfer a vehicle.'):format(fee), 'error')
    end

    persistTransfer(id, v, dest)
    local m = meta[v.plate] or {}
    m.garage = dest.id
    if label then m.label = label end -- keep the cache fresh even if it was missing
    meta[v.plate] = m
    saveMeta()

    refresh(src, garageId)
    notify(src, ('%s transferred to %s.'):format(label or v.label or v.model or v.plate, dest.name), 'success')
end)

-- ───────────── vehicle recovery ─────────────
-- Find a loaded world vehicle by plate (OneSync). Returns the entity id, or nil if not loaded.
local function findVehicleByPlate(plate)
    plate = trim(plate)
    if not plate or plate == '' then return nil end
    local ok, vehs = pcall(GetAllVehicles)
    if not ok or type(vehs) ~= 'table' then return nil end
    for _, e in ipairs(vehs) do
        if DoesEntityExist(e) then
            local okp, p = pcall(GetVehicleNumberPlateText, e)
            if okp and p and trim(p) == plate then return e end
        end
    end
end

-- Anti-abuse for recovery: returns true if someone is sitting in the driver seat.
local function isBeingDriven(veh)
    if not veh or not DoesEntityExist(veh) then return false end
    local ok, ped = pcall(GetPedInVehicleSeat, veh, -1)
    return ok and ped and ped ~= 0
end

-- Pay a steep fee to teleport an "Out" vehicle back to the garage you have open.
-- A vehicle being actively driven (someone in the driver seat) cannot be recovered,
-- so a stolen car cannot just be yanked back to the garage mid-RP.
RegisterNetEvent('bgarage:recover', function(plate, garageId)
    local src = source
    if Config.AllowRecover == false then return notify(src, 'Vehicle recovery is disabled.', 'error') end
    local id = ident(src)
    local l = findLocation(garageId)
    if not l or not id then return end
    if not hasAccess(l, id) then return notify(src, 'This garage is private.', 'error') end

    local v = find(owned(id), trim(plate))
    if not v then return notify(src, 'You do not own this vehicle.', 'error') end
    if v.state ~= 'out' then return notify(src, 'Only vehicles that are out can be recovered.', 'error') end

    -- Anti-abuse: if the car exists in the world and someone is driving it, block recovery.
    local veh = findVehicleByPlate(plate)
    if isBeingDriven(veh) then
        return notify(src, 'Someone is driving that vehicle. It cannot be recovered.', 'error')
    end

    local fee = math.max(0, math.floor(tonumber(Config.RecoverFee) or 0))
    if not charge(src, fee, 'bgarage-recover', Config.RecoverAccount or 'bank') then
        return notify(src, ('You need $%d to recover a vehicle.'):format(fee), 'error')
    end

    -- Mark the vehicle as stored at the destination garage (preserves its last saved fuel/engine/body)
    persistPark(id, v, l, { fuel = v.fuel, engine = v.engine, body = v.body })

    local m = meta[v.plate] or {}
    m.garage = garageId
    if v.label then m.label = v.label end
    meta[v.plate] = m
    saveMeta()

    -- If the vehicle exists in the world (parked empty somewhere far away), remove it
    if veh then pcall(DeleteEntity, veh) end

    refresh(src, garageId)
    local feeText = fee > 0 and (' for $%d'):format(fee) or ''
    notify(src, ('%s recovered to %s%s.'):format(v.label or v.model or v.plate, l.name, feeText), 'success')
end)

-- /bgarage manage: opens the location menu for admins without having to stand in a garage
RegisterNetEvent('bgarage:openManage', function()
    local src = source
    if not canManage(src) then return notify(src, 'You do not have permission to manage garages.', 'error') end
    TriggerClientEvent('bgarage:openManage', src, {
        garages = allLocations(), vehicles = {}, canManage = true, transfer = transferInfo(), recover = recoverInfo(), thumbnails = loadThumbnails(),
    })
end)

-- Look inside the trunk of a vehicle you own, whether it is parked, out or impounded
local trunkCooldown = {}
RegisterNetEvent('bgarage:getTrunk', function(plate)
    local src = source
    plate = trim(plate)
    if plate == '' then return end

    local now = GetGameTimer()
    if trunkCooldown[src] and trunkCooldown[src] > now then
        return TriggerClientEvent('bgarage:trunk', src, { plate = plate, error = 'Try again in a moment.' })
    end
    trunkCooldown[src] = now + 400

    local id = ident(src)
    if not id or not find(listOwned(id), plate) then
        return TriggerClientEvent('bgarage:trunk', src, { plate = plate, error = 'You do not own this vehicle.' })
    end

    local supported, items = readTrunk(plate)
    TriggerClientEvent('bgarage:trunk', src, { plate = plate, supported = supported, items = items })
end)

AddEventHandler('playerDropped', function() trunkCooldown[source] = nil end)

RegisterNetEvent('bgarage:favourite', function(plate, garageId)
    local src = source
    local id = ident(src)
    if id and find(listOwned(id), plate) then
        local m = meta[plate] or {}
        m.favourite = not m.favourite
        meta[plate] = m
        saveMeta()
    end
    refresh(src, garageId)
end)

RegisterNetEvent('bgarage:addLocation', function(data, garageId)
    local src = source
    if not canManage(src) then return notify(src, 'You do not have permission to add locations.', 'error') end
    if type(data) ~= 'table' or type(data.name) ~= 'string' or #trim(data.name) < 2 then
        return notify(src, 'Enter a name for the location.', 'error')
    end
    local zone, spawns = cleanZone(data.zone), cleanSpawns(data.spawns or { data.spawn })
    if not zone or not spawns then return notify(src, 'Invalid drop-off area.', 'error') end

    local newId = 0
    for _, l in ipairs(locations) do if l.id > newId then newId = l.id end end
    local name = trim(data.name):sub(1, 32)
    locations[#locations + 1] = {
        id = newId + 1,
        name = name,
        slots = 999999, -- no limit enforced; kept for data-shape compatibility with existing locations.json
        private = data.private == true,
        owner = ident(src),
        coords = zoneCentre(zone, spawns[1].w),
        zone = zone,
        spawn = spawns[1],
        spawns = spawns,
    }
    save('data/locations.json', locations)
    broadcastLocations()
    refresh(src, garageId)
    notify(src, ('Location "%s" added.'):format(name), 'success')
end)

-- Replace the drop-off area and spawn point of an existing location
RegisterNetEvent('bgarage:redrawLocation', function(id, zoneData, spawnsData, garageId)
    local src = source
    if not canManage(src) then return notify(src, 'You do not have permission to edit locations.', 'error') end
    local l = findLocation(id)
    if not l then return end
    local zone, spawns = cleanZone(zoneData), cleanSpawns(spawnsData)
    if not zone or not spawns then return notify(src, 'Invalid drop-off area.', 'error') end
    l.zone, l.spawns, l.spawn, l.coords = zone, spawns, spawns[1], zoneCentre(zone, spawns[1].w)
    save('data/locations.json', locations)
    broadcastLocations()
    refresh(src, garageId)
    notify(src, ('Drop-off area for "%s" updated.'):format(l.name), 'success')
end)

-- Replace just the drive-out bays of a location, leaving its drop-off area alone
RegisterNetEvent('bgarage:setSpawns', function(id, spawnsData, garageId)
    local src = source
    if not canManage(src) then return notify(src, 'You do not have permission to edit locations.', 'error') end
    local l = findLocation(id)
    if not l then return end
    local spawns = cleanSpawns(spawnsData)
    if not spawns then return notify(src, ('A location needs between 1 and %d bays.'):format(Config.MaxSpawns or 8), 'error') end
    l.spawns, l.spawn = spawns, spawns[1]
    save('data/locations.json', locations)
    broadcastLocations()
    refresh(src, garageId)
    notify(src, ('"%s" now has %d drive-out bay(s).'):format(l.name, #spawns), 'success')
end)

RegisterNetEvent('bgarage:deleteLocation', function(id, garageId)
    local src = source
    if not canManage(src) then return notify(src, 'You do not have permission to delete locations.', 'error') end
    for i, l in ipairs(locations) do
        if l.id == id then
            table.remove(locations, i)
            save('data/locations.json', locations)
            broadcastLocations()
            refresh(src, garageId ~= id and garageId or (locations[1] and locations[1].id))
            return notify(src, 'Location deleted.', 'success')
        end
    end
end)

local function grantAces()
    for _, group in ipairs(Config.AutoGrantGroups or {}) do
        ExecuteCommand(('add_ace %s bgarage.manage allow'):format(group))
    end
end

AddEventHandler('onResourceStart', function(res)
    if res == RES then seed() grantAces() end
end)
seed()
grantAces()
