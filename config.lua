Config = {}

-- Which framework owns the player vehicles:
-- 'auto' (detects qbx_core / qb-core / es_extended), 'qb', 'qbox', 'esx' or 'standalone'
Config.Framework = 'auto'

-- Database tables that hold owned vehicles
Config.QBTable  = 'player_vehicles'   -- QBCore and Qbox (citizenid, plate, vehicle, mods, state, garage, fuel, engine, body)
Config.ESXTable = 'owned_vehicles'    -- ESX (owner, plate, vehicle, stored)

-- Vehicles stored by another garage script have no BGarage location yet.
-- They are shown in the first location in the list until they are parked in one of yours.

-- Distance (metres) from the entrance at which the prompt appears.
-- Only used by locations that have no drawn drop-off area (e.g. the default location below).
Config.InteractRadius = 3.0

-- Garage spaces are not limited. The `slots` field is kept on locations only for data-shape
-- compatibility with existing data/locations.json entries; it is never enforced.

-- If true, only players with the ace "bgarage.manage" can add or delete locations.
-- Add to server.cfg:  add_ace group.admin bgarage.manage allow
Config.AdminOnly = true

-- Groups that BGarage grants the "bgarage.manage" ace to automatically when it starts,
-- so you do not need the add_ace line in server.cfg. Set to {} to manage it yourself.
Config.AutoGrantGroups = { 'group.admin' }

-- Drive-out bays: each location can have several spawn points so that people
-- pulling cars out at the same moment never land on top of each other.
Config.MaxSpawns = 8            -- most bays one location can have
Config.SpawnClearRadius = 2.5   -- a bay counts as taken if a vehicle is within this many metres
Config.SpawnReserveMs = 6000    -- a bay is held for this long after someone pulls a car out of it

-- Vehicle transfers: owners can move a parked vehicle from one garage to another from the garage menu.
-- The destination must be a garage they can use.
Config.AllowTransfers = true
Config.TransferFee = 0          -- charged per transfer, 0 = free. Ignored in standalone mode (no money system)
Config.TransferAccount = 'bank' -- 'bank' or 'cash' (QBCore / Qbox); 'bank' or 'money' (ESX)

-- Vehicle recovery: pay to teleport an "Out" vehicle back to the garage you have open.
-- Useful when a vehicle is lost, abandoned or stuck. The fee should be steep to discourage spam.
-- A vehicle being actively driven (someone in the driver seat) cannot be recovered,
-- so a car that was stolen in RP cannot just be yanked back to the garage mid-scene.
Config.AllowRecover = true
Config.RecoverFee = 5000          -- charged per recovery, 0 = free. Ignored in standalone mode (no money system)
Config.RecoverAccount = 'bank'     -- 'bank' or 'cash' (QBCore / Qbox); 'bank' or 'money' (ESX)

-- Trunk contents: which inventory script holds vehicle trunks.
-- 'auto' (detects ox_inventory / qb-inventory / ps-inventory / lj-inventory), 'ox', 'qb' or 'none' (hides the contents).
Config.Inventory = 'auto'
Config.OxInventoryTable = 'ox_inventory'   -- ox_inventory saves trunks here (name = 'trunk' .. plate)
Config.QBInventoryTable = 'inventories'    -- newer qb-inventory (identifier = 'trunk-' .. plate)
Config.QBTrunkTable     = 'trunkitems'     -- older qb-inventory / ps-inventory / lj-inventory (plate, items)

-- Show map blips for garages
Config.Blips = true

-- Garages created on first start (more can be added in-game from the Manage button)
Config.DefaultLocations = {
    {
        name = 'Legion Square',
        slots = 12,
        private = false,
        coords = { x = 215.9, y = -810.1, z = 30.7, w = 160.0 },
        spawn  = { x = 222.0, y = -804.7, z = 30.7, w = 160.0 },
    },
}
