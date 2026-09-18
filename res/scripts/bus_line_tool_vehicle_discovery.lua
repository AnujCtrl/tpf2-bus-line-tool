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
  for __, name in pairs(names) do
    local suffix = string.sub(name, -7, -5)
    if suffix == "_v3" then
      legacy[string.sub(name, 1, -8) .. "_v2.mdl"] = true
    elseif suffix == "_v2" then
      legacy[string.sub(name, 1, -8) .. ".mdl"] = true
    end
  end
  return legacy
end

-- Label for the vehicle chooser: "<name> · <pax> pax · <speed>".
-- capacityByCargo is the model's entry of cargoCapacityLookup (may be nil); formatSpeed formats a top speed (api.util.formatSpeed in game).
function discovery.describeVehicle(model, capacityByCargo, formatSpeed)
  local pax = capacityByCargo and capacityByCargo["PASSENGERS"] or 0
  local config = model.metadata.roadVehicle or model.metadata.railVehicle
  local speed = config and config.topSpeed and formatSpeed(config.topSpeed) or "?"
  return _(model.metadata.description.name) .. " · " .. tostring(pax) .. " pax · " .. speed
end

-- env: see plan Task 2 "Interfaces". wanted: { bus = true, tram = true }.
function discovery.run(env, wanted)
  local started = env.clock()
  local names = {}
  for __, name in pairs(env.getAllModels()) do names[#names + 1] = name end
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
  for __, ct in ipairs(cargoTypes) do
    local weight = env.getCargoType(ct.idx).weight
    result.cargoWeightLookup[ct.idx] = weight
    result.cargoWeightLookup[ct.name] = weight
  end

  for __, name in ipairs(names) do
    local vehicleType = discovery.vehicleTypeForName(name, wanted)
    if vehicleType and not legacy[name] then
      local ok, err = pcall(function()
        local id = env.findModel(name)
        local copy = discovery.copyModel(env.getModel(id))
        result.modelRepLookup[id] = copy
        result.modelNameLookup[id] = env.getModelName(id)
        result.modelAvailability[id] = env.availability(name, vehicleType, copy)

        local capacity, cargoIdx, inverse = {}, {}, {}
        for __, ct in ipairs(cargoTypes) do
          capacity[ct.idx] = 0
          capacity[ct.name] = 0
        end
        local tv = copy.metadata.transportVehicle
        if tv then
          for __, compartment in pairs(tv.compartments) do
            for j, loadConfig in pairs(compartment.loadConfigs) do
              for __, entry in pairs(loadConfig.cargoEntries) do
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
  local vehicleTypes = {}
  for vehicleType in pairs(result.counts) do vehicleTypes[#vehicleTypes + 1] = vehicleType end
  table.sort(vehicleTypes)
  local summary = {}
  for __, vehicleType in ipairs(vehicleTypes) do summary[#summary + 1] = result.counts[vehicleType] .. " " .. vehicleType end
  env.log(("bus_line_tool: discovered %s models in %.0f ms (%d skipped)"):format(table.concat(summary, ", "), result.millis, #result.skipped))
  return result
end

return discovery
