-- In-world drawing for the bus line tool. Everything goes through game.interface.setZone.
-- Zone names all start with "blt_" so clear() removes exactly what this module drew.
local util = require("bus_line_tool_base_util")
local vec3 = require("vec3")
local geometry = require("bus_line_tool_overlay_geometry")

local overlay = {}
local drawn = {}          -- name -> true for every zone currently drawn
local groups = {}         -- group -> { name = true } so a group can be replaced atomically

-- Zone colours are {r, g, b, a} with every channel in 0..1 (the game clamps larger values, which
-- is why upstream's {128,128,128,0.25} rendered as "transparent white").
local HOVER_STATION = { 0.16, 0.78, 0.31, 0.35 }
local HOVER_STREET = { 0.24, 0.55, 1.0, 0.35 }
local UPGRADE = { 1.0, 0.63, 0.0, 0.45 }
overlay.UPGRADE_COLOUR = UPGRADE
overlay.FALLBACK_COLOUR = { 0.5, 0.5, 0.5, 0.25 }

local function setZone(name, polygon, colour, group)
	if not polygon or #polygon < 3 then return end
	game.interface.setZone(name, { polygon = polygon, draw = true, drawColor = colour })
	drawn[name] = true
	if group then
		groups[group] = groups[group] or {}
		groups[group][name] = true
	end
end

local function clearGroup(group)
	for name in pairs(groups[group] or {}) do
		game.interface.setZone(name, nil)
		drawn[name] = nil
	end
	groups[group] = {}
end

function overlay.clear()
	for name in pairs(drawn) do game.interface.setZone(name, nil) end
	drawn = {}
	groups = {}
end

local function v3to2d(v) return { v.x, v.y } end

local function hermiteStrip(p0, t0, p1, t1, w)
	local t0perp = vec3.normalize(util.rotateXY(t0, math.rad(90)))
	local t1perp = vec3.normalize(util.rotateXY(t1, math.rad(90)))
	local result = {}
	for i = 0, 6 do
		result[#result + 1] = v3to2d(util.hermite(i / 6, p0 + w * t0perp, t0, p1 + w * t1perp, t1).p)
	end
	for i = 6, 0, -1 do
		result[#result + 1] = v3to2d(util.hermite(i / 6, p0 - w * t0perp, t0, p1 - w * t1perp, t1).p)
	end
	return result
end

-- entity as returned by util.searchForNearestEntity for a BASE_EDGE
function overlay.getShapeForEdge(edge)
	local w = util.getEdgeWidth(edge.id) / 2
	return hermiteStrip(util.v3fromArr(edge.node0pos), util.v3fromArr(edge.node0tangent),
		util.v3fromArr(edge.node1pos), util.v3fromArr(edge.node1tangent), w)
end

-- any street edge id (used for route preview edges from pathfinding)
function overlay.shapeForEdgeId(edgeId)
	local edge = api.engine.getComponent(edgeId, api.type.ComponentType.BASE_EDGE)
	if not edge then return nil end
	local w = util.getEdgeWidth(edgeId) / 2
	return hermiteStrip(util.nodePos(edge.node0), util.v3(edge.tangent0), util.nodePos(edge.node1), util.v3(edge.tangent1), w)
end

function overlay.getShapeForConstruction(entity)
	local result = {}
	local bbox
	pcall(function() bbox = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME) end)
	if not bbox then return nil end
	local isInBox = function(p)
		return p.x >= bbox.bbox.min.x and p.x <= bbox.bbox.max.x and p.y >= bbox.bbox.min.y and p.y <= bbox.bbox.max.y
	end
	local x = (bbox.bbox.max.x - bbox.bbox.min.x) / 2
	local y = (bbox.bbox.max.y - bbox.bbox.min.y) / 2
	local construction = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
	local p = util.v3(construction.transf:cols(3))
	local t0 = util.v3(construction.transf:cols(0))
	local t1 = util.v3(construction.transf:cols(1))
	local midP = vec3.new((bbox.bbox.min.x + bbox.bbox.max.x) / 2, (bbox.bbox.min.y + bbox.bbox.max.y) / 2, p.z)
	p = midP
	local maxExtent = math.ceil(math.sqrt(x * x + y * y))
	for i = 1, maxExtent do
		if not isInBox(p + i * t0) then x = i; break end
	end
	for i = 1, maxExtent do
		if not isInBox(p + i * t1) then y = i; break end
	end
	result[1] = v3to2d(p + x * t0 + y * t1)
	result[2] = v3to2d(p + x * t0 - y * t1)
	result[3] = v3to2d(p - x * t0 - y * t1)
	result[4] = v3to2d(p - x * t0 + y * t1)
	return result
end

function overlay.getShapeForEntity(entity)
	if entity.type == "BASE_EDGE" then
		return overlay.getShapeForEdge(entity)
	end
	return overlay.getShapeForConstruction(api.engine.system.streetConnectorSystem.getConstructionEntityForStation(entity.id))
end

-- entity: nil or { id=, type="BASE_EDGE"|"STATION", ... }
function overlay.setHover(entity)
	clearGroup("hover")
	if not entity then return end
	local shape = overlay.getShapeForEntity(entity)
	setZone("blt_hover", shape, entity.type == "BASE_EDGE" and HOVER_STREET or HOVER_STATION, "hover")
end

-- stops: { {id=, pos={x,y}, colour={r,g,b,a}, pending=bool}, ... } in line order
function overlay.setStops(stops)
	clearGroup("stops")
	for i, stop in ipairs(stops) do
		local alpha = stop.pending and 0.3 or 0.6
		local colour = { stop.colour[1], stop.colour[2], stop.colour[3], alpha }
		setZone("blt_stop_" .. i, geometry.circle(stop.pos[1], stop.pos[2], 6, 20), colour, "stops")
		local digits = geometry.digitPolygons(i, stop.pos[1] - 2.25, stop.pos[2] + 10)
		for k, poly in ipairs(digits) do
			setZone("blt_digit_" .. i .. "_" .. k, poly, { colour[1], colour[2], colour[3], 0.9 }, "stops")
		end
	end
end

-- edges: { {edgeId=, colour={r,g,b,a}}, ... }; a shape that cannot be built is skipped
function overlay.setRouteEdges(edges)
	clearGroup("route")
	for i, edge in ipairs(edges) do
		local ok, shape = pcall(overlay.shapeForEdgeId, edge.edgeId)
		if ok and shape then setZone("blt_route_" .. i, shape, edge.colour, "route") end
	end
end

-- points: list of {x, y}; drawn as a closed thin polygon (out and back)
function overlay.setFallbackPolyline(points, colour)
	clearGroup("polyline")
	if #points < 2 then return end
	local shape = {}
	for i = 1, #points do shape[#shape + 1] = points[i] end
	for i = #points - 1, 2, -1 do shape[#shape + 1] = points[i] end
	setZone("blt_route_line", shape, colour, "polyline")
end

return overlay
