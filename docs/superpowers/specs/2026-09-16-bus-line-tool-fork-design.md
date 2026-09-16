# Bus Line Tool fork — design

Date: 2026-09-16
Upstream: "Bus line tool!" v1.1 by okeating, Steam Workshop 2998909889 (last updated 2024-05-26).
Game: Transport Fever 2 build 35924, native Linux, ~206 Workshop mods active.

## 1. Goal

Fork the mod as a local mod (`bus_line_tool_fixed_1`) that:

1. does not crash or freeze the game when a save with many mods is loaded or when the tool is opened;
2. has a cleaner window;
3. shows a richer in-world overlay while stops are placed;
4. names and colours new lines automatically (editable);
5. stops converting truck stops to bus stops when an existing combined station is reused;
6. can edit existing bus and tram lines with the same click workflow.

Non-goals: publishing to the Workshop (no licence in the upstream mod; okeating's permission would be needed), train/ship/plane support, buying vehicles when editing an existing line, keyboard shortcuts (the scripting API exposes no key listener, only `insertMouseListener`).

## 2. Root cause being fixed

`discoverVehicles()` in `res/scripts/bus_line_tool_vehicle_util.lua` walks every model in `api.res.modelRep.getAll()` whose name starts with `vehicle/`, calls `api.res.modelRep.get()` on each, keeps raw native references (`modelCopy.metadata = model.metadata`), and walks nested `compartments → loadConfigs → cargoEntries` maps. It is triggered on the second GUI frame after the window is built, because `buildBusLinePanel` calls `createBusLine:setSelected(true, true)` (emit = true), which queues `vehicleSelection.refresh(0)`.

With 206 mods this is thousands of train, wagon, ship and plane models, several with broken metadata. The observed crash was a segfault in `std::_Rb_tree_increment` (map iteration) inside the game's Lua bridge while the GUI thread was in the mod's `guiUpdate()`. The upstream author's own comment on the cache says "frequent calls to modelRep seem to cause random crashes".

## 3. Current structure (upstream)

```
mod.lua
res/config/game_script/bus_line_tool_script.lua   GUI window, overlay circles, mouse listener, event plumbing (755 lines)
res/config/style_sheet/bus_line_tool_styles.lua   one button style
res/scripts/bus_line_tool_base_util.lua           3.7k lines of shared helpers (edges, stations, search, buttons)
res/scripts/bus_line_tool_builder.lua             createBusLine: builds stops proposal, upgrades stations, setupLine
res/scripts/bus_line_tool_line_manager.lua        line creation/extension, vehicle assignment (3k lines, mostly unused here)
res/scripts/bus_line_tool_route_builder.lua       street upgrades (bus lanes, tram tracks)
res/scripts/bus_line_tool_construction_util.lua   stations/depots
res/scripts/bus_line_tool_pathfinding_util.lua    road/rail path queries
res/scripts/bus_line_tool_vehicle_util.lua        vehicle discovery and consist building (2.1k lines)
res/scripts/bus_line_tool_base_param_helper.lua, bus_line_tool_station_template_helper.lua
```

Two Lua states run the game script: the engine state (`update`, `handleEvent`, all building) and the GUI state (`guiInit`, `guiUpdate`, the window, the overlay). `workItems` queues are per state. Communication GUI → engine is `api.cmd.make.sendScriptEvent("bus_line_tool_script.lua", "createBusLine", "", param)`.

## 4. Crash fix — vehicle discovery

File: `res/scripts/bus_line_tool_vehicle_util.lua`.

- `discoverVehicles(vehicleTypes)` takes the set of types wanted. The tool passes `{bus = true, tram = true}`. Only model names with prefix `vehicle/bus/` or `vehicle/tram/` are touched; everything else is skipped before any `modelRep.get()` call. The `_v2`/`_v3` legacy-name pass stays, on names only.
- Each model is processed inside `pcall`. A failing model is logged once (`bus_line_tool: skipped model <name>: <err>`) and skipped.
- The cache stores plain Lua copies, never native handles. Per model: `name`, `description.name`, `description.smallIcon`, `description.icon20`, `availability.yearFrom/yearTo`, `transportVehicle.carrier`, `transportVehicle.topSpeed`, `transportVehicle.multipleUnitOnly`, `transportVehicle.loadSpeed`, per-compartment capacity by cargo type (already computed into `cargoCapacityLookup`), `railVehicle.topSpeed/engines` when present, and `boundingInfo` extents. `getModel(id)` returns the copy. Functions in this file that the bus/tram path reaches (`findVehiclesOfType`, `findBestMatchVehicleOfType`, `buildUrbanBus`, `buildTram`, `buildVehicle`, `createVehicleConfig`, `isElectricTram`, `getTopSpeed`, `getConsistInfo` for road vehicles) are checked to use only copied fields. Train/ship/plane paths are left in place but untested; they are not reachable from this tool.
- Discovery is lazy: it runs the first time the vehicle chooser needs it, which is the first time the window is opened, not when the save loads. `createBusLine:setSelected(true, false)` at build time; the refresh is queued from the toolbar toggle handler when the window becomes visible.
- Discovery runs in one frame but logs its duration and the model counts (`bus_line_tool: discovered N bus, M tram models in X ms`).

## 5. Window

File: `res/config/game_script/bus_line_tool_script.lua` (window code moved to `res/scripts/bus_line_tool_window.lua`, required from the GUI state).

Layout, top to bottom:

- **TabWidget** with two tabs: *New line* and *Edit line*.
- *New line* tab
  - Section "Stops": the existing Table (segment, distance, remove), plus a status TextView under it that shows what is under the cursor ("Street: Main St — click to add stop", "Station: Springfield Central — click to add", or "Nothing selectable here").
  - Section "Line": mode ToggleButtonGroup Bus/Tram; TextInputField *Name* (pre-filled, see §7); colour control (see §7); CheckBoxes *Bus lanes*, *Circle line*, *Ignore validation*.
  - Section "Vehicles": the existing vehicle icon + choose button + count field.
  - Button row: Build, Reset, Cancel.
- *Edit line* tab
  - ComboBox of the player's bus and tram lines, sorted by name, plus a *Locate* button (moves the camera with `game.gui.setCamera`, which the upstream helpers already use for locate rows).
  - Same Stops table and status line; each row has a remove button; the selected row is where new stops are inserted (after it). No selection = append at end.
  - Section "Line": Name field (rename via `api.cmd.make.setName`); Bus lanes / Ignore validation checkboxes. Colour cannot be changed on an existing line (no command for it) so the control is hidden here.
  - Button row: Apply, Reload, Cancel.
- Every control gets `setTooltip`. Section headers are TextViews with a `BusLineToolHeader` style; the style sheet gains header and status-line styles.
- The vehicle chooser sub-window is unchanged except that each row shows capacity and top speed in its label.

## 6. In-world overlay

New file `res/scripts/bus_line_tool_overlay.lua` (GUI state only). All drawing uses `game.interface.setZone(name, {polygon=…, draw=true, drawColor=…})`, the only in-world drawing primitive available to scripts; there is no world-to-screen projection, so text labels are not possible.

Zone name prefix `blt_` everywhere so `clear()` can remove exactly what the tool drew.

- **Hover highlight.** Existing `updateCircle` behaviour kept, with colours: station → green (`{40,200,80,0.35}`), street edge → blue (`{60,140,255,0.35}`), nothing → no zone. Shape comes from the existing `getShapeForEntity`. The status line in the window is updated in the same pass.
- **Numbered stop markers.** For stop *i* at position *p*: a filled circle (radius 6 m, line colour, alpha 0.6) plus the number *i* rendered as seven-segment digits made of thin rectangles (each segment its own zone, 1.2 m wide, digit 8 m tall) laid on the terrain 10 m north of the marker. Numbers ≥ 10 render two digits side by side. Rebuilt only when the stop list changes.
- **Route preview.** For each consecutive pair of stops (and last→first for circle lines), the road path is computed with the existing pathfinding helpers: `findRoadPathStations` for station↔station, `findRoadPathBetweenEdges` for edge↔edge, and a new `findRoadPathBetweenEntities(a, b, isTram)` in `bus_line_tool_pathfinding_util.lua` that picks start edges / destination nodes per entity kind for mixed pairs. Each edge on the path is drawn with `getShapeForEdge` in the line colour at alpha 0.3. Unreachable pairs fall back to the current straight polyline in grey and the status line says "No road path between stop 3 and 4". Paths are cached per (a, b, isTram) and recomputed only when the stop list or the Bus/Tram mode changes. `api.engine.util.pathfinding.findPath` is a read query; if it turns out not to be callable from the GUI state, the preview degrades to the straight polyline.
- **Upgrade preview.** Edges on the previewed route that the build would upgrade are drawn in orange (`{255,160,0,0.45}`) instead of the line colour. The predicate is extracted from `route_builder` into `routeBuilder.edgeNeedsUpgrade(edgeId, params)` (tram: `BASE_EDGE_STREET.tramTrackType` below the required type; bus lanes: street type without a bus lane) and used by both preview and build so they cannot disagree.

## 7. Auto name and colour

New file `res/scripts/bus_line_tool_naming.lua` (pure Lua, testable offline; takes town names, stop names, carrier, circle flag, existing line names).

Rules for a new line, applied when the New line tab's stop list changes and the user has not edited the field:

- all stops in one town: `"<Town> Bus 3"` / `"<Town> Tram 2"`, N = number of existing lines whose name starts with that prefix + 1;
- circle line in one town: `"<Town> Bus Ring 2"`;
- first and last stop in different towns: `"<TownA> – <TownB> Bus"` (en dash), with a numeric suffix only if that name already exists.

The field is editable; once edited it is not overwritten until Reset. The final name is passed to `api.cmd.make.createLine(name, colour, player, line)` in `setupLine`, replacing the current `"<town> line <count>"`.

Colour: `api.gui.comp.ColorChooser` with `onColorChanged`. Construction is wrapped in `pcall`; if the component cannot be created with the guessed signature, the fallback is a *Next colour* button cycling through `api.res.getBaseConfig().gui.lineColors` with the current index shown. The chosen colour drives the overlay and the `createLine` call. Default: next unused line colour, as now.

## 8. Keep truck stops

File: `res/scripts/bus_line_tool_builder.lua`, `upgradeRoadStation`.

Today the function regenerates the whole module table from the road-station template (`params.modules = util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params))`) with `templateIndex` forced to 2 (bus), which rewrites truck terminals as bus terminals. The upstream author left the merge that would have preserved them commented out.

Change: keep every existing entry of `construction.params.modules`, and add only the modules the template generates for slots that do not exist yet (the new platform). `templateIndex` is left untouched when it is already set. A unit test feeds a fake construction with mixed truck/bus modules and asserts the truck modules survive and exactly one new bus platform appears. In-game check: reuse a combined station in a bus line and confirm the truck stop still lists truck lines.

## 9. Edit existing lines

New file `res/scripts/bus_line_tool_line_editor.lua`, used from both states.

GUI side (`loadLine(lineId)`): reads the LINE component, sets `selectedEntities` to the station id of each stop in order (via `lineManager.stationFromStop`), records the line's carrier (bus/tram) and colour (from the line's colour component, read-only), and redraws overlay and table. Clicking the map inserts after the selected table row: a station is inserted as-is; a street edge is inserted as a pending stop (drawn as a dashed-looking marker: circle at alpha 0.3) and is built on Apply. Removing a row removes only that occurrence.

