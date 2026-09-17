-- Static guards for mistakes the game only reveals at runtime.
local t = {}

-- Files written or rewritten by the fork (upstream helpers are left alone).
local FORK_FILES = {
  "res/config/game_script/bus_line_tool_script.lua",
  "res/scripts/bus_line_tool_window.lua",
  "res/scripts/bus_line_tool_overlay.lua",
  "res/scripts/bus_line_tool_overlay_geometry.lua",
  "res/scripts/bus_line_tool_line_editor.lua",
  "res/scripts/bus_line_tool_naming.lua",
  "res/scripts/bus_line_tool_vehicle_discovery.lua",
  "res/scripts/bus_line_tool_upgrade_rules.lua",
  "res/scripts/bus_line_tool_station_modules.lua",
  "res/scripts/bus_line_tool_builder.lua",
  "res/scripts/bus_line_tool_vehicle_util.lua",
  "res/scripts/bus_line_tool_pathfinding_util.lua",
  "res/scripts/bus_line_tool_route_builder.lua",
}

local function readLines(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("a")
  f:close()
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  return lines
end

-- In Transport Fever 2, `_` is the translation function. A loop variable, a local or a parameter
-- named `_` shadows it and any later `_("text")` in that scope calls a number (this crashed Build
-- once). The local pattern also has to catch `local _, x = f()`, and the parameter pattern has to
-- catch a bare `_` anywhere in the list; the %f frontiers keep `__` (the approved spelling) clean.
function t.no_loop_variable_shadows_the_translator()
  local offenders = {}
  for _i, path in ipairs(FORK_FILES) do
    for n, line in ipairs(readLines(path)) do
      if line:match("for%s+_%s*[,i]") or line:match("^%s*local%s+_%s*[,=]") or line:match("function%s*%([^)]*%f[%w_]_%f[^%w_]") then
        offenders[#offenders + 1] = path .. ":" .. n .. ": " .. line:gsub("^%s+", "")
      end
    end
  end
  assert(#offenders == 0, "`_` shadowed in:\n  " .. table.concat(offenders, "\n  "))
end

-- Every fork file must parse under the host luac (catches the `0then` class of typo).
function t.fork_files_parse()
  for _i, path in ipairs(FORK_FILES) do
    local ok = os.execute("luac -p " .. path .. " >/dev/null 2>&1")
    assert(ok, path .. " does not parse")
  end
end

return t
