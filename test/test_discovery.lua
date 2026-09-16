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
