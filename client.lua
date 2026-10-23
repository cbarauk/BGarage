local locations, blips = {}, {}
local isOpen, currentGarage, lastPrompt = false, nil, nil
local drawing, showZones = false, false
local prepareZone -- defined in the zones section
local tripMetres = 0.0

-- ───────────── fuel integration ─────────────
-- Swap these two functions for ox_fuel / LegacyFuel / your own system if you use one.
local function getFuel(veh)
    local s = Entity(veh).state.fuel
    if s then return s end
    local tank = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fPetrolTankVolume')
    if tank <= 0 then return 100.0 end
    return (GetVehicleFuelLevel(veh) / tank) * 100.0
end

local function setFuel(veh, pct)
    local tank = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fPetrolTankVolume')
    SetVehicleFuelLevel(veh, (pct / 100.0) * (tank > 0 and tank or 65.0))
    Entity(veh).state:set('fuel', pct, true)
end

-- ───────────── vehicle mods (saved on park, restored on drive) ─────────────
local function getProps(veh)
    local ok, props = pcall(function()
        if lib and lib.getVehicleProperties then return lib.getVehicleProperties(veh) end
        if GetResourceState('qb-core') == 'started' then
            return exports['qb-core']:GetCoreObject().Functions.GetVehicleProperties(veh)
        end
        if GetResourceState('es_extended') == 'started' then
            return exports['es_extended']:getSharedObject().Game.GetVehicleProperties(veh)
        end
    end)
    return ok and props or nil
end

local function applyProps(veh, props)
    if type(props) ~= 'table' or not next(props) then return end
    pcall(function()
        if lib and lib.setVehicleProperties then return lib.setVehicleProperties(veh, props) end
        if GetResourceState('qb-core') == 'started' then
            return exports['qb-core']:GetCoreObject().Functions.SetVehicleProperties(veh, props)
        end
        if GetResourceState('es_extended') == 'started' then
            return exports['es_extended']:getSharedObject().Game.SetVehicleProperties(veh, props)
        end
    end)
end

-- Fills in display name and image name from the model (works with names or hashes)
local function labelVehicles(list)
    for _, v in ipairs(list or {}) do
        local hash = type(v.model) == 'number' and v.model or joaat(tostring(v.model or ''))
        local name = GetDisplayNameFromVehicleModel(hash)
        if name and name ~= 'CARNOTFOUND' then
            local text = GetLabelText(name)
            v.label = (text ~= 'NULL' and text) or v.label or name
            v.model = name:lower()
        else
            v.label = v.label or tostring(v.model or 'Unknown')
            v.model = tostring(v.model or 'unknown')
        end
    end
end

-- ───────────── helpers ─────────────
local function clamp(n) return math.max(0, math.min(100, math.floor(n + 0.5))) end
local function trim(s) return (s:gsub('%s+$', ''):gsub('^%s+', '')) end

local function setPrompt(text)
    if text == lastPrompt then return end
    lastPrompt = text
    SendNUIMessage({ action = 'prompt', text = text })
end

local function vehicleInfo(veh)
    local model = GetEntityModel(veh)
    local name = GetDisplayNameFromVehicleModel(model)
    local label = GetLabelText(name)
    return {
        plate  = trim(GetVehicleNumberPlateText(veh)),
        model  = name:lower(),
        modelHash = model, -- the actual entity hash; needed for addon cars whose GXT name differs from their spawn name
        label  = label ~= 'NULL' and label or name,
        fuel   = clamp(getFuel(veh)),
        engine = clamp(GetVehicleEngineHealth(veh) / 10.0),
        body   = clamp(GetVehicleBodyHealth(veh) / 10.0),
        driven = tripMetres / 1609.344,
        props  = getProps(veh),
    }
end

