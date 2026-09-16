local gui = require("gui")
local vec2 = require("vec2")
local vec3 = require("vec3")
local util = require("bus_line_tool_base_util")
local builder = require("bus_line_tool_builder")
local lineManager = require("bus_line_tool_line_manager")
local zoneutil = require "mission.zone"
local constructionUtil = require("bus_line_tool_construction_util")
local routeBuilder = require("bus_line_tool_route_builder")
local vehicleUtil = require("bus_line_tool_vehicle_util")
local windowModule = require("bus_line_tool_window")
local trace = util.trace
local v3 = util.v3

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

local function hypot(x, y)
	return math.sqrt(x*x + y*y)
end

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
 
local function addCircle(name, circle, colour, shape)
	if not shape then 
		shape = zoneutil.makeCircleZone(circle.pos , circle.radius, 16)
	end
	game.interface.setZone(name, {
		polygon= shape,
		draw=true,
		drawColor = colour,
	})
	if not guiState.circles[name] then 
		guiState.circles[name]=circle 
	end
end 
local function removeCircle(name)
	game.interface.setZone(name, nil)
	guiState.circles[name]=nil
end 
local function v3to2d(v) 
	return {v.x, v.y }
end  
 
 local function getShapeForEdge(edge) 
	 
	local w = util.getEdgeWidth(edge.id)/2
	local p0 = util.v3fromArr(edge.node0pos)
	local t0 = util.v3fromArr(edge.node0tangent)
	local p1 = util.v3fromArr(edge.node1pos)
	local t1 = util.v3fromArr(edge.node1tangent)
	
	local t0perp = vec3.normalize(util.rotateXY(t0, math.rad(90)))
	local t1perp = vec3.normalize(util.rotateXY(t1, math.rad(90)))
	
	local p0right = p0+w*t0perp
	local p0left = p0-w*t0perp
	local p1right = p1+w*t1perp
	local p1left = p1-w*t1perp
	
	local result = {}
	
	for i = 0, 6 do 
		table.insert(result, v3to2d(util.hermite(i/6, p0right, t0, p1right, t1).p))
	end
	for i = 6, 0, -1 do 
		table.insert(result, v3to2d(util.hermite(i/6, p0left, t0, p1left, t1).p))
	end
	
	return result
 end
 local function getShapeForConstruction(entity ) 
	local result = {}
	local bbox 
	pcall(function() bbox = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME) end)
	if not bbox then 
		trace("Unable to find bbox for ",entity)
		return 
	end
	 
	local isInBox = function(p)   
		return p.x >= bbox.bbox.min.x and p.x <= bbox.bbox.max.x  and p.y >= bbox.bbox.min.y  and p.y <= bbox.bbox.max.y
	end	
	local x = (bbox.bbox.max.x - bbox.bbox.min.x)/2
	local y = (bbox.bbox.max.y - bbox.bbox.min.y)/2
	local construction = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
	local rotation  = vec3.xyAngle(construction.transf:cols(1))
	local rotation  = vec3.xyAngle(construction.transf:cols(0))
	local p  = v3(construction.transf:cols(3))
	local t0 = v3(construction.transf:cols(0))
	local t1 = v3(construction.transf:cols(1))
	
	trace("The rotation was",math.deg(rotation))
	local points = {}
	table.insert(points, vec3.new(bbox.bbox.min.x, bbox.bbox.min.y ,p.z)  )
	table.insert(points, vec3.new(bbox.bbox.min.x, bbox.bbox.max.y  ,p.z )  )
	table.insert(points, vec3.new(bbox.bbox.max.x, bbox.bbox.max.y  ,p.z)  )
	table.insert(points, vec3.new(bbox.bbox.max.x, bbox.bbox.min.y  ,p.z)  )
	-- somewhat crude, not sure how to access the true collider list
	
	local midP = 0.25*(points[1]+points[2]+points[3]+points[4]) 
	--rotation = math.abs(rotation)%math.rad(90)
	for i, point in pairs(points) do 
		local vector = point - midP 
	--	table.insert(result, v3to2d(midP + util.rotateXY(vector, rotation)))
	end 
	
	p = midP
	local maxExtent = math.ceil(hypot(x,y))
	for i = 1, maxExtent do
		local testP = p + i*t0 
		--local entities = util.findIntersectingEntities(testP, 5, 50)
		--if not util.contains(entities, entity.id) then 
		if not isInBox(testP) then 
			x = i
			break
		end 
	end 
	for i = 1, maxExtent do
		--local testY = i*5 
		local testP = p + i*t1 
		--local entities = util.findIntersectingEntities(testP, 5, 50)
		--if not util.contains(entities, entity.id) then 
		if not isInBox(testP) then 
			y = i
			break
		end 
	end 
	 
	
	table.insert(result, v3to2d(p + x*t0 + y*t1))
	table.insert(result, v3to2d(p + x*t0 - y*t1))
	table.insert(result, v3to2d(p - x*t0 - y*t1))
	table.insert(result, v3to2d(p - x*t0 + y*t1))
	
	return result
 end
 
 local function getShapeForEntity(entity) 
	if entity.type == "BASE_EDGE" then 
		return getShapeForEdge(entity)
	else 
		return getShapeForConstruction(api.engine.system.streetConnectorSystem.getConstructionEntityForStation(entity.id))
	end 
 end 
 
 local function getPosition(entityId) 
	if util.getEdge(entityId) then 
		return  util.getEdgeMidPoint(entityId)
	else 
		return util.getStationPosition(entityId)
	end 
 end 	
 