Engine side (`applyEdit(param)` via a new script event `editBusLine`):

1. Build a proposal for the pending street-edge stops using the extracted `builder.buildStopsProposal(edgeIds, isTram)` (the first half of today's `createBusLine`), then examine/upgrade touched stations exactly as new lines do.
2. Construct an `api.type.Line`: for each entry in the edited stop list, reuse the original `Line.Stop` (terminal, waypoints, stopConfig, waiting times) when the station was already on the line, otherwise `createStopForStation(station, nextStopPos)`. `vehicleInfo` and `waitingTime` are copied from the existing line.
3. `api.cmd.make.updateLine(lineId, line)`; on success, optional street upgrades for the new segments via `routeBuilder.checkRoadRouteForUpgradeBetweenStations` when *Bus lanes* or tram mode requires it; then `api.cmd.make.setName` if the name changed.
4. Vehicles keep running; the count is not changed.

The line list for the ComboBox comes from `api.engine.system.lineSystem.getLines()` filtered with `lineManager` `isBusLine`/`isTramLine` and player ownership, refreshed each time the tab is shown.

## 10. Error handling

- All engine-side work runs through the existing `xpcall(..., err)` queue; failures print a traceback and leave the game untouched (proposals are atomic in the game).
- Overlay drawing never throws to the game: each zone update is wrapped, and any error clears the tool's zones and shows the message in the status line.
- Discovery skips bad models; if zero bus or tram models are found the chooser shows "No vehicles available this year" and Build is disabled.
- Edit mode refuses to apply when the line no longer exists or has fewer than two stops after edits.

## 11. Testing

Offline (`test/`, run with `lua5.1 test/run.lua`, fake `api` stub in `test/fake_api.lua`):

- discovery: only bus/tram prefixes touched, bad model skipped, copies contain no userdata;
- naming rules including collisions and en dash;
- seven-segment geometry: each digit yields the expected segment count and all points are finite;
- station module merge (§8);
- line editing: insert-after-selected, remove single occurrence, reuse of original stops, circle handling.

In-game checklist (user runs, tool logs `bus_line_tool:` lines to stdout.txt):

1. Load "gtnh kab" with the fork enabled and the Workshop copy disabled: no freeze, no crash, log shows no discovery until the window opens.
2. Open the tool: discovery line in the log with counts and time; chooser lists buses.
3. Place three stops on streets: numbered markers, route preview along streets, hover colours, orange upgrade segments when *Bus lanes* is on.
4. Build: line created with the auto name and chosen colour; vehicles bought.
5. Reuse a combined bus/truck station: truck stop intact.
6. Edit an existing line: add a stop after row 2, remove one, rename, Apply; line updated, vehicles still assigned.

## 12. Files and modules

```
mod.lua                                   name → "Bus line tool! (fixed fork)", minorVersion 2
res/config/game_script/bus_line_tool_script.lua   thin: state, events, guiInit/guiUpdate wiring
res/scripts/bus_line_tool_window.lua       (new) window and tabs
res/scripts/bus_line_tool_overlay.lua      (new) zones: hover, markers, digits, route, upgrade preview
res/scripts/bus_line_tool_naming.lua       (new) pure naming rules
res/scripts/bus_line_tool_line_editor.lua  (new) load/apply edits
res/scripts/bus_line_tool_vehicle_util.lua discovery rewrite (§4)
res/scripts/bus_line_tool_builder.lua      buildStopsProposal extraction, upgradeRoadStation merge (§8), name/colour params
res/scripts/bus_line_tool_route_builder.lua edgeNeedsUpgrade extraction
res/scripts/bus_line_tool_pathfinding_util.lua findRoadPathBetweenEntities
res/config/style_sheet/bus_line_tool_styles.lua header/status styles
install.sh                                 rsync into the game's local mods folder
test/                                      offline tests
```

Module names stay `bus_line_tool_*` so the Workshop copy must be unsubscribed or disabled; both loaded at once would collide on `require` names and the script event target.

## 13. API assumptions to verify at implementation

- `api.gui.comp.ColorChooser` constructor and `onColorChanged` payload (fallback defined in §7).
- `api.engine.util.pathfinding.findPath` callable from the GUI state (fallback in §6).
- `api.cmd.make.setName(entity, name)` signature for renaming lines.
- `api.gui.comp.TabWidget.new(...)`, `addTab(title, component)`.
- `Table:onSelect` callback argument (row index) for insert-after.