local function refreshBlips()
    for _, b in ipairs(blips) do RemoveBlip(b) end
    blips = {}
    if not Config.Blips then return end
    for _, l in ipairs(locations) do
        local b = AddBlipForCoord(l.coords.x, l.coords.y, l.coords.z)
        SetBlipSprite(b, 357)
        SetBlipScale(b, 0.7)
        SetBlipColour(b, 0)
        SetBlipAsShortRange(b, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(l.name)
        EndTextCommandSetBlipName(b)
        blips[#blips + 1] = b
    end
end

-- ───────────── mileage tracking ─────────────
CreateThread(function()
    while true do
        Wait(1000)
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            tripMetres = tripMetres + GetEntitySpeed(veh)
        end
    end
end)

-- ───────────── locations ─────────────
RegisterNetEvent('bgarage:locations', function(list)
    locations = list
    for _, l in ipairs(locations) do prepareZone(l) end
    refreshBlips()
end)

CreateThread(function()
    Wait(1000)
    TriggerServerEvent('bgarage:requestLocations')
end)

for _, ev in ipairs({ 'QBCore:Client:OnPlayerLoaded', 'esx:playerLoaded', 'qbx_core:client:playerLoaded' }) do
    RegisterNetEvent(ev, function()
        Wait(2000)
        TriggerServerEvent('bgarage:requestLocations')
    end)
end

-- ───────────── zones ─────────────
-- Locations drawn in-game carry a polygon zone. Older locations without one keep using the radius.
function prepareZone(l)
    local z = l.zone
    if not z or z.bb then return end
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(z.points) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
    end
    z.bb = { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

local function inPoly(px, py, pts)
    local inside, j = false, #pts
    for i = 1, #pts do
        local a, b = pts[i], pts[j]
        if (a.y > py) ~= (b.y > py) and px < (b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x then
            inside = not inside
        end
        j = i
    end
    return inside
end

local function inLocation(pos, l)
    local z = l.zone
    if not z then
        return #(pos - vec3(l.coords.x, l.coords.y, l.coords.z)) <= Config.InteractRadius
    end
    if pos.z < z.minZ or pos.z > z.maxZ then return false end
    local bb = z.bb
    if pos.x < bb.minX or pos.x > bb.maxX or pos.y < bb.minY or pos.y > bb.maxY then return false end
    return inPoly(pos.x, pos.y, z.points)
end

local function nearestLocation(pos)
    for _, l in ipairs(locations) do
        if inLocation(pos, l) then return l end
    end
end

-- ───────────── zone drawing (admin) ─────────────
local function drawZone(points, minZ, maxZ, r, g, b, closed)
    local n = #points
    for i = 1, n do
        local a = points[i]
        local c = points[i % n + 1]
        if closed or i < n then
            DrawLine(a.x, a.y, minZ, c.x, c.y, minZ, r, g, b, 255)
            DrawLine(a.x, a.y, maxZ, c.x, c.y, maxZ, r, g, b, 255)
            DrawPoly(a.x, a.y, minZ, c.x, c.y, minZ, a.x, a.y, maxZ, r, g, b, 60)
            DrawPoly(a.x, a.y, maxZ, c.x, c.y, minZ, c.x, c.y, maxZ, r, g, b, 60)
            DrawPoly(a.x, a.y, maxZ, c.x, c.y, minZ, a.x, a.y, minZ, r, g, b, 60)
            DrawPoly(c.x, c.y, maxZ, c.x, c.y, minZ, a.x, a.y, maxZ, r, g, b, 60)
        end
        DrawLine(a.x, a.y, minZ, a.x, a.y, maxZ, r, g, b, 255)
    end
end

local function helpText(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, false, -1)
end

-- A drive-out bay: a ring on the ground, a line showing the way the car will face, and its number
local function drawBay(s, n, r, g, b)
    DrawMarker(1, s.x, s.y, s.z, 0, 0, 0, 0, 0, 0, 2.0, 2.0, 0.6, r, g, b, 150, false, false, 2, false, nil, nil, false)
    local h = math.rad(s.w)
    DrawLine(s.x, s.y, s.z + 0.4, s.x - math.sin(h) * 2.5, s.y + math.cos(h) * 2.5, s.z + 0.4, r, g, b, 255)
    local on, sx, sy = GetScreenCoordFromWorldCoord(s.x, s.y, s.z + 1.2)
    if on then
        SetTextScale(0.35, 0.35)
        SetTextFont(4)
        SetTextCentre(true)
        SetTextOutline()
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName('Bay ' .. n)
        EndTextCommandDisplayText(sx, sy)
    end
end

-- Where the admin is aiming (world hit under the crosshair), or their feet if nothing is hit
local function aimPoint()
    local ped = PlayerPedId()
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local cx = math.abs(math.cos(rx))
    local dir = vec3(-math.sin(rz) * cx, math.cos(rz) * cx, math.sin(rx))
    local dest = cam + dir * 40.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z, dest.x, dest.y, dest.z, 1, ped, 4)
    local _, hit, hitPos = GetShapeTestResult(ray)
    if hit == 1 then return hitPos end
    local p = GetEntityCoords(ped)
    return vec3(p.x, p.y, p.z - 1.0)
end

local DRAW_KEYS = { 24, 25, 37, 44, 140, 141, 142, 257, 263, 264 } -- attack, aim, weapon wheel, cover, melee

-- Place one or more drive-out bays by standing in each and pressing E. Blocks until finished.
-- `existing` pre-loads bays so an admin can add to them. Returns the list, or nil if cancelled.
local function collectSpawns(points, minZ, maxZ, existing)
    local spawns = {}
    for _, s in ipairs(existing or {}) do spawns[#spawns + 1] = { x = s.x + 0.0, y = s.y + 0.0, z = s.z + 0.0, w = s.w + 0.0 } end
    local max = Config.MaxSpawns or 8

    while drawing do
        Wait(0)
        for _, k in ipairs(DRAW_KEYS) do DisableControlAction(0, k, true) end
        helpText(('Bays: %d/%d. Stand in a bay, facing the way the car should point.~n~~INPUT_PICKUP~ Add bay  ~INPUT_FRONTEND_RRIGHT~ Undo last  ~INPUT_FRONTEND_ACCEPT~ Finish  ~INPUT_VEH_DUCK~ Cancel'):format(#spawns, max))
        if points then drawZone(points, minZ, maxZ, 80, 200, 120, true) end
        for i, s in ipairs(spawns) do drawBay(s, i, 80, 200, 120) end

        local ped = PlayerPedId()
        local p = GetEntityCoords(ped)
        DrawMarker(1, p.x, p.y, p.z - 1.0, 0, 0, 0, 0, 0, 0, 2.0, 2.0, 0.6, 255, 190, 60, 150, false, false, 2, false, nil, nil, false)

        if IsControlJustPressed(0, 38) then
            if #spawns >= max then
                TriggerEvent('bgarage:notify', ('Maximum of %d bays.'):format(max), 'error')
            else
                spawns[#spawns + 1] = { x = p.x + 0.0, y = p.y + 0.0, z = p.z - 1.0, w = GetEntityHeading(ped) + 0.0 }
            end
        elseif IsControlJustPressed(0, 194) and #spawns > 0 then
            spawns[#spawns] = nil
        elseif IsControlJustPressed(0, 191) then
            if #spawns < 1 then
                TriggerEvent('bgarage:notify', 'Place at least 1 bay.', 'error')
            else
                return spawns
            end
        elseif IsControlJustPressed(0, 73) then
            return nil
        end
    end
    return nil -- resource stopped mid-draw
end

-- Step 1: click the corners of the drop-off area. Step 2: stand in each drive-out bay and press E.
-- Calls onDone(zone, spawns) when finished, or onDone(nil) if cancelled.
local function startDrawing(onDone)
    if drawing then return end
    drawing = true
    local points, spawns = {}, nil
    local result, minZ, maxZ

    CreateThread(function()
        while drawing do
            Wait(0)
            for _, k in ipairs(DRAW_KEYS) do DisableControlAction(0, k, true) end
            local aim = aimPoint()

            if #points == 0 then
                helpText('~INPUT_PICKUP~ Add first corner  ~INPUT_VEH_DUCK~ Cancel')
            else
                helpText(('Corners: %d (min 3)  ~INPUT_PICKUP~ Add corner  ~INPUT_FRONTEND_RRIGHT~ Undo  ~INPUT_FRONTEND_ACCEPT~ Finish  ~INPUT_VEH_DUCK~ Cancel'):format(#points))
            end

            DrawMarker(28, aim.x, aim.y, aim.z, 0, 0, 0, 0, 0, 0, 0.25, 0.25, 0.25, 255, 255, 255, 180, false, false, 2, false, nil, nil, false)

            if #points > 0 then
                local lo, hi = math.huge, -math.huge
                for _, p in ipairs(points) do lo, hi = math.min(lo, p.z), math.max(hi, p.z) end
                lo, hi = lo - 0.2, hi + 2.5
                local preview = { table.unpack(points) }
                preview[#preview + 1] = { x = aim.x, y = aim.y, z = aim.z }
                drawZone(preview, lo, hi, 80, 200, 120, #preview >= 3)
            end

            if IsControlJustPressed(0, 38) then
                points[#points + 1] = { x = aim.x + 0.0, y = aim.y + 0.0, z = aim.z + 0.0 }
            elseif IsControlJustPressed(0, 194) and #points > 0 then
                points[#points] = nil
            elseif IsControlJustPressed(0, 191) then
                if #points < 3 then
                    TriggerEvent('bgarage:notify', 'Place at least 3 corners.', 'error')
                elseif #points > 32 then
                    TriggerEvent('bgarage:notify', 'Too many corners (max 32).', 'error')
                else
                    break
                end
            elseif IsControlJustPressed(0, 73) then
                result = 'cancel'
                break
            end
        end

        if not drawing then result = 'cancel' end -- resource stopped mid-draw

        if result ~= 'cancel' then
            -- Step 2: drive-out bays = where the admin stands, facing the way each car should point
            local lo, hi = math.huge, -math.huge
            for _, p in ipairs(points) do lo, hi = math.min(lo, p.z), math.max(hi, p.z) end
            minZ, maxZ = lo - 1.0, hi + 3.5
            spawns = collectSpawns(points, minZ, maxZ)
            if not spawns then result = 'cancel' end
        end

        drawing = false
        if result == 'cancel' then
            TriggerEvent('bgarage:notify', 'Drawing cancelled.', 'info')
            return onDone(nil)
        end
        onDone({ points = points, minZ = minZ, maxZ = maxZ }, spawns)
    end)
end

-- Edit only the drive-out bays of an existing location (its zone, if any, is shown for reference)
local function startSpawnEdit(loc, onDone)
    if drawing then return end
    drawing = true
    CreateThread(function()
        local z = loc.zone
        local existing = loc.spawns or (loc.spawn and { loc.spawn }) or {}
        local spawns = collectSpawns(z and z.points, z and z.minZ, z and z.maxZ, existing)
        drawing = false
        if not spawns then
            return TriggerEvent('bgarage:notify', 'Bay editing cancelled.', 'info')
        end
        onDone(spawns)
    end)
end

-- Admin helper: /garagezones shows every zone in the world
RegisterCommand('garagezones', function()
    showZones = not showZones
    TriggerEvent('bgarage:notify', showZones and 'Garage zones shown.' or 'Garage zones hidden.', 'info')
end, false)

CreateThread(function()
    while true do
        if showZones then
            Wait(0)
            for _, l in ipairs(locations) do
                if l.zone then drawZone(l.zone.points, l.zone.minZ, l.zone.maxZ, 80, 160, 255, true) end
                for i, s in ipairs(l.spawns or (l.spawn and { l.spawn }) or {}) do drawBay(s, i, 80, 160, 255) end
            end
        else
            Wait(500)
        end
    end
end)

-- ───────────── interaction loop ─────────────
CreateThread(function()
    while true do
        local sleep = 300
        if not isOpen and not drawing then
            local ped = PlayerPedId()
            local loc = nearestLocation(GetEntityCoords(ped))
            if loc then
                sleep = 0
                local veh = GetVehiclePedIsIn(ped, false)
                local driving = veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped
                if driving then
                    setPrompt('Park vehicle')
                    if IsControlJustReleased(0, 38) then
                        TriggerServerEvent('bgarage:park', vehicleInfo(veh), loc.id)
                    end
                else
                    setPrompt('Open garage')
                    if IsControlJustReleased(0, 38) then
                        TriggerServerEvent('bgarage:getData', loc.id)
                    end
                end
            else
                setPrompt(nil)
            end
        else
            setPrompt(nil)
        end
        Wait(sleep)
    end
end)

-- ───────────── open / close ─────────────
RegisterNetEvent('bgarage:open', function(data)
    labelVehicles(data.vehicles)
    isOpen, currentGarage = true, data.garage.id
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', data = data })
end)

RegisterNetEvent('bgarage:update', function(data)
    if not isOpen then return end
    labelVehicles(data.vehicles)
    currentGarage = data.garage and data.garage.id or currentGarage
    SendNUIMessage({ action = 'update', data = data })
end)

-- Admin menu (/bgarage manage): the manage dialog on its own, with no garage open
RegisterNetEvent('bgarage:openManage', function(data)
    if isOpen or drawing then return end
    isOpen, currentGarage = true, nil
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'manage', data = data })
end)

RegisterNetEvent('bgarage:notify', function(msg, kind)
    SendNUIMessage({ action = 'toast', text = msg, kind = kind })
end)

local function close()
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNUICallback('close', function(_, cb) close() cb('ok') end)

-- ───────────── vehicle actions ─────────────
RegisterNUICallback('drive', function(d, cb)
    TriggerServerEvent('bgarage:drive', d.plate, currentGarage)
    cb('ok')
end)

RegisterNUICallback('trunk', function(d, cb)
    TriggerServerEvent('bgarage:getTrunk', d.plate)
    cb('ok')
end)

RegisterNetEvent('bgarage:trunk', function(data)
    if not isOpen then return end
    SendNUIMessage({ action = 'trunk', data = data })
end)

RegisterNUICallback('favourite', function(d, cb)
    TriggerServerEvent('bgarage:favourite', d.plate, currentGarage)
    cb('ok')
end)

RegisterNUICallback('transfer', function(d, cb)
    TriggerServerEvent('bgarage:transfer', d.plate, d.to, currentGarage, d.label)
    cb('ok')
end)

RegisterNUICallback('recover', function(d, cb)
    TriggerServerEvent('bgarage:recover', d.plate, currentGarage)
    cb('ok')
end)

RegisterNetEvent('bgarage:spawn', function(v, spawn, props)
    close()
    -- Prefer the model hash from props (saved by qb-core/ox_lib), which is the actual entity hash.
    -- This matters for addon cars: their GXT name (stored in the DB's vehicle column) may differ
    -- from their spawn name, so joaat(v.model) would fail. The hash in props.model is always correct.
    local hash
    if type(props) == 'table' and type(props.model) == 'number' then
        hash = props.model
    elseif type(v.model) == 'number' then
        hash = v.model
    else
        hash = joaat(v.model)
    end
    RequestModel(hash)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < timeout do Wait(0) end
    if not HasModelLoaded(hash) then return end

    local veh = CreateVehicle(hash, spawn.x, spawn.y, spawn.z, spawn.w, true, false)
    applyProps(veh, props)
    SetVehicleNumberPlateText(veh, v.plate)
    SetVehicleOnGroundProperly(veh)
    SetVehicleEngineHealth(veh, v.engine * 10.0)
    SetVehicleBodyHealth(veh, v.body * 10.0)
    setFuel(veh, v.fuel)
    tripMetres = 0.0
    SetPedIntoVehicle(PlayerPedId(), veh, -1)
    SetModelAsNoLongerNeeded(hash)
end)

RegisterNetEvent('bgarage:parked', function()
    tripMetres = 0.0
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return end
    TaskLeaveVehicle(ped, veh, 0)
    Wait(1200)
    SetEntityAsMissionEntity(veh, true, true)
    DeleteVehicle(veh)
end)

-- ───────────── location management ─────────────
RegisterNUICallback('addLocation', function(d, cb)
    local garageId = currentGarage
    close()
    cb('ok')
    startDrawing(function(zone, spawns)
        if not zone then return end
        TriggerServerEvent('bgarage:addLocation', {
            name = d.name,
            slots = d.slots,
            private = d.private,
            zone = zone,
            spawns = spawns,
        }, garageId)
    end)
end)

RegisterNUICallback('redrawLocation', function(d, cb)
    local garageId = currentGarage
    close()
    cb('ok')
    startDrawing(function(zone, spawns)
        if not zone then return end
        TriggerServerEvent('bgarage:redrawLocation', d.id, zone, spawns, garageId)
    end)
end)

RegisterNUICallback('editSpawns', function(d, cb)
    local garageId = currentGarage
    local loc
    for _, l in ipairs(locations) do if l.id == d.id then loc = l break end end
    loc = loc or d.loc -- admin menu lists private locations this client was not sent
    close()
    cb('ok')
    if not loc then return end
    startSpawnEdit(loc, function(spawns)
        TriggerServerEvent('bgarage:setSpawns', d.id, spawns, garageId)
    end)
end)

RegisterNUICallback('deleteLocation', function(d, cb)
    TriggerServerEvent('bgarage:deleteLocation', d.id, currentGarage)
    cb('ok')
end)

RegisterNUICallback('waypoint', function(d, cb)
    SetNewWaypoint(d.x + 0.0, d.y + 0.0)
    SendNUIMessage({ action = 'toast', text = 'Waypoint set.', kind = 'success' })
    cb('ok')
end)

-- ───────────── commands ─────────────
RegisterCommand('addveh', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return TriggerEvent('bgarage:notify', 'Sit in a vehicle first.', 'error') end
    TriggerServerEvent('bgarage:register', vehicleInfo(veh))
end, false)

RegisterCommand('bgarage', function(_, args)
    if (args[1] or ''):lower() == 'manage' then
        if isOpen or drawing then return end
        TriggerServerEvent('bgarage:openManage') -- the server checks the admin permission
    else
        TriggerEvent('bgarage:notify', 'Usage: /bgarage manage', 'info')
    end
end, false)

CreateThread(function()
    Wait(2000)
    TriggerEvent('chat:addSuggestion', '/bgarage', 'BGarage commands', {
        { name = 'manage', help = 'Open the garage management menu (admins)' },
    })
    TriggerEvent('chat:addSuggestion', '/addveh', 'Register the vehicle you are sitting in as yours', {
        { name = '—', help = 'Standalone: anyone. QB/ESX: requires bgarage.manage ace (admin). Useful for addon cars not bought through a dealership.' },
    })
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    drawing = false
    SetNuiFocus(false, false)
    for _, b in ipairs(blips) do RemoveBlip(b) end
    TriggerEvent('chat:removeSuggestion', '/bgarage')
end)