local function updateCircle() 
	local colour = {128,128,128,0.25} -- transparent white 
	if guiState.needsRedrawRoute then 
		guiState.needsRedrawRoute = false -- do upfront to avoid repeated exceptions
		local key = "bus_line_tool_route"
		if #guiState.selectedEntities > 1 then 
			local shape = {}
			for i = 1, #guiState.selectedEntities do 
				local p = getPosition(guiState.selectedEntities[i])
				table.insert(shape, v3to2d(p))
			end 
			if not guiState.isCircle then 
				for i = #guiState.selectedEntities, 1, -1 do 
					table.insert(shape, shape[i])
				end 
			end 
			addCircle(key, true, colour, shape)
		else 
			removeCircle(key)
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
	local circles = guiState.circles
	if not circles["mouse"] then 
		circles["mouse"]={}
	end
	 
	local circle = circles["mouse"]
	local prevX = circle.pos and circle.pos[1]
	local prevY = circle.pos and circle.pos[2]
	
	circle.pos = pos
	circle.radius = 50
	local entity =util.searchForNearestEntity(util.v3fromArr(circle.pos), circle.radius, "STATION", 
		function(station) 
			return
				not station.cargo 
				and station.carriers.ROAD
		end
		)
	if not entity then 
		entity =util.searchForNearestEntity(util.v3fromArr(circle.pos), circle.radius, "BASE_EDGE", 
		function(edge) 
			return
				not edge.track 
				and not util.isFrozenEdge(edge.id) 
				and #util.getEdge(edge.id).objects == 0
				and util.getEdgeLength(edge.id) > 40
		end
		)
	end
	guiState.entity = entity
	local shape
	if entity then 
		--trace("Found entity ",entity.id,"near",  circle.pos[1],    circle.pos[2]) 
		circle.pos =  util.v3ToArr(getPosition(entity.id)) 
		--colour = {0,128,0,0.25} 
		 
		shape = getShapeForEntity(entity)
		  
		
	end 
	local circleChanged = prevX ~= circle.pos[1] or prevY ~= circle.pos[2]
 
	 
	--trace("In updateCircle, circleChanged?",circleChanged, prevX,circle.pos[1], prevY, circle.pos[2] )
	if circleChanged then --performance optimisation
		addCircle("mouse", circle, colour, shape)
	end
	
	
end 



local function removeCircles() 
	for k, v in pairs(guiState.circles) do 
		removeCircle(k)
	end 
	guiState.entity = nil
	guiState.selectedEntities = {}
	guiState.colours = {}
	guiState.stopMeta = {}

end


local mouseListener = function(MouseEvent)
	local wasHandled = false
	if guiState.isActive then 
		xpcall(
		function() 
			if  guiState.entity and MouseEvent.type == 2 and MouseEvent.button == 0 and not isMouseWithinWindow() then 
				--debugPrint(MouseEvent)
				guiState.needsRedrawRoute = true
				local circle = guiState.circles["mouse"]
				local entityId = guiState.entity.id
				trace("Processing mouseEvent the selected entity was ", entityId)
				local entityString = "bus_line_tool"..tostring(entityId)
				local idx = util.indexOf(guiState.selectedEntities, entityId)
				if idx ~= -1 then --treat as deselection
					table.remove(guiState.selectedEntities, idx)
					table.remove(guiState.colours, idx)
					table.remove(guiState.stopMeta, idx)
					removeCircle(entityString)
				else
					local colour = nextColour()
					local shape = getShapeForEntity(guiState.entity)
					addCircle(entityString, circle, colour, shape)
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


 