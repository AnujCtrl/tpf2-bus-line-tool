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
