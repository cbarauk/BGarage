# BGarage

Standalone FiveM garage with a NUI: fuel, engine and body status, favourites, search, list/grid views and in-game location management.

## Install
1. Drop the `BGarage` folder in `resources/` and add `ensure BGarage` to server.cfg.
2. Location management is granted to `group.admin` automatically on start (`Config.AutoGrantGroups`).
   To manage it yourself, empty that list and use `add_ace group.admin bgarage.manage allow`,
   or set `Config.AdminOnly = false`.

## Frameworks
Owned vehicles are read straight from your framework's database through oxmysql (required).
- **QBCore / Qbox:** `player_vehicles` (set `Config.QBTable` if yours differs)
- **ESX:** `owned_vehicles` (set `Config.ESXTable`)
- **Standalone:** uses its own JSON file, see `/addveh`

`Config.Framework = 'auto'` detects which one is running. The console prints `[BGarage] Using framework: ...` the first time a player opens a garage.
Parking saves fuel, engine, body and vehicle mods back to the database. Driving restores them.
Qbox: uncomment the ox_lib line in fxmanifest.lua so mods can be saved and restored.
Vehicles stored by a different garage script appear in the first BGarage location until you park them in one of yours.

## Use
- Walk to a garage and press **E** to open it.
- Sit in an owned vehicle inside a garage radius and press **E** to park it.
- Open the garage you want a car in, expand a vehicle parked in another garage and press **Transfer here**, then confirm. It moves to the garage you have open. Set a price with `Config.TransferFee` (QBCore, Qbox and ESX) or turn the feature off with `Config.AllowTransfers = false`.
- Expand a vehicle that is **Out** and press **Recover** to pay a fee and have it delivered to the garage you have open. Configure the fee with `Config.RecoverFee`, the account with `Config.RecoverAccount`, or turn it off with `Config.AllowRecover = false`. A vehicle being actively driven (someone in the driver seat) cannot be recovered, so a car stolen in RP cannot just be yanked back mid-scene.
- Expand any vehicle and press **Trunk** to see what is inside it (item names and counts). Press it again to hide the list. It works for vehicles you own whether they are parked, out or impounded.
- `/bgarage manage` opens the location management menu from anywhere, no need to stand in a garage. It needs the `bgarage.manage` ace (granted to `group.admin` by default) and, unlike the in-garage menu, lists private locations too.
- `/addveh` registers the vehicle you are sitting in as yours. In standalone mode anyone can use it (it's the only way to get ownership). In QB / ESX mode it requires the `bgarage.manage` ace (admin only) because it bypasses the dealership purchase flow — handy for addon cars that aren't sold through a shop. The model hash is saved into the mods JSON so addon cars whose GXT name differs from their spawn name still drive out correctly.
- **Manage** lists every location as a pill. Click a pill to open it and see its details and the Bays / Redraw / Waypoint / Delete actions; click again to close it.
- **Manage** → add a location (you draw its drop-off area in the world), redraw an existing one, or delete it.
- The prompt appears anywhere inside a location's drawn area, not just at one point.

## Drawing a drop-off area (admins)
1. Open any garage → **Manage** → enter a name and privacy → **Draw drop-off area**. The menu closes.
2. Aim at the ground and press **E** to place each corner (3 to 32). **Backspace** undoes the last corner, **Enter** finishes, **X** cancels.
3. Stand in a spot where vehicles should appear, facing the way they should point, and press **E**. Repeat for every drive-out bay you want (up to `Config.MaxSpawns`, default 8). **Backspace** removes the last bay, **Enter** finishes, **X** cancels.
4. Use **Redraw** next to a location in Manage to replace its area and all of its bays.
5. `/garagezones` toggles a blue outline of every zone in the world, handy for checking placement.

Zones use the height of the corners you placed (about 1 m below to 3.5 m above), so multi-storey car parks work if you draw each floor as its own location. Locations created before this update, and the default location in config.lua, keep the old radius behaviour until you redraw them.

## Multiple drive-out bays
Each location can have several bays so people pulling cars out at the same time don't spawn on top of each other.
- When a car is pulled out, the server picks the first bay that is free: not reserved by someone else in the last `Config.SpawnReserveMs`, and with no vehicle within `Config.SpawnClearRadius` metres (the vehicle check needs OneSync; without it only the reservation applies).
- If every bay is busy, the player sees "All bays are busy" and the car stays stored, so nothing is lost.
- **Manage → Bays** lets you add or remove bays on an existing location without redrawing its area. Your current bays are shown and kept; press **E** to add more, **Backspace** to remove the last one.
- Existing locations with a single spawn point keep working as a one-bay location. `/garagezones` shows every bay with its number and facing direction.

## Trunk contents
BGarage reads trunks straight from your inventory script, so nothing is stored by BGarage itself.
- **ox_inventory:** reads the `trunk<plate>` inventory (live copy if loaded, otherwise the `ox_inventory` table).
- **qb-inventory / ps-inventory / lj-inventory:** reads `inventories` (`trunk-<plate>`) or the older `trunkitems` table.
- `Config.Inventory = 'auto'` detects which one is running. Use `'ox'`, `'qb'` or `'none'` to force it. Table names are in `config.lua`.
- Other inventory scripts show "Trunk contents are not available". Add a reader next to `trunkOx` / `trunkQB` in server.lua.
- A vehicle that is currently out may show its last saved trunk, because some inventories only write to the database when the trunk is closed.

## Previewing in a browser
Open `html/index.html` directly in any browser. A mock server loads sample data and a small dev bar lets you reopen the garage and toggle the prompt. Nothing is sent anywhere, and the mock is skipped automatically inside FiveM.

## Data
Saved as JSON in `data/vehicles.json` and `data/locations.json`.

## Custom thumbnails (addon cars)
Stock GTA vehicles get their thumbnails from docs.fivem.net automatically. Addon cars have no entry there, so they show an empty tile by default. To use your own images, edit `data/thumbnails.json`:

```json
{
    "na6":       "https://i.imgur.com/your-na6-shot.png",
    "myaddon":   "https://cdn.yourserver.com/thumbs/myaddon.jpg"
}
```

Each key is the **spawn name** of the vehicle (the same name you'd use in a `/spawn` command, or in the BGStudio queue), matched case-insensitively. Each value is a direct URL to an image file — any URL that returns an image works (Imgur, Discord CDN, GitHub raw, your own web server). Recommended size: roughly 256×128 (the docs.fivem.net thumbnails are that shape).

Edits are picked up **live** — no resource restart needed. Just save the file, walk into a garage, press E, and the new thumbnails appear. The `_README`, `_example_format`, etc. keys in the default file are documentation only (keys starting with `_` are ignored by the matcher).

The thumbnail lookup order is:
1. Your custom URL in `data/thumbnails.json` (if the model is listed there).
2. The docs.fivem.net vehicle thumbnail (`https://docs.fivem.net/vehicles/<model>.webp`).
3. An empty tile (if neither loads).

Use **BGStudio** to take the screenshots in the first place — green screen + overcast lighting + the same framing for every car. Key the green out, save the PNG, upload it to a host, paste the URL into `data/thumbnails.json`.

## Framework / fuel integration
- Ownership: replace the `bgarage:register` event and the `vehicles` table in server.lua with your framework's database.
- Fuel: edit `getFuel` and `setFuel` at the top of client.lua (ox_fuel, LegacyFuel, etc).
