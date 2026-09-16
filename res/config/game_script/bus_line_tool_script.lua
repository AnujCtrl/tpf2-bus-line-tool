local gui = require("gui")
local vec2 = require("vec2")
local util = require("bus_line_tool_base_util")
local builder = require("bus_line_tool_builder")
local lineManager = require("bus_line_tool_line_manager")
local constructionUtil = require("bus_line_tool_construction_util")
local routeBuilder = require("bus_line_tool_route_builder")
local vehicleUtil = require("bus_line_tool_vehicle_util")
local windowModule = require("bus_line_tool_window")
local overlay = require("bus_line_tool_overlay")
local trace = util.trace
local pathFindingUtil = require("bus_line_tool_pathfinding_util")
local naming = require("bus_line_tool_naming")
local lineEditor = require("bus_line_tool_line_editor")
local paramHelper = require("bus_line_tool_base_param_helper")
local routeCache = {}

local workItems = {}

local function addWork(work) 
	table.insert(workItems, work)
end 
local function addDelayedWork(work) 
	table.insert(workItems, 1, work)
end 
-- Every log line the README tells the user to grep for starts with "bus_line_tool:".
local function err(x)
	print("bus_line_tool: error " .. tostring(x))
	print(debug.traceback())
end  
local function standardCallback(res, success) 
	trace("command was completed, success= ",success)
	
	if success then 
		util.clearCacheNode2SegMaps() 
	elseif util.tracelog then  
		debugPrint(res)
	end 
	
end

builder.standardCallback = standardCallback
builder.addWork = addWork
builder.addDelayedWork = addDelayedWork
lineManager.addWork = addWork
lineManager.addDelayedWork = addDelayedWork
lineManager.standardCallback = standardCallback
constructionUtil.addWork = addWork
constructionUtil.standardCallback = standardCallback
routeBuilder.addWork = addWork
routeBuilder.standardCallback = standardCallback
--local circle = {
 --radius = math.huge,
 --pos = {0,0}
--}

local guiState = {
	circles = {},
	
	selectedEntities = {},
	stopMeta = {},
	colours = {},
	isActive = false
}

local function nextColour()  
	local colors = api.res.getBaseConfig().gui.lineColors
	if not guiState.nextColour then 
		guiState.nextColour = math.random(1, #colors)
	end
	
	local color = colors[guiState.nextColour]
	--color = api.type.Vec3f.new(color[1],color[2],color[3])
	color = { color[1],color[2],color[3] , 1}
	guiState.nextColour = guiState.nextColour+1
	if guiState.nextColour > #colors then
		guiState.nextColour = 1
	end
	return color
end

local function isMouseWithinWindow() 
	local rect = guiState.window:getContentRect()
	local mousePos = api.gui.util.getMouseScreenPos()
	if rect:contains(mousePos.x, mousePos.y) then 
		return true 
	end 
	if guiState.window2:isVisible() then 
		return guiState.window2:getContentRect():contains(mousePos.x, mousePos.y)
	end 
	return false
end
 
local function removeCircle(name)
	game.interface.setZone(name, nil)
	guiState.circles[name]=nil
	guiState.needsRedrawRoute = true
end

 local function getPosition(entityId)
	if util.getEdge(entityId) then 
		return  util.getEdgeMidPoint(entityId)
	else 
		return util.getStationPosition(entityId)
	end 
 end 	
 
-- Tram track type the preview should require: mirrors the build rule (electric tram + catenary year).
local function previewTramTrackType()
	if not (guiState.ui and guiState.ui.isTram()) then return 0 end
	if guiState.ui.mode() == "edit" then return util.getCurrentTramTrackType() end
	local catenary = util.year() >= api.res.getBaseConfig().tramCatenaryYearFrom
	return (catenary and guiState.ui.isElectricTramSelected()) and 2 or 1
end

local function updateCircle()
	if guiState.needsRedrawRoute then
		guiState.needsRedrawRoute = false -- do upfront to avoid repeated exceptions
		local stops = {}
		for i, entityId in ipairs(guiState.selectedEntities) do
			local p = getPosition(entityId)
			stops[i] = { id = entityId, pos = { p.x, p.y }, colour = guiState.colours[i], pending = guiState.stopMeta[i] and guiState.stopMeta[i].pending }
		end
		overlay.setStops(stops)
		if #stops > 1 then
			local isTram = guiState.ui and guiState.ui.isTram() or false
			local previewParams = {
				addBusLanes = guiState.ui and guiState.ui.addBusLanes() or false,
				tramTrackType = previewTramTrackType(),
			}
			local colour = guiState.ui and guiState.ui.lineColour() or { 0.5, 0.5, 0.5 }
			local lineColour = { colour[1], colour[2], colour[3], 0.3 } -- 0..1 channels, like lineColors
			local edges, seen, missing = {}, {}, {}
			local pairsToDraw = #stops - 1
			if guiState.isCircle then pairsToDraw = #stops end
			for i = 1, pairsToDraw do
				local a = stops[i].id
				local b = stops[i % #stops + 1].id
				local key = a .. ":" .. b .. ":" .. tostring(isTram)
				if not routeCache[key] then
					routeCache[key] = pathFindingUtil.findRoadPathBetweenEntities(a, b, isTram)
				end
				local path = routeCache[key]
				if #path == 0 then
					missing[#missing + 1] = i .. "→" .. (i % #stops + 1)
				end
				for _, e in ipairs(path) do
					if not seen[e.entity] then
						seen[e.entity] = true
						local c = routeBuilder.edgeNeedsUpgrade(e.entity, previewParams) and overlay.UPGRADE_COLOUR or lineColour
						edges[#edges + 1] = { edgeId = e.entity, colour = c }
					end
				end
			end
			overlay.setRouteEdges(edges)
			local points = {}
			for i, stop in ipairs(stops) do points[i] = stop.pos end
			if guiState.isCircle then points[#points + 1] = stops[1].pos end
			if #missing > 0 then
				overlay.setFallbackPolyline(points, overlay.FALLBACK_COLOUR)
				if guiState.ui then guiState.ui.setStatus(_("No road path between stops ") .. table.concat(missing, ", ")) end
			else
				overlay.setFallbackPolyline({}, nil)
			end
		else
			overlay.setRouteEdges({})
			overlay.setFallbackPolyline({}, nil)
		end
	end
	if isMouseWithinWindow() then
		--trace("Suppressed update circle due to in window")
		return
	end
	local pos = game.gui.getTerrainPos()
	if not pos then
		-- trace("No position found")
		return
	end
	local circle = guiState.circles["mouse"] or {}
	guiState.circles["mouse"] = circle
	local prevX = circle.pos and circle.pos[1]
	local prevY = circle.pos and circle.pos[2]
	circle.pos = pos
	circle.radius = 50
	local entity = util.searchForNearestEntity(util.v3fromArr(circle.pos), circle.radius, "STATION",
		function(station) return not station.cargo and station.carriers.ROAD end)
	if not entity then
		entity = util.searchForNearestEntity(util.v3fromArr(circle.pos), circle.radius, "BASE_EDGE",
			function(edge)
				return not edge.track and not util.isFrozenEdge(edge.id)
					and #util.getEdge(edge.id).objects == 0 and util.getEdgeLength(edge.id) > 40
			end)
	end
	guiState.entity = entity
	if entity then
		circle.pos = util.v3ToArr(getPosition(entity.id))
	end
	local circleChanged = prevX ~= circle.pos[1] or prevY ~= circle.pos[2]
	if circleChanged then
		overlay.setHover(entity)
		if guiState.ui then
			if not entity then
				guiState.ui.setStatus(_("Nothing selectable here"))
			elseif entity.type == "BASE_EDGE" then
				guiState.ui.setStatus(_("Street segment: click to add a stop"))
			else
				local name = api.engine.getComponent(entity.id, api.type.ComponentType.NAME)
				guiState.ui.setStatus(_("Station: ") .. (name and name.name or "?") .. _(" — click to add"))
			end
		end
	end
end



local function removeCircles()
	overlay.clear()
	for k, v in pairs(guiState.circles) do
		removeCircle(k)
	end 
	guiState.entity = nil
	guiState.selectedEntities = {}
	guiState.colours = {}
	guiState.stopMeta = {}
	routeCache = {}
	guiState.editLine = nil

end


local mouseListener = function(MouseEvent)
	local wasHandled = false
	if guiState.isActive then 
		xpcall(
		function() 
			if  guiState.entity and MouseEvent.type == 2 and MouseEvent.button == 0 and not isMouseWithinWindow() then 
				--debugPrint(MouseEvent)
				guiState.needsRedrawRoute = true
				local entityId = guiState.entity.id
				trace("Processing mouseEvent the selected entity was ", entityId)
				local mode = guiState.ui and guiState.ui.mode() or "new"
				local idx = util.indexOf(guiState.selectedEntities, entityId)
				-- Only a new line deselects on a second click. An edited line may legitimately
				-- visit the same station twice (A-B-C-B), so in edit mode a click always inserts;
				-- rows are removed with the row's own remove button.
				if mode == "new" and idx ~= -1 then --treat as deselection
					table.remove(guiState.selectedEntities, idx)
					table.remove(guiState.colours, idx)
					table.remove(guiState.stopMeta, idx)
				else
					local colour = nextColour()
					local insertAt = #guiState.selectedEntities + 1
					if mode == "edit" and guiState.ui.selectedRow() >= 0 then
						insertAt = math.min(guiState.ui.selectedRow() + 2, #guiState.selectedEntities + 1)
					end
					-- "pending" means a stop that still has to be built: only a street edge added
					-- to an existing line is. New-line stops are all built by Build, so they draw
					-- at the full marker alpha.
					local meta = {}
					if mode == "edit" and util.getEdge(entityId) ~= nil then meta = { pending = true } end
					table.insert(guiState.selectedEntities, insertAt, entityId)
					table.insert(guiState.colours, insertAt, colour)
					table.insert(guiState.stopMeta, insertAt, meta)
				end
				addWork(function() guiState.ui.refreshStops() end)
				wasHandled = true
			end
		end,
		err)
	end
	return wasHandled
end

local function townNameForEntity(entityId)
	local townId
	if util.getEdge(entityId) then
		local town = util.searchForNearestEntity(util.getEdgeMidPoint(entityId), math.huge, "TOWN")
		return town and town.name
	end
	local ok, id = pcall(api.engine.system.stationSystem.getTown, entityId)
	if ok and id and id ~= -1 then
		local name = api.engine.getComponent(id, api.type.ComponentType.NAME)
		return name and name.name
	end
	return nil
end

local function existingLineNames()
	local names = {}
	for _, lineId in pairs(api.engine.system.lineSystem.getLines()) do
		local name = api.engine.getComponent(lineId, api.type.ComponentType.NAME)
		if name then names[#names + 1] = name.name end
	end
	return names
end

local function suggestedLineName()
	local towns = {}
	for i, entityId in ipairs(guiState.selectedEntities) do
		local ok, town = pcall(townNameForEntity, entityId)
		towns[i] = (ok and town) or false -- false, not nil: keeps the list without holes
	end
	return naming.suggest({
		carrier = guiState.ui and guiState.ui.isTram() and _("Tram") or _("Bus"),
		towns = towns,
		isCircle = guiState.isCircle or false,
		existingNames = existingLineNames(),
	})
end

-- Loads an existing line into the working state so it can be edited: its stops become the
-- selected entities, each tagged with the index of the stop it came from.
local function loadLineForEdit(lineId)
	removeCircles()
	local loaded = lineEditor.load(lineId, lineManager)
	guiState.editLine = { lineId = lineId, name = loaded.name, isTram = loaded.isTram, isCircle = loaded.isCircle, stopCount = loaded.stopCount }
	guiState.isCircle = loaded.isCircle
	for i, station in ipairs(loaded.stations) do
		guiState.selectedEntities[i] = station
		guiState.colours[i] = nextColour()
		guiState.stopMeta[i] = { origIndex = i }
	end
	guiState.selectedRow = -1
	guiState.needsRedrawRoute = true
	guiState.isActive = true
	guiState.ui.refreshStops()
end

local function createComponents()
	local gameBar = api.gui.util.getById("gameInfo.layout")
	if not gameBar then
		return
	end
	local ui = windowModule.create({
		guiState = guiState,
		addWork = addWork,
		err = err,
		getPosition = getPosition,
		removeCircle = removeCircle,
		removeCircles = removeCircles,
		updateCircle = updateCircle,
		onBuild = function(param)
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("bus_line_tool_script.lua", "createBusLine", "", param), standardCallback)
		end,
		onEditLoad = loadLineForEdit,
		onEditApply = function(param)
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("bus_line_tool_script.lua", "editBusLine", "", param), standardCallback)
		end,
		onLineListNeeded = function() return lineEditor.listLines(lineManager) end,
		onNameNeeded = suggestedLineName,
		colourDefault = function()
			local colours = api.res.getBaseConfig().gui.lineColors
			local c = colours[math.random(1, #colours)]
			return { c[1], c[2], c[3] }
		end,
	})
	guiState.ui = ui
	ui.window:setVisible(false, false)
	api.gui.util.getGameUI():getMainRendererComponent():insertMouseListener(mouseListener)

	local icon = api.gui.comp.ImageView.new("ui/icons/windows/destinations@4x.tga")
	local layout = api.gui.util.getById("mainButtonsLayout"):getItem(1):getLayout()
	icon:setMaximumSize(api.gui.util.Size.new(60, 60))
	icon:setMinimumSize(api.gui.util.Size.new(50, 50))
	local button = api.gui.comp.ToggleButton.new(icon)
	button:setTooltip(_("Bus Line Tool"))
	button:setName("ConstructionMenuIndicator")
	layout:insertItem(button, 0)
	local vehiclesLoaded = false
	button:onToggle(function(b)
		ui.window:setVisible(b, false)
		guiState.isActive = b
		if b then
			local mainView = game.gui.getContentRect("mainView")
			ui.window:setPosition(math.floor(mainView[3] / 2), math.floor(mainView[4] * (2 / 3)))
			if not vehiclesLoaded then
				vehiclesLoaded = true
				addWork(function() xpcall(ui.refreshVehicles, err) end) -- first (and only) vehicle discovery
			end
			pcall(ui.refreshLineList)
			xpcall(ui.refreshStops, err)
		else
			ui.window:close()
		end
	end)
	guiState.isInit = true
end


function data()
    return {
		guiInit = function()
			xpcall(createComponents, err)
		end,
		update = function() 
			if #workItems > 0 then
				xpcall(table.remove(workItems, #workItems), err) 
			end
		end, 
        guiUpdate = function()
			if not guiState.isInit then 
				xpcall(createComponents, err) 
				guiState.isInit = true -- in case of exception don't keep trying
			end
			if guiState.isActive then 
				-- An overlay failure would otherwise leave stale zones on the map with no hint why.
				xpcall(updateCircle, function(x)
					err(x)
					pcall(overlay.clear)
					if guiState.ui then
						pcall(function() guiState.ui.setStatus(_("Overlay error: ") .. tostring(x)) end)
					end
				end)
			end 
			if #workItems > 0 then
				xpcall(table.remove(workItems, #workItems), err)  
			end 
        end,
		handleEvent = function (src, id, name, param)
			if src == "bus_line_tool_script.lua" and id == "createBusLine" then 
				addWork(function() builder.createBusLine(param) end)
			end 
			if src == "bus_line_tool_script.lua" and id == "editBusLine" then
				addWork(function()
					lineEditor.applyEdit(param, {
						builder = builder, util = util, routeBuilder = routeBuilder, paramHelper = paramHelper,
						lineManager = lineManager, addWork = addWork, addDelayedWork = addDelayedWork, standardCallback = standardCallback,
					})
				end)
			end
		end
    }
end


 