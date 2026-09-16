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
-- A stop's waypoints describe the leg leaving it, so they survive only while its successor is the
-- same original stop. Lines are cyclic: the last stop leads back to the first.
local function reused(i) return { origIndex = i, entityId = i * 10 } end
local inserted = { entityId = 99 }

function t.successor_unchanged_when_the_line_was_not_touched()
  local le = require("bus_line_tool_line_editor")
  local plan = { reused(1), reused(2), reused(3) }
  for k = 1, 3 do assert(le.successorChanged(plan, k, 3) == false) end
end

function t.inserting_a_stop_changes_only_the_stop_before_it()
  local le = require("bus_line_tool_line_editor")
  local plan = { reused(1), inserted, reused(2), reused(3) } -- X inserted after A
  assert(le.successorChanged(plan, 1, 3) == true)  -- A now leads to X
  assert(le.successorChanged(plan, 2, 3) == true)  -- X is new, it has no original leg
  assert(le.successorChanged(plan, 3, 3) == false) -- B -> C untouched
  assert(le.successorChanged(plan, 4, 3) == false) -- C -> A untouched
end

function t.removing_a_stop_changes_its_predecessor()
  local le = require("bus_line_tool_line_editor")
  local plan = { reused(1), reused(3) } -- B removed from A B C
  assert(le.successorChanged(plan, 1, 3) == true)  -- A -> C is a new leg
  assert(le.successorChanged(plan, 2, 3) == false) -- C -> A still wraps to A
end

function t.successor_of_the_last_stop_wraps_to_the_first()
  local le = require("bus_line_tool_line_editor")
  local plan = { inserted, reused(1), reused(2), reused(3) } -- X inserted before A
  assert(le.successorChanged(plan, 4, 3) == true)  -- C wraps to X now, not to A
  assert(le.successorChanged(plan, 2, 3) == false) -- A -> B untouched
end

return t
