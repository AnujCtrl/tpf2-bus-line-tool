# Bus Line Tool Fork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the imported "Bus line tool!" Workshop mod into a local Transport Fever 2 mod that does not crash on save load, has a two-tab window, a richer in-world overlay, auto naming and colour, keeps truck stops intact, and can edit existing bus/tram lines.

**Architecture:** The mod is Lua run by the game in two states (engine: `update`/`handleEvent`; GUI: `guiInit`/`guiUpdate`). Pure logic goes into small new modules with no `api` access at load time so it can be unit-tested with the host's `lua5.4` and a fake `api`; game-facing code stays in the existing modules and is verified in-game by the user. The window and overlay are split out of the 755-line game script into `bus_line_tool_window.lua` and `bus_line_tool_overlay.lua`.

**Tech Stack:** Lua (game scripting API `api.*`, `game.interface.*`), Transport Fever 2 build 35924, `lua5.4` on the host for tests, rsync install script.

**Spec:** `docs/superpowers/specs/2026-09-16-bus-line-tool-fork-design.md`

## Global Constraints

- Repo: `~/Projects/tpf2-bus-line-tool`. All paths below are relative to it. Commit after every task with the trailer `Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe`.
- Installed folder name: `bus_line_tool_fixed_1` under `~/.local/share/Steam/userdata/204184616/1066780/local/mods/` (via `./install.sh`).
- Module names keep the `bus_line_tool_` prefix; the script event target stays `"bus_line_tool_script.lua"`.
- Every zone the tool draws is named with prefix `blt_`.
- Log lines the tool prints start with `bus_line_tool:`.
- No `api.*` or `game.*` access at module load time in any new module (they must load under the fake api).
- Vehicle discovery touches only names with prefix `vehicle/bus/` or `vehicle/tram/` and never stores native handles.
- Tests: `lua5.4 test/run.lua` from the repo root must pass at the end of every task.
- The game itself cannot be run by the implementer; in-game steps are handed to the user with exact instructions and expected log lines.

---

### Task 1: Test harness, fake api, mod identity

**Files:**
- Create: `test/run.lua`, `test/fake_api.lua`, `test/test_smoke.lua`, `README.md`, `.gitignore`
- Modify: `mod.lua` (name, version, description header)

**Interfaces:**
- Produces: global `api`, `game`, `_`, `debugPrint` for tests (from `test/fake_api.lua`); `fake.modelRep(models)` helper; `fake.reset()`; test files return a table of `name = function()` cases.

- [ ] **Step 1: Write the test runner**

`test/run.lua`:

```lua
-- Run from the repo root:  lua5.4 test/run.lua
package.path = "res/scripts/?.lua;test/?.lua;" .. package.path
local fake = require("fake_api")

local files = {
  "test_smoke",
}

local passed, failed = 0, 0
for _, file in ipairs(files) do
  local ok, cases = pcall(require, file)
  if not ok then
    failed = failed + 1
    print(("FAIL %s: could not load: %s"):format(file, tostring(cases)))
  else
    local names = {}
    for name in pairs(cases) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      fake.reset()
      local ok2, err = pcall(cases[name])
      if ok2 then
        passed = passed + 1
      else
        failed = failed + 1
        print(("FAIL %s.%s: %s"):format(file, name, tostring(err)))
      end
    end
  end
end
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 2: Write the fake api**

`test/fake_api.lua`:

```lua
-- Minimal stand-ins for the Transport Fever 2 scripting globals, enough for the pure modules.
local fake = {}

-- Lua 5.4 compatibility for code written against the game's Lua
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
math.pow = math.pow or function(a, b) return a ^ b end
unpack = unpack or table.unpack
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end

_ = _ or function(s) return s end
debugPrint = debugPrint or function() end

function fake.reset()
  api = {
    res = {},
    engine = { getComponent = function() return nil end, util = { getPlayer = function() return 1 end } },
    type = {
      enum = { VehicleEngineType = { ELECTRIC = 1, STEAM = 0, DIESEL = 2 } },
      ComponentType = { BASE_EDGE_STREET = 1, NAME = 2, LINE = 3, STATION_GROUP = 4 },
      Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
    },
    util = { formatSpeed = function(v) return tostring(v) .. " km/h" end },
  }
  game = { interface = {}, config = { gui = { lineColors = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } } } }
  fake.log = {}
end

-- Build a model repository. `models` is a list of { name = "vehicle/bus/x.mdl", metadata = {...}, boundingInfo = {...}, broken = true|nil }.
-- A broken model makes modelRep.get() raise, like a mod model with corrupt metadata.
function fake.modelRep(models)
  local byId, idByName, names = {}, {}, {}
  for i, m in ipairs(models) do
    local id = i - 1
    byId[id] = m
    idByName[m.name] = id
    names[id] = m.name
  end
  api.res.modelRep = {
    getAll = function() return names end,
    find = function(name) return idByName[name] or -1 end,
    getName = function(id) return names[id] end,
    get = function(id)
      local m = byId[id]
      if m.broken then error("simulated native failure for " .. m.name) end
      return m
    end,
  }
  api.res.cargoTypeRep = {
    getAll = function() return { [0] = "PASSENGERS", [1] = "MAIL" } end,
    find = function(name) return ({ PASSENGERS = 0, MAIL = 1 })[name] end,
    get = function(id) return { weight = ({ [0] = 0.1, [1] = 0.5 })[id], id = ({ [0] = "PASSENGERS", [1] = "MAIL" })[id] } end,
  }
end

-- A plausible bus/tram model for tests.
function fake.model(name, opts)
  opts = opts or {}
  local vehicleType = name:match("^vehicle/(%a+)/")
  local m = {
    name = name,
    broken = opts.broken,
    metadata = {
      description = { name = opts.label or name, smallIcon = "ui/small/" .. name .. ".tga", icon20 = "ui/20/" .. name .. ".tga" },
      availability = { yearFrom = opts.yearFrom or 1900, yearTo = opts.yearTo or 0 },
      transportVehicle = {
        carrier = vehicleType == "tram" and "TRAM" or "ROAD",
        topSpeed = opts.topSpeed or 20,
        loadSpeed = 1,
        multipleUnitOnly = false,
        compartments = { { loadConfigs = { { cargoEntries = { { type = "PASSENGERS", capacity = opts.capacity or 30 } } } } } },
      },
      cost = { price = opts.price or 100000 },
      maintenance = { runningCosts = 1000, lifespan = 20 },
      emission = { idleEmission = 10 },
    },
    boundingInfo = { bbMin = { x = -5, y = -1, z = 0 }, bbMax = { x = 5, y = 1, z = 3 } },
  }
  if vehicleType == "tram" then
    m.metadata.railVehicle = { topSpeed = opts.topSpeed or 20, weight = 30, engines = { { power = 200, tractiveEffort = 50, type = opts.electric and 1 or 2 } } }
  else
    m.metadata.roadVehicle = { topSpeed = opts.topSpeed or 20, weight = 12, engine = { power = 150, tractiveEffort = 30, type = 2 } }
  end
  return m
end

fake.reset()
return fake
```

- [ ] **Step 3: Write the smoke test**

`test/test_smoke.lua`:

```lua
local t = {}

function t.fake_api_has_model_rep()
  local fake = require("fake_api")
  fake.modelRep({ fake.model("vehicle/bus/a.mdl") })
  assert(api.res.modelRep.find("vehicle/bus/a.mdl") == 0)
  assert(api.res.modelRep.get(0).metadata.description.name == "vehicle/bus/a.mdl")
end

function t.broken_model_raises()
  local fake = require("fake_api")
  fake.modelRep({ fake.model("vehicle/bus/bad.mdl", { broken = true }) })
  local ok = pcall(api.res.modelRep.get, 0)
  assert(not ok)
end

