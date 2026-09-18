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
