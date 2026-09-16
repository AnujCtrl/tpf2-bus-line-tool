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

end

  
local function newImageView()
	local icon = api.gui.comp.ImageView.new(" ")
	icon:setMaximumSize(api.gui.util.Size.new(60,60))
	return icon
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
					removeCircle(entityString) 
					--game.interface.setMarker(entityString)
				else 
					local colour = nextColour()
					local shape = getShapeForEntity(guiState.entity)
					addCircle(entityString, circle, colour, shape)
					--game.interface.setMarker(entityString, entityId)
					table.insert(guiState.selectedEntities, entityId) 
					table.insert(guiState.colours, colour)
				end 
				addWork(guiState.refreshTable)
				wasHandled = true
			end
		end,
		err)
	end
	return wasHandled
end 

local function newButton(text) 
	local button = api.gui.comp.Button.new(api.gui.comp.TextView.new(text),true)
	button:addStyleClass("BusLineToolButton")
	return button
end
 
local function buildVehicleSelectionPanel() 
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	boxLayout:addItem(api.gui.comp.TextView.new(_("Vehicle:")))
	local selectedVehicle = api.gui.comp.ImageView.new(" ")
	boxLayout:addItem(selectedVehicle)
	local chooseButton = util.newButton("","ui/button/small/line_tasks@2x.tga")
	boxLayout:addItem(chooseButton)
	
	boxLayout:addItem(api.gui.comp.TextView.new(_("Count:")))
	local countInput = api.gui.comp.TextInputField.new("0")
	boxLayout:addItem(countInput)
	local priorYear
	local priorIndex
	local chooserLayout = api.gui.layout.BoxLayout.new("VERTICAL")
	
	local window = api.gui.comp.Window.new(_("Vehicle selection"), chooserLayout)
	window:setVisible(false, false)
	window:addHideOnCloseHandler()
	guiState.window2 = window
	chooseButton:onClick(function() 
		window:setVisible(true, false)
		local mousePos = api.gui.util.getMouseScreenPos()
		window:setPosition(mousePos.x,mousePos.y)
	end)
	local screenSize = api.gui.util.getGameUI():getMainRendererComponent():getContentRect()
 
	window:setMaximumSize(api.gui.util.Size.new(math.floor((1/3)*screenSize.w),math.floor((3/4)*screenSize.h)))
	local lastComputedCount = 0
	local vehicleConfig
	
	return {
		comp = boxLayout,
		refresh = function(index) 
			if index == 0 then 
				vehicleConfig = vehicleUtil.buildUrbanBus() 
			else 
				vehicleConfig = vehicleUtil.buildTram() 
			end 
			local originalVehicleConfig = vehicleConfig
			local function populateIcon(modelId) 
				local model = vehicleUtil.getModel(modelId) 
				local name = model.metadata.description.name
 
				local icon = model.metadata.description.icon20
			 
				selectedVehicle:setImage(icon, true)
				selectedVehicle:setTooltip(name)
			end 
			local modelId = vehicleConfig.vehicles[1].part.modelId
			if priorYear ~= util.year() or priorIndex ~= index then 
				priorYear = util.year() 
				priorIndex = index
				--chooserLayout:deleteAll()
				for i = chooserLayout:getNumItems()-1, 0, -1 do 
					chooserLayout:removeItem(chooserLayout:getItem(i))
				end 
				local selectedButton
				local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.VERTICAL, 0, false)
				for i, vehicle in pairs(vehicleUtil.findVehiclesOfType(index == 0 and "bus" or "tram")) do 
					local model = vehicle.model
					trace("Setting up vehicle",i," of id ",vehicle.modelId)
					local name = model.metadata.description.name
					if util.tracelog then 
						name = name.." "..tostring(vehicle.modelId)
					end 
					local icon = model.metadata.description.smallIcon 
					if not icon then debugPrint(model.metadata.description) end
					local toggleButton = util.newToggleButton(name, icon)
					if modelId == vehicle.modelId then 
						toggleButton:setSelected(true, false) 
						selectedButton = toggleButton
					end
					toggleButton:onToggle(function(b) 
						addWork(function() 
							vehicleConfig = vehicleUtil.copyConfig(vehicleUtil.createVehicleConfig(vehicle.modelId))
							populateIcon(vehicle.modelId) 
						end)
					end)
					buttonGroup:add(toggleButton)
				end 
				buttonGroup:setOneButtonMustAlwaysBeSelected(true)
				local size = buttonGroup:calcMinimumSize()
				trace("THe min size was ",size.h, size.w)
				local screenSize = api.gui.util.getGameUI():getMainRendererComponent():getContentRect()
				local maximum = (2/3)*screenSize.h
				
				local scrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.Component.new(" "), " ")
				scrollArea:setContent(buttonGroup)
				--scrollArea:setVerticalScrollBarPolicy(api.gui.comp.ScrollBarPolicy.ALWAYS_ON)
				if size.h > maximum or true then 
					maximum = maximum / 2
					trace("Setting maxmimum size on scroll area, maximum was ",maximum)
					scrollArea:setMaximumSize(api.gui.util.Size.new(size.w,math.floor(maximum)))
					--buttonGroup:setMaximumSize(api.gui.util.Size.new(size.w,math.floor(maximum)))
				end 
				chooserLayout:addItem(scrollArea)
				local acceptButton = util.newButton("","ui/button/small/accept@2x.tga")
				local resetButton = util.newButton("","ui/button/small/vehicle_replace_active@2x.tga")
				local cancelButton = util.newButton("","ui/button/small/cancel@2x.tga")
				trace("Creating button panel")
				local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL");
				local function reset() 
					addWork(function() 
						selectedButton:setSelected(true, true) 
					end)
				end
				buttonPanel:addItem(acceptButton)
				buttonPanel:addItem(resetButton) 
				buttonPanel:addItem(cancelButton)
				chooserLayout:addItem(buttonPanel)
				acceptButton:onClick(function() window:close() end)
				resetButton:onClick(reset)
				cancelButton:onClick(function() 
					reset()
					window:close()
				end)
			end 
			populateIcon(modelId) 
		end,
		getVehicleConfig = function() 
			return vehicleConfig 
		end,
		updateCount = function( ) 
			local numStops = #guiState.selectedEntities
			if not guiState.circleLine then 
				numStops = numStops * 2 - 2
			end
			local computedCount = numStops < 2 and 0 or math.min(100, math.max(2, math.floor(numStops/2)))
			if lastComputedCount ~= computedCount then 
				lastComputedCount = computedCount 
				countInput:setText(tostring(computedCount), false)
			end 
		end,
		getNumberOfVehicles = function() 
			local result 
			if not pcall(function() result = tonumber(countInput:getText()) end) then
				result = lastComputedCount
			end 
			return result
		end 
	}
