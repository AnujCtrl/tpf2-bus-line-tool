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
