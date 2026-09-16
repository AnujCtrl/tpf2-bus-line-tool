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