end



local function buildBusLinePanel()
	trace("Begin buildBusLinePanel")
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
    
	local colHeaders = {
		api.gui.comp.TextView.new(_("Segment")),
		api.gui.comp.TextView.new(_("Distance")),
		api.gui.comp.TextView.new(" "),
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	local tramIcon ="/ui/hud/station_tram@2x.tga" -- station_bus@2x -- vehicle_tram@2x
	--\ui\button\medium
	local tramOrBus = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local createTramLine = util.newToggleButton("TRAM", "ui/button/medium/vehicle_tram@2x.tga") 
	local createBusLine = util.newToggleButton("BUS",  "ui/button/medium/vehicle_bus@2x.tga") 
	
	tramOrBus:add(createBusLine)
	tramOrBus:add(createTramLine)
	tramOrBus:setOneButtonMustAlwaysBeSelected(true)
	local addBusLanes = api.gui.comp.CheckBox.new(_("Add bus lanes?"))
	local circleLine = api.gui.comp.CheckBox.new(_("CircleLine?"))
	
	trace("Setting up display table")
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	displayTable:setHeader(colHeaders)
	local acceptButton = util.newButton("","ui/button/small/accept@2x.tga")
	local vehicleSelection = buildVehicleSelectionPanel()
	function guiState.refreshTable() 
		displayTable:deleteAll()
		vehicleSelection.updateCount()
		for i, entityId in pairs(guiState.selectedEntities) do 
			local distanceDisplay = api.gui.comp.TextView.new(" ")
			if i > 1 or circleLine:isSelected() and #guiState.selectedEntities > 1then 
				local priorEntity = i == 1 and guiState.selectedEntities[#guiState.selectedEntities] or guiState.selectedEntities[i-1]
				distanceDisplay:setText(api.util.formatLength(util.distance(getPosition(entityId),getPosition(priorEntity))))
			end 
			local cancelButton = util.newButton("","ui/button/small/cancel@2x.tga")
			
			
			cancelButton:onClick(function() 
				addWork(function()
					local index = util.indexOf(guiState.selectedEntities, entityId) -- need to recompute index in case others were removed
					displayTable:deleteRows(index-1, index)
					table.remove(guiState.selectedEntities, index)
					removeCircle("bus_line_tool"..tostring(entityId))
					acceptButton:setEnabled(#guiState.selectedEntities > 1, false)
					guiState.needsRedrawRoute = true
				end)
			end)
			displayTable:addRow({ util.makelocateRowForEdge(entityId, guiState.colours[i]), distanceDisplay, cancelButton }) 
		end 
		acceptButton:setEnabled(#guiState.selectedEntities > 1, false)
	end
	
	tramOrBus:onCurrentIndexChanged(function(i)
		addWork(function() 
			vehicleSelection.refresh(i)
		end)
	end)

	trace("Adding items to layout")
	createBusLine:setSelected(true, true)
	boxlayout:addItem(displayTable)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	boxlayout:addItem(tramOrBus)
	boxlayout:addItem(vehicleSelection.comp)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	boxlayout:addItem(addBusLanes)
	boxlayout:addItem(circleLine)
	circleLine:onToggle(function(b) 
		guiState.isCircle = b 
		guiState.needsRedrawRoute = true
		addWork(vehicleSelection.updateCount)
	end)
	
	local resetButton = util.newButton("","ui/button/small/vehicle_replace_active@2x.tga")
	local cancelButton = util.newButton("","ui/button/small/cancel@2x.tga")
	trace("Creating button panel")
	local ignoreErrors = api.gui.comp.CheckBox.new(_("Ignore validation?"))
	ignoreErrors:setTooltip(_("Toggle on to ignore collisions etc. (\"Construction not possible\" cannot be ignored)"))
	boxlayout:addItem(ignoreErrors)
	local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL");
	buttonPanel:addItem(acceptButton)
	buttonPanel:addItem(resetButton) 
	buttonPanel:addItem(cancelButton)
	
	acceptButton:onClick(function() 
		addWork(function() 
			local param = {} 
			param.createTramLine = createTramLine:isSelected()
			param.addBusLanes = addBusLanes:isSelected()
			param.circleLine = circleLine:isSelected()
			param.selectedEntities = guiState.selectedEntities
			param.ignoreErrors = ignoreErrors:isSelected()
			param.vehicleConfig = vehicleSelection.getVehicleConfig()
			param.numberOfVehicles = vehicleSelection.getNumberOfVehicles()
			api.cmd.sendCommand(api.cmd.make.sendScriptEvent("bus_line_tool_script.lua","createBusLine", "", param), standardCallback)
			removeCircles() 
			acceptButton:setEnabled(false, false)
			--vehicleSelection.updateCount()
			guiState.isActive=false
		end)
	end)
	acceptButton:setEnabled(false, false)
	resetButton:onClick(function()
		addWork(function()
			removeCircles() 
			updateCircle()
			displayTable:deleteAll()
			acceptButton:setEnabled(false, false)
			vehicleSelection.refresh(tramOrBus:getSelectedIndex())
			addWork(vehicleSelection.updateCount)
		end)
		guiState.isActive=true
	end)
	
	cancelButton:onClick(function() 
		guiState.window:close()
	end)
	
   -- local button =  newButton(_('Execute Upgrade'))
	--button:onClick(function() xpcall(executeUpgrade,err)	end)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	boxlayout:addItem(buttonPanel) 
	local comp= api.gui.comp.Component.new(" ")
	comp:setLayout(boxlayout)
	trace("End buildBusLinePanel")
	return {
		comp=comp,
		refresh = function() 
			displayTable:deleteAll()
		--	populateCategories()
		--	populateChoices() 
		end
	}
end 


local function buildWindow()
	

	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
 
	local busLinePanel = buildBusLinePanel()
	boxlayout:addItem(busLinePanel.comp)
	local bottomPanel =  api.gui.layout.BoxLayout.new("HORIZONTAL");
	  

	 
	 
	boxlayout:addItem(bottomPanel)
	 
    local window = api.gui.comp.Window.new(_('Bus Line Tool'), boxlayout)

	 window:addHideOnCloseHandler()
	 window:onClose(function() 
		removeCircles()
		guiState.isActive = false
	 end)
	api.gui.util.getGameUI():getMainRendererComponent():insertMouseListener(mouseListener)
	guiState.window = window
	return {
		window = window,
		refresh = function() 
			xpcall(busLinePanel.refresh, err) 
		 
		end
	}
end

local function createComponents()
	local gameBar =  api.gui.util.getById("gameInfo.layout")
	if not gameBar then 
		return 
	end
	trace("bus_line_tool_script createComponents start, lua used memory=",api.util.getLuaUsedMemory())
	local button = newButton(_('Bus Line Tool'))
	button:setTooltip(_('Bus Line Tool'))
    local window = buildWindow()
		

    window.window:setVisible(false,false)
	local icon = api.gui.comp.ImageView.new("ui/icons/windows/destinations@4x.tga")
	trace("About to get layout")
    local layout = api.gui.util.getById("mainButtonsLayout"):getItem(1):getLayout()
	trace("Got layout")
	icon:setMaximumSize(api.gui.util.Size.new(60,60))
	icon:setMinimumSize(api.gui.util.Size.new(50,50))
    local button = api.gui.comp.ToggleButton.new(icon )
	button:setTooltip(_("Bus Line Tool!"))
    button:setName("ConstructionMenuIndicator")
	layout:insertItem(button, 0)
	button:onToggle(function (b) 
		window.window:setVisible(b,false)
		guiState.isActive = b
		if b then 
			local mainView = game.gui.getContentRect("mainView")
			local y = math.floor(mainView[4]*(2/3)) 
			local x = math.floor(mainView[3]/2) 
			window.window:setPosition(x,y)
			window.refresh()
		else 
			window.window:close()
		end 
		
    end)
	trace("bus_line_tool_script createComponents end, lua used memory=",api.util.getLuaUsedMemory())
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


 