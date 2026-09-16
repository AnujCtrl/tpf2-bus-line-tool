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
local routeCache = {}

local workItems = {}

local function addWork(work) 
	table.insert(workItems, work)
end 
local function addDelayedWork(work) 
	table.insert(workItems, 1, work)
end 
local function err(x)
	print("An error was caught",x)
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
				tramTrackType = isTram and util.getCurrentTramTrackType() or 0,
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
				local idx = util.indexOf(guiState.selectedEntities, entityId)
				if idx ~= -1 then --treat as deselection
					table.remove(guiState.selectedEntities, idx)
					table.remove(guiState.colours, idx)
					table.remove(guiState.stopMeta, idx)
				else
					local colour = nextColour()
					local insertAt = #guiState.selectedEntities + 1
					if guiState.ui and guiState.ui.mode() == "edit" and guiState.ui.selectedRow() >= 0 then
						insertAt = math.min(guiState.ui.selectedRow() + 2, #guiState.selectedEntities + 1)
					end
					table.insert(guiState.selectedEntities, insertAt, entityId)
					table.insert(guiState.colours, insertAt, colour)
					table.insert(guiState.stopMeta, insertAt, { pending = true })
				end
				addWork(function() guiState.ui.refreshStops() end)
				wasHandled = true
			end
		end,
		err)
	end
	return wasHandled
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
		onEditLoad = function(lineId) end,   -- filled in Task 8
		onEditApply = function(param) end,  -- filled in Task 8
		onLineListNeeded = function() return {} end, -- filled in Task 8
		onNameNeeded = function() return "" end,     -- filled in Task 6
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
				xpcall(updateCircle, err)
			end 
			if #workItems > 0 then
				xpcall(table.remove(workItems, #workItems), err)  
			end 
        end,
		handleEvent = function (src, id, name, param)
			if src == "bus_line_tool_script.lua" and id == "createBusLine" then 
				addWork(function() builder.createBusLine(param) end)
			end 
		end
    }
end


 