-- The Bus Line Tool window: two tabs (New line / Edit line), sections, tooltips, status line.
-- GUI state only. Everything that touches the world goes through ctx callbacks.
local util = require("bus_line_tool_base_util")
local vehicleUtil = require("bus_line_tool_vehicle_util")

local windowModule = {}

local function header(text)
	local view = api.gui.comp.TextView.new(text)
	view:addStyleClass("BusLineToolHeader")
	return view
end

local function tipped(component, tooltip)
	component:setTooltip(tooltip)
	return component
end

local function rgbFromLineColor(entry)
	return { entry[1], entry[2], entry[3] }
end

-- Colour control: the game's ColorChooser when it can be built, else a cycling button.
local function buildColourControl(ctx, onChange)
	local current = ctx.colourDefault()
	local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local swatch = api.gui.comp.LineRenderView.new()
	swatch:addLine(api.type.Vec2f.new(0, 12), api.type.Vec2f.new(60, 12))
	swatch:setWidth(20)
	swatch:setMinimumSize(api.gui.util.Size.new(60, 24))
	local function apply(rgb)
		current = rgb
		swatch:setColor(api.type.Vec4f.new(rgb[1], rgb[2], rgb[3], 1))
		onChange(rgb)
	end
	apply(current)
	layout:addItem(swatch)

	local ok, chooser = pcall(function()
		local c = api.gui.comp.ColorChooser.new()
		c:onColorChanged(function(colour)
			local rgb
			if type(colour) == "table" then
				rgb = { colour[1] or colour.r or colour.x, colour[2] or colour.g or colour.y, colour[3] or colour.b or colour.z }
			else
				local okx, x, y, z = pcall(function() return colour.x, colour.y, colour.z end)
				if okx and x then rgb = { x, y, z } else rgb = { colour.r, colour.g, colour.b } end
			end
			if rgb[1] and rgb[2] and rgb[3] then apply(rgb) end
		end)
		return c
	end)
	if ok and chooser then
		layout:addItem(chooser)
		print("bus_line_tool: colour chooser available")
	else
		print("bus_line_tool: colour chooser unavailable, using cycling button (" .. tostring(chooser) .. ")")
		local colours = api.res.getBaseConfig().gui.lineColors
		local index = 1
		local button = tipped(util.newButton(_("Next colour")), _("Cycle through the game's line colours"))
		button:onClick(function()
			index = index % #colours + 1
			apply(rgbFromLineColor(colours[index]))
		end)
		layout:addItem(button)
	end
	local comp = api.gui.comp.Component.new(" ")
	comp:setLayout(layout)
	return { comp = comp, get = function() return current end }
end

local function buildVehicleSelectionPanel(ctx, state)
	local boxLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	boxLayout:addItem(api.gui.comp.TextView.new(_("Vehicle:")))
	local selectedVehicle = api.gui.comp.ImageView.new(" ")
	selectedVehicle:setMaximumSize(api.gui.util.Size.new(60, 60))
	boxLayout:addItem(selectedVehicle)
	local chooseButton = tipped(util.newButton("", "ui/button/small/line_tasks@2x.tga"), _("Choose a different vehicle"))
	boxLayout:addItem(chooseButton)
	boxLayout:addItem(api.gui.comp.TextView.new(_("Count:")))
	local countInput = tipped(api.gui.comp.TextInputField.new("0"), _("Number of vehicles to buy. Default: stops / 2, at least 2"))
	boxLayout:addItem(countInput)

	local chooserLayout = api.gui.layout.BoxLayout.new("VERTICAL")
	local window = api.gui.comp.Window.new(_("Vehicle selection"), chooserLayout)
	window:setVisible(false, false)
	window:addHideOnCloseHandler()
	ctx.guiState.window2 = window
	chooseButton:onClick(function()
		window:setVisible(true, false)
		local mousePos = api.gui.util.getMouseScreenPos()
		window:setPosition(mousePos.x, mousePos.y)
	end)
	local screenSize = api.gui.util.getGameUI():getMainRendererComponent():getContentRect()
	window:setMaximumSize(api.gui.util.Size.new(math.floor((1 / 3) * screenSize.w), math.floor((3 / 4) * screenSize.h)))

	local lastComputedCount = 0
	local vehicleConfig
	local priorYear, priorIndex

	local function populateIcon(modelId)
		local model = vehicleUtil.getModel(modelId)
		selectedVehicle:setImage(model.metadata.description.icon20, true)
		selectedVehicle:setTooltip(_(model.metadata.description.name))
	end

	local panel = { comp = boxLayout }

	function panel.refresh(index)
		if index == 0 then
			vehicleConfig = vehicleUtil.buildUrbanBus()
		else
			vehicleConfig = vehicleUtil.buildTram()
		end
		local modelId = vehicleConfig.vehicles[1].part.modelId
		if priorYear ~= util.year() or priorIndex ~= index then
			priorYear = util.year()
			priorIndex = index
			for i = chooserLayout:getNumItems() - 1, 0, -1 do
				chooserLayout:removeItem(chooserLayout:getItem(i))
			end
			local selectedButton
			local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.VERTICAL, 0, false)
			for _, vehicle in pairs(vehicleUtil.findVehiclesOfType(index == 0 and "bus" or "tram")) do
				local toggleButton = util.newToggleButton(vehicleUtil.describeVehicle(vehicle), vehicle.model.metadata.description.smallIcon)
				if modelId == vehicle.modelId then
					toggleButton:setSelected(true, false)
					selectedButton = toggleButton
				end
				toggleButton:onToggle(function()
					ctx.addWork(function()
						vehicleConfig = vehicleUtil.copyConfig(vehicleUtil.createVehicleConfig(vehicle.modelId))
						populateIcon(vehicle.modelId)
					end)
				end)
				buttonGroup:add(toggleButton)
			end
			buttonGroup:setOneButtonMustAlwaysBeSelected(true)
			local size = buttonGroup:calcMinimumSize()
			local maximum = (2 / 3) * screenSize.h / 2
			local scrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.Component.new(" "), " ")
			scrollArea:setContent(buttonGroup)
			scrollArea:setMaximumSize(api.gui.util.Size.new(size.w, math.floor(maximum)))
			chooserLayout:addItem(scrollArea)
			local acceptButton = tipped(util.newButton("", "ui/button/small/accept@2x.tga"), _("Use this vehicle"))
			local resetButton = tipped(util.newButton("", "ui/button/small/vehicle_replace_active@2x.tga"), _("Back to the suggested vehicle"))
			local cancelButton = tipped(util.newButton("", "ui/button/small/cancel@2x.tga"), _("Close without changes"))
			local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL")
			local function reset()
				ctx.addWork(function() if selectedButton then selectedButton:setSelected(true, true) end end)
			end
			buttonPanel:addItem(acceptButton)
			buttonPanel:addItem(resetButton)
			buttonPanel:addItem(cancelButton)
			chooserLayout:addItem(buttonPanel)
			acceptButton:onClick(function() window:close() end)
			resetButton:onClick(reset)
			cancelButton:onClick(function() reset(); window:close() end)
		end
		populateIcon(modelId)
	end

	function panel.getVehicleConfig() return vehicleConfig end

	function panel.updateCount()
		local numStops = #ctx.guiState.selectedEntities
		if not ctx.guiState.isCircle then numStops = numStops * 2 - 2 end
		local computedCount = numStops < 2 and 0 or math.min(100, math.max(2, math.floor(numStops / 2)))
		if lastComputedCount ~= computedCount then
			lastComputedCount = computedCount
			countInput:setText(tostring(computedCount), false)
		end
	end

	function panel.getNumberOfVehicles()
		local result
		if not pcall(function() result = tonumber(countInput:getText()) end) then result = lastComputedCount end
		return result
	end

	return panel
end

