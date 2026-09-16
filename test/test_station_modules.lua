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
  assert(merged ~= existing and merged ~= generated, "merge must return a new table")
  assert(existing[2] == nil, "existing gained a key")
  assert(existing[1].name == "station/street/cargo_platform.module", "existing entry changed")
  assert(generated[1].name == "station/street/passenger_platform.module" and generated[2].name == "station/street/passenger_platform.module", "generated entries changed")
  local count = 0
  for _ in pairs(generated) do count = count + 1 end
  assert(count == 2, "generated gained or lost keys")
end

function t.empty_existing_takes_all_generated()
  local sm = require("bus_line_tool_station_modules")
  local merged = sm.merge({}, { [1] = pax(), [2] = pax() })
  assert(merged[1] and merged[2])
end

return t