return t
```

- [ ] **Step 4: Run the tests**

Run: `cd ~/Projects/tpf2-bus-line-tool && lua5.4 test/run.lua`
Expected: `2 passed, 0 failed`

- [ ] **Step 5: Rename the mod and add README and .gitignore**

In `mod.lua` change:

```lua
			minorVersion = 1,
			severityAdd = 'NONE',
			severityRemove = 'NONE',
			name = _('Bus line tool!'),
			description = _([[ 
```

to:

```lua
			minorVersion = 2,
			severityAdd = 'NONE',
			severityRemove = 'NONE',
			name = _('Bus line tool! (fixed fork)'),
			description = _([[ 
Local fork of okeating's Bus line tool (Workshop 2998909889): no crash on save load with many mods, tabbed window, numbered stop markers, route preview, auto line names, truck stops preserved, edit existing lines.

Original description:
```

`README.md`:

```markdown
# Bus line tool! (fixed fork)

Fork of okeating's Transport Fever 2 mod "Bus line tool!" (Steam Workshop 2998909889).
Personal use only: the upstream mod carries no licence.

## Install

    ./install.sh

Copies the mod to the game's local mods folder as `bus_line_tool_fixed_1`.
Unsubscribe from or disable the Workshop copy: both use the same module names.

## Tests

    lua5.4 test/run.lua

Pure logic is tested on the host with a fake `api` (`test/fake_api.lua`).
Game-facing changes are verified in-game; the tool logs lines prefixed `bus_line_tool:` to
`~/.local/share/Steam/userdata/204184616/1066780/local/crash_dump/stdout.txt`.

## Design

See `docs/superpowers/specs/2026-09-16-bus-line-tool-fork-design.md`.
```

`.gitignore`:

```
*.swp
*~
```

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/tpf2-bus-line-tool
git add -A
git commit -m "Add test harness with fake api, rename mod to fixed fork

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
```

---

### Task 2: Safe vehicle discovery (the crash fix)

**Files:**
- Create: `res/scripts/bus_line_tool_vehicle_discovery.lua`, `test/test_discovery.lua`
- Modify: `res/scripts/bus_line_tool_vehicle_util.lua:641-786` (`discoverVehicles`, `getAllVehiclesByType`, `getVehicleDescription`)
- Modify: `test/run.lua` (add `"test_discovery"` to `files`)

**Interfaces:**
- Produces: `discovery.run(env, wanted) -> result` where `env = { getAllModels, findModel, getModel, getModelName, getAllCargoTypes, findCargoType, getCargoType, log, clock, availability }`, `wanted = { bus = true, tram = true }`, and `result = { byType = { bus = {[id]=copy}, tram = {[id]=copy} }, modelRepLookup = {[id]=copy}, modelNameLookup = {[id]=name}, modelAvailability = {[id]={all=true, auto=bool, europe=bool, usa=bool, asia=bool}}, cargoCapacityLookup, cargoIdxLookup, inverseCargoIdxLookup, cargoWeightLookup, skipped = {names}, counts = {bus=n, tram=n}, millis = number }`.
- Produces: `discovery.copyModel(model) -> plain table` with the fields listed in the spec §4.
- Produces: `vehicleUtil.describeVehicle(vehicleDetail) -> string` ("Name · 40 pax · 60 km/h").

- [ ] **Step 1: Write the failing tests**

`test/test_discovery.lua`:

```lua
local fake = require("fake_api")
local t = {}

local function env()
  return {
    getAllModels = api.res.modelRep.getAll,
    findModel = api.res.modelRep.find,
    getModel = api.res.modelRep.get,
    getModelName = api.res.modelRep.getName,
    getAllCargoTypes = api.res.cargoTypeRep.getAll,
    findCargoType = api.res.cargoTypeRep.find,
    getCargoType = api.res.cargoTypeRep.get,
    log = function(...) fake.log[#fake.log + 1] = table.concat({ ... }, " ") end,
    clock = os.clock,
    availability = function() return { all = true, auto = true, europe = true } end,
  }
end

function t.only_bus_and_tram_are_fetched()
  local fetched = {}
  fake.modelRep({
    fake.model("vehicle/bus/a.mdl"),
    fake.model("vehicle/tram/b.mdl"),
    fake.model("vehicle/train/c.mdl", { broken = true }),
    fake.model("vehicle/waggon/d.mdl", { broken = true }),
    fake.model("station/bus/small.mdl", { broken = true }),
  })
  local realGet = api.res.modelRep.get
  api.res.modelRep.get = function(id) fetched[#fetched + 1] = id; return realGet(id) end
  local discovery = require("bus_line_tool_vehicle_discovery")
  local result = discovery.run(env(), { bus = true, tram = true })
  assert(#fetched == 2, "expected 2 fetches, got " .. #fetched)
  assert(result.counts.bus == 1 and result.counts.tram == 1)
  assert(result.byType.bus[0] and result.byType.tram[1])
end

function t.broken_model_is_skipped_and_logged()
  fake.modelRep({
    fake.model("vehicle/bus/good.mdl"),
    fake.model("vehicle/bus/bad.mdl", { broken = true }),
  })
  local discovery = require("bus_line_tool_vehicle_discovery")
  local result = discovery.run(env(), { bus = true })
  assert(result.counts.bus == 1)
  assert(result.skipped[1] == "vehicle/bus/bad.mdl")
  assert(fake.log[1]:find("skipped model vehicle/bus/bad.mdl", 1, true), fake.log[1])
end

function t.copies_are_plain_and_complete()
  fake.modelRep({ fake.model("vehicle/tram/t.mdl", { electric = true, capacity = 80, topSpeed = 70, label = "Tram T" }) })
  local discovery = require("bus_line_tool_vehicle_discovery")
  local result = discovery.run(env(), { tram = true })
  local copy = result.modelRepLookup[0]
  assert(copy.metadata.description.name == "Tram T")
  assert(copy.metadata.description.smallIcon == "ui/small/vehicle/tram/t.mdl.tga")
  assert(copy.metadata.availability.yearFrom == 1900 and copy.metadata.availability.yearTo == 0)
  assert(copy.metadata.transportVehicle.carrier == "TRAM")
  assert(copy.metadata.railVehicle.engines[1].type == 1)
  assert(copy.metadata.railVehicle.topSpeed == 70)
  assert(copy.metadata.cost.price == 100000)
  assert(copy.boundingInfo.bbMax.x - copy.boundingInfo.bbMin.x == 10)
  assert(result.cargoCapacityLookup[0].PASSENGERS == 80)
  assert(result.cargoCapacityLookup[0][0] == 80)
  assert(result.cargoIdxLookup[0].PASSENGERS == 1)
  assert(result.cargoWeightLookup.PASSENGERS == 0.1)
  -- nothing in the copy refers back to the source object
  local source = api.res.modelRep.get(0)
  assert(copy.metadata ~= source.metadata)
  assert(copy.metadata.transportVehicle.compartments ~= source.metadata.transportVehicle.compartments)
end

function t.legacy_v2_models_are_ignored()
  fake.modelRep({
    fake.model("vehicle/bus/old.mdl"),
    fake.model("vehicle/bus/old_v2.mdl"),
  })
  local discovery = require("bus_line_tool_vehicle_discovery")
  local result = discovery.run(env(), { bus = true })
  assert(result.counts.bus == 1)
  assert(result.byType.bus[1], "the _v2 model should be kept")
  assert(not result.byType.bus[0], "the legacy model should be ignored")
end

function t.multiple_unit_only_models_are_not_offered()
  local m = fake.model("vehicle/tram/mu.mdl")
  m.metadata.transportVehicle.multipleUnitOnly = true
  fake.modelRep({ m })
  local discovery = require("bus_line_tool_vehicle_discovery")
  local result = discovery.run(env(), { tram = true })
  assert(result.modelRepLookup[0], "still cached for lookups")
  assert(not result.byType.tram[0], "but not offered as a choice")
end

return t
```

- [ ] **Step 2: Add the file to the runner and run it to see it fail**

In `test/run.lua` change `local files = {` block to:

```lua
local files = {
  "test_smoke",
  "test_discovery",
}
```

Run: `lua5.4 test/run.lua`
Expected: 5 failures mentioning `bus_line_tool_vehicle_discovery` not found.

- [ ] **Step 3: Write the discovery module**

`res/scripts/bus_line_tool_vehicle_discovery.lua`:

```lua
-- Vehicle discovery for the bus line tool.
-- Walks only the bus and tram models, copies the fields the tool needs into plain Lua
-- tables, and skips any model whose native data cannot be read. See spec §4.
local discovery = {}

local PREFIX = { bus = "vehicle/bus/", tram = "vehicle/tram/" }

function discovery.vehicleTypeForName(name, wanted)
  for vehicleType, prefix in pairs(PREFIX) do
    if wanted[vehicleType] and string.sub(name, 1, #prefix) == prefix then
      return vehicleType
    end
  end
  return nil
end

local function copyEngine(e)
  if not e then return nil end
  return { power = e.power, tractiveEffort = e.tractiveEffort, type = e.type }
end

local function copyVehicleConfig(c)
  if not c then return nil end
  local copy = { topSpeed = c.topSpeed, weight = c.weight }
  if c.engine then copy.engine = copyEngine(c.engine) end
  if c.engines then
    copy.engines = {}
    for i, engine in pairs(c.engines) do copy.engines[i] = copyEngine(engine) end
  end
  return copy
end

local function copyCompartments(compartments)
  local result = {}
  for i, compartment in pairs(compartments or {}) do
    local loadConfigs = {}
    for j, loadConfig in pairs(compartment.loadConfigs or {}) do
      local entries = {}
      for k, entry in pairs(loadConfig.cargoEntries or {}) do
        entries[k] = { type = entry.type, capacity = entry.capacity }
      end
      loadConfigs[j] = { cargoEntries = entries }
    end
    result[i] = { loadConfigs = loadConfigs }
  end
  return result
end

local function copyXYZ(v)
  return { x = v.x, y = v.y, z = v.z }
end

function discovery.copyModel(model)
  local m = model.metadata
  local copy = { metadata = {}, boundingInfo = {} }
  copy.metadata.description = {
    name = m.description.name,
    icon = m.description.icon,
    smallIcon = m.description.smallIcon,
    icon20 = m.description.icon20,
  }
  copy.metadata.availability = { yearFrom = m.availability.yearFrom, yearTo = m.availability.yearTo }
  if m.transportVehicle then
    local tv = m.transportVehicle
    copy.metadata.transportVehicle = {
      carrier = tv.carrier,
      topSpeed = tv.topSpeed,
      loadSpeed = tv.loadSpeed,
      multipleUnitOnly = tv.multipleUnitOnly,
      compartments = copyCompartments(tv.compartments),
    }
  end
  copy.metadata.roadVehicle = copyVehicleConfig(m.roadVehicle)
  copy.metadata.railVehicle = copyVehicleConfig(m.railVehicle)
  copy.metadata.cost = { price = m.cost and m.cost.price or 0 }
  copy.metadata.maintenance = {
    runningCosts = m.maintenance and m.maintenance.runningCosts or 0,
    lifespan = m.maintenance and m.maintenance.lifespan or 0,
  }
  if m.emission then copy.metadata.emission = { idleEmission = m.emission.idleEmission } end
  copy.boundingInfo.bbMin = copyXYZ(model.boundingInfo.bbMin)
  copy.boundingInfo.bbMax = copyXYZ(model.boundingInfo.bbMax)
  return copy
end

local function legacyNamesToIgnore(names)
  local legacy = {}
  for _, name in pairs(names) do
    local suffix = string.sub(name, -7, -5)
    if suffix == "_v3" then
      legacy[string.sub(name, 1, -8) .. "_v2.mdl"] = true
    elseif suffix == "_v2" then
      legacy[string.sub(name, 1, -8) .. ".mdl"] = true
    end
  end
  return legacy
end

-- env: see plan Task 2 "Interfaces". wanted: { bus = true, tram = true }.
function discovery.run(env, wanted)
  local started = env.clock()
  local names = {}
  for _, name in pairs(env.getAllModels()) do names[#names + 1] = name end
  local legacy = legacyNamesToIgnore(names)

  local result = {
    byType = {}, modelRepLookup = {}, modelNameLookup = {}, modelAvailability = {},
    cargoCapacityLookup = {}, cargoIdxLookup = {}, inverseCargoIdxLookup = {}, cargoWeightLookup = {},
    skipped = {}, counts = {},
  }
  for vehicleType in pairs(wanted) do
    result.byType[vehicleType] = {}
    result.counts[vehicleType] = 0
  end

  local cargoTypes = {}
  for idx, name in pairs(env.getAllCargoTypes()) do cargoTypes[#cargoTypes + 1] = { idx = idx, name = name } end
  for _, ct in ipairs(cargoTypes) do
    local weight = env.getCargoType(ct.idx).weight
    result.cargoWeightLookup[ct.idx] = weight
    result.cargoWeightLookup[ct.name] = weight
  end

  for _, name in ipairs(names) do
    local vehicleType = discovery.vehicleTypeForName(name, wanted)
    if vehicleType and not legacy[name] then
      local ok, err = pcall(function()
        local id = env.findModel(name)
        local copy = discovery.copyModel(env.getModel(id))
        result.modelRepLookup[id] = copy
        result.modelNameLookup[id] = env.getModelName(id)
        result.modelAvailability[id] = env.availability(name, vehicleType, copy)

        local capacity, cargoIdx, inverse = {}, {}, {}
        for _, ct in ipairs(cargoTypes) do
          capacity[ct.idx] = 0
          capacity[ct.name] = 0
        end
        local tv = copy.metadata.transportVehicle
        if tv then
          for _, compartment in pairs(tv.compartments) do
            for j, loadConfig in pairs(compartment.loadConfigs) do
              for _, entry in pairs(loadConfig.cargoEntries) do
                local idx = env.findCargoType(entry.type)
                capacity[entry.type] = (capacity[entry.type] or 0) + entry.capacity
                capacity[idx] = (capacity[idx] or 0) + entry.capacity
                cargoIdx[entry.type] = j
                cargoIdx[idx] = j
                inverse[j] = entry.type
              end
            end
          end
        end
        result.cargoCapacityLookup[id] = capacity
        result.cargoIdxLookup[id] = cargoIdx
        result.inverseCargoIdxLookup[id] = inverse

        if tv and not tv.multipleUnitOnly then
          result.byType[vehicleType][id] = copy
          result.counts[vehicleType] = result.counts[vehicleType] + 1
        end
      end)
      if not ok then
        result.skipped[#result.skipped + 1] = name
        env.log("bus_line_tool: skipped model " .. name .. ": " .. tostring(err))
      end
    end
  end

  result.millis = (env.clock() - started) * 1000
  local summary = {}
  for vehicleType, count in pairs(result.counts) do summary[#summary + 1] = count .. " " .. vehicleType end
  table.sort(summary)
  env.log(("bus_line_tool: discovered %s models in %.0f ms (%d skipped)"):format(table.concat(summary, ", "), result.millis, #result.skipped))
  return result
end

return discovery
```

- [ ] **Step 4: Run the tests**

Run: `lua5.4 test/run.lua`
Expected: `7 passed, 0 failed`

- [ ] **Step 5: Wire it into vehicle_util**

In `res/scripts/bus_line_tool_vehicle_util.lua`, add near the top (after `local pathFindingUtil = require(...)`):

```lua
local discovery = require("bus_line_tool_vehicle_discovery")
```

Replace the whole `local function discoverVehicles()` (lines 641–750, from `local function discoverVehicles()` through its closing `end` just before `local function getAllVehiclesByType`) with:

```lua
local WANTED_VEHICLE_TYPES = { bus = true, tram = true }

local function discoverVehicles()
	collectgarbage("collect")
	local env = {
		getAllModels = api.res.modelRep.getAll,
		findModel = api.res.modelRep.find,
		getModel = api.res.modelRep.get,
		getModelName = api.res.modelRep.getName,
		getAllCargoTypes = api.res.cargoTypeRep.getAll,
		findCargoType = api.res.cargoTypeRep.find,
		getCargoType = api.res.cargoTypeRep.get,
		log = print,
		clock = os.clock,
		availability = function(name, vehicleType, model)
			local availability = { all = true }
			if filterClimate(name, vehicleType, model) then
				availability.auto = true
			end
			for _, region in pairs({ "europe", "usa", "asia" }) do
				if filterClimateOverride(name, vehicleType, model, region) then
					availability[region] = true
				end
			end
			return availability
		end,
	}
	local result = discovery.run(env, WANTED_VEHICLE_TYPES)
	vehicleUtil.modelAvailablility = result.modelAvailability
	vehicleUtil.cargoIdxLookup = result.cargoIdxLookup
	vehicleUtil.inverseCargoIdxLookup = result.inverseCargoIdxLookup
	vehicleUtil.cargoWeightLookup = result.cargoWeightLookup
	vehicleUtil.cargoCapacityLookup = result.cargoCapacityLookup
	vehicleUtil.locomotiveReplacments = {}
	vehicleUtil.discoveredVehiclesByType = result.byType
	vehicleUtil.modelRepLookup = result.modelRepLookup
	vehicleUtil.modelNameLookup = result.modelNameLookup
	vehicleUtil.lastDiscovery = result
end
```

Replace `getAllVehiclesByType` (the function right after) with:

```lua
local function getAllVehiclesByType(vehicleType)
	if not vehicleUtil.discoveredVehiclesByType then
		discoverVehicles()
	end
	local vehicles = vehicleUtil.discoveredVehiclesByType[vehicleType]
	if not vehicles then
		print("bus_line_tool: WARNING no vehicles of type " .. tostring(vehicleType) .. " were discovered")
		return {}
	end
	return vehicles
end
```

In `getVehicleDescription` (line ~787) change:

```lua
	if vehicleUtil.discoveredVehiclesByType["waggon"][vehicle.modelId] then -- it is a waggon - needs some disambiguation
```

to:

```lua
	local waggons = vehicleUtil.discoveredVehiclesByType["waggon"]
	if waggons and waggons[vehicle.modelId] then -- it is a waggon - needs some disambiguation
```

Directly after `vehicleUtil.getVehicleDescription = getVehicleDescription` add:

```lua
function vehicleUtil.describeVehicle(vehicleDetail)
	local model = vehicleDetail.model
	local capacity = vehicleUtil.cargoCapacityLookup[vehicleDetail.modelId]
	local pax = capacity and capacity["PASSENGERS"] or 0
	local config = getVehicleConfig(model)
	local speed = config and config.topSpeed and api.util.formatSpeed(config.topSpeed) or "?"
	return _(model.metadata.description.name) .. " · " .. tostring(pax) .. " pax · " .. speed
end
```

- [ ] **Step 6: Syntax-check the modified file and run tests**

Run: `luac5.1 -p res/scripts/bus_line_tool_vehicle_util.lua && lua5.4 test/run.lua`
Expected: no luac output; `7 passed, 0 failed`.

(If `luac5.1` rejects `goto`, use `luac -p` instead; the game accepts `goto`.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Discover only bus and tram models into plain copies, skip broken models

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
```

---

### Task 3: Window module with tabs, sections, status line, lazy discovery

**Files:**
- Create: `res/scripts/bus_line_tool_window.lua`
- Modify: `res/config/game_script/bus_line_tool_script.lua` (remove `buildVehicleSelectionPanel`, `buildBusLinePanel`, `buildWindow`, `newImageView`, `newButton`; `createComponents` uses the window module; toggle handler triggers the first vehicle refresh)
- Modify: `res/config/style_sheet/bus_line_tool_styles.lua` (header and status styles)

**Interfaces:**
- Consumes: `vehicleUtil.findVehiclesOfType`, `vehicleUtil.describeVehicle`, `vehicleUtil.buildUrbanBus`, `vehicleUtil.buildTram`, `vehicleUtil.getModel`, `util.newButton`, `util.newToggleButton`, `util.makelocateRowForEdge`, `util.year`.
- Produces: `windowModule.create(ctx) -> handles` where `ctx = { guiState, addWork, err, getPosition(entityId), removeCircle(name), removeCircles(), updateCircle(), onBuild(param), onEditLoad(lineId), onEditApply(param), onLineListNeeded() -> {{id=,name=}}, onNameNeeded() -> string, colourDefault() -> {r,g,b} }` and `handles = { window, refreshStops(), setStatus(text), setSuggestedName(text), mode() -> "new"|"edit", isTram() -> bool, addBusLanes() -> bool, isCircle() -> bool, ignoreErrors() -> bool, lineName() -> string, lineColour() -> {r,g,b}, selectedRow() -> int, refreshVehicles(), refreshLineList() }`.
- `guiState` fields used: `selectedEntities` (list of entity ids), `colours` (parallel), `stopMeta` (parallel list of `{origIndex=, pending=}`), `isActive`, `isCircle`, `needsRedrawRoute`, `window`, `window2`, `editLine` (nil or `{lineId=, name=}`), `selectedRow`.

- [ ] **Step 1: Add styles**

Replace `res/config/style_sheet/bus_line_tool_styles.lua` with:

```lua
local ssu = require "stylesheetutil"
function data()
    local result = {}
    local a = ssu.makeAdder(result)

	a("!BusLineToolButton", {
		backgroundColor = ssu.makeColor(83, 151, 198, 200),
		borderColor = ssu.makeColor(0, 0, 0, 150)
	})
	a("!BusLineToolButton:hover", {
		backgroundColor =  ssu.makeColor(106, 192, 251, 200),
	})
	a("!BusLineToolButton:active", {
		backgroundColor = ssu.makeColor(161, 217, 255, 200),
	})
	a("!BusLineToolButton:disabled", {
		backgroundColor = ssu.makeColor(160, 180, 190, 50),
	})
	a("!BusLineToolHeader", {
		fontSize = 15,
		color = ssu.makeColor(255, 255, 255, 255),
		padding = { 6, 0, 2, 0 },
	})
	a("!BusLineToolStatus", {
		fontSize = 12,
		color = ssu.makeColor(200, 220, 240, 255),
		padding = { 2, 0, 2, 0 },
	})
	return result
end
```

- [ ] **Step 2: Write the window module**

`res/scripts/bus_line_tool_window.lua`:

```lua
-- The Bus Line Tool window: two tabs (New line / Edit line), sections, tooltips, status line.
-- GUI state only. Everything that touches the world goes through ctx callbacks.
local util = require("bus_line_tool_base_util")
local vehicleUtil = require("bus_line_tool_vehicle_util")

local windowModule = {}

local function header(text)
	local view = api.gui.comp.TextView.new(text)
	view:addStyleClass("BusLineToolHeader")
	return view
end

local function tipped(component, tooltip)
	component:setTooltip(tooltip)
	return component
end

local function rgbFromLineColor(entry)
	return { entry[1], entry[2], entry[3] }
end

-- Colour control: the game's ColorChooser when it can be built, else a cycling button.
local function buildColourControl(ctx, onChange)
	local current = ctx.colourDefault()
	local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local swatch = api.gui.comp.LineRenderView.new()
	swatch:addLine(api.type.Vec2f.new(0, 12), api.type.Vec2f.new(60, 12))
	swatch:setWidth(20)
	swatch:setMinimumSize(api.gui.util.Size.new(60, 24))
	local function apply(rgb)
		current = rgb
		swatch:setColor(api.type.Vec4f.new(rgb[1], rgb[2], rgb[3], 1))
		onChange(rgb)
	end
	apply(current)
	layout:addItem(swatch)

	local ok, chooser = pcall(function()
		local c = api.gui.comp.ColorChooser.new()
		c:onColorChanged(function(colour)
			local rgb
			if type(colour) == "table" then
				rgb = { colour[1] or colour.r or colour.x, colour[2] or colour.g or colour.y, colour[3] or colour.b or colour.z }
			else
				local okx, x, y, z = pcall(function() return colour.x, colour.y, colour.z end)
				if okx and x then rgb = { x, y, z } else rgb = { colour.r, colour.g, colour.b } end
			end
			if rgb[1] and rgb[2] and rgb[3] then apply(rgb) end
		end)
		return c
	end)
	if ok and chooser then
		layout:addItem(chooser)
		print("bus_line_tool: colour chooser available")
	else
		print("bus_line_tool: colour chooser unavailable, using cycling button (" .. tostring(chooser) .. ")")
		local colours = api.res.getBaseConfig().gui.lineColors
		local index = 1
		local button = tipped(util.newButton(_("Next colour")), _("Cycle through the game's line colours"))
		button:onClick(function()
			index = index % #colours + 1
			apply(rgbFromLineColor(colours[index]))
		end)
		layout:addItem(button)
	end
	local comp = api.gui.comp.Component.new(" ")
	comp:setLayout(layout)
	return { comp = comp, get = function() return current end }
end

local function buildVehicleSelectionPanel(ctx, state)
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	boxLayout:addItem(api.gui.comp.TextView.new(_("Vehicle:")))
	local selectedVehicle = api.gui.comp.ImageView.new(" ")
	selectedVehicle:setMaximumSize(api.gui.util.Size.new(60, 60))
	boxLayout:addItem(selectedVehicle)
	local chooseButton = tipped(util.newButton("", "ui/button/small/line_tasks@2x.tga"), _("Choose a different vehicle"))
	boxLayout:addItem(chooseButton)
	boxLayout:addItem(api.gui.comp.TextView.new(_("Count:")))
	local countInput = tipped(api.gui.comp.TextInputField.new("0"), _("Number of vehicles to buy. Default: stops / 2, at least 2"))
	boxLayout:addItem(countInput)

	local chooserLayout = api.gui.layout.BoxLayout.new("VERTICAL")
	local window = api.gui.comp.Window.new(_("Vehicle selection"), chooserLayout)
	window:setVisible(false, false)
	window:addHideOnCloseHandler()
	ctx.guiState.window2 = window
	chooseButton:onClick(function()
		window:setVisible(true, false)
		local mousePos = api.gui.util.getMouseScreenPos()
		window:setPosition(mousePos.x, mousePos.y)
	end)
	local screenSize = api.gui.util.getGameUI():getMainRendererComponent():getContentRect()
	window:setMaximumSize(api.gui.util.Size.new(math.floor((1 / 3) * screenSize.w), math.floor((3 / 4) * screenSize.h)))

	local lastComputedCount = 0
	local vehicleConfig
	local priorYear, priorIndex

	local function populateIcon(modelId)
		local model = vehicleUtil.getModel(modelId)
		selectedVehicle:setImage(model.metadata.description.icon20, true)
		selectedVehicle:setTooltip(_(model.metadata.description.name))
	end

	local panel = { comp = boxLayout }

	function panel.refresh(index)
		if index == 0 then
			vehicleConfig = vehicleUtil.buildUrbanBus()
		else
			vehicleConfig = vehicleUtil.buildTram()
		end
		local modelId = vehicleConfig.vehicles[1].part.modelId
		if priorYear ~= util.year() or priorIndex ~= index then
			priorYear = util.year()
			priorIndex = index
			for i = chooserLayout:getNumItems() - 1, 0, -1 do
				chooserLayout:removeItem(chooserLayout:getItem(i))
			end
			local selectedButton
			local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.VERTICAL, 0, false)
			for _, vehicle in pairs(vehicleUtil.findVehiclesOfType(index == 0 and "bus" or "tram")) do
				local toggleButton = util.newToggleButton(vehicleUtil.describeVehicle(vehicle), vehicle.model.metadata.description.smallIcon)
				if modelId == vehicle.modelId then
					toggleButton:setSelected(true, false)
					selectedButton = toggleButton
				end
				toggleButton:onToggle(function()
					ctx.addWork(function()
						vehicleConfig = vehicleUtil.copyConfig(vehicleUtil.createVehicleConfig(vehicle.modelId))
						populateIcon(vehicle.modelId)
					end)
				end)
				buttonGroup:add(toggleButton)
			end
			buttonGroup:setOneButtonMustAlwaysBeSelected(true)
			local size = buttonGroup:calcMinimumSize()
			local maximum = (2 / 3) * screenSize.h / 2
			local scrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.Component.new(" "), " ")
			scrollArea:setContent(buttonGroup)
			scrollArea:setMaximumSize(api.gui.util.Size.new(size.w, math.floor(maximum)))
			chooserLayout:addItem(scrollArea)
			local acceptButton = tipped(util.newButton("", "ui/button/small/accept@2x.tga"), _("Use this vehicle"))
			local resetButton = tipped(util.newButton("", "ui/button/small/vehicle_replace_active@2x.tga"), _("Back to the suggested vehicle"))
			local cancelButton = tipped(util.newButton("", "ui/button/small/cancel@2x.tga"), _("Close without changes"))
			local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL")
			local function reset()
				ctx.addWork(function() if selectedButton then selectedButton:setSelected(true, true) end end)
			end
			buttonPanel:addItem(acceptButton)
			buttonPanel:addItem(resetButton)
			buttonPanel:addItem(cancelButton)
			chooserLayout:addItem(buttonPanel)
			acceptButton:onClick(function() window:close() end)
			resetButton:onClick(reset)
			cancelButton:onClick(function() reset(); window:close() end)
		end
		populateIcon(modelId)
	end

	function panel.getVehicleConfig() return vehicleConfig end

	function panel.updateCount()
		local numStops = #ctx.guiState.selectedEntities
		if not ctx.guiState.isCircle then numStops = numStops * 2 - 2 end
		local computedCount = numStops < 2 and 0 or math.min(100, math.max(2, math.floor(numStops / 2)))
		if lastComputedCount ~= computedCount then
			lastComputedCount = computedCount
			countInput:setText(tostring(computedCount), false)
		end
	end

	function panel.getNumberOfVehicles()
		local result
		if not pcall(function() result = tonumber(countInput:getText()) end) then result = lastComputedCount end
		return result
	end

	return panel
end

-- The stops table is shared by both tabs; only one tab is visible at a time so one table is enough.
local function buildStopsSection(ctx, state, onRowsChanged)
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")
	layout:addItem(header(_("Stops")))
	local colHeaders = {
		api.gui.comp.TextView.new(_("#")),
		api.gui.comp.TextView.new(_("Stop")),
		api.gui.comp.TextView.new(_("Distance")),
		api.gui.comp.TextView.new(" "),
	}
	local table_ = api.gui.comp.Table.new(#colHeaders, "SINGLE")
	table_:setHeader(colHeaders)
	pcall(function()
		table_:onSelect(function(row)
			ctx.guiState.selectedRow = row
		end)
	end)
	layout:addItem(table_)
	local status = api.gui.comp.TextView.new(_("Hover a street or station and click to add a stop"))
	status:addStyleClass("BusLineToolStatus")
	layout:addItem(status)

	local section = { comp = layout, status = status }

	function section.refresh()
		table_:deleteAll()
		local entities = ctx.guiState.selectedEntities
		for i, entityId in pairs(entities) do
			local distanceDisplay = api.gui.comp.TextView.new(" ")
			if i > 1 or ctx.guiState.isCircle and #entities > 1 then
				local prior = i == 1 and entities[#entities] or entities[i - 1]
				distanceDisplay:setText(api.util.formatLength(util.distance(ctx.getPosition(entityId), ctx.getPosition(prior))))
			end
			local removeButton = tipped(util.newButton("", "ui/button/small/cancel@2x.tga"), _("Remove this stop"))
			removeButton:onClick(function()
				ctx.addWork(function()
					local index = util.indexOf(ctx.guiState.selectedEntities, entityId)
					if index == -1 then return end
					table.remove(ctx.guiState.selectedEntities, index)
					table.remove(ctx.guiState.colours, index)
					table.remove(ctx.guiState.stopMeta, index)
					ctx.removeCircle("bus_line_tool" .. tostring(entityId))
					ctx.guiState.needsRedrawRoute = true
					onRowsChanged()
				end)
			end)
			local number = api.gui.comp.TextView.new(tostring(i))
			table_:addRow({ number, util.makelocateRowForEdge(entityId, ctx.guiState.colours[i]), distanceDisplay, removeButton })
		end
	end

	return section
end

local function buildNewLineTab(ctx, state, stops, vehicles)
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")
	layout:addItem(stops.comp)

	layout:addItem(header(_("Line")))
	local modeGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local busButton = tipped(util.newToggleButton("BUS", "ui/button/medium/vehicle_bus@2x.tga"), _("Build a bus line"))
	local tramButton = tipped(util.newToggleButton("TRAM", "ui/button/medium/vehicle_tram@2x.tga"), _("Build a tram line (tram tracks are added where missing)"))
	modeGroup:add(busButton)
	modeGroup:add(tramButton)
	modeGroup:setOneButtonMustAlwaysBeSelected(true)
	busButton:setSelected(true, false) -- emit=false: no vehicle discovery until the window opens
	layout:addItem(modeGroup)

	local nameRow = api.gui.layout.BoxLayout.new("HORIZONTAL")
	nameRow:addItem(api.gui.comp.TextView.new(_("Name:")))
	local nameField = tipped(api.gui.comp.TextInputField.new(""), _("Suggested from the towns of the first and last stop. Edit freely."))
	nameField:setMinimumSize(api.gui.util.Size.new(220, 24))
	state.nameEdited = false
	pcall(function() nameField:onChange(function() state.nameEdited = true end) end)
	nameRow:addItem(nameField)
	layout:addItem(nameRow)

	local colourRow = api.gui.layout.BoxLayout.new("HORIZONTAL")
	colourRow:addItem(api.gui.comp.TextView.new(_("Colour:")))
	local colour = buildColourControl(ctx, function() ctx.guiState.needsRedrawRoute = true end)
	colourRow:addItem(colour.comp)
	layout:addItem(colourRow)

	local addBusLanes = tipped(api.gui.comp.CheckBox.new(_("Bus lanes")), _("Upgrade the streets along the route with bus lanes"))
	local circleLine = tipped(api.gui.comp.CheckBox.new(_("Circle line")), _("Last stop connects back to the first instead of returning the same way"))
	local ignoreErrors = tipped(api.gui.comp.CheckBox.new(_("Ignore validation")), _("Force street upgrades even when the game reports collisions (\"Construction not possible\" cannot be ignored)"))
	layout:addItem(addBusLanes)
	layout:addItem(circleLine)
	layout:addItem(ignoreErrors)
	circleLine:onToggle(function(b)
		ctx.guiState.isCircle = b
		ctx.guiState.needsRedrawRoute = true
		ctx.addWork(vehicles.updateCount)
	end)
	addBusLanes:onToggle(function() ctx.guiState.needsRedrawRoute = true end)

	layout:addItem(header(_("Vehicles")))
	layout:addItem(vehicles.comp)

	modeGroup:onCurrentIndexChanged(function(i)
		ctx.guiState.needsRedrawRoute = true
		ctx.addWork(function() vehicles.refresh(i) end)
	end)

	layout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local buildButton = tipped(util.newButton(_("Build"), "ui/button/small/accept@2x.tga"), _("Build the stops, the line and buy the vehicles"))
	local resetButton = tipped(util.newButton(_("Reset"), "ui/button/small/vehicle_replace_active@2x.tga"), _("Clear all selected stops"))
	local cancelButton = tipped(util.newButton(_("Cancel"), "ui/button/small/cancel@2x.tga"), _("Close the tool"))
	buttonPanel:addItem(buildButton)
	buttonPanel:addItem(resetButton)
	buttonPanel:addItem(cancelButton)
	layout:addItem(buttonPanel)
	buildButton:setEnabled(false, false)

	local tab = { comp = api.gui.comp.Component.new(" "), buildButton = buildButton, nameField = nameField }
	tab.comp:setLayout(layout)

	function tab.isTram() return modeGroup:getSelectedIndex() == 1 end
	function tab.addBusLanes() return addBusLanes:isSelected() end
	function tab.isCircle() return circleLine:isSelected() end
	function tab.ignoreErrors() return ignoreErrors:isSelected() end
	function tab.lineName() return nameField:getText() end
	function tab.lineColour() return colour.get() end
	function tab.setSuggestedName(text)
		if not state.nameEdited then nameField:setText(text, false) end
	end

	buildButton:onClick(function()
		ctx.addWork(function()
			ctx.onBuild({
				createTramLine = tab.isTram(),
				addBusLanes = tab.addBusLanes(),
				circleLine = tab.isCircle(),
				selectedEntities = ctx.guiState.selectedEntities,
				ignoreErrors = tab.ignoreErrors(),
				vehicleConfig = vehicles.getVehicleConfig(),
				numberOfVehicles = vehicles.getNumberOfVehicles(),
				lineName = tab.lineName(),
				lineColour = tab.lineColour(),
			})
			ctx.removeCircles()
			buildButton:setEnabled(false, false)
			state.nameEdited = false
			ctx.guiState.isActive = false
		end)
	end)
	resetButton:onClick(function()
		ctx.addWork(function()
			ctx.removeCircles()
			ctx.updateCircle()
			stops.refresh()
			buildButton:setEnabled(false, false)
			state.nameEdited = false
			vehicles.refresh(modeGroup:getSelectedIndex())
			ctx.addWork(vehicles.updateCount)
		end)
		ctx.guiState.isActive = true
	end)
	cancelButton:onClick(function() ctx.guiState.window:close() end)
	return tab
end

local function buildEditLineTab(ctx, state, stops)
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")
	layout:addItem(header(_("Line to edit")))
	local pickRow = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local combo = tipped(api.gui.comp.ComboBox.new(), _("Your bus and tram lines"))
	pickRow:addItem(combo)
	local locateButton = tipped(util.newButton("", "ui/button/xxsmall/locate.tga"), _("Move the camera to this line's first stop"))
	pickRow:addItem(locateButton)
	layout:addItem(pickRow)
	local lines = {}

	layout:addItem(stops.comp)

	layout:addItem(header(_("Line")))
	local nameRow = api.gui.layout.BoxLayout.new("HORIZONTAL")
	nameRow:addItem(api.gui.comp.TextView.new(_("Name:")))
	local nameField = tipped(api.gui.comp.TextInputField.new(""), _("Rename the line"))
	nameField:setMinimumSize(api.gui.util.Size.new(220, 24))
	nameRow:addItem(nameField)
	layout:addItem(nameRow)
	local addBusLanes = tipped(api.gui.comp.CheckBox.new(_("Bus lanes")), _("Upgrade the streets along the route with bus lanes"))
	local ignoreErrors = tipped(api.gui.comp.CheckBox.new(_("Ignore validation")), _("Force street upgrades even when the game reports collisions"))
	layout:addItem(addBusLanes)
	layout:addItem(ignoreErrors)
	addBusLanes:onToggle(function() ctx.guiState.needsRedrawRoute = true end)

	layout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local applyButton = tipped(util.newButton(_("Apply"), "ui/button/small/accept@2x.tga"), _("Build new stops and update the line"))
	local reloadButton = tipped(util.newButton(_("Reload"), "ui/button/small/vehicle_replace_active@2x.tga"), _("Discard edits and reload the line"))
	local cancelButton = tipped(util.newButton(_("Cancel"), "ui/button/small/cancel@2x.tga"), _("Close the tool"))
	buttonPanel:addItem(applyButton)
	buttonPanel:addItem(reloadButton)
	buttonPanel:addItem(cancelButton)
	layout:addItem(buttonPanel)
	applyButton:setEnabled(false, false)

	local tab = { comp = api.gui.comp.Component.new(" "), applyButton = applyButton, nameField = nameField }
	tab.comp:setLayout(layout)

	local function currentLine()
		return lines[combo:getCurrentIndex() + 1]
	end

	function tab.refreshLineList()
		lines = ctx.onLineListNeeded()
		combo:clear(false)
		for _, line in ipairs(lines) do combo:addItem(line.name) end
	end

	combo:onIndexChanged(function(index)
		local line = lines[index + 1]
		if line then
			ctx.addWork(function()
				ctx.onEditLoad(line.id)
				nameField:setText(line.name, false)
				applyButton:setEnabled(true, false)
			end)
		end
	end)
	locateButton:onClick(function()
		local line = currentLine()
		if line and line.firstStation then
			pcall(function() api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(line.firstStation, false) end)
		end
	end)
	applyButton:onClick(function()
		local line = currentLine()
		if not line then return end
		ctx.addWork(function()
			ctx.onEditApply({
				lineId = line.id,
				entities = ctx.guiState.selectedEntities,
				stopMeta = ctx.guiState.stopMeta,
				addBusLanes = addBusLanes:isSelected(),
				ignoreErrors = ignoreErrors:isSelected(),
				name = nameField:getText(),
			})
			ctx.removeCircles()
			applyButton:setEnabled(false, false)
			ctx.guiState.isActive = false
		end)
	end)
	reloadButton:onClick(function()
		local line = currentLine()
		if line then ctx.addWork(function() ctx.onEditLoad(line.id) end) end
	end)
	cancelButton:onClick(function() ctx.guiState.window:close() end)

	function tab.addBusLanes() return addBusLanes:isSelected() end
	function tab.ignoreErrors() return ignoreErrors:isSelected() end
	function tab.lineName() return nameField:getText() end
	return tab
end

function windowModule.create(ctx)
	local state = {}
	local handles = {}
	local vehicles = buildVehicleSelectionPanel(ctx, state)
	local stops = buildStopsSection(ctx, state, function() handles.refreshStops() end)
	local newTab = buildNewLineTab(ctx, state, stops, vehicles)
	local editTab = buildEditLineTab(ctx, state, stops)

	local tabs = api.gui.comp.TabWidget.new("NORTH")
	tabs:addTab(api.gui.comp.TextView.new(_("New line")), newTab.comp)
	tabs:addTab(api.gui.comp.TextView.new(_("Edit line")), editTab.comp)
	-- The tab-change event name is unverified, so the mode is derived from state instead:
	-- "edit" while a line is loaded (guiState.editLine), "new" otherwise. The line list is
	-- refreshed when the window opens (toolbar toggle) and by the Reload button.
	pcall(function()
		tabs:onCurrentChanged(function(index)
			if index == 1 then editTab.refreshLineList() end
		end)
	end)

	local outer = api.gui.layout.BoxLayout.new("VERTICAL")
	outer:addItem(tabs)
	local window = api.gui.comp.Window.new(_("Bus Line Tool"), outer)
	window:addHideOnCloseHandler()
	window:onClose(function()
		ctx.removeCircles()
		ctx.guiState.isActive = false
	end)
	ctx.guiState.window = window

	handles.window = window
	function handles.mode() return ctx.guiState.editLine and "edit" or "new" end
	function handles.refreshStops()
		stops.refresh()
		vehicles.updateCount()
		local n = #ctx.guiState.selectedEntities
		newTab.buildButton:setEnabled(n > 1, false)
		if handles.mode() == "new" then newTab.setSuggestedName(ctx.onNameNeeded()) end
	end
	function handles.setStatus(text) stops.status:setText(text, false) end
	function handles.setSuggestedName(text) newTab.setSuggestedName(text) end
	function handles.isTram()
		if handles.mode() == "edit" then return ctx.guiState.editLine and ctx.guiState.editLine.isTram or false end
		return newTab.isTram()
	end
	function handles.addBusLanes() return handles.mode() == "edit" and editTab.addBusLanes() or newTab.addBusLanes() end
	function handles.isCircle()
		if handles.mode() == "edit" then return ctx.guiState.editLine and ctx.guiState.editLine.isCircle or false end
		return newTab.isCircle()
	end
	function handles.ignoreErrors() return handles.mode() == "edit" and editTab.ignoreErrors() or newTab.ignoreErrors() end
	function handles.lineName() return handles.mode() == "edit" and editTab.lineName() or newTab.lineName() end
	function handles.lineColour() return newTab.lineColour() end
	function handles.selectedRow() return ctx.guiState.selectedRow or -1 end
	function handles.refreshVehicles() vehicles.refresh(newTab.isTram() and 1 or 0) end
	function handles.refreshLineList() editTab.refreshLineList() end
	function handles.setEditApplyEnabled(b) editTab.applyButton:setEnabled(b, false) end
	return handles
end

return windowModule
```

- [ ] **Step 3: Rewire the game script**

In `res/config/game_script/bus_line_tool_script.lua`:

1. Add after `local vehicleUtil = require("bus_line_tool_vehicle_util")`:

```lua
local windowModule = require("bus_line_tool_window")
```

2. Add `stopMeta = {},` to the `guiState` table (after `selectedEntities = {},`).

3. In `removeCircles()` add `guiState.stopMeta = {}` after `guiState.colours = {}`.

4. In the `mouseListener`, replace the block from `local idx = util.indexOf(guiState.selectedEntities, entityId)` through `addWork(guiState.refreshTable)` with:

```lua
				local idx = util.indexOf(guiState.selectedEntities, entityId)
				if idx ~= -1 then --treat as deselection
					table.remove(guiState.selectedEntities, idx)
					table.remove(guiState.colours, idx)
					table.remove(guiState.stopMeta, idx)
					removeCircle(entityString)
				else
					local colour = nextColour()
					local shape = getShapeForEntity(guiState.entity)
					addCircle(entityString, circle, colour, shape)
					local insertAt = #guiState.selectedEntities + 1
					if guiState.ui and guiState.ui.mode() == "edit" and guiState.ui.selectedRow() >= 0 then
						insertAt = math.min(guiState.ui.selectedRow() + 2, #guiState.selectedEntities + 1)
					end
					table.insert(guiState.selectedEntities, insertAt, entityId)
					table.insert(guiState.colours, insertAt, colour)
					table.insert(guiState.stopMeta, insertAt, { pending = true })
				end
				addWork(function() guiState.ui.refreshStops() end)
```

5. Delete `newImageView`, `newButton`, `buildVehicleSelectionPanel`, `buildBusLinePanel`, `buildWindow` (everything from `local function newImageView()` to the end of `buildWindow`, except keep `mouseListener`).

6. Replace `createComponents` with:

```lua
local function createComponents()
	local gameBar = api.gui.util.getById("gameInfo.layout")
	if not gameBar then
		return
	end
	local ui = windowModule.create({
		guiState = guiState,
		addWork = addWork,
		err = err,
		getPosition = getPosition,
		removeCircle = removeCircle,
		removeCircles = removeCircles,
		updateCircle = updateCircle,
		onBuild = function(param)
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("bus_line_tool_script.lua", "createBusLine", "", param), standardCallback)
		end,
		onEditLoad = function(lineId) end,   -- filled in Task 8
		onEditApply = function(param) end,  -- filled in Task 8
		onLineListNeeded = function() return {} end, -- filled in Task 8
		onNameNeeded = function() return "" end,     -- filled in Task 6
		colourDefault = function()
			local colours = api.res.getBaseConfig().gui.lineColors
			local c = colours[math.random(1, #colours)]
			return { c[1], c[2], c[3] }
		end,
	})
	guiState.ui = ui
	ui.window:setVisible(false, false)
	api.gui.util.getGameUI():getMainRendererComponent():insertMouseListener(mouseListener)

	local icon = api.gui.comp.ImageView.new("ui/icons/windows/destinations@4x.tga")
	local layout = api.gui.util.getById("mainButtonsLayout"):getItem(1):getLayout()
	icon:setMaximumSize(api.gui.util.Size.new(60, 60))
	icon:setMinimumSize(api.gui.util.Size.new(50, 50))
	local button = api.gui.comp.ToggleButton.new(icon)
	button:setTooltip(_("Bus Line Tool"))
	button:setName("ConstructionMenuIndicator")
	layout:insertItem(button, 0)
	local vehiclesLoaded = false
	button:onToggle(function(b)
		ui.window:setVisible(b, false)
		guiState.isActive = b
		if b then
			local mainView = game.gui.getContentRect("mainView")
			ui.window:setPosition(math.floor(mainView[3] / 2), math.floor(mainView[4] * (2 / 3)))
			if not vehiclesLoaded then
				vehiclesLoaded = true
				addWork(function() xpcall(ui.refreshVehicles, err) end) -- first (and only) vehicle discovery
			end
			pcall(ui.refreshLineList)
			ui.refreshStops()
		else
			ui.window:close()
		end
	end)
	guiState.isInit = true
end
```

7. In `data().guiInit` and `guiUpdate` nothing changes. In `data().handleEvent` nothing changes yet.

- [ ] **Step 4: Syntax-check**

Run: `luac -p res/config/game_script/bus_line_tool_script.lua res/scripts/bus_line_tool_window.lua res/config/style_sheet/bus_line_tool_styles.lua && lua5.4 test/run.lua`
Expected: no luac output, `7 passed, 0 failed`.

- [ ] **Step 5: Install and hand the first in-game check to the user**

Run: `./install.sh`

Tell the user: in the game's mod manager for save "gtnh kab", disable the Workshop "Bus line tool!" and enable "Bus line tool! (fixed fork)", load the save, then open the tool from the toolbar button. Expected in `crash_dump/stdout.txt`: no `bus_line_tool: discovered` line before the window is opened, then one such line with bus and tram counts and a time in ms after opening, plus either `colour chooser available` or `colour chooser unavailable`. Wait for the user's report before continuing. If `describeVehicle` or the tabs raise a Lua error it will be printed with `An error was caught`; fix and reinstall.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Split window into module with tabs and status line; discover vehicles only when opened

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
```

---

### Task 4: Overlay geometry and overlay module (hover colours, numbered markers)

**Files:**
- Create: `res/scripts/bus_line_tool_overlay_geometry.lua`, `res/scripts/bus_line_tool_overlay.lua`, `test/test_geometry.lua`
- Modify: `res/config/game_script/bus_line_tool_script.lua` (move shape functions and circle drawing into the overlay module; use it from `updateCircle`, the mouse listener and `removeCircles`)
- Modify: `test/run.lua` (add `"test_geometry"`)

**Interfaces:**
- Produces (pure): `geometry.circle(cx, cy, radius, n) -> polygon`, `geometry.rect(x, y, w, h) -> polygon`, `geometry.digitPolygons(number, originX, originY, opts) -> {polygon,...}` with `opts = { height = 8, width = 4.5, thickness = 1.2, gap = 1.5 }`. A polygon is a list of `{x, y}`.
- Produces (GUI): `overlay.setHover(entity | nil)`, `overlay.setStops(stops)` with `stops = { {id=, pos={x,y}, colour={r,g,b,a}, pending=bool}, ... }`, `overlay.setRouteEdges(edges)` with `edges = { {edgeId=, colour={r,g,b,a}}, ... }`, `overlay.setFallbackPolyline(points, colour)`, `overlay.clear()`, `overlay.getShapeForEntity(entity)`, `overlay.shapeForEdgeId(edgeId)`.

- [ ] **Step 1: Write the failing geometry tests**

`test/test_geometry.lua`:

```lua
local t = {}

local function finite(p) return p[1] == p[1] and p[2] == p[2] and math.abs(p[1]) < 1e9 and math.abs(p[2]) < 1e9 end

function t.circle_has_n_points()
  local g = require("bus_line_tool_overlay_geometry")
  local poly = g.circle(10, 20, 6, 16)
  assert(#poly == 16)
  for _, p in ipairs(poly) do
    local d = math.sqrt((p[1] - 10) ^ 2 + (p[2] - 20) ^ 2)
    assert(math.abs(d - 6) < 1e-6)
  end
end

function t.rect_is_counter_clockwise_quad()
  local g = require("bus_line_tool_overlay_geometry")
  local poly = g.rect(1, 2, 3, 4)
  assert(#poly == 4)
  assert(poly[1][1] == 1 and poly[1][2] == 2)
  assert(poly[3][1] == 4 and poly[3][2] == 6)
end

local SEGMENTS = { [0] = 6, 2, 5, 5, 4, 5, 6, 3, 7, 6 }

function t.each_digit_has_expected_segment_count()
  local g = require("bus_line_tool_overlay_geometry")
  for digit = 0, 9 do
    local polys = g.digitPolygons(digit, 0, 0)
    assert(#polys == SEGMENTS[digit], ("digit %d: %d segments"):format(digit, #polys))
    for _, poly in ipairs(polys) do
      assert(#poly == 4)
      for _, p in ipairs(poly) do assert(finite(p)) end
    end
  end
end

function t.two_digit_numbers_render_side_by_side()
  local g = require("bus_line_tool_overlay_geometry")
  local polys = g.digitPolygons(12, 100, 50)
  assert(#polys == SEGMENTS[1] + SEGMENTS[2])
  local minX, maxX = math.huge, -math.huge
  for _, poly in ipairs(polys) do
    for _, p in ipairs(poly) do minX = math.min(minX, p[1]); maxX = math.max(maxX, p[1]) end
  end
  assert(minX >= 100 and maxX <= 100 + 2 * 4.5 + 1.5 + 1e-6, ("x range %f..%f"):format(minX, maxX))
end

function t.digits_sit_above_origin()
  local g = require("bus_line_tool_overlay_geometry")
  for _, poly in ipairs(g.digitPolygons(8, 0, 0)) do
    for _, p in ipairs(poly) do assert(p[2] >= 0 and p[2] <= 8 + 1e-6) end
  end
end

return t
```

Add `"test_geometry",` to `files` in `test/run.lua`.

- [ ] **Step 2: Run to see failures**

Run: `lua5.4 test/run.lua`
Expected: 5 failures, module not found.

- [ ] **Step 3: Write the geometry module**

`res/scripts/bus_line_tool_overlay_geometry.lua`:

```lua
-- Pure 2D geometry for the in-world overlay. Polygons are lists of {x, y}; y points north.
local geometry = {}

function geometry.circle(cx, cy, radius, n)
	local poly = {}
	for i = 0, n - 1 do
		local a = 2 * math.pi * i / n
		poly[#poly + 1] = { cx + radius * math.cos(a), cy + radius * math.sin(a) }
	end
	return poly
end

function geometry.rect(x, y, w, h)
	return { { x, y }, { x + w, y }, { x + w, y + h }, { x, y + h } }
end

-- Seven-segment layout. Segment letters: a top, b top-right, c bottom-right, d bottom, e bottom-left, f top-left, g middle.
local DIGIT_SEGMENTS = {
	[0] = "abcdef", [1] = "bc", [2] = "abged", [3] = "abgcd", [4] = "fgbc",
	[5] = "afgcd", [6] = "afgedc", [7] = "abc", [8] = "abcdefg", [9] = "abcdfg",
}

local DEFAULTS = { height = 8, width = 4.5, thickness = 1.2, gap = 1.5 }

local function segmentRect(letter, ox, oy, o)
	local t, w, h = o.thickness, o.width, o.height
	local half = h / 2
	if letter == "a" then return geometry.rect(ox, oy + h - t, w, t) end
	if letter == "d" then return geometry.rect(ox, oy, w, t) end
	if letter == "g" then return geometry.rect(ox, oy + half - t / 2, w, t) end
	if letter == "f" then return geometry.rect(ox, oy + half, t, half) end
	if letter == "e" then return geometry.rect(ox, oy, t, half) end
	if letter == "b" then return geometry.rect(ox + w - t, oy + half, t, half) end
	if letter == "c" then return geometry.rect(ox + w - t, oy, t, half) end
	error("unknown segment " .. tostring(letter))
end

function geometry.digitPolygons(number, originX, originY, opts)
	local o = {}
	for k, v in pairs(DEFAULTS) do o[k] = opts and opts[k] or v end
	local text = tostring(math.floor(number))
	local polys = {}
	for i = 1, #text do
		local digit = tonumber(text:sub(i, i))
		local ox = originX + (i - 1) * (o.width + o.gap)
		for letter in DIGIT_SEGMENTS[digit]:gmatch(".") do
			polys[#polys + 1] = segmentRect(letter, ox, originY, o)
		end
	end
	return polys
end

return geometry
```

- [ ] **Step 4: Run tests**

Run: `lua5.4 test/run.lua`
Expected: `12 passed, 0 failed`

- [ ] **Step 5: Write the overlay module**

`res/scripts/bus_line_tool_overlay.lua`:

```lua
-- In-world drawing for the bus line tool. Everything goes through game.interface.setZone.
-- Zone names all start with "blt_" so clear() removes exactly what this module drew.
local util = require("bus_line_tool_base_util")
local vec3 = require("vec3")
local geometry = require("bus_line_tool_overlay_geometry")

local overlay = {}
local drawn = {}          -- name -> true for every zone currently drawn
local groups = {}         -- group -> { name = true } so a group can be replaced atomically

-- Zone colours are {r, g, b, a} with every channel in 0..1 (the game clamps larger values, which
-- is why upstream's {128,128,128,0.25} rendered as "transparent white").
local HOVER_STATION = { 0.16, 0.78, 0.31, 0.35 }
local HOVER_STREET = { 0.24, 0.55, 1.0, 0.35 }
local UPGRADE = { 1.0, 0.63, 0.0, 0.45 }
overlay.UPGRADE_COLOUR = UPGRADE
overlay.FALLBACK_COLOUR = { 0.5, 0.5, 0.5, 0.25 }

local function setZone(name, polygon, colour, group)
	if not polygon or #polygon < 3 then return end
	game.interface.setZone(name, { polygon = polygon, draw = true, drawColor = colour })
	drawn[name] = true
	if group then
		groups[group] = groups[group] or {}
		groups[group][name] = true
	end
end

local function clearGroup(group)
	for name in pairs(groups[group] or {}) do
		game.interface.setZone(name, nil)
		drawn[name] = nil
	end
	groups[group] = {}
end

function overlay.clear()
	for name in pairs(drawn) do game.interface.setZone(name, nil) end
	drawn = {}
	groups = {}
end

local function v3to2d(v) return { v.x, v.y } end

local function hermiteStrip(p0, t0, p1, t1, w)
	local t0perp = vec3.normalize(util.rotateXY(t0, math.rad(90)))
	local t1perp = vec3.normalize(util.rotateXY(t1, math.rad(90)))
	local result = {}
	for i = 0, 6 do
		result[#result + 1] = v3to2d(util.hermite(i / 6, p0 + w * t0perp, t0, p1 + w * t1perp, t1).p)
	end
	for i = 6, 0, -1 do
		result[#result + 1] = v3to2d(util.hermite(i / 6, p0 - w * t0perp, t0, p1 - w * t1perp, t1).p)
	end
	return result
end

-- entity as returned by util.searchForNearestEntity for a BASE_EDGE
function overlay.getShapeForEdge(edge)
	local w = util.getEdgeWidth(edge.id) / 2
	return hermiteStrip(util.v3fromArr(edge.node0pos), util.v3fromArr(edge.node0tangent),
		util.v3fromArr(edge.node1pos), util.v3fromArr(edge.node1tangent), w)
end

-- any street edge id (used for route preview edges from pathfinding)
function overlay.shapeForEdgeId(edgeId)
	local edge = api.engine.getComponent(edgeId, api.type.ComponentType.BASE_EDGE)
	if not edge then return nil end
	local w = util.getEdgeWidth(edgeId) / 2
	return hermiteStrip(util.nodePos(edge.node0), util.v3(edge.tangent0), util.nodePos(edge.node1), util.v3(edge.tangent1), w)
end

function overlay.getShapeForConstruction(entity)
	local result = {}
	local bbox
	pcall(function() bbox = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME) end)
	if not bbox then return nil end
	local isInBox = function(p)
		return p.x >= bbox.bbox.min.x and p.x <= bbox.bbox.max.x and p.y >= bbox.bbox.min.y and p.y <= bbox.bbox.max.y
	end
	local x = (bbox.bbox.max.x - bbox.bbox.min.x) / 2
	local y = (bbox.bbox.max.y - bbox.bbox.min.y) / 2
	local construction = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
	local p = util.v3(construction.transf:cols(3))
	local t0 = util.v3(construction.transf:cols(0))
	local t1 = util.v3(construction.transf:cols(1))
	local midP = vec3.new((bbox.bbox.min.x + bbox.bbox.max.x) / 2, (bbox.bbox.min.y + bbox.bbox.max.y) / 2, p.z)
	p = midP
	local maxExtent = math.ceil(math.sqrt(x * x + y * y))
	for i = 1, maxExtent do
		if not isInBox(p + i * t0) then x = i; break end
	end
	for i = 1, maxExtent do
		if not isInBox(p + i * t1) then y = i; break end
	end
	result[1] = v3to2d(p + x * t0 + y * t1)
	result[2] = v3to2d(p + x * t0 - y * t1)
	result[3] = v3to2d(p - x * t0 - y * t1)
	result[4] = v3to2d(p - x * t0 + y * t1)
	return result
end

function overlay.getShapeForEntity(entity)
	if entity.type == "BASE_EDGE" then
		return overlay.getShapeForEdge(entity)
	end
	return overlay.getShapeForConstruction(api.engine.system.streetConnectorSystem.getConstructionEntityForStation(entity.id))
end

-- entity: nil or { id=, type="BASE_EDGE"|"STATION", ... }
function overlay.setHover(entity)
	clearGroup("hover")
	if not entity then return end
	local shape = overlay.getShapeForEntity(entity)
	setZone("blt_hover", shape, entity.type == "BASE_EDGE" and HOVER_STREET or HOVER_STATION, "hover")
end

-- stops: { {id=, pos={x,y}, colour={r,g,b,a}, pending=bool}, ... } in line order
function overlay.setStops(stops)
	clearGroup("stops")
	for i, stop in ipairs(stops) do
		local alpha = stop.pending and 0.3 or 0.6
		local colour = { stop.colour[1], stop.colour[2], stop.colour[3], alpha }
		setZone("blt_stop_" .. i, geometry.circle(stop.pos[1], stop.pos[2], 6, 20), colour, "stops")
		local digits = geometry.digitPolygons(i, stop.pos[1] - 2.25, stop.pos[2] + 10)
		for k, poly in ipairs(digits) do
			setZone("blt_digit_" .. i .. "_" .. k, poly, { colour[1], colour[2], colour[3], 0.9 }, "stops")
		end
	end
end

-- edges: { {edgeId=, colour={r,g,b,a}}, ... }; a shape that cannot be built is skipped
function overlay.setRouteEdges(edges)
	clearGroup("route")
	for i, edge in ipairs(edges) do
		local ok, shape = pcall(overlay.shapeForEdgeId, edge.edgeId)
		if ok and shape then setZone("blt_route_" .. i, shape, edge.colour, "route") end
	end
end

-- points: list of {x, y}; drawn as a closed thin polygon (out and back)
function overlay.setFallbackPolyline(points, colour)
	clearGroup("polyline")
	if #points < 2 then return end
	local shape = {}
	for i = 1, #points do shape[#shape + 1] = points[i] end
	for i = #points - 1, 2, -1 do shape[#shape + 1] = points[i] end
	setZone("blt_route_line", shape, colour, "polyline")
end

return overlay
```

- [ ] **Step 6: Use the overlay from the game script**

In `res/config/game_script/bus_line_tool_script.lua`:

1. Add `local overlay = require("bus_line_tool_overlay")` after the window require.
2. Delete `v3to2d`, `getShapeForEdge`, `getShapeForConstruction`, `getShapeForEntity` and replace every remaining use of `getShapeForEntity(` with `overlay.getShapeForEntity(`.
3. In `updateCircle`, replace the section from `local circles = guiState.circles` to the end of the function with:

```lua
	local circle = guiState.circles["mouse"] or {}
	guiState.circles["mouse"] = circle
	local prevX = circle.pos and circle.pos[1]
	local prevY = circle.pos and circle.pos[2]
	circle.pos = pos
	circle.radius = 50
	local entity = util.searchForNearestEntity(util.v3fromArr(circle.pos), circle.radius, "STATION",
		function(station) return not station.cargo and station.carriers.ROAD end)
	if not entity then
		entity = util.searchForNearestEntity(util.v3fromArr(circle.pos), circle.radius, "BASE_EDGE",
			function(edge)
				return not edge.track and not util.isFrozenEdge(edge.id)
					and #util.getEdge(edge.id).objects == 0 and util.getEdgeLength(edge.id) > 40
			end)
	end
	guiState.entity = entity
	if entity then
		circle.pos = util.v3ToArr(getPosition(entity.id))
	end
	local circleChanged = prevX ~= circle.pos[1] or prevY ~= circle.pos[2]
	if circleChanged then
		overlay.setHover(entity)
		if guiState.ui then
			if not entity then
				guiState.ui.setStatus(_("Nothing selectable here"))
			elseif entity.type == "BASE_EDGE" then
				guiState.ui.setStatus(_("Street segment: click to add a stop"))
			else
				local name = api.engine.getComponent(entity.id, api.type.ComponentType.NAME)
				guiState.ui.setStatus(_("Station: ") .. (name and name.name or "?") .. _(" — click to add"))
			end
		end
	end
```

4. Replace the route-drawing block at the top of `updateCircle` (the `if guiState.needsRedrawRoute then ... end` block) with:

```lua
	if guiState.needsRedrawRoute then
		guiState.needsRedrawRoute = false -- do upfront to avoid repeated exceptions
		local stops = {}
		for i, entityId in ipairs(guiState.selectedEntities) do
			local p = getPosition(entityId)
			stops[i] = { id = entityId, pos = { p.x, p.y }, colour = guiState.colours[i], pending = guiState.stopMeta[i] and guiState.stopMeta[i].pending }
		end
		overlay.setStops(stops)
		if #stops > 1 then
			local points = {}
			for i, stop in ipairs(stops) do points[i] = stop.pos end
			if guiState.isCircle then points[#points + 1] = stops[1].pos end
			overlay.setFallbackPolyline(points, overlay.FALLBACK_COLOUR)
		else
			overlay.setFallbackPolyline({}, nil)
		end
	end
```

5. In `removeCircles()` add `overlay.clear()` as the first line. In the mouse listener, remove the `addCircle(entityString, circle, colour, shape)` line and the `removeCircle(entityString)` line (stop markers are now drawn from `needsRedrawRoute`), and set `guiState.needsRedrawRoute = true` (already there). Keep `addCircle`/`removeCircle` functions for the stops section's remove button, but make `removeCircle` also set `guiState.needsRedrawRoute = true`.

- [ ] **Step 7: Syntax-check, install, hand off**

Run: `luac -p res/config/game_script/bus_line_tool_script.lua res/scripts/bus_line_tool_overlay.lua && lua5.4 test/run.lua && ./install.sh`

Tell the user: open the tool, hover a street (blue) and a station (green), click three stops. Expected: numbered markers 1–3 with digits north of each circle, a grey straight polyline between them, status line names the hovered thing.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add overlay module: hover colours, numbered seven-segment stop markers

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
```

---

### Task 5: Route preview and upgrade preview

**Files:**
- Create: `res/scripts/bus_line_tool_upgrade_rules.lua`, `test/test_upgrade_rules.lua`
- Modify: `res/scripts/bus_line_tool_route_builder.lua:2072-2090` (`initEntity` uses the rules), `res/scripts/bus_line_tool_pathfinding_util.lua` (add `findRoadPathBetweenEntities`), `res/config/game_script/bus_line_tool_script.lua` (route preview in `updateCircle`)
- Modify: `test/run.lua` (add `"test_upgrade_rules"`)

**Interfaces:**
- Produces (pure): `rules.targets(street, params) -> { hasBus = bool, tramTrackType = int }` and `rules.needsUpgrade(street, params) -> bool` where `street = { hasBus = bool, tramTrackType = int }` and `params = { addBusLanes = bool, tramTrackType = int, tramOnlyUpgrade = bool }`.
- Produces: `pathFindingUtil.findRoadPathBetweenEntities(a, b, isTram) -> { {entity = edgeId, index = laneIndex}, ... }` where `a`, `b` are station ids or street edge ids.

- [ ] **Step 1: Write the failing rules tests**

`test/test_upgrade_rules.lua`:

```lua
local t = {}

function t.bus_lane_requested_and_missing_needs_upgrade()
  local rules = require("bus_line_tool_upgrade_rules")
  assert(rules.needsUpgrade({ hasBus = false, tramTrackType = 0 }, { addBusLanes = true, tramTrackType = 0 }))
  assert(not rules.needsUpgrade({ hasBus = true, tramTrackType = 0 }, { addBusLanes = true, tramTrackType = 0 }))
end

function t.tram_track_below_required_needs_upgrade()
  local rules = require("bus_line_tool_upgrade_rules")
  assert(rules.needsUpgrade({ hasBus = false, tramTrackType = 0 }, { addBusLanes = false, tramTrackType = 1 }))
  assert(rules.needsUpgrade({ hasBus = false, tramTrackType = 1 }, { addBusLanes = false, tramTrackType = 2 }))
  assert(not rules.needsUpgrade({ hasBus = false, tramTrackType = 2 }, { addBusLanes = false, tramTrackType = 1 }))
end

function t.nothing_requested_never_upgrades()
  local rules = require("bus_line_tool_upgrade_rules")
  assert(not rules.needsUpgrade({ hasBus = false, tramTrackType = 0 }, { addBusLanes = false, tramTrackType = 0 }))
end

function t.targets_never_downgrade()
  local rules = require("bus_line_tool_upgrade_rules")
  local target = rules.targets({ hasBus = true, tramTrackType = 2 }, { addBusLanes = false, tramTrackType = 1 })
  assert(target.hasBus == true and target.tramTrackType == 2)
end

function t.tram_only_upgrade_ignores_bus_lanes()
  local rules = require("bus_line_tool_upgrade_rules")
  local target = rules.targets({ hasBus = false, tramTrackType = 0 }, { addBusLanes = true, tramTrackType = 1, tramOnlyUpgrade = true })
  assert(target.hasBus == false and target.tramTrackType == 1)
end

return t
```

Add `"test_upgrade_rules",` to `files`.

- [ ] **Step 2: Run to see failures**

Run: `lua5.4 test/run.lua`
Expected: 5 failures, module not found.

- [ ] **Step 3: Write the rules module**

`res/scripts/bus_line_tool_upgrade_rules.lua`:

```lua
-- Which street attributes a route upgrade sets. Used by the builder (route_builder.initEntity)
-- and by the overlay preview so that the orange "will be upgraded" edges match what gets built.
local rules = {}

function rules.targets(street, params)
	local hasBus = street.hasBus
	if params.addBusLanes and not params.tramOnlyUpgrade then hasBus = true end
	local tramTrackType = math.max(street.tramTrackType or 0, params.tramTrackType or 0)
	return { hasBus = hasBus, tramTrackType = tramTrackType }
end

function rules.needsUpgrade(street, params)
	local target = rules.targets(street, params)
	return target.hasBus ~= street.hasBus or target.tramTrackType ~= (street.tramTrackType or 0)
end

return rules
```

- [ ] **Step 4: Run tests**

Run: `lua5.4 test/run.lua`
Expected: `17 passed, 0 failed`

- [ ] **Step 5: Use the rules in route_builder.initEntity**

In `res/scripts/bus_line_tool_route_builder.lua` add near the other requires at the top:

```lua
local upgradeRules = require("bus_line_tool_upgrade_rules")
```

In `initEntity` (inside `tryRoadRouteForUpgrade`) replace:

```lua
		entity.streetEdge.streetType = preferredStreetType
		if not params.tramOnlyUpgrade then 
			entity.streetEdge.hasBus = entity.streetEdge.hasBus or params.addBusLanes 
		end
		entity.streetEdge.tramTrackType = math.max(entity.streetEdge.tramTrackType, params.tramTrackType)
		return entity
```

with:

```lua
		entity.streetEdge.streetType = preferredStreetType
		local target = upgradeRules.targets(entity.streetEdge, params)
		entity.streetEdge.hasBus = target.hasBus
		entity.streetEdge.tramTrackType = target.tramTrackType
		return entity
```

Add at the end of the file, before `return routeBuilder`:

```lua
-- Preview helper: true when building with `params` would change this street edge.
function routeBuilder.edgeNeedsUpgrade(edgeId, params)
	local street = api.engine.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
	if not street then return false end
	return upgradeRules.needsUpgrade({ hasBus = street.hasBus, tramTrackType = street.tramTrackType }, params)
end
```

- [ ] **Step 6: Add the mixed-entity path helper**

In `res/scripts/bus_line_tool_pathfinding_util.lua`, add before `function pathFindingUtil.findPath(`:

```lua
-- Road path between two entities that are each either a station id or a street edge id.
-- Returns the list from findPath ({entity=, index=} per lane edge), possibly empty.
function pathFindingUtil.findRoadPathBetweenEntities(a, b, isTram)
	local function isEdge(id) return util.getEdge(id) ~= nil end
	local mode = isTram and api.type.enum.TransportMode.TRAM or api.type.enum.TransportMode.BUS
	local startingEdges
	if isEdge(a) then
		startingEdges = pathFindingUtil.getStartingEdgesForEdge(a, mode)
	else
		startingEdges = pathFindingUtil.getStartingEdgesForEdge(findStreetEdgeForStation(a), mode)
	end
	local destNodes
	if isEdge(b) then
		local edge = util.getEdge(b)
		local startPos = isEdge(a) and util.getEdgeMidPoint(a) or util.getStationPosition(a)
		local targetNode = edge.node1
		if util.distance(util.nodePos(edge.node0), startPos) > util.distance(util.nodePos(edge.node1), startPos) and not util.isOneWayStreet(b) then
			targetNode = edge.node0
		end
		destNodes = pathFindingUtil.getDestinationNodesForEdge(b, mode, targetNode)
	else
		destNodes = pathFindingUtil.getDestinationNodesForStation(b)
	end
	local ok, answer = pcall(pathFindingUtil.findPath, startingEdges, destNodes, { mode }, math.huge)
	if not ok then
		trace("findRoadPathBetweenEntities failed", answer)
		return {}
	end
	return answer
end
```

`findStreetEdgeForStation` is a local defined earlier in the same file (line ~495); this function must be placed after it.

- [ ] **Step 7: Draw the route preview in the game script**

In `res/config/game_script/bus_line_tool_script.lua` (which already requires `bus_line_tool_route_builder` as `routeBuilder`), add after the requires:

```lua
local pathFindingUtil = require("bus_line_tool_pathfinding_util")
local routeCache = {}
```

Replace the fallback-polyline part of the `needsRedrawRoute` block (from `if #stops > 1 then` to its matching `end`) with:

```lua
		if #stops > 1 then
			local isTram = guiState.ui and guiState.ui.isTram() or false
			local previewParams = {
				addBusLanes = guiState.ui and guiState.ui.addBusLanes() or false,
				tramTrackType = isTram and util.getCurrentTramTrackType() or 0,
			}
			local colour = guiState.ui and guiState.ui.lineColour() or { 0.5, 0.5, 0.5 }
			local lineColour = { colour[1], colour[2], colour[3], 0.3 } -- 0..1 channels, like lineColors
			local edges, seen, missing = {}, {}, {}
			local pairsToDraw = #stops - 1
			if guiState.isCircle then pairsToDraw = #stops end
			for i = 1, pairsToDraw do
				local a = stops[i].id
				local b = stops[i % #stops + 1].id
				local key = a .. ":" .. b .. ":" .. tostring(isTram)
				if not routeCache[key] then
					routeCache[key] = pathFindingUtil.findRoadPathBetweenEntities(a, b, isTram)
				end
				local path = routeCache[key]
				if #path == 0 then
					missing[#missing + 1] = i .. "→" .. (i % #stops + 1)
				end
				for _, e in ipairs(path) do
					if not seen[e.entity] then
						seen[e.entity] = true
						local c = routeBuilder.edgeNeedsUpgrade(e.entity, previewParams) and overlay.UPGRADE_COLOUR or lineColour
						edges[#edges + 1] = { edgeId = e.entity, colour = c }
					end
				end
			end
			overlay.setRouteEdges(edges)
			local points = {}
			for i, stop in ipairs(stops) do points[i] = stop.pos end
			if guiState.isCircle then points[#points + 1] = stops[1].pos end
			if #missing > 0 then
				overlay.setFallbackPolyline(points, overlay.FALLBACK_COLOUR)
				if guiState.ui then guiState.ui.setStatus(_("No road path between stops ") .. table.concat(missing, ", ")) end
			else
				overlay.setFallbackPolyline({}, nil)
			end
		else
			overlay.setRouteEdges({})
			overlay.setFallbackPolyline({}, nil)
		end
```

In `removeCircles()` add `routeCache = {}`.

- [ ] **Step 8: Syntax-check, install, hand off**

Run: `luac -p res/scripts/bus_line_tool_route_builder.lua res/scripts/bus_line_tool_pathfinding_util.lua res/config/game_script/bus_line_tool_script.lua && lua5.4 test/run.lua && ./install.sh`

Tell the user: select three stops on connected streets. Expected: the streets between them fill in the line colour; ticking "Bus lanes" turns streets without bus lanes orange; picking TRAM turns streets without tram tracks orange; an unreachable pair falls back to the grey straight line and the status says which pair. If the log shows `findRoadPathBetweenEntities failed` the pathfinding call is not usable from the GUI state; in that case leave the fallback polyline as the only preview and note it in the README.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Route preview along streets with shared upgrade rules and orange upgrade segments

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
```

---

### Task 6: Auto line name and chosen colour

**Files:**
- Create: `res/scripts/bus_line_tool_naming.lua`, `test/test_naming.lua`
- Modify: `res/scripts/bus_line_tool_builder.lua:262-320` (`setupLine` uses `param.lineName` / `param.lineColour`), `res/config/game_script/bus_line_tool_script.lua` (`onNameNeeded`)
- Modify: `test/run.lua` (add `"test_naming"`)

**Interfaces:**
- Produces (pure): `naming.suggest(input) -> string` with `input = { carrier = "Bus"|"Tram", towns = { "TownA", ..., "TownZ" } (one per stop, in order), isCircle = bool, existingNames = { "name", ... } }`.

- [ ] **Step 1: Write the failing naming tests**

`test/test_naming.lua`:

```lua
local t = {}

function t.single_town_counts_existing_lines()
  local naming = require("bus_line_tool_naming")
  assert(naming.suggest({ carrier = "Bus", towns = { "Springfield", "Springfield" }, isCircle = false, existingNames = {} }) == "Springfield Bus 1")
  assert(naming.suggest({ carrier = "Bus", towns = { "Springfield", "Springfield" }, isCircle = false, existingNames = { "Springfield Bus 1", "Springfield Bus 7", "Springfield Tram 1" } }) == "Springfield Bus 3")
end

function t.circle_line_gets_ring()
  local naming = require("bus_line_tool_naming")
  assert(naming.suggest({ carrier = "Tram", towns = { "Shelbyville", "Shelbyville", "Shelbyville" }, isCircle = true, existingNames = { "Shelbyville Tram Ring 1" } }) == "Shelbyville Tram Ring 2")
end

function t.two_towns_use_en_dash_and_suffix_only_on_collision()
  local naming = require("bus_line_tool_naming")
  assert(naming.suggest({ carrier = "Bus", towns = { "Springfield", "Ogdenville", "Shelbyville" }, isCircle = false, existingNames = {} }) == "Springfield – Shelbyville Bus")
  assert(naming.suggest({ carrier = "Bus", towns = { "Springfield", "Shelbyville" }, isCircle = false, existingNames = { "Springfield – Shelbyville Bus" } }) == "Springfield – Shelbyville Bus 2")
  assert(naming.suggest({ carrier = "Bus", towns = { "Springfield", "Shelbyville" }, isCircle = false, existingNames = { "Springfield – Shelbyville Bus", "Springfield – Shelbyville Bus 2" } }) == "Springfield – Shelbyville Bus 3")
end

function t.unknown_towns_fall_back()
  local naming = require("bus_line_tool_naming")
  assert(naming.suggest({ carrier = "Bus", towns = {}, isCircle = false, existingNames = {} }) == "Bus 1")
  assert(naming.suggest({ carrier = "Bus", towns = { false, "Springfield" }, isCircle = false, existingNames = {} }) == "Springfield Bus 1")
end

return t
```

Add `"test_naming",` to `files`.

- [ ] **Step 2: Run to see failures**

Run: `lua5.4 test/run.lua`
Expected: 4 failures, module not found.

- [ ] **Step 3: Write the naming module**

`res/scripts/bus_line_tool_naming.lua`:

```lua
-- Suggests a name for a new line. Pure; see spec §7.
local naming = {}

local function escape(s) return (s:gsub("%p", "%%%1")) end

local function countWithPrefix(existingNames, prefix)
	local count = 0
	local pattern = "^" .. escape(prefix) .. " %d+$"
	for _, name in ipairs(existingNames) do
		if name == prefix or name:match(pattern) then count = count + 1 end
	end
	return count
end

local function exists(existingNames, name)
	for _, n in ipairs(existingNames) do if n == name then return true end end
	return false
end

function naming.suggest(input)
	local towns = {}
	for i = 1, #input.towns do if input.towns[i] then towns[#towns + 1] = input.towns[i] end end
	local first, last = towns[1], towns[#towns]
	local existing = input.existingNames or {}

	if first and last and first ~= last then
		local base = first .. " – " .. last .. " " .. input.carrier
		if not exists(existing, base) then return base end
		local n = 2
		while exists(existing, base .. " " .. n) do n = n + 1 end
		return base .. " " .. n
	end

	local prefix = input.carrier
	if first then prefix = first .. " " .. input.carrier end
	if input.isCircle then prefix = prefix .. " Ring" end
	return prefix .. " " .. (countWithPrefix(existing, prefix) + 1)
end

return naming
```

- [ ] **Step 4: Run tests**

Run: `lua5.4 test/run.lua`
Expected: `21 passed, 0 failed`

- [ ] **Step 5: Wire the suggestion into the GUI**

In `res/config/game_script/bus_line_tool_script.lua` add `local naming = require("bus_line_tool_naming")` after the other requires, and add before `createComponents`:

```lua
local function townNameForEntity(entityId)
	local townId
	if util.getEdge(entityId) then
		local town = util.searchForNearestEntity(util.getEdgeMidPoint(entityId), math.huge, "TOWN")
		return town and town.name
	end
	local ok, id = pcall(api.engine.system.stationSystem.getTown, entityId)
	if ok and id and id ~= -1 then
		local name = api.engine.getComponent(id, api.type.ComponentType.NAME)
		return name and name.name
	end
	return nil
end

local function existingLineNames()
	local names = {}
	for _, lineId in pairs(api.engine.system.lineSystem.getLines()) do
		local name = api.engine.getComponent(lineId, api.type.ComponentType.NAME)
		if name then names[#names + 1] = name.name end
	end
	return names
end

local function suggestedLineName()
	local towns = {}
	for i, entityId in ipairs(guiState.selectedEntities) do
		local ok, town = pcall(townNameForEntity, entityId)
		towns[i] = (ok and town) or false -- false, not nil: keeps the list without holes
	end
	return naming.suggest({
		carrier = guiState.ui and guiState.ui.isTram() and _("Tram") or _("Bus"),
		towns = towns,
		isCircle = guiState.isCircle or false,
		existingNames = existingLineNames(),
	})
end
```

In `createComponents`, replace `onNameNeeded = function() return "" end,` with `onNameNeeded = suggestedLineName,`.

- [ ] **Step 6: Use the name and colour when building**

In `res/scripts/bus_line_tool_builder.lua`, `setupLine`, replace:

```lua
	local lineCount = #api.engine.system.lineSystem.getLines() 
	local name = townName.." ".._("line").." "..tostring(lineCount+1)
```

with:

```lua
	local lineCount = #api.engine.system.lineSystem.getLines()
	local name = param.lineName
	if not name or name == "" then
		name = townName.." ".._("line").." "..tostring(lineCount+1)
	end
	local colour
	if param.lineColour and param.lineColour[1] then
		colour = api.type.Vec3f.new(param.lineColour[1], param.lineColour[2], param.lineColour[3])
	else
		colour = lineColorFn()
	end
```

and replace `api.cmd.make.createLine(name, lineColorFn() , game.interface.getPlayer(), line)` with `api.cmd.make.createLine(name, colour, game.interface.getPlayer(), line)`.

- [ ] **Step 7: Syntax-check, install, hand off**

Run: `luac -p res/scripts/bus_line_tool_builder.lua res/config/game_script/bus_line_tool_script.lua && lua5.4 test/run.lua && ./install.sh`

Tell the user: pick stops in one town, the Name field should read like "Springfield Bus 3"; pick a colour; Build. Expected: the new line in the game's line list has that name and colour. Edit the name before building and confirm the edited name wins.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Suggest line names from towns and pass chosen colour to createLine

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
```

---

### Task 7: Keep truck stops when upgrading a combined station

**Files:**
- Create: `res/scripts/bus_line_tool_station_modules.lua`, `test/test_station_modules.lua`
- Modify: `res/scripts/bus_line_tool_builder.lua:150-160` (`upgradeRoadStation` module assignment)
- Modify: `test/run.lua` (add `"test_station_modules"`)

**Interfaces:**
- Produces (pure): `stationModules.merge(existing, generated) -> modules` where both are `{ [slotId] = moduleTable }`; result keeps every existing entry and adds generated entries for slots that did not exist.

- [ ] **Step 1: Write the failing tests**

`test/test_station_modules.lua`:

```lua
local t = {}

local function cargo() return { name = "station/street/cargo_platform.module", variant = 0 } end
local function pax() return { name = "station/street/passenger_platform.module", variant = 0 } end

function t.existing_truck_modules_survive()
  local sm = require("bus_line_tool_station_modules")
  local existing = { [100] = cargo(), [101] = cargo(), [900] = { name = "station/street/entrance_exit.module" } }
  local generated = { [100] = pax(), [101] = pax(), [102] = pax(), [900] = { name = "station/street/entrance_exit.module" } }
  local merged = sm.merge(existing, generated)
  assert(merged[100].name == "station/street/cargo_platform.module")
  assert(merged[101].name == "station/street/cargo_platform.module")
  assert(merged[102].name == "station/street/passenger_platform.module")
  assert(merged[900].name == "station/street/entrance_exit.module")
  local count = 0
  for _ in pairs(merged) do count = count + 1 end
  assert(count == 4)
end

function t.inputs_are_not_mutated()
  local sm = require("bus_line_tool_station_modules")
  local existing = { [1] = cargo() }
  local generated = { [1] = pax(), [2] = pax() }
  local merged = sm.merge(existing, generated)
  assert(existing[2] == nil)
  assert(merged[1] ~= existing[1] or merged[1].name == existing[1].name)
end

function t.empty_existing_takes_all_generated()
  local sm = require("bus_line_tool_station_modules")
  local merged = sm.merge({}, { [1] = pax(), [2] = pax() })
  assert(merged[1] and merged[2])
end

return t
```

Add `"test_station_modules",` to `files`.

- [ ] **Step 2: Run to see failures**

Run: `lua5.4 test/run.lua`
Expected: 3 failures, module not found.

- [ ] **Step 3: Write the module**

`res/scripts/bus_line_tool_station_modules.lua`:

```lua
-- Merges the modules of an existing modular road station with the modules a template generates
-- for its new size, keeping every existing module (truck platforms stay truck platforms).
local stationModules = {}

function stationModules.merge(existing, generated)
	local merged = {}
	for slot, module in pairs(existing or {}) do merged[slot] = module end
	for slot, module in pairs(generated or {}) do
		if merged[slot] == nil then merged[slot] = module end
	end
	return merged
end

return stationModules
```

- [ ] **Step 4: Run tests**

Run: `lua5.4 test/run.lua`
Expected: `24 passed, 0 failed`

- [ ] **Step 5: Use it in upgradeRoadStation**

In `res/scripts/bus_line_tool_builder.lua` add near the top requires:

```lua
local stationModules = require("bus_line_tool_station_modules")
```

In `upgradeRoadStation` replace:

```lua
		local modules = util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params))   
		--[[for k, v in pairs(modules) do 
			if not params.modules[k] then 
				params.modules[k]=v 
			end 
		end ]]--
		params.modules = modules
```

with:

```lua
		local generated = util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params))
		-- keep every module the station already has (truck platforms included); add only new slots
		params.modules = stationModules.merge(params.modules, generated)
```

- [ ] **Step 6: Syntax-check, install, hand off**

Run: `luac -p res/scripts/bus_line_tool_builder.lua && lua5.4 test/run.lua && ./install.sh`

Tell the user: build a bus line that reuses a station which has both truck and bus terminals and needs an extra terminal. Expected: after the build the station still shows its truck terminals and truck lines; one extra bus platform appears. If the game rejects the upgrade (log: `upgradeConstruction` error inside pcall, station unchanged), report the log lines.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Keep existing station modules when adding a platform (truck stops preserved)

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
```

---

### Task 8: Edit existing lines

**Files:**
- Create: `res/scripts/bus_line_tool_line_editor.lua`, `test/test_line_editor.lua`
- Modify: `res/scripts/bus_line_tool_builder.lua` (expose `builder.buildStopsProposal`, `builder.createStopForStation`, `builder.stationForBuiltStop`), `res/scripts/bus_line_tool_line_manager.lua` (expose `isBusOrTramLine`, `isTramLine`), `res/config/game_script/bus_line_tool_script.lua` (`onEditLoad`, `onEditApply`, `onLineListNeeded`, `handleEvent` for `editBusLine`)
- Modify: `test/run.lua` (add `"test_line_editor"`)

**Interfaces:**
- Produces (pure): `lineEditor.plan(originalStopCount, entities, stopMeta) -> { {origIndex = int|nil, entityId = id}, ... }`; `lineEditor.stationsOnly(plan, resolveStation) -> {stationIds}`.
- Produces (engine): `lineEditor.applyEdit(param, deps)` with `param = { lineId, entities, stopMeta, addBusLanes, ignoreErrors, name }` and `deps = { builder, routeBuilder, paramHelper, util, lineManager, addWork, addDelayedWork, standardCallback }`.
- Produces (GUI): `lineEditor.listLines() -> { {id=, name=, firstStation=}, ... }` sorted by name; `lineEditor.load(lineId) -> { stations = {ids}, name = string, isTram = bool, isCircle = bool }`.
- Consumes: `builder.buildStopsProposal(edgeIds, positionsOut) -> proposal` (first half of `createBusLine`), `builder.stationForBuiltStop(position, nextStopPos) -> stationId|nil`, `builder.createStopForStation(stationId, nextStopPos)`.

- [ ] **Step 1: Write the failing plan tests**

`test/test_line_editor.lua`:

```lua
local t = {}

function t.unchanged_line_reuses_every_original_stop()
  local le = require("bus_line_tool_line_editor")
  local plan = le.plan(3, { 10, 20, 30 }, { { origIndex = 1 }, { origIndex = 2 }, { origIndex = 3 } })
  assert(#plan == 3)
  for i = 1, 3 do assert(plan[i].origIndex == i and plan[i].entityId == i * 10) end
end

function t.inserted_stop_has_no_original_index()
  local le = require("bus_line_tool_line_editor")
  local plan = le.plan(2, { 10, 99, 20 }, { { origIndex = 1 }, { pending = true }, { origIndex = 2 } })
  assert(plan[2].origIndex == nil and plan[2].entityId == 99)
  assert(plan[3].origIndex == 2)
end

function t.removed_stop_disappears_and_duplicates_keep_own_index()
  local le = require("bus_line_tool_line_editor")
  -- original A B C B ; user removed the second B (index 4)
  local plan = le.plan(4, { 1, 2, 3 }, { { origIndex = 1 }, { origIndex = 2 }, { origIndex = 3 } })
  assert(#plan == 3 and plan[2].origIndex == 2)
end

function t.stations_only_resolves_pending_edges()
  local le = require("bus_line_tool_line_editor")
  local plan = { { origIndex = 1, entityId = 10 }, { entityId = 99 }, { origIndex = 2, entityId = 20 } }
  local stations = le.stationsOnly(plan, function(entityId) return entityId == 99 and 555 or entityId end)
  assert(stations[1] == 10 and stations[2] == 555 and stations[3] == 20)
end

function t.stations_only_drops_unresolved()
  local le = require("bus_line_tool_line_editor")
  local plan = { { entityId = 10 }, { entityId = 99 } }
  local stations = le.stationsOnly(plan, function(entityId) return entityId == 10 and 10 or nil end)
  assert(#stations == 1 and stations[1] == 10)
end

return t
```

Add `"test_line_editor",` to `files`.

- [ ] **Step 2: Run to see failures**

Run: `lua5.4 test/run.lua`
Expected: 5 failures, module not found.

- [ ] **Step 3: Write the line editor module**

`res/scripts/bus_line_tool_line_editor.lua`:

```lua
-- Editing existing bus and tram lines. Pure planning functions at the top (unit-tested);
-- game-facing load/list (GUI state) and applyEdit (engine state) below.
local lineEditor = {}

-- entities: working list of entity ids in stop order; stopMeta[i] = { origIndex = n } for stops
-- that came from the line, { pending = true } for stops the user added.
function lineEditor.plan(originalStopCount, entities, stopMeta)
	local plan = {}
	for i, entityId in ipairs(entities) do
		local meta = stopMeta[i] or {}
		local origIndex = meta.origIndex
		if origIndex and (origIndex < 1 or origIndex > originalStopCount) then origIndex = nil end
		plan[i] = { entityId = entityId, origIndex = origIndex }
	end
	return plan
end

-- resolveStation(entityId) -> stationId or nil (nil drops the stop, e.g. a street stop that failed to build)
function lineEditor.stationsOnly(plan, resolveStation)
	local stations = {}
	for _, entry in ipairs(plan) do
		local station = resolveStation(entry.entityId)
		if station then stations[#stations + 1] = station end
	end
	return stations
end

---------------------------------------------------------------------------------------------
-- GUI side

function lineEditor.listLines(lineManager)
	local result = {}
	local player = api.engine.util.getPlayer()
	for _, lineId in pairs(api.engine.system.lineSystem.getLines()) do
		local ok = pcall(function()
			local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
			if not line or not lineManager.isBusOrTramLine(line) then return end
			local owned = api.engine.getComponent(lineId, api.type.ComponentType.PLAYER_OWNED)
			if owned and owned.player ~= player then return end
			local name = api.engine.getComponent(lineId, api.type.ComponentType.NAME)
			local firstStation = #line.stops > 0 and lineManager.stationFromStop(line.stops[1]) or nil
			result[#result + 1] = { id = lineId, name = name and name.name or ("line " .. lineId), firstStation = firstStation }
		end)
		if not ok then print("bus_line_tool: could not read line " .. tostring(lineId)) end
	end
	table.sort(result, function(a, b) return a.name < b.name end)
	return result
end

function lineEditor.load(lineId, lineManager)
	local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local name = api.engine.getComponent(lineId, api.type.ComponentType.NAME)
	local stations = {}
	for i, stop in ipairs(line.stops) do stations[i] = lineManager.stationFromStop(stop) end
	return {
		stations = stations,
		name = name and name.name or "",
		isTram = lineManager.isTramLine(line),
		isCircle = lineManager.isCircleLine(line),
		stopCount = #line.stops,
	}
end

---------------------------------------------------------------------------------------------
-- Engine side

local function buildLine(lineId, plan, resolveStation, builder, util)
	local original = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local line = api.type.Line.new()
	line.vehicleInfo = original.vehicleInfo
	pcall(function() line.waitingTime = original.waitingTime end)
	local stations = lineEditor.stationsOnly(plan, resolveStation)
	local k = 0
	for i, entry in ipairs(plan) do
		local station = resolveStation(entry.entityId)
		if station then
			k = k + 1
			if entry.origIndex and original.stops[entry.origIndex] then
				line.stops[k] = original.stops[entry.origIndex]
			else
				local nextStation = stations[k % #stations + 1]
				line.stops[k] = builder.createStopForStation(station, util.getStationPosition(nextStation))
			end
		end
	end
	return line, stations
end

function lineEditor.applyEdit(param, deps)
	local builder, util, routeBuilder, paramHelper, lineManager = deps.builder, deps.util, deps.routeBuilder, deps.paramHelper, deps.lineManager
	if not api.engine.entityExists(param.lineId) then
		print("bus_line_tool: line " .. tostring(param.lineId) .. " no longer exists, edit cancelled")
		return
	end
	local loaded = lineEditor.load(param.lineId, lineManager)
	local plan = lineEditor.plan(loaded.stopCount, param.entities, param.stopMeta)

	local edgeIds, positions = {}, {}
	for _, entry in ipairs(plan) do
		if util.getEdge(entry.entityId) then edgeIds[#edgeIds + 1] = entry.entityId end
	end

	local function finish()
		local builtStation = {}
		for _, edgeId in ipairs(edgeIds) do
			local pos = positions[edgeId]
			if pos then
				local nextEntity
				for i, entry in ipairs(plan) do
					if entry.entityId == edgeId then nextEntity = (plan[i % #plan + 1] or entry).entityId end
				end
				local nextPos = nextEntity and (util.getEdge(nextEntity) and util.getEdgeMidPoint(nextEntity) or util.getStationPosition(nextEntity)) or pos.p
				builtStation[edgeId] = builder.stationForBuiltStop(pos, nextPos)
			end
		end
		local function resolveStation(entityId)
			if builtStation[entityId] then return builtStation[entityId] end
			if util.getEdge(entityId) then return nil end
			return entityId
		end
		local line, stations = buildLine(param.lineId, plan, resolveStation, builder, util)
		if #stations < 2 then
			print("bus_line_tool: edit would leave fewer than two stops, cancelled")
			return
		end
		api.cmd.sendCommand(api.cmd.make.updateLine(param.lineId, line), function(res, success)
			print("bus_line_tool: updateLine " .. tostring(success))
			if not success then return end
			if param.name and param.name ~= "" and param.name ~= loaded.name then
				local ok, err = pcall(function()
					api.cmd.sendCommand(api.cmd.make.setName(param.lineId, param.name), function(_, ok2) print("bus_line_tool: rename " .. tostring(ok2)) end)
				end)
				if not ok then print("bus_line_tool: rename not supported: " .. tostring(err)) end
			end
			if param.addBusLanes or loaded.isTram then
				deps.addWork(function()
					local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", false, param.ignoreErrors)
					params.setAddBusLanes(param.addBusLanes)
					if loaded.isTram then params.tramTrackType = util.getCurrentTramTrackType() end
					routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, deps.standardCallback, params, loaded.isCircle)
				end)
			end
		end)
	end

	if #edgeIds == 0 then
		finish()
		return
	end
	local proposal = builder.buildStopsProposal(edgeIds, positions)
	api.cmd.sendCommand(api.cmd.make.buildProposal(proposal, util.initContext(), param.ignoreErrors), function(res, success)
		print("bus_line_tool: built " .. #edgeIds .. " new stops: " .. tostring(success))
		if success then
			deps.addDelayedWork(finish)
		end
	end)
end

return lineEditor
```

- [ ] **Step 4: Run tests**

Run: `lua5.4 test/run.lua`
Expected: `29 passed, 0 failed`

- [ ] **Step 5: Expose builder pieces**

In `res/scripts/bus_line_tool_builder.lua`:

1. After `local function createStopForStation(stationId, nextStopPos) ... end` add:

```lua
builder.createStopForStation = createStopForStation
```

2. Extract the first half of `createBusLine` into a reusable function. Add before `function builder.createBusLine(param)`:

```lua
-- Builds the street proposal that places a bus stop pair on each edge. positionsOut[edgeId] = {p=, p0=, p1=}.
function builder.buildStopsProposal(edgeIds, positionsOut)
	local busStopModel = getBusStopModel()
	local edgeObjectsToAdd = {}
	local newProposal = api.type.SimpleProposal.new()
	local countByTown = {}
	for _, edgeId in ipairs(edgeIds) do
		local j = 1 + #newProposal.streetProposal.edgesToAdd
		local entity = util.copyExistingEdge(edgeId, -j)
		local p = util.getEdgeMidPoint(edgeId)
		local objects = {}
		local town = util.searchForNearestEntity(p, math.huge, "TOWN")
		if not countByTown[town.id] then
			countByTown[town.id] = util.countBusStopsForTown(town) + 1
		else
			countByTown[town.id] = countByTown[town.id] + 1
		end
		local name = town.name .. " " .. _("stop") .. " " .. tostring(countByTown[town.id])
		for _, left in pairs({ true, false }) do
			table.insert(objects, { -1 - #edgeObjectsToAdd, left and 0 or 1 })
			local newStop = api.type.SimpleStreetProposal.EdgeObject.new()
			newStop.left = left
			newStop.oneWay = false
			newStop.playerEntity = api.engine.util.getPlayer()
			newStop.edgeEntity = entity.entity
			newStop.name = name
			newStop.model = busStopModel
			newStop.param = 0.5
			table.insert(edgeObjectsToAdd, newStop)
		end
		entity.comp.objects = objects
		newProposal.streetProposal.edgesToAdd[j] = entity
		newProposal.streetProposal.edgesToRemove[j] = edgeId
		local edge = util.getEdge(edgeId)
		positionsOut[edgeId] = { p = p, p0 = util.nodePos(edge.node0), p1 = util.nodePos(edge.node1) }
	end
	for i, edgeObj in pairs(edgeObjectsToAdd) do
		newProposal.streetProposal.edgeObjectsToAdd[i] = edgeObj
	end
	return newProposal
end

-- After a stop pair was built on an edge, returns the station on the side facing nextStopPos.
function builder.stationForBuiltStop(position, nextStopPos)
	local edgeId = util.findEdgeConnectingPoints(position.p0, position.p1)
	if not edgeId then return nil end
	local edge = util.getEdge(edgeId)
	local left = util.distance(nextStopPos, position.p0) < util.distance(nextStopPos, position.p1)
	local target = left and api.type.enum.EdgeObjectType.STOP_LEFT or api.type.enum.EdgeObjectType.STOP_RIGHT
	for _, edgeObj in pairs(edge.objects) do
		if edgeObj[2] == target then return edgeObj[1] end
	end
	return nil
end
```

3. In `createBusLine`, the existing loop over `selectedEntities` stays as it is (it also collects station entries); no behaviour change is required there.

- [ ] **Step 6: Expose line_manager predicates**

In `res/scripts/bus_line_tool_line_manager.lua` after `local function isAirLine(line) ... end` add:

```lua
function lineManager.isTramLine(line) return isTramLine(line) end
function lineManager.isBusOrTramLine(line) return isBusLine(line) or isTramLine(line) end
```

- [ ] **Step 7: Wire the GUI and the engine event**

In `res/config/game_script/bus_line_tool_script.lua`:

1. Add requires: `local lineEditor = require("bus_line_tool_line_editor")` and `local paramHelper = require("bus_line_tool_base_param_helper")`.

2. Add before `createComponents`:

```lua
local function loadLineForEdit(lineId)
	removeCircles()
	local loaded = lineEditor.load(lineId, lineManager)
	guiState.editLine = { lineId = lineId, name = loaded.name, isTram = loaded.isTram, isCircle = loaded.isCircle, stopCount = loaded.stopCount }
	guiState.isCircle = loaded.isCircle
	for i, station in ipairs(loaded.stations) do
		guiState.selectedEntities[i] = station
		guiState.colours[i] = nextColour()
		guiState.stopMeta[i] = { origIndex = i }
	end
	guiState.selectedRow = -1
	guiState.needsRedrawRoute = true
	guiState.isActive = true
	guiState.ui.refreshStops()
end
```

3. In `createComponents` replace the three placeholders:

```lua
		onEditLoad = loadLineForEdit,
		onEditApply = function(param)
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("bus_line_tool_script.lua", "editBusLine", "", param), standardCallback)
		end,
		onLineListNeeded = function() return lineEditor.listLines(lineManager) end,
```

4. In `removeCircles()` add `guiState.editLine = nil`.

5. In `data().handleEvent` add after the `createBusLine` branch:

```lua
			if src == "bus_line_tool_script.lua" and id == "editBusLine" then
				addWork(function()
					lineEditor.applyEdit(param, {
						builder = builder, util = util, routeBuilder = routeBuilder, paramHelper = paramHelper,
						lineManager = lineManager, addWork = addWork, addDelayedWork = addDelayedWork, standardCallback = standardCallback,
					})
				end)
			end
```

- [ ] **Step 8: Syntax-check, install, hand off**

Run: `luac -p res/scripts/bus_line_tool_line_editor.lua res/scripts/bus_line_tool_builder.lua res/scripts/bus_line_tool_line_manager.lua res/config/game_script/bus_line_tool_script.lua && lua5.4 test/run.lua && ./install.sh`

Tell the user: open the Edit line tab, pick a bus line. Expected: its stops appear numbered in the table and on the map with the route drawn. Select row 2, click a street: a faint (pending) marker is inserted after stop 2. Remove one stop with its × button. Change the name. Apply. Expected log lines: `built 1 new stops: true`, `updateLine true`, `rename true` (or `rename not supported`, in which case the name stays and that is reported). The line window in the game shows the new stop order and the vehicles still assigned.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Edit existing bus and tram lines: load, insert, remove, rename, apply

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
```

---

### Task 9: Final verification, README checklist, tag

**Files:**
- Modify: `README.md` (in-game checklist and known limitations)

- [ ] **Step 1: Run everything**

Run: `lua5.4 test/run.lua && for f in $(git ls-files 'res/*.lua'); do luac -p "$f" || echo "SYNTAX $f"; done && ./install.sh`
Expected: `29 passed, 0 failed`, no `SYNTAX` lines.

- [ ] **Step 2: Add the checklist to README**

Append to `README.md`:

```markdown
## In-game checklist

1. Load "gtnh kab" with the fork enabled and the Workshop copy disabled: no freeze, no crash, and no `bus_line_tool: discovered` line in stdout.txt until the window is opened.
2. Open the tool: one `bus_line_tool: discovered N bus, M tram models in X ms` line; the chooser lists buses with capacity and speed.
3. Place three stops on streets: numbered markers, route along the streets, green/blue hover, orange segments with Bus lanes on.
4. Build: the line gets the suggested (or edited) name and the chosen colour; vehicles are bought.
5. Reuse a combined bus/truck station: truck stop intact.
6. Edit line tab: add a stop after row 2, remove one, rename, Apply; line updated, vehicles still assigned.

## Known limitations

- No keyboard shortcut (the scripting API has no key listener).
- Colour cannot be changed on an existing line (no command for it).
- A street stop added in edit mode is inserted once, on the side facing the next stop; add the opposite side by clicking the new station in a second edit.
- Stop numbers are drawn as seven-segment digits on the terrain because scripts cannot draw text in the world.
```

- [ ] **Step 3: Commit and tag**

```bash
git add -A
git commit -m "Add in-game checklist and known limitations

Claude-Session: https://claude.ai/code/session_016Ji7iFUfxKbf3iV44jToGe"
git tag v2.0-fork
```

- [ ] **Step 4: Report to the user**

Summarise which in-game checks passed per the user's reports, which API fallbacks kicked in (colour chooser, pathfinding from GUI, rename), and any remaining open items.