-- Builds one Stops section. Each tab gets its own instance (a widget has one parent),
-- both reading/writing the same ctx.guiState lists so their rows stay in sync.
local function buildStopsSection(ctx, state, onRowsChanged)
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")
	layout:addItem(header(_("Stops")))
	local colHeaders = {
		api.gui.comp.TextView.new(_("#")),
		api.gui.comp.TextView.new(_("Stop")),
		api.gui.comp.TextView.new(_("Distance")),
		api.gui.comp.TextView.new(" "),
	}
	local table_ = api.gui.comp.Table.new(#colHeaders, "SINGLE")
	table_:setHeader(colHeaders)
	pcall(function()
		table_:onSelect(function(row)
			ctx.guiState.selectedRow = row
		end)
	end)
	layout:addItem(table_)
	local status = api.gui.comp.TextView.new(_("Hover a street or station and click to add a stop"))
	status:addStyleClass("BusLineToolStatus")
	layout:addItem(status)

	local section = { comp = layout, status = status }

	function section.refresh()
		table_:deleteAll()
		local entities = ctx.guiState.selectedEntities
		for i, entityId in pairs(entities) do
			local distanceDisplay = api.gui.comp.TextView.new(" ")
			if i > 1 or ctx.guiState.isCircle and #entities > 1 then
				local prior = i == 1 and entities[#entities] or entities[i - 1]
				distanceDisplay:setText(api.util.formatLength(util.distance(ctx.getPosition(entityId), ctx.getPosition(prior))))
			end
			local removeButton = tipped(util.newButton("", "ui/button/small/cancel@2x.tga"), _("Remove this stop"))
			removeButton:onClick(function()
				ctx.addWork(function()
					local index = util.indexOf(ctx.guiState.selectedEntities, entityId)
					if index == -1 then return end
					table.remove(ctx.guiState.selectedEntities, index)
					table.remove(ctx.guiState.colours, index)
					table.remove(ctx.guiState.stopMeta, index)
					ctx.removeCircle("bus_line_tool" .. tostring(entityId))
					ctx.guiState.needsRedrawRoute = true
					onRowsChanged()
				end)
			end)
			local number = api.gui.comp.TextView.new(tostring(i))
			table_:addRow({ number, util.makelocateRowForEdge(entityId, ctx.guiState.colours[i]), distanceDisplay, removeButton })
		end
	end

	return section
end

local function buildNewLineTab(ctx, state, stops, vehicles, refreshAll)
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")
	layout:addItem(stops.comp)

	layout:addItem(header(_("Line")))
	local modeGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local busButton = tipped(util.newToggleButton("BUS", "ui/button/medium/vehicle_bus@2x.tga"), _("Build a bus line"))
	local tramButton = tipped(util.newToggleButton("TRAM", "ui/button/medium/vehicle_tram@2x.tga"), _("Build a tram line (tram tracks are added where missing)"))
	modeGroup:add(busButton)
	modeGroup:add(tramButton)
	modeGroup:setOneButtonMustAlwaysBeSelected(true)
	busButton:setSelected(true, false) -- emit=false: no vehicle discovery until the window opens
	layout:addItem(modeGroup)

	local nameRow = api.gui.layout.BoxLayout.new("HORIZONTAL")
	nameRow:addItem(api.gui.comp.TextView.new(_("Name:")))
	local nameField = tipped(api.gui.comp.TextInputField.new(""), _("Suggested from the towns of the first and last stop. Edit freely."))
	nameField:setMinimumSize(api.gui.util.Size.new(220, 24))
	state.nameEdited = false
	state.lastSuggested = nil
	pcall(function() nameField:onChange(function() state.nameEdited = true end) end)
	nameRow:addItem(nameField)
	layout:addItem(nameRow)

	local colourRow = api.gui.layout.BoxLayout.new("HORIZONTAL")
	colourRow:addItem(api.gui.comp.TextView.new(_("Colour:")))
	local colour = buildColourControl(ctx, function() ctx.guiState.needsRedrawRoute = true end)
	colourRow:addItem(colour.comp)
	layout:addItem(colourRow)

	local addBusLanes = tipped(api.gui.comp.CheckBox.new(_("Bus lanes")), _("Upgrade the streets along the route with bus lanes"))
	local circleLine = tipped(api.gui.comp.CheckBox.new(_("Circle line")), _("Last stop connects back to the first instead of returning the same way"))
	local ignoreErrors = tipped(api.gui.comp.CheckBox.new(_("Ignore validation")), _("Force street upgrades even when the game reports collisions (\"Construction not possible\" cannot be ignored)"))
	layout:addItem(addBusLanes)
	layout:addItem(circleLine)
	layout:addItem(ignoreErrors)
	circleLine:onToggle(function(b)
		ctx.guiState.isCircle = b
		ctx.guiState.needsRedrawRoute = true
		ctx.addWork(vehicles.updateCount)
	end)
	addBusLanes:onToggle(function() ctx.guiState.needsRedrawRoute = true end)

	layout:addItem(header(_("Vehicles")))
	layout:addItem(vehicles.comp)

	modeGroup:onCurrentIndexChanged(function(i)
		ctx.guiState.needsRedrawRoute = true
		ctx.addWork(function() vehicles.refresh(i) end)
	end)

	layout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local buildButton = tipped(util.newButton(_("Build"), "ui/button/small/accept@2x.tga"), _("Build the stops, the line and buy the vehicles"))
	local resetButton = tipped(util.newButton(_("Reset"), "ui/button/small/vehicle_replace_active@2x.tga"), _("Clear all selected stops"))
	local cancelButton = tipped(util.newButton(_("Cancel"), "ui/button/small/cancel@2x.tga"), _("Close the tool"))
	buttonPanel:addItem(buildButton)
	buttonPanel:addItem(resetButton)
	buttonPanel:addItem(cancelButton)
	layout:addItem(buttonPanel)
	buildButton:setEnabled(false, false)

	local tab = { comp = api.gui.comp.Component.new(" "), buildButton = buildButton, nameField = nameField }
	tab.comp:setLayout(layout)

	function tab.isTram() return modeGroup:getSelectedIndex() == 1 end
	function tab.addBusLanes() return addBusLanes:isSelected() end
	function tab.isCircle() return circleLine:isSelected() end
	function tab.ignoreErrors() return ignoreErrors:isSelected() end
	function tab.lineName() return nameField:getText() end
	function tab.lineColour() return colour.get() end
	function tab.setSuggestedName(text)
		local current = nameField:getText()
		if not state.nameEdited and (current == "" or current == state.lastSuggested) then
			nameField:setText(text, false)
		end
		state.lastSuggested = text
	end

	buildButton:onClick(function()
		ctx.addWork(function()
			ctx.onBuild({
				createTramLine = tab.isTram(),
				addBusLanes = tab.addBusLanes(),
				circleLine = tab.isCircle(),
				selectedEntities = ctx.guiState.selectedEntities,
				ignoreErrors = tab.ignoreErrors(),
				vehicleConfig = vehicles.getVehicleConfig(),
				numberOfVehicles = vehicles.getNumberOfVehicles(),
				lineName = tab.lineName(),
				lineColour = tab.lineColour(),
			})
			ctx.removeCircles()
			buildButton:setEnabled(false, false)
			state.nameEdited = false
			state.lastSuggested = nil
			ctx.guiState.isActive = false
		end)
	end)
	resetButton:onClick(function()
		ctx.addWork(function()
			ctx.removeCircles()
			ctx.updateCircle()
			refreshAll()
			buildButton:setEnabled(false, false)
			state.nameEdited = false
			state.lastSuggested = nil
			vehicles.refresh(modeGroup:getSelectedIndex())
			ctx.addWork(vehicles.updateCount)
		end)
		ctx.guiState.isActive = true
	end)
	cancelButton:onClick(function() ctx.guiState.window:close() end)
	return tab
end

local function buildEditLineTab(ctx, state, stops, refreshAll)
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")
	layout:addItem(header(_("Line to edit")))
	local pickRow = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local combo = tipped(api.gui.comp.ComboBox.new(), _("Your bus and tram lines"))
	pickRow:addItem(combo)
	local locateButton = tipped(util.newButton("", "ui/button/xxsmall/locate.tga"), _("Move the camera to this line's first stop"))
	pickRow:addItem(locateButton)
	layout:addItem(pickRow)
	local lines = {}

	layout:addItem(stops.comp)

	layout:addItem(header(_("Line")))
	local nameRow = api.gui.layout.BoxLayout.new("HORIZONTAL")
	nameRow:addItem(api.gui.comp.TextView.new(_("Name:")))
	local nameField = tipped(api.gui.comp.TextInputField.new(""), _("Rename the line"))
	nameField:setMinimumSize(api.gui.util.Size.new(220, 24))
	nameRow:addItem(nameField)
	layout:addItem(nameRow)
	local addBusLanes = tipped(api.gui.comp.CheckBox.new(_("Bus lanes")), _("Upgrade the streets along the route with bus lanes"))
	local ignoreErrors = tipped(api.gui.comp.CheckBox.new(_("Ignore validation")), _("Force street upgrades even when the game reports collisions"))
	layout:addItem(addBusLanes)
	layout:addItem(ignoreErrors)
	addBusLanes:onToggle(function() ctx.guiState.needsRedrawRoute = true end)

	layout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	local buttonPanel = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local applyButton = tipped(util.newButton(_("Apply"), "ui/button/small/accept@2x.tga"), _("Build new stops and update the line"))
	local reloadButton = tipped(util.newButton(_("Reload"), "ui/button/small/vehicle_replace_active@2x.tga"), _("Discard edits and reload the line"))
	local cancelButton = tipped(util.newButton(_("Cancel"), "ui/button/small/cancel@2x.tga"), _("Close the tool"))
	buttonPanel:addItem(applyButton)
	buttonPanel:addItem(reloadButton)
	buttonPanel:addItem(cancelButton)
	layout:addItem(buttonPanel)
	applyButton:setEnabled(false, false)

	local tab = { comp = api.gui.comp.Component.new(" "), applyButton = applyButton, nameField = nameField }
	tab.comp:setLayout(layout)

	local function currentLine()
		return lines[combo:getCurrentIndex() + 1]
	end

	function tab.refreshLineList()
		lines = ctx.onLineListNeeded()
		combo:clear(false)
		for _, line in ipairs(lines) do combo:addItem(line.name) end
	end

	combo:onIndexChanged(function(index)
		local line = lines[index + 1]
		if line then
			ctx.addWork(function()
				ctx.onEditLoad(line.id)
				nameField:setText(line.name, false)
				applyButton:setEnabled(true, false)
			end)
		end
	end)
	locateButton:onClick(function()
		local line = currentLine()
		if line and line.firstStation then
			pcall(function() api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(line.firstStation, false) end)
		end
	end)
	applyButton:onClick(function()
		local line = currentLine()
		if not line then return end
		ctx.addWork(function()
			ctx.onEditApply({
				lineId = line.id,
				entities = ctx.guiState.selectedEntities,
				stopMeta = ctx.guiState.stopMeta,
				addBusLanes = addBusLanes:isSelected(),
				ignoreErrors = ignoreErrors:isSelected(),
				name = nameField:getText(),
			})
			ctx.removeCircles()
			applyButton:setEnabled(false, false)
			ctx.guiState.isActive = false
		end)
	end)
	reloadButton:onClick(function()
		local line = currentLine()
		if line then ctx.addWork(function() ctx.onEditLoad(line.id) end) end
	end)
	cancelButton:onClick(function() ctx.guiState.window:close() end)

	function tab.addBusLanes() return addBusLanes:isSelected() end
	function tab.ignoreErrors() return ignoreErrors:isSelected() end
	function tab.lineName() return nameField:getText() end
	return tab
end

function windowModule.create(ctx)
	local state = {}
	local handles = {}
	-- Tab builders that need to refresh both Stops sections (e.g. Reset) call this
	-- instead of refreshing their own section directly, so nothing goes stale.
	local function refreshAll() handles.refreshStops() end
	local vehicles = buildVehicleSelectionPanel(ctx, state)
	-- Each tab gets its own Stops section: a widget has one parent, so the two tabs
	-- cannot share a single section's comp. Both sections read/write the same
	-- ctx.guiState lists, so their rows stay in sync; handles.refreshStops()/setStatus()
	-- below drive both.
	local newStops = buildStopsSection(ctx, state, function() handles.refreshStops() end)
	local editStops = buildStopsSection(ctx, state, function() handles.refreshStops() end)
	local newTab = buildNewLineTab(ctx, state, newStops, vehicles, refreshAll)
	local editTab = buildEditLineTab(ctx, state, editStops, refreshAll)

	local tabs = api.gui.comp.TabWidget.new("NORTH")
	tabs:addTab(api.gui.comp.TextView.new(_("New line")), newTab.comp)
	tabs:addTab(api.gui.comp.TextView.new(_("Edit line")), editTab.comp)
	-- The tab-change event name is unverified, so the mode is derived from state instead:
	-- "edit" while a line is loaded (guiState.editLine), "new" otherwise. The line list is
	-- refreshed when the window opens (toolbar toggle) and by the Reload button.
	pcall(function()
		tabs:onCurrentChanged(function(index)
			if index == 1 then editTab.refreshLineList() end
		end)
	end)

	local outer = api.gui.layout.BoxLayout.new("VERTICAL")
	outer:addItem(tabs)
	local window = api.gui.comp.Window.new(_("Bus Line Tool"), outer)
	window:addHideOnCloseHandler()
	window:onClose(function()
		ctx.removeCircles()
		ctx.guiState.isActive = false
	end)
	ctx.guiState.window = window

	handles.window = window
	function handles.mode() return ctx.guiState.editLine and "edit" or "new" end
	function handles.refreshStops()
		newStops.refresh()
		editStops.refresh()
		vehicles.updateCount()
		local n = #ctx.guiState.selectedEntities
		newTab.buildButton:setEnabled(n > 1, false)
		if handles.mode() == "new" then newTab.setSuggestedName(ctx.onNameNeeded()) end
	end
	function handles.setStatus(text)
		newStops.status:setText(text, false)
		editStops.status:setText(text, false)
	end
	function handles.setSuggestedName(text) newTab.setSuggestedName(text) end
	function handles.isTram()
		if handles.mode() == "edit" then return ctx.guiState.editLine and ctx.guiState.editLine.isTram or false end
		return newTab.isTram()
	end
	function handles.addBusLanes()
		if handles.mode() == "edit" then return editTab.addBusLanes() end
		return newTab.addBusLanes()
	end
	function handles.isCircle()
		if handles.mode() == "edit" then return ctx.guiState.editLine and ctx.guiState.editLine.isCircle or false end
		return newTab.isCircle()
	end
	function handles.ignoreErrors()
		if handles.mode() == "edit" then return editTab.ignoreErrors() end
		return newTab.ignoreErrors()
	end
	function handles.lineName() return handles.mode() == "edit" and editTab.lineName() or newTab.lineName() end
	function handles.lineColour() return newTab.lineColour() end
	function handles.selectedRow() return ctx.guiState.selectedRow or -1 end
	function handles.refreshVehicles() vehicles.refresh(newTab.isTram() and 1 or 0) end
	function handles.refreshLineList() editTab.refreshLineList() end
	function handles.setEditApplyEnabled(b) editTab.applyButton:setEnabled(b, false) end
	return handles
end

return windowModule
