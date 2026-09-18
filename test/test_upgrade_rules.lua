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
