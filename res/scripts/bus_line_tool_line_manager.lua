local vec3 = require("vec3")
local vec2 = require("vec2")
local pathFindingUtil = require("bus_line_tool_pathfinding_util")
local routeBuilder = require("bus_line_tool_route_builder")
local constructionUtil = require("bus_line_tool_construction_util")
--local paramHelper = require("bus_line_tool_base_param_helper")
local util = require("bus_line_tool_base_util")
local vehicleUtil = require("bus_line_tool_vehicle_util")
local lineManager = {}
constructionUtil.lineManager = lineManager
lineManager.nextTrainLine = 0
lineManager.nextLineColor = 1
local function trace(...)
	util.trace(...)
end
local formatTime = util.formatTime
local noPathVehicles = {}

local multiplyTargetByLineStops = false

local function nextTrainLineFn() 
	lineManager.nextTrainLine = lineManager.nextTrainLine + 1
	return lineManager.nextTrainLine
end
local function nextLineColorFn() 
	local color = game.config.gui.lineColors[lineManager.nextLineColor]
	color = api.type.Vec3f.new(color[1],color[2],color[3])
	lineManager.nextLineColor = lineManager.nextLineColor+1
	if lineManager.nextLineColor > #game.config.gui.lineColors then
		lineManager.nextLineColor = 1
	end
	return color
end
local function getLine(lineId)
	return api.engine.getComponent(lineId, api.type.ComponentType.LINE)
end
function lineManager.getLine(lineId)
	return getLine(lineId) 
end

local function isLineType(line, enum)
	return line.vehicleInfo.transportModes[enum+1]==1 
end

local function isElectricRailLine(line)
	return isLineType(line, api.type.enum.TransportMode.ELECTRIC_TRAIN)
end

local function isRailLine(line)
	return isLineType(line, api.type.enum.TransportMode.TRAIN) or isElectricRailLine(line)
end
local function isBusLine(line) 
	return isLineType(line, api.type.enum.TransportMode.BUS)
end 
local function isElectricTramLine(line) 
	return isLineType(line, api.type.enum.TransportMode.ELECTRIC_TRAM)
end

local function isTramLine(line) 
	return isLineType(line, api.type.enum.TransportMode.TRAM)
	or isElectricTramLine(line)
end 
local function isTruckLine(line)
	return isLineType(line, api.type.enum.TransportMode.TRUCK)
end 	
local function isRoadLine(line)
	return isBusLine(line) 
	or isTruckLine(line)
	or isTramLine(line) 
end
local function isShipLine(line)
	return isLineType(line, api.type.enum.TransportMode.SMALL_SHIP) or isLineType(line, api.type.enum.TransportMode.SHIP)
end

local function isAirLine(line)
	return isLineType(line, api.type.enum.TransportMode.SMALL_AIRCRAFT) or isLineType(line, api.type.enum.TransportMode.AIRCRAFT)
end

function lineManager.isTramLine(line) return isTramLine(line) end
function lineManager.isBusOrTramLine(line) return isBusLine(line) or isTramLine(line) end

local function lineName(lineId) 
	return api.engine.getComponent(lineId, api.type.ComponentType.NAME).name
end

local function stationFromGroup(group) 
	return api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP).stations[1]
end
local function stationFromConstruction(constructionId) 
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	if not construction then 
		return constructionId
	end
	return construction.stations[1]
end

local function constructionFromStation(stationId) 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then 
		constructioNId = stationId
	end
	return  api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
end
local function depotFromConstruction(constructionId) 
	return api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION).depots[1]
end
local function groupFromStation(station)
	return api.engine.system.stationGroupSystem.getStationGroup(station)
end
local stationFromStop = util.stationFromStop


function lineManager.stationFromStop(stop) 
	return stationFromStop(stop) 
end
local function discoverLineCarrier(line) 
	if isTramLine(line) then 
		return api.type.enum.Carrier.TRAM 
	elseif isRailLine(line) then 
		return api.type.enum.Carrier.RAIL
	elseif isShipLine(line) then 
		return api.type.enum.Carrier.WATER 
	elseif isAirLine(line) then 
		return api.type.enum.Carrier.AIR 
	elseif isRoadLine(line) then 
		return api.type.enum.Carrier.ROAD 
	end 
	trace("Having trouble determinging carrier, falling back to stations") 
	if #line.stops > 0 then 
		local stationId = stationFromStop(line.stops[1])
		local station = game.interface.getEntity(stationId) 
		if station.carriers.TRAM then 
			return api.type.enum.Carrier.TRAM 
		elseif station.carriers.ROAD then 
			return api.type.enum.Carrier.ROAD 
		elseif station.carriers.RAIL then 
			return api.type.enum.Carrier.RAIL
		elseif station.carriers.WATER then 
			return api.type.enum.Carrier.WATER 
		elseif station.carriers.AIR then 
			return api.type.enum.Carrier.AIR  
		end
	end 
	trace("Line has no stops, unknown carrier")
end 
function lineManager.checkNoPathVehicles() 
	local currentNoPathVehicles = {}
	for i, vehicleId in pairs(api.engine.system.transportVehicleSystem.getNoPathVehicles()) do 
		currentNoPathVehicles[vehicleId]=true
	end
	for noPathVehicle, attemptCount in pairs(noPathVehicles) do 
		if not currentNoPathVehicles[noPathVehicle] then
			noPathVehicles[noPathVehicles]=nil
		else 
			if attemptCount <= 2 then 
				lineManager.addWork(function()api.cmd.sendCommand(api.cmd.make.reverseVehicle(noPathVehicle) , function(res, success)
					if success then 
						noPathVehicles[noPathVehicle]=attemptCount+1
					end
				end)end)
			else
				lineManager.addWork(function()lineManager.replaceVehicle(noPathVehicle)end)
			end
			currentNoPathVehicles[noPathVehicle] = nil
		end 
	end
	for noPathVehicle, __ in pairs(currentNoPathVehicles) do
		noPathVehicles[noPathVehicle]=0
		lineManager.addWork(function()api.cmd.sendCommand(api.cmd.make.reverseVehicle(noPathVehicle) , function(res, success)
			if success then 
				noPathVehicles[noPathVehicle]=1
			end
		end)end)
	end
end



lineManager.changeTerminal = function(stationId, oldTerminal, newTerminal, callback, stopIndex, lineId)
	trace("request to change terminal, stationId=",stationId, " oldTerminal=",oldTerminal, " newTerminal=",newTerminal)
	--local lineId  = api.engine.system.lineSystem.getLineStopsForTerminal(stationId, oldTerminal-1)[1]
	--if not lineId then
	--	callback({}, true)
	--	return
	--end
	local lineDetails = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)

	local line = api.type.Line.new()
	line.vehicleInfo = lineDetails.vehicleInfo
	for i, stopDetail in pairs(lineDetails.stops) do 	
		local stop = api.type.Line.Stop.new()
		stop.stationGroup = stopDetail.stationGroup 
		stop.station = stopDetail.station 
		stop.terminal = stopDetail.terminal
		stop.loadMode = stopDetail.loadMode
		stop.minWaitingTime = stopDetail.minWaitingTime
		stop.maxWaitingTime = stopDetail.maxWaitingTime
		stop.waypoints = stopDetail.waypoints
		stop.stopConfig = stopDetail.stopConfig
		
--		if stationGroup == stopDetail.stationGroup and oldTerminal-1 == stopDetail.terminal then
		if i == stopIndex then 
			if stop.terminal == newTerminal then 
				trace("WARNING! Already have the terminal set the same aborting")
				callback({}, true)
				return
			end
			stop.terminal = newTerminal-1
		end
		line.stops[i]=stop  
	end
	local updateLine = api.cmd.make.updateLine(lineId, line)
	api.cmd.sendCommand(updateLine, callback)
end 

function lineManager.stopIndex(stationId, terminal)
	local lineId  = api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminal-1)[1]
	local lineDetails = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)
	for i, stopDetail in pairs(lineDetails.stops) do 
		if stationGroup == stopDetail.stationGroup and terminal-1 == stopDetail.terminal then
			return { stopIndex = i , lineId = lineId}
		end 
	end 
end 


lineManager.getNeighbouringStationStops = function(stationId, terminalId)
	local result = {}
	local lineId  = api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminalId-1)[1]
	if not lineId then 
		return result 
	end
	local lineDetails = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(stationId)	
	for i, stopDetail in pairs(lineDetails.stops) do 	
		if stationGroup == stopDetail.stationGroup and terminalId-1 == stopDetail.terminal then
			if i > 1 then
				table.insert(result, stationFromGroup(lineDetails.stops[i-1].stationGroup))
			elseif #lineDetails.stops > 2 then 
				table.insert(result, stationFromGroup(lineDetails.stops[#lineDetails.stops].stationGroup))
			end
			if i < #lineDetails.stops then
				table.insert(result, stationFromGroup(lineDetails.stops[i+1].stationGroup))
			elseif #lineDetails.stops > 2 then 
				table.insert(result, stationFromGroup(lineDetails.stops[1].stationGroup))
			end
		end
	end
	return result
end
local function isAboveMaximumInterval(lineId, line, params)

	params.targetMaximumPassengerInterval = paramHelper.getParams().targetMaximumPassengerInterval
	if isRoadLine(line) then 
		params.targetMaximumPassengerInterval =  paramHelper.getParams().targetMaximumPassengerBusInterval 
	elseif isAirLine(line) then 
		params.targetMaximumPassengerInterval =  paramHelper.getParams().targetMaximumPassengerAirInterval 
	end 
	local frequency = game.interface.getEntity(lineId).frequency
	if frequency == 0 then 
		return true
	end
	local interval = 1 / frequency
	trace("interval for line ",lineId," was ",interval)
	return interval >  params.targetMaximumPassengerInterval
end	
function lineManager.assignVehicleToLine(vehicle, line, callback,stopIndex, buyCommand, buyRes)			
	if not callback then callback = lineManager.standardCallback end
	if not stopIndex then stopIndex = 0 end
	local setLine = api.cmd.make.setLine(vehicle, line, stopIndex)
	api.cmd.sendCommand(setLine, function(res, success) 
		if not success and buyCommand then 
			debugPrint({buyCommand = buyCommand, buyRes= buyRes, vehicleDetail = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)})
		end
		if not success and stopIndex >0 then
			lineManager.addDelayedWork(function() lineManager.assignVehicleToLine(vehicle, line, callback, 0)end)	
		end
		callback(res, success)
	end)
end

function lineManager.buildVehicleAndAssignToLine(vehicleConfig, depotEntity, lineId, callback, stopIndex)
	if not stopIndex then
		local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
		stopIndex = pathFindingUtil.findClosestStopIndexForDepot(depotEntity, line) 
	end
	if not stopIndex then
		trace("WARNING! Could not find path from depot ",depotEntity," to any stop on line",lineId)
	end
	local wrappedCallback = function(res, success)
		if success then 
			local resultVehicle = res.resultVehicleEntity 
			lineManager.addWork(function() lineManager.assignVehicleToLine(resultVehicle, lineId, callback, stopIndex) end)
		end			
		callback(res, success)
	end
	local buyVehicle = api.cmd.make.buyVehicle( game.interface.getPlayer(),depotEntity,  vehicleUtil.copyConfigToApi(vehicleConfig))
	api.cmd.sendCommand(buyVehicle, wrappedCallback)
end
local function isRailStation(stationId) 
	return game.interface.getEntity(stationId).carriers.RAIL
end 

local function getFreeTerminalsForStation(stationId, nextStationId, priorStop) 
	local result = {}
	for i = 1, #api.engine.getComponent(stationId, api.type.ComponentType.STATION).terminals do
		local terminal = i-1
		local numstops =  #api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminal)
		trace("Inspecting station ",stationId," the numstops at terminal ", terminal , " was ",numstops)
		if 0 == numstops then
			if nextStationId and isRailStation(stationId) then 
				if priorStop then 
					if #pathFindingUtil.findRailPathBetweenStations(stationFromStop(priorStop), stationId, priorStop.terminal, terminal) > 0 
						and pathFindingUtil.checkForRailPathBetweenTerminalAndStation(stationId, terminal, nextStationId) then 
						table.insert(result, terminal)
					end
				else 
					if pathFindingUtil.checkForRailPathBetweenTerminalAndStation(stationId, terminal, nextStationId) then 
						table.insert(result, terminal)
					end
				end
			else 
				table.insert(result, terminal)
			end
		end
	end 

	return result
end
local function getFreeTerminalForStation(stationId, nextStationId, priorStop ) 
	local freeTerminals = getFreeTerminalsForStation(stationId, nextStationId, priorStop)
	if #freeTerminals > 1 and nextStationId and game.interface.getEntity(stationId).carriers.RAIL then 
		local stationVector = util.vectorBetweenStations(stationId, nextStationId)
		return lineManager.chooseRightHandTerminal(stationVector, stationId,  freeTerminals[1], freeTerminals[2], nextStationId)
	end
	if #freeTerminals > 0 then 
		return freeTerminals[1]
	end 
	local options = {} 
	for i = 1, #api.engine.getComponent(stationId, api.type.ComponentType.STATION).terminals do
		local terminal = i-1
		local numstops =  #api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminal)
		trace("Inspecting station ",stationId," the numstops at terminal ", terminal , " was ",numstops) 
		table.insert(options, {terminal = terminal, scores={numstops}})
	end 
	return util.evaluateWinnerFromScores(options).terminal
end
local function indexOfStop(line, station, fromLast)
	local startAt = fromLast and #line.stops or 1 
	local endAt = fromLast and 1 or #line.stops 
	local increment = fromLast  and -1 or 1
	for i = startAt, endAt, increment do 
		if station == stationFromGroup(line.stops[i].stationGroup) then
			return i 
		end
	end
end

local function getNextStationStop(line, station)
	local stopIndex = indexOfStop(line, station)
	return stopIndex < #line.stops and line.stops[stopIndex+1] or line.stops[1]
end

local function stationAppearsOnceOnLineAndAdjacentToFreeTerminal(line, station, freeTerminal)
	local count = 0
	for  i, stop  in pairs(line.stops) do 	
		if station == stationFromGroup(stop.stationGroup) then
			local terminalGap = math.abs(stop.terminal-freeTerminal)
			trace("The terminal gap was ",terminalGap)
			if terminalGap > 3 then 
				return false
			end
			count = count + 1
		end
	end
	return count == 1
end



local function chooseRightHandTerminal(stationVector, stationId,  terminal1, terminal2, otherStation, otherLineId) 
	local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION)
	local vehicleNodeId1 = station.terminals[terminal1+1].vehicleNodeId.entity
	local vehicleNodeId2 = station.terminals[terminal2+1].vehicleNodeId.entity
	local nodeVector = util.vecBetweenNodes(vehicleNodeId1, vehicleNodeId2)
	local angle = util.signedAngle(stationVector, nodeVector)
	local routeInfo = pathFindingUtil.getRouteInfo(stationId, otherStation) 
	if routeInfo and routeInfo.firstFreeEdge then
		local exitVector = util.getEdgeMidPoint(routeInfo.edges[routeInfo.firstFreeEdge].id) -  util.getStationPosition(stationId)
		local oldAngle = angle 
		angle = util.signedAngle(exitVector, nodeVector)
		trace("The angle using basic station vector was",math.deg(oldAngle)," the angle using exitVector was ",math.deg(angle))
	else 
		trace("WARNING! No route info found between stations",stationId, otherStation)
	end 
	local chosenTerminal = angle < 0 and terminal1 or terminal2
	trace("angle to the station and node vector was", math.deg(angle), "chosenTerminal=",chosenTerminal, " terminal choices were ",terminal1, terminal2, " of a total of ", #station.terminals, " for station",stationId, " otherStation=",otherStation)
	if not otherLineId and  not pathFindingUtil.checkForRailPathBetweenTerminalAndStation(stationId, chosenTerminal, otherStation) then 
		local otherTerminal = chosenTerminal == terminal1 and terminal2 or terminal1 
		if pathFindingUtil.checkForRailPathBetweenTerminalAndStation(stationId, otherTerminal, otherStation) then 
			chosenTerminal = otherTerminal
			trace("Path finding could not find a path using proposed terminal, using ",chosenTerminal," instead")
		else 
			trace("WARNING! No path could be found from either terminal")
		end
	end
	return chosenTerminal
end	
lineManager.chooseRightHandTerminal = chooseRightHandTerminal

local function isPassengerLine(line)
	local stationId = stationFromGroup(line.stops[1].stationGroup)
	local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION)
	return not station.cargo
end
local function discoverLineCargoType(lineId)
	
	for i, simCargoId in pairs( util.deepClone(api.engine.system.simCargoSystem.getSimCargosForLine(lineId))) do
		local simCargo = api.engine.getComponent(simCargoId, api.type.ComponentType.SIM_CARGO)
		if simCargo then -- this is subject to a race condition if the cargo dissapears
			return  simCargo.cargoType 
		end 
	end 
	if #api.engine.system.simPersonSystem.getSimPersonsForLine(lineId) > 0 then 
		return api.res.cargoTypeRep.find("PASSENGERS")
	end
	local firstStation = stationFromStop(getLine(lineId).stops[1])
	if not firstStation then 
		trace("No first station for line?")
		debugPrint(getLine(lineId))
		return
	end 
	if not util.getStation(firstStation).cargo then 
		return api.res.cargoTypeRep.find("PASSENGERS")
	end
	trace("Having difficulty finding cargo type for line",lineId)
	local vehicle = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)[1]
	if vehicle then 
		local vehicleConfig = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE).transportVehicleConfig
		if vehicleConfig.vehicles[1].autoLoadConfig[1] == 0 then 
			trace("Attempting to find cargoType from vehicleConfig")
			return vehicleUtil.getCurrentCargoConfig(vehicleConfig.vehicles[1])
		end 
	end
	
	local industry = util.searchForFirstEntity(util.getStationPosition(firstStation), 300, "SIM_BUILDING")
	
	local cargoType = industry and  util.discoverCargoType(industry) 
	if not cargoType then 
		trace("Attempting to find from industry2")
		local industry2 = util.searchForFirstEntity(util.getStationPosition(stationFromStop(getLine(lineId).stops[2])), 300, "SIM_BUILDING")
		if industry2 then 
			return util.discoverCargoType(industry2)
		end 
	else 
		return cargoType
	end
	trace("WARNING! Unable to determine cargo type for line",lineId)
end 

lineManager.discoverLineCargoType = discoverLineCargoType

local function getMinStationLength(line)
	local minStationLength = math.huge 
	for i , stop in pairs(line.stops) do 
		minStationLength = math.min(constructionUtil.getStationLength(stationFromStop(stop)), minStationLength)
	end
	
	trace("MinStationLength was ",minStationLength)
	return minStationLength
end 
local function getMinStationLengthParam(line)
	local minStationLength = math.huge 
	for i , stop in pairs(line.stops) do 
		minStationLength = math.min(constructionUtil.getStationLengthParam(stationFromStop(stop)), minStationLength)
	end
	
	trace("MinStationLength was ",minStationLength)
	return minStationLength
end 
local function isLargeHarbour(construction) 
	for k, v in pairs(construction.params) do -- cannot index size directly as it calls a different method 
		if k == "size" then 
			return v == 1
		end 
	end 

end 

local function getLineParams(lineId)
	local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local cargoType =  discoverLineCargoType(lineId)
	local distance = util.distBetweenStations(stationFromGroup(line.stops[1].stationGroup),stationFromGroup(line.stops[2].stationGroup))
	if cargoType and type(cargoType)=="number" then 
		cargoType = api.res.cargoTypeRep.getName(cargoType)
	end
	local params = paramHelper.getDefaultRouteBuildingParams(cargoType , isRailLine(line), false, distance)
	params.isElectricTrack = isElectricRailLine(line)
	if isRailLine(line) then 
		params.stationLength = getMinStationLength (line)
		params.stationLengthParam = getMinStationLengthParam(line)
		local vehicle = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)[1]
		if vehicle then 
			local vehicleConfig = vehicleUtil.copyConfig(api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE).transportVehicleConfig)
			local info = vehicleUtil.getConsistInfo(vehicleConfig, cargoType)
			params.isHighSpeedTrack = info.isHighSpeed -- TODO: could actually look at routeinfo 
			params.isVeryHighSpeedTrain = info.isVeryHighSpeedTrain
		end 
	end
	if isShipLine(line) then 	
		params.allowLargeShips = true 
		for i , stop in pairs(line.stops) do
			local station = stationFromStop(stop)
			local construction = constructionFromStation(station)
			if not isLargeHarbour(construction) then 
				params.allowLargeShips = false 
				break 
			end
		end 
	end 
	if isBusLine(line) and #line.stops > 0 then 
		local isUrbanLine = true 
		local town = api.engine.system.stationSystem.getTown(stationFromStop(line.stops[1]))
		for i = 2, #line.stops do 
			if town ~= api.engine.system.stationSystem.getTown(stationFromStop(line.stops[i])) then 
				isUrbanLine = false 
				break 
			end 
		end 
		trace("Setup line",line,"isUrbanLine=",isUrbanLine)
		params.isUrbanLine = isUrbanLine
		
	end 
	return params
end
lineManager.getLineParams = getLineParams 


local function buyAndAssignVechicles(vehicleConfig, depotOptions, lineId, numberOfVehicles, callback)
	if not callback then callback = lineManager.standardCallback end
	lineManager.addDelayedWork(function()
		for i = 1, numberOfVehicles do 
			trace("about to fetch ", ( i%#depotOptions+1) , " of ",#depotOptions, " depot")
			local depotOption = depotOptions[i%#depotOptions+1]
			trace("About to buy using config ", vehicleConfig, " and depot ", depotOption.depotEntity)
			local buyCommand = api.cmd.make.buyVehicle( api.engine.util.getPlayer(),depotOption.depotEntity, vehicleUtil.copyConfigToApi(vehicleConfig))
		
			api.cmd.sendCommand(buyCommand, function(res, success)  
				if success then 
					lineManager.addDelayedWork(function()
					local line = getLine(lineId)
					local station =  stationFromStop(line.stops[depotOption.stopIndex+1])
					local count = 0
					while station == -1 and count <= #line.stops  do 
						count = count+1
						trace("WARNING!, line had invalid station, attempting to correct using  depot option at",count)
						depotOption = depotOptions[count%#depotOptions+1]
						station =  stationFromStop(line.stops[depotOption.stopIndex+1])
					end 
					lineManager.assignVehicleToLine(res.resultVehicleEntity, lineId, callback, depotOption.stopIndex, buyCommand, res)
					end)		
				end 
				lineManager.standardCallback(res, success)
			end)
		end
	end)
end

local function  getStopPosition(line, stopIndex)
	local stop = line.stops[1+stopIndex]
	local stationId = stationFromGroup(stop.stationGroup)
	return util.getStationPosition(stationId)
end

function lineManager.findDepotsForLine(lineId, carrier, nonStrict, isElectric)
	trace("Finding depots for line",lineId,"isElectric?",isElectric)
	local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	if not carrier then 
		carrier = discoverLineCarrier(line)
	end
	if carrier == api.type.enum.Carrier.WATER  then
		local result = {} 
		for i, stop in pairs(line.stops) do
			local stopIndex = i-1
			local stopPos = getStopPosition(line, stopIndex)
			local constructionId = constructionUtil.searchForShipDepot(stopPos, 1500)
			if constructionId then 
				table.insert(result, {
					stopIndex = stopIndex,
					depotEntity = depotFromConstruction(constructionId) 
				})
			end
		end
		return result
	end
	if carrier == api.type.enum.Carrier.AIR then 
		local result = {} 
		for i, stop in pairs(line.stops) do
			local station = stationFromGroup(stop.stationGroup)
			local depotEntity = util.getConstructionForStation(station).depots[1]
			if depotEntity then 
				table.insert(result, {
					stopIndex = i-1,
					depotEntity = depotEntity
				})
			end 
		end
		return result
	end

	local matchingTypes = {}
	trace("About to get line for lineId ",lineId)

	trace("Got line, about to loop over depots")
	api.engine.system.vehicleDepotSystem.forEach(function(depotEntity) 
		
		local depot = api.engine.getComponent(depotEntity, api.type.ComponentType.VEHICLE_DEPOT)
		if depot.carrier == carrier then
			table.insert(matchingTypes, depotEntity)
		end
	end)
	trace("There were ",#matchingTypes," for carrier ",carrier)
	
	local optionsByStopIndex = {} 
	local isRoadOrTramLine = carrier == api.type.enum.Carrier.ROAD or carrier == api.type.enum.Carrier.TRAM
	local range = isRoadOrTramLine and 1500 or math.huge
	for i, depotEntity in pairs(matchingTypes) do
		--trace("Looking for closest to depot for depot ", depotEntity)
		local okPos, depotPos = pcall(util.getDepotPosition, depotEntity)
		-- findStopIndexesForDepot runs a path search per stop. Every option it can return is
		-- thrown away below when the depot is further than `range` from the stop as the crow
		-- flies, so a depot that far from EVERY stop is not worth searching from at all.
		local usable = okPos and depotPos ~= nil
		local nearAnyStop = usable and range == math.huge
		if usable and not nearAnyStop then
			for k = 1, #line.stops do
				if util.distance(depotPos, getStopPosition(line, k-1)) <= range then
					nearAnyStop = true
					break
				end
			end
		end
		if nearAnyStop then
			for i, stopIndex in pairs(pathFindingUtil.findStopIndexesForDepot(depotEntity, line, nonStrict, isElectric, range)) do
				--trace("Found stopIndex=",stopIndex)
				--trace("Getting stop pos")
				local stopPos = getStopPosition(line, stopIndex)
				if  util.distance(depotPos, stopPos) > range then
					--trace("Skipping check as the gap is too big")
					goto continue
				end
				if not optionsByStopIndex[stopIndex] then
					optionsByStopIndex[stopIndex]={}
				end
				table.insert(optionsByStopIndex[stopIndex], {
					stopIndex = stopIndex,
					depotEntity = depotEntity,
					scores = { util.distance(depotPos, stopPos) }

				})
				::continue::
			end
		end
	end
	local result = {}
	for stopIndex, options in pairs(optionsByStopIndex) do 
		table.insert(result, util.evaluateWinnerFromScores(options))
	end
	
	return result
end

local function estimateTotalTimeForLine(lineId, transportVehicleConfig, params )
	local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local totalTime = 0 
	if not params then 
		params = getLineParams(lineId)
		params.line = line
	end
	local transportVehicleConfig
	if vehicle then 
		transportVehicleConfig =  api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE).transportVehicleConfig
	else 
		transportVehicleConfig = lineManager.estimateInitialConsist(params, params.distance).vehicleConfig 
	end
 --[[
	for i =2 , #line.stops do 
		local station1 = stationFromGroup(line.stops[i-1].stationGroup)
		local station2 = stationFromGroup(line.stops[i].stationGroup)
		local distance = util.distBetweenStations(station1, station2)
		params.distance = distance
		totalTime = totalTime + 0.5*vehicleUtil.estimateThroughputBasedOnConsist(transportVehicleConfig, params).totalTime
		if i == #line.stops then
			station1 = stationFromGroup(line.stops[1].stationGroup)
			distance = util.distBetweenStations(station1, station2)
			params.distance = distance
			totalTime = totalTime + 0.5*vehicleUtil.estimateThroughputBasedOnConsist(transportVehicleConfig, params).totalTime
		end
	end]]--
	totalTime = vehicleUtil.estimateThroughputBasedOnConsist(transportVehicleConfig, params).totalTime
	trace("Estimated total time for line ",lineId," as ",totalTime)
	return totalTime
end


function lineManager.buildTrain(depot, line, cargoType, targetCapacity, params)

		
		--debugPrint({buyVehicle=buyVehicle})
		api.cmd.sendCommand(buyVehicle, function(res, success) 
			trace("buyVehicle result was ",success)
			if success then 
				lineManager.assignVehicleToLine(res.resultVehicleEntity, line, standardCallback )
				
			end
			--debugPrint({buyVehicleres=res})
			workComplete=true
		end)
	
end


function lineManager.estimateInitialConsist(params, distance, stations) 
	local begin = os.clock()
	local targetLineRate = params.rateOverride or params.initialTargetLineRate or params.targetThroughput
	local numberOfVehicles = 1
	if not targetLineRate then 
		trace("WARNING! no target line rate set, defaulting")
		targetLineRate = 100
	end
	if params.cargoType == "PASSENGERS" and targetLineRate> 1500    then 
		trace("Setting upper limit for passenger rate",targetLineRate)
		targetLineRate = 1500
		if params.targetThroughput and not params.rateOverride then 
			params.targetThroughput = math.min(params.targetThroughput, 1500)
		end
		if params.initialTargetLineRate and not params.rateOverride then 
			params.initialTargetLineRate = math.min(params.initialTargetLineRate, 1500)
		end
	end
	if stations then 
		 
		params.routeInfos = {}
		distance = 0
		for i = 1 , #stations do 
			local priorStation = i == 1 and stations[#stations] or stations[i-1]
			local station = stations[i]
			 
			params.routeInfos[i]= pathFindingUtil.getRouteInfo(priorStation, station)
			distance = distance + util.distBetweenStations(priorStation, station)
		end 
	
	end 
	
	local estimate = vehicleUtil.estimateThroughputPerConsist(distance, targetLineRate, params)
	trace("Estimated throuput per consist, time taken was ",os.clock()-begin)
	local targetCapacity = estimate.totalCapacity * (targetLineRate/estimate.throughput)
	if estimate.isMaxLength and params.isDoubleTrack then 
		numberOfVehicles = math.ceil(targetLineRate/estimate.throughput)
		targetCapacity = estimate.totalCapacity * (targetLineRate/(numberOfVehicles*estimate.throughput))
		trace("recaulculated numberofVehicles to ",numberOfVehicles, " and targetCapacity=", targetCapacity)
	end
	if params.cargoType == "PASSENGERS"     then 
		if (estimate.totalTime/numberOfVehicles) > paramHelper.getParams().targetMaximumPassengerInterval then 
			local previousNumberOfVehicles = numberOfVehicles
			numberOfVehicles = math.ceil(estimate.totalTime/paramHelper.getParams().targetMaximumPassengerInterval)
			targetCapacity = (previousNumberOfVehicles/numberOfVehicles)*targetCapacity
			trace("To satisfy passenger intervals recaulculated numberofVehicles to ",numberOfVehicles, " and targetCapacity=", targetCapacity)
		elseif (estimate.totalTime/numberOfVehicles) > paramHelper.getParams().minimumInterval then 
			local previousNumberOfVehicles = numberOfVehicles
			numberOfVehicles = math.max(1,math.floor(estimate.totalTime/paramHelper.getParams().minimumInterval))
			targetCapacity = (previousNumberOfVehicles/numberOfVehicles)*targetCapacity
			trace("Initial calculation put number of vehicles too high, reduced numberofVehicles to ",numberOfVehicles, " and targetCapacity=", targetCapacity)
		end
		if stations and #stations > 4 then 
			numberOfVehicles = math.min(2*#stations, numberOfVehicles)
			trace("Clamped numberOfVehicles to ",numberOfVehicles)-- avoid excessive vehicle assignments
		end
	end	
	
	trace("Calculated a targetCapacity of ", targetCapacity, " based on targetLineRate of",targetLineRate, "numberOfVehicles=",numberOfVehicles) 
	params.totalTargetThroughput = targetLineRate
	params.targetThroughput = targetLineRate / numberOfVehicles
	local vehicleConfig = vehicleUtil.buildTrain(targetCapacity, params)	
	local info = vehicleUtil.getConsistInfo(vehicleConfig, params.cargoType)
	trace("Estimated initial consist,total time taken was ",os.clock()-begin)
	return {
		vehicleConfig = vehicleConfig,
		info = info,
		numberOfVehicles = numberOfVehicles
	}
	
end
function lineManager.setupTrainLineParams(params, distance)
	local initialConsist = lineManager.estimateInitialConsist(params, distance)
	params.isElectricTrack = initialConsist.info.isElectric
	params.isHighSpeedTrack = initialConsist.info.isHighSpeed
	params.isDoubleTrack  = initialConsist.numberOfVehicles > 1 
	params.isVeryHighSpeedTrain = initialConsist.info.isVeryHighSpeedTrain
	if not params.isCargo then 
	
	end
	
	if params.isHighSpeedTrack and not params.isCargo then 
		params.smoothingPasses = params.smoothingPasses*2
	end 
	if params.isCargo and initialConsist.info.length < 120 and initialConsist.numberOfVehicles == 1 and distance < 1500 and params.stationLengthParam > 2 and not params.stationLengthOverriden then 
		params.stationLengthParam = 2
		params.stationLength = 160
	end
end

function lineManager.checkForExtensionPosibilities(params, station)
	if util.isStationTerminus(station) then 
		trace("Station terminus detected, extension not possible from",station)
		return 
	end 
	local freeTerminal = util.getFreeTerminals(station)[1]
	if not freeTerminal then 
		trace("WARNING! No free terminal found for ",station, "aborting")
		return
	end		
	for i, lineId in pairs(util.deepClone(api.engine.system.lineSystem.getLineStopsForStation(station))) do
		local line = getLine(lineId)
		if stationAppearsOnceOnLineAndAdjacentToFreeTerminal(line, station,freeTerminal) then 
			trace("Discovered an extension possibility from line") 
			local theirLineParams = getLineParams(lineId)
			params.isHighSpeedTrack = params.isHighSpeedTrack or theirLineParams.isHighSpeedTrack
			params.isVeryHighSpeedTrain = params.isVeryHighSpeedTrain or theirLineParams.isVeryHighSpeedTrain
			params.stationLengthParam = math.max(params.stationLengthParam, theirLineParams.stationLengthParam)
			params.stationLength = math.max(params.stationLength, theirLineParams.stationLength)
			trace("Overriding isHighSpeedTrack to",params.isHighSpeedTrack," isVeryHighSpeedTrain=",params.isVeryHighSpeedTrain)
		end 
	end
end

function lineManager.createNewTrainLineBetweenStations(stations, params, callback, suffix) 
	local station1 = stations[1]
	local station2 = stations[#stations]
	params.routeInfo = pathFindingUtil.getRouteInfo(station1, station2) 
	local distance = util.distBetweenStations(station1, station2)
	params.distance = distance
	params.stationLength = math.min(constructionUtil.getStationLength(station1), constructionUtil.getStationLength(station2))
	local vehicleInfo = lineManager.estimateInitialConsist(params, distance, stations) 
	local vehicleConfig = vehicleInfo.vehicleConfig
	local numberOfVehicles = vehicleInfo.numberOfVehicles
	trace("Got vehicle config=",vehicleConfig)
	local lineName 
	if params.cargoType == "PASSENGERS" then
		local townName = api.engine.getComponent(station1, api.type.ComponentType.NAME).name
		if not suffix then suffix = _("Express") end
		lineName = townName.." "..suffix
	else 
		local stationName = api.engine.getComponent(station1, api.type.ComponentType.NAME).name
		lineName = stationName.." ".._("Cargo")
	end
	
	
	
	if not params.isDoubleTrack then 
		numberOfVehicles = 1
	end
	
	
	lineManager.createLineAndAssignVechicles(vehicleConfig, stations, lineName, numberOfVehicles, api.type.enum.Carrier.RAIL, params, callback )
end

function lineManager.setupTrainLineBetweenStations(station1, station2, params, callback) 
	util.lazyCacheNode2SegMaps()
	if not lineManager.checkIfLineCanBeExtended(station1, station2, callback) then
		lineManager.createNewTrainLineBetweenStations({station1, station2}, params, callback) 
	end
end

function lineManager.getBusAndTramLinesForTown(town) 
	local result = {}
	local alreadySeen = {} 
	for i , stationId in pairs(api.engine.system.stationSystem.getStations(town)) do
		for j, lineId in pairs(api.engine.system.lineSystem.getLineStopsForStation(stationId)) do 
			if not alreadySeen[lineId] then  
				alreadySeen[lineId] = true 
				local line = getLine(lineId)
				if isBusLine(line) or isTramLine(line) then 
					local allWithinThisTown = true 
					for k, stop in pairs(line.stops) do 
						local station2 = stationFromStop(stop)
						if api.engine.system.stationSystem.getTown(station2)~=town then 
							allWithinThisTown = false 
							break 
						end
					end 
					if allWithinThisTown then 
						table.insert(result, lineId) 
					end
				end
			end 
		end 
	end
	
	return result
end 
local function checkForLineUpgrades(lineId, line, report, newVehicleConfig, params, oldVehicleConfig)
	if isRailLine(line)  then 
		local info = vehicleUtil.getConsistInfo(newVehicleConfig, params.cargoType)
		if info.isElectric and not params.isElectricTrack then 
			report.upgrades.needsElectricUpgrade = true	
		end
		if info.isHighSpeed and not params.isHighSpeedTrack then
			report.upgrades.needsHighSpeedUpgrade = true
		end
		params.isElectricTrack = params.isElectricTrack or info.isElectric
		params.isHighSpeedTrack = params.isHighSpeedTrack or info.isHighSpeed
		params.isVeryHighSpeedTrain = info.isVeryHighSpeedTrain
		if report.upgrades.needsElectricUpgrade  or report.upgrades.needsHighSpeedUpgrade then 
			table.insert(report.executionFns, function() 
				trace("Checking track for upgrades")
				routeBuilder.checkForTrackupgrades(line, lineManager.standardCallback, params, lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.RAIL, true))
			end)
		end 
	end 
	if isShipLine(line)   then 
		if vehicleUtil.isLargeShip(newVehicleConfig) and not params.allowLargeShips then 
			report.upgrades.needsHarbourUpgrade=true 
			for i , stop in pairs(line.stops) do 
				local station = stationFromStop(stop)
				table.insert(report.executionFns, function() 
					trace("upgrading to large harbour")
					constructionUtil.upgradeToLargeHarbor(station)
				end)
			end 
		end 
	end 
	if isTramLine(line) and not isElectricTramLine(line) then 
		if vehicleUtil.isElectricTram(newVehicleConfig) then 
			report.upgrades.electricTramTrack=true 
			table.insert(report.executionFns, function() 
				
				params.tramTrackType = 2
				params.tramOnlyUpgrade = true
				trace("upgrading to electricTramTrack")
				for i =1 ,#line.stops do 
					local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
					util.cacheNode2SegMaps()
					local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(stationFromStop(priorStop), stationFromStop(line.stops[i]),true)
					
					routeBuilder.tryRoadRouteForUpgrade(routeInfo, lineManager.standardCallback, params)  
				end  
				for i =1 ,#line.stops do 
					local station = stationFromStop(line.stops[i])
					if not util.isBusStop(station) then 
						constructionUtil.checkBusStationForUpgrade(station, true)
					end
				end 
				for i , depotOption in pairs(lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.TRAM, false)) do 
					local depotEntity = depotOption.depotEntity 
					local stop = line.stops[depotOption.stopIndex+1]
					util.cacheNode2SegMaps()
					trace("Finding route info for depot",depotEntity)
					local routeInfo = pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findPathFromDepotToStop(depotEntity, stop, true, line))
					routeBuilder.tryRoadRouteForUpgrade(routeInfo, lineManager.standardCallback, params)  
					constructionUtil.upgradeToElectricTramDepot(depotOption.depotEntity)
					 
				end
				
			end)
		end
	end 
	if isRoadLine(line) and not isTramLine(line) and not params.isUrbanLine  then 
		local topSpeedNew = vehicleUtil.getTopSpeed(newVehicleConfig) 
		local topSpeedOld = vehicleUtil.getTopSpeed(oldVehicleConfig) 
		trace("The old topSpeed was",api.util.formatSpeed(topSpeedOld)," the new top speed was",api.util.formatSpeed(topSpeedNew))
		if topSpeedNew > topSpeedOld then
			table.insert(report.executionFns, function()  
				trace("Checking road route for possible upgrades")
				for i =1 ,#line.stops do 
					util.lazyCacheNode2SegMaps()
					local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
					local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(stationFromStop(priorStop), stationFromStop(line.stops[i]))
					
					routeBuilder.tryRoadRouteForUpgrade(routeInfo, lineManager.standardCallback, params)  
				end  
			end)
		end
	end
end

function lineManager.getDemandRate(lineId,line, report, params )
	if params.isCargo then 
		local sourceEntity
		local targetEntity
		local targetAlreadySeen = {} 
		local production = 0 
		local cargoSourceMap 
		if lineManager.cargoSourceMap then 
			cargoSourceMap = lineManager.cargoSourceMap 
		else 
			cargoSourceMap = util.deepClone(api.engine.system.stockListSystem.getCargoType2stockList2sourceAndCount())
		end
		local cargoTypeName 
		local cargoType = params.cargoType 
		if type(cargoType)=="string" then 
			cargoTypeName = cargoType
			cargoType = api.res.cargoTypeRep.find(cargoType) 
		else 
			cargoTypeName = api.res.cargoTypeRep.getName(cargoType)
		end 
		 
		
		for i, simCargoId in pairs(util.deepClone( api.engine.system.simCargoSystem.getSimCargosForLine(lineId))) do
			local simCargo = api.engine.getComponent(simCargoId, api.type.ComponentType.SIM_CARGO)
			if simCargo and simCargo.sourceEntity >0 and simCargo.targetEntity > 0 then -- this is subject to a race condition if the cargo dissapears
				sourceEntity = simCargo.sourceEntity
				targetEntity = simCargo.targetEntity
				if not targetAlreadySeen[targetEntity] and cargoSourceMap[cargoType+1][targetEntity] then 
					local thisProduction = cargoSourceMap[cargoType+1][targetEntity][sourceEntity]
					if thisProduction then 
						production = production + thisProduction
						targetAlreadySeen[targetEntity] = true
					end
				end
			end 
		
		end
		if targetEntity and sourceEntity then 
			trace("ABout to get construction for ",targetEntity)
			local townBuilding = util.getConstruction(targetEntity).townBuildings[1]
			if townBuilding then -- the above approach does not quite capture all the demand, attempt to correct
				local town = api.engine.getComponent(townBuilding, api.type.ComponentType.TOWN_BUILDING).town
				local townLimit = game.interface.getTownCargoSupplyAndLimit(town)[cargoTypeName][2]
				local industryShipping = game.interface.getIndustryShipping(sourceEntity)
				trace("Found a town shipment, town limit",townLimit, " industryShipping=",industryShipping," initial production calculated as",production)
				production = math.max(production, math.min(townLimit, industryShipping))
				trace("Production recaulculated to ",production)
			end 
		end
		
		return production
	else 
		-- not sure this is technically correct but it seems close most of the time
		return  #api.engine.system.simPersonSystem.getSimPersonsForLine(lineId) / math.log(#line.stops, 2) -- approximate demand across multiple stops
	end 

end
 
function lineManager.buyVehicleForLine(lineId, i, depotOptions, newVehicleConfig)
	local depotOption = depotOptions[i%#depotOptions+1]
	trace("Buying vehicle using depot ",depotOption.depotEntity, " at stopIndex=", depotOption.stopIndex)
	local buyVehicle = api.cmd.make.buyVehicle(api.engine.util.getPlayer(), depotOption.depotEntity, vehicleUtil.copyConfigToApi(	newVehicleConfig))
	local buyVehicleCallback = function(res, success) 
		trace("buyVehicle result was ",success)
		if success then 
			local resultVehicle = res.resultVehicleEntity 
			lineManager.addWork(function() lineManager.assignVehicleToLine(resultVehicle, lineId, lineManager.standardCallback, depotOption.stopIndex, buyVehicle, res) end)	
		end
	end 
	api.cmd.sendCommand(buyVehicle, buyVehicleCallback) 
end 

 
function lineManager.isCircleLine(line) 
	if #line.stops <= 2 then 
		return false 
	end 
	local alreadySeen = {}
	for i, stop in pairs(line.stops) do 
		local station = stationFromStop(stop)
		if alreadySeen[station] then 
			return false
		end 
		alreadySeen[station]=true
	end 
	return true
end

 
function lineManager.checkIfLineCanBeExtended(station1, station2, callback)

	trace("Checking if line can be extended from ",station1, " to ", station2)
	local stationPos1 = util.getStationPosition(station1)
	local stationPos2 = util.getStationPosition(station2)
	local canExtend = lineManager.checkAndExtendFrom(station1, station2, stationPos1 - stationPos2, callback)
	canExtend = lineManager.checkAndExtendFrom(station2, station1, stationPos2 - stationPos1, callback, canExtend) or canExtend
	return canExtend
		
end
local function setAppropriateStationIdx(stop, station)
	stop.station = util.indexOf(api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations, station) - 1
end


function lineManager.createNewLine(stations, callback, name, params)	 
	local line = api.type.Line.new()
	trace("Begin creating new line for ",#stations," stations")
	local isRailLine = isRailStation(stations[1])
	for i, station in pairs(stations) do 	
		local stop = api.type.Line.Stop.new()
		stop.stationGroup =api.engine.system.stationGroupSystem.getStationGroup(station)
		setAppropriateStationIdx(stop, station)
		local nextStation =  stations[i+1] or stations[1]
		local priorStop = i>1 and line.stops[i-1]
		stop.terminal =  getFreeTerminalForStation(station, nextStation, priorStop)  
		
		if params and params.alwaysDoubleTrackPassengerTerminus and util.isStationTerminus(station) and util.countFreeTerminalsForStation(station) >=2  then 
			
			local otherTerminal 
			for i, terminal in pairs(getFreeTerminalsForStation(station, nextStation)) do 
				if terminal ~= stop.terminal then 
					otherTerminal = terminal 
					break
				end 
			end 
			if otherTerminal then 
				trace("Setting up alternative terminal at",otherTerminal)
				local alternative = api.type.StationTerminal.new()
				alternative.station = stop.station 
				alternative.terminal = otherTerminal
				stop.alternativeTerminals[1]=alternative
			end
		end 
		
		--[[if i == 1 and params and params.cargoType then 
			trace("Setting up line for cargo ",params.cargoType)
			local stopConfig = stop.stopConfig
			local loadConfig = stop.stopConfig.load
			local unloadConfig = stop.stopConfig.load
			for cargoTypeIdx, cargoTypeName in pairs(util.deepClone(api.res.cargoTypeRep.getAll())) do 
				local config = (cargoTypeName == params.cargoType or cargoTypeIdx == params.cargoType) and 1 or 0
				trace("For cargoTypeIdx",cargoTypeIdx," the config is ",config)
				loadConfig:add(config)
				unloadConfig:add(config)
				--stop.stopConfig.load[config ]=cargoTypeIdx+1
				 --stop.stopConfig.unload[config ]=cargoTypeIdx+1
				--stop.stopConfig.load[cargoTypeIdx ]=config
				--stop.stopConfig.unload[cargoTypeIdx ]=config
				--stop.stopConfig.maxLoad[cargoTypeIdx+1]=config
			end 
			stopConfig.load = loadConfig
			stopConfig.unload = unloadConfig 
			stop.stopConfig=stopConfig
			if util.tracelog then debugPrint({stop=stop,stopConfig=stopConfig, loadConfig=loadConfig, unloadConfig=unloadConfig}) end
		end]]--
		line.stops[i]=stop  
	end
	if isRailLine then 
		for i, stop in pairs(line.stops) do 
			local station = stationFromStop(stop)
			local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
			local nextStop  = i == #line.stops and line.stops[1] or line.stops[i+1]
			local nextStation = stationFromStop(nextStop)
			local priorStation = stationFromStop(priorStop)
			if util.isStationTerminus(station) then 
				if #pathFindingUtil.findRailPathBetweenStations(station, nextStation, stop.terminal, nextStop.terminal) == 0  or 
				#pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, stop.terminal) == 0 then 
					trace("No path found for terminal, attempting to correct. Terminal was ",stop.terminal)
					for j, terminal in pairs(getFreeTerminalsForStation(station, nextStation)) do 
						if #pathFindingUtil.findRailPathBetweenStations(station, nextStation, terminal, nextStop.terminal) > 0
							and #pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, terminal) > 0 then
							stop.terminal = terminal 
							trace("Found a terminal with a path",terminal)
							line.stops[i]=stop 
							break 
						end 
					end
				end
				if stop.alternativeTerminals[1] and ( #pathFindingUtil.findRailPathBetweenStations(station, nextStation, stop.alternativeTerminals[1].terminal, nextStop.terminal) == 0 
				or #pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, stop.alternativeTerminals[1].terminal))
				then 
					trace("Alternative terminal was not good, trying another")
					for j, terminal in pairs(getFreeTerminalsForStation(station, nextStation)) do 
						if terminal~= stop.terminal and #pathFindingUtil.findRailPathBetweenStations(station, nextStation, terminal, nextStop.terminal) > 0
							and #pathFindingUtil.findRailPathBetweenStations(priorStation, station, priorStop.terminal, terminal) > 0						then 
							trace("Found a terminal with a path",terminal)
							local alternative = api.type.StationTerminal.new()
							alternative.station = stop.station 
							alternative.terminal = terminal
							stop.alternativeTerminals[1]=alternative
							break 
						end 
					end
				end 
			end 
		end 
	end
	if not name then 
		name = _("Line").." "..nextTrainLineFn()
	end
	trace("About to create line with name ",name)
	local create = api.cmd.make.createLine(name, nextLineColorFn() , game.interface.getPlayer(), line)
	trace("Created the command to createLine, now about to send command ",name)
	api.cmd.sendCommand(create, callback)
	trace("The command was sent")
end



function lineManager.setupRoadLine(stations, transportMode, lineName, callback)	
local line = api.type.Line.new()
	for i, station in pairs(stations) do 
		local stop = api.type.Line.Stop.new()
		stop.stationGroup =api.engine.system.stationGroupSystem.getStationGroup(station) 
		stop.station = 0
		stop.terminal = 0
		line.stops[#line.stops+1]=stop
	end
	local transportModes = line.vehicleInfo.transportModes
	transportModes[transportMode]=1
	line.vehicleInfo.transportModes = transportModes -- seems to be necessary for some reason, hidden pass by value not reference? 
	--if tracelog then debugPrint({line=line})  end
	local create = api.cmd.make.createLine(lineName, nextLineColorFn() , game.interface.getPlayer(), line)
	api.cmd.sendCommand(create, callback)
end

 
function lineManager.replaceVehicle(vehicleId)
	trace("Replacing stuck vehicle ",vehicleId)
	local vehicle = api.engine.getComponent(vehicleId, api.type.ComponentType.TRANSPORT_VEHICLE)
	local lineId = vehicle.line
	local transportVehicleConfig = vehicleUtil.copyConfig(vehicle.transportVehicleConfig)
	local depotOptions = lineManager.findDepotsForLine(lineId, vehicle.carrier)
	if #depotOptions == 0 then 
		trace("Unable to find depot for replacement")
		return 
	end
	trace("About to sell vechicle")
	if api.engine.entityExists(vehicleId) then 
		api.cmd.sendCommand( api.cmd.make.sellVehicle(vehicleId), function(res, success) 
			if success then 
				buyAndAssignVechicles(transportVehicleConfig, depotOptions, lineId, 1)
			end
		end)
	end
end

function lineManager.upgradeToTramLines(townLines) 
	local linesToUpgrade = {} 
	for i , line in pairs(townLines) do 
		if not isTramLine(getLine(line)) then 
			table.insert(linesToUpgrade, line)
		end 
	end 
	for i, lineId in pairs(linesToUpgrade) do 
		lineManager.addWork(function() 
			lineManager.upgradeBusToTramLine(lineId) 
		end)
	end
end 

function lineManager.upgradeBusToTramLine(lineId) 
	local vehicleCount = lineManager.sellAllVehicles(lineId)
	local depotOptions = lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.TRAM)
	local params = getLineParams(lineId)
	params.tramTrackType = util.getCurrentTramTrackType()
	params.tramOnlyUpgrade = true
	if #depotOptions==0 then 
		trace("No tram depot options found, attempting to rectify")
		local line = getLine(lineId)
		local firstStation = stationFromStop(line.stops[1])
		local tramDepot = constructionUtil.searchForTramDepot(util.getStationPosition(firstStation), 500)
		if tramDepot then 
			routeBuilder.checkRoadRouteForUpgrade(lineManager.standardCallback, params, function() 
				local depotEntity = util.getConstruction(tramDepot).depots[1]
				return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findPathFromDepotToStop(depotEntity, line.stops[1], true))
			end)
		else 
			constructionUtil.buildTramDepotAlongRoute(firstStation, stationFromStop(line.stops[2]),params)
		end
	end 
	local newVehicleCount = math.ceil((2/3)*vehicleCount)
	lineManager.addDelayedWork(function() 
		local depotOptions = lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.TRAM)
		local newVehicleConfig = vehicleUtil.buildTram()
		for i = 1, newVehicleCount do 
			lineManager.buyVehicleForLine(lineId,i, depotOptions, newVehicleConfig)
		end
	end)
	
end
function lineManager.convertTramToBusLine(lineId) 
	local vehicleCount = lineManager.sellAllVehicles(lineId)
	local depotOptions = lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.ROAD)
	local params = getLineParams(lineId)
	if #depotOptions==0 then 
		trace("No   depot options found, attempting to rectify")
		 
		constructionUtil.buildRoadDepotAlongRoute(firstStation, stationFromStop(line.stops[2]),params)
		 
	end 
	 
	lineManager.addDelayedWork(function() 
	 
		local newLine =  api.type.Line.new()
		local line = getLine(lineId)
		for i, stop in pairs(line.stops) do 	
			newLine.stops[i]=stop
		end 
		newLine.vehicleInfo.transportModes[api.type.enum.TransportMode.BUS+1]=1
		--assert(isBusLine(newLine)) -- does not work
		if util.tracelog then debugPrint(newLine) end
		local updateLine = api.cmd.make.updateLine(lineId, newLine)
		api.cmd.sendCommand(updateLine, function(res, success) 
			trace("Attempt to update line was",success)
			if success then 
				lineManager.addWork(function() 
					local depotOptions = lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.ROAD)
					local newVehicleConfig = vehicleUtil.buildUrbanBus()
					for i = 1, vehicleCount do 
						lineManager.buyVehicleForLine(lineId,i, depotOptions, newVehicleConfig)
					end
				end)
			end 
		end)
	end)
	
end
function lineManager.createLineAndAssignVechicles(vehicleConfig, stations, lineName, numberOfVehicles, carrier, params, callback)
	local wrappedCallback = function(res, success) 
		if callback then 
			callback(res, success)
		end
				
		if success then
			lineManager.addDelayedWork(function() 
				local lineId = res.resultEntity
			
				local depotOptions
				if carrier == api.type.enum.Carrier.RAIL then
					local minStationLength = math.huge 
					for i , station in pairs(stations) do 
						minStationLength = math.min(constructionUtil.getStationLength(station), minStationLength)
					end
					trace("Now creating line and assigning vehicles  params.isElectricTrack?", params.isElectricTrack)
					trace("MinStationLength was ",minStationLength)
					params.stationLength = minStationLength
				
					local info = vehicleUtil.getConsistInfo(vehicleConfig, params.cargoType)
					local needsUpgrade = info.isElectric and not params.isElectricTrack or info.isHighSpeed and not params.isHighSpeedTrack
					params.isElectricTrack = params.isElectricTrack or info.isElectric
					params.isHighSpeedTrack = params.isHighSpeedTrack or info.isHighSpeed
					local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
					routeBuilder.checkForTrackupgrades(line, callback, params, lineManager.findDepotsForLine(lineId, carrier, true))
					depotOptions = lineManager.findDepotsForLine(lineId, carrier, false, params.isElectricTrack)
				else 
					depotOptions = lineManager.findDepotsForLine(lineId, carrier, false, params and params.tramTrackType==2)
				end
				if #depotOptions == 0 then 
					trace("No depot options found, attempting to rectify")
					local newCallback = function(res, success) 
						if success then 
							depotOptions = lineManager.findDepotsForLine(lineId, carrier)
							assert(#depotOptions>0)
							buyAndAssignVechicles(vehicleConfig, depotOptions , lineId, numberOfVehicles, callback)
						else 
							callback(res, success)
						end 
					end 
					constructionUtil.buildDepotAlongRoute(stations, params, carrier, newCallback)
				else 				
					buyAndAssignVechicles(vehicleConfig, depotOptions , lineId, numberOfVehicles, callback)
				end 
			end)
		end
	end		
	lineManager.createNewLine(stations, wrappedCallback, lineName, params)
end

function lineManager.setupBusLine(vehicleConfig, mainStation, station, numberOfBusses, prefix)
	local lineName = api.engine.getComponent(station, api.type.ComponentType.NAME).name
	if prefix then 
		lineName = _(prefix).." "..lineName 
	end 
	lineName = lineName:gsub(_("Bus Stop"), _("Bus Line")) -- trying to preserve translations 
	lineManager.createLineAndAssignVechicles(vehicleConfig, {mainStation, station}, lineName, numberOfBusses, api.type.enum.Carrier.ROAD )
end
function lineManager.createIntercityBusLine(station1, station2, town1, town2, params, callback)
 
	local modelDetail = vehicleUtil.getBestMatchForIntercityBus()
	local targetCapacity = paramHelper.getParams().initialTargetBusCapacity
	
	local numberOfBusses = math.ceil(targetCapacity / vehicleUtil.getCargoCapacityFromId(modelDetail.modelId, "PASSENGERS"))
	trace("Initial numberOfBusses based on capacity was",numberOfBusses)
	local vehicleConfig = vehicleUtil.createVehicleConfig(modelDetail.modelId)
	
	local speed = (2/3)* modelDetail.model.metadata.roadVehicle.topSpeed -- estimate 
	local routeLength = util.distBetweenStations(station1, station2) -- likely underestimate
	local oldEstimatedTripTime = routeLength/speed
	
	
	local namePrefix=town1.name.." ".._("Intercity")
	local alreadyCalledBack = false
	local function wrappedCallback(res, success)
		util.clearCacheNode2SegMaps()
		if success then 
			if not alreadyCalledBack then 
				alreadyCalledBack = true 
				lineManager.addWork(function()
					util.lazyCacheNode2SegMaps()
					local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(vehicleConfig, {station1, station2}, params)
					local estimatedTripTime = throughputInfo.estimatedTripTime
					numberOfBusses = math.max(numberOfBusses, math.ceil(estimatedTripTime/paramHelper.getParams().targetMaximumPassengerBusInterval))
					trace("estimated trip time was " , estimatedTripTime, " calculated number of busses required=",numberOfBusses, " oldEstimatedTripTime=",oldEstimatedTripTime)
					lineManager.setupFullStationBusLine(station1, station2, numberOfBusses, namePrefix, callback)	
				end)
			else 
				trace("WARNING!, Called back to create full station bus line multiple times")
			end
		else
			callback(res, success)
		end
	end
	routeBuilder.buildOrUpgradeForBusRoute(station1, station2, wrappedCallback, params)
end

function lineManager.setupBusOrTramLine(vehicleConfig, station1, station2, lineName, numberOfBusses, isTram, callback, params)
	util.lazyCacheNode2SegMaps()
	params = params or  paramHelper.getDefaultRouteBuildingParams("PASSENGERS")
	local stations = {station1}
	if not params.expressBusRoute then  
		local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2, isTram)
		local returnStations = {}
		for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
			local edge = routeInfo.edges[i].edge
			local isLeft = edge.node1 == routeInfo.edges[i-1].edge.node0 or edge.node1 == routeInfo.edges[i-1].edge.node1
			if #edge.objects == 2 then 
				for i , edgeObjs in pairs(edge.objects) do 
					local objIsLeft = edgeObjs[2] == api.type.enum.EdgeObjectType.STOP_LEFT  
					trace("Idx=",i,"At edge ",routeInfo.edges[i].id," detemined ",edgeObjs[1]," is left? ",objIsLeft," we are left?",isLeft)
					if isLeft == objIsLeft  then 
						table.insert(stations, edgeObjs[1])
					else 
						table.insert(returnStations, edgeObjs[1])
					end
				end
			end
		end
		table.insert(stations, station2)
		for i = #returnStations, 1, -1 do
			table.insert(stations, returnStations[i])
		end
	else
		table.insert(stations, station2)
	end 
	local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(vehicleConfig, stations, params)
	local estimatedTripTime = throughputInfo.estimatedTripTime
	 
	local minBussesForInterval = math.ceil(estimatedTripTime/paramHelper.getParams().targetMaximumPassengerBusInterval)
	trace("Calculated min trams for interval as",minBussesForInterval,"based on estimatedTripTime of ",estimatedTripTime)
	numberOfBusses = math.max(numberOfBusses, minBussesForInterval)
	local carrier = isTram and api.type.enum.Carrier.TRAM or api.type.enum.Carrier.ROAD
	lineManager.createLineAndAssignVechicles(vehicleConfig, stations, lineName, numberOfBusses,carrier , params, callback)
end
function lineManager.getCallbackAfterBusChanged(town) 
	return function(res, success) 
		if success then 
			lineManager.addDelayedWork(function() end) -- allow at least one tick
			lineManager.addDelayedWork(function() 
				
				local function expiringStation(stop) 
					return stop.station == -1
--										return #api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations == 0 
				end 
				local function lineIsForThisTown(line) 
					for i , stop in pairs(line.stops) do 
						if not expiringStation(stop) then 
							local station = api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations[stop.station+1]
							local townForStation = api.engine.system.stationSystem.getTown(station)
							if townForStation ~= town then 
								return false 
							end 
						end 
					end 
					return true
				end 
				local function foundExpiringStation(line)
					for i , stop in pairs(line.stops) do
						if expiringStation(stop) then 
							return true 
						end 
					end 
					return false
				end
				local alreadyAssigned = {}
				local function findNewStopForLine() 
					for i, stationId in pairs(api.engine.system.stationSystem.getStations(town)) do 
						if #api.engine.system.lineSystem.getLineStopsForStation(stationId) == 0 
						and util.isBusStop(stationId, true) 
						and not alreadyAssigned[stationId] then 
							alreadyAssigned[stationId]=true
							return stationId 
						end 
					end 
				end 
				
				for i, lineId in pairs(api.engine.system.lineSystem.getProblemLines(api.engine.util.getPlayer())) do 
					local line = getLine(lineId) 
					if isBusLine(line) and lineIsForThisTown(line) and (#line.stops == 1 or foundExpiringStation(line)) then 
						local newLine =  api.type.Line.new()
						for i, stopDetail in pairs(line.stops) do 	
							local stop = api.type.Line.Stop.new()
							stop.stationGroup = stopDetail.stationGroup 
							stop.station = stopDetail.station 
							stop.terminal = stopDetail.terminal
							if stop.station == -1 then 
								local newStation = findNewStopForLine() 
								stop.stationGroup = api.engine.system.stationGroupSystem.getStationGroup(newStation)
								stop.station = util.indexOf(api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations, newStation) - 1
								stop.terminal = 0
							end 
							
							stop.loadMode = stopDetail.loadMode
							stop.minWaitingTime = stopDetail.minWaitingTime
							stop.maxWaitingTime = stopDetail.maxWaitingTime
							stop.waypoints = stopDetail.waypoints
							stop.stopConfig = stopDetail.stopConfig
							
							
							newLine.stops[i]=stop  
						end
						if #line.stops == 1 then 
							local stop = api.type.Line.Stop.new()
							local newStation = findNewStopForLine() 
							stop.stationGroup = api.engine.system.stationGroupSystem.getStationGroup(newStation)
							stop.station = util.indexOf(api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations, newStation) - 1
							stop.terminal = 0
							newLine.stops[2]=stop
						end 
						
						local updateLine = api.cmd.make.updateLine(lineId, newLine)
						api.cmd.sendCommand(updateLine, lineManager.standardCallback)
					end
					
				end
			end)
			lineManager.addWork(function() end) -- to skip a cycle
		end 
	end
end

function lineManager.setupFullStationBusLine(station1, station2, numberOfBusses, namePrefix, callback, params)
	local town =api.engine.system.stationSystem.getTown(station1)
	local useTrams = town==api.engine.system.stationSystem.getTown(station2)
	local lineName = namePrefix.." ".._(useTrams and "Tram Line" or "Bus Line")
	local vehicleConfig = useTrams and vehicleUtil.buildTram() or vehicleUtil.buildIntercityBus()
	
	params = params or paramHelper.getDefaultRouteBuildingParams("PASSENGERS", false, false, util.distBetweenStations(station1, station2))
	if useTrams then 
		params.tramTrackType = util.getCurrentTramTrackType()
		
	end
	constructionUtil.checkBusStationForUpgrade(station1, useTrams) 
	constructionUtil.checkBusStationForUpgrade(station2, useTrams) 
	local alreadyInvoked = false
	local wrappedCallback = function(res, success)
		trace("Result of attempt to add bus terminals was", success, " alreadyInvoked?",alreadyInvoked)
		if alreadyInvoked then return end 
		alreadyInvoked = true
		if success then 
			local wrappedCallback2 = function(res, success) 
				util.clearCacheNode2SegMaps()
				if success then 
					--if useTrams then 
						lineManager.addWork(function() lineManager.setupBusOrTramLine(vehicleConfig, station1, station2, lineName, numberOfBusses, useTrams, callback, params) end)
						
					if not params.expressBusRoute then 
						lineManager.addDelayedWork(function()  constructionUtil.repositionBusStops(town, lineManager.getCallbackAfterBusChanged(town) ) end)
					end
					--else 
						--lineManager.addWork(function() lineManager.createLineAndAssignVechicles(vehicleConfig, {station1, station2}, lineName, numberOfBusses, useTrams and api.type.enum.Carrier.TRAM or api.type.enum.Carrier.ROAD, params, callback)end)
				--end
				else 
					callback(res, success)
				end
			end
			
			lineManager.addWork(function()
				local wrappedCallBack3 = function(res, success) 
					if success and not params.expressBusRoute then 
						lineManager.addWork(function() constructionUtil.buildTramOrBusStopsAlongRoute(station1, station2, params, wrappedCallback2, useTrams)end)
					else 
						wrappedCallback2(res, success)
					end
				end
				if useTrams then 
					if constructionUtil.searchForTramDepot(util.getStationPosition(station1),500) then
						wrappedCallBack3(res, true)
					else 
						constructionUtil.buildTramDepotAlongRoute(station1, station2, params, wrappedCallBack3)
					end
				else 
					wrappedCallBack3(res, true)
				end 
				
			end)
			
		else
			debugPrint(res)
			callback(res, success)
		end
	end
	
	
	routeBuilder.buildOrUpgradeForBusRoute(station1, station2, wrappedCallback,params)	
 
end
 


function lineManager.findLineConnectingStations(station1, station2)
	for i, line in pairs(api.engine.system.lineSystem.getLineStopsForStation(station1)) do 
		for j, line2 in pairs(api.engine.system.lineSystem.getLineStopsForStation(station2)) do
			if line == line2 then
				return line
			end
		end
	end
end
function lineManager.getSourceStationForTruckStop(truckStop)
	for i, lineId in pairs(api.engine.system.lineSystem.getLineStopsForStation(truckStop)) do 
		for j, stop in pairs(getLine(lineId).stops) do 
			local station = stationFromStop(stop) 
			if api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) ~= -1 then 
				return station 
			end
		end 
	end 
end
function lineManager.setupTownBusNetwork(   stationConstr, town, prefix )
	local townId = type(town)=="number" and town or town.id
	if  type(town)=="number" then 
		town = game.interface.getEntity(townId)
	end
	local stations = util.deepClone(api.engine.system.stationSystem.getStations(townId))
	local busStops =  {}
	--local depotEntity = api.engine.getComponent(depotConstr ,api.type.ComponentType.CONSTRUCTION).depots[1]
	--trace("got depotEntity=",depotEntity)
 
	local mainStation
	if game.interface.getEntity(stationConstr).type=="STATION" then 
		mainStation = stationConstr
	else 
		mainStation =  api.engine.getComponent(stationConstr ,api.type.ComponentType.CONSTRUCTION).stations[1]
	end

	
	local modelDetail = vehicleUtil.getBestMatchForUrbanBus()
	local targetCapacity = paramHelper.getParams().initialTargetBusCapacity
	
	local numberOfBusses = math.ceil(targetCapacity / vehicleUtil.getCargoCapacityFromId(modelDetail.modelId, "PASSENGERS"))
	local config = vehicleUtil.createVehicleConfig(modelDetail.modelId)
	local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS")
	
	local function getMinNumberOfBusses(station1, station2)
		util.lazyCacheNode2SegMaps()
		local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(config, {station1, station2}, params)
		local estimatedTripTime = throughputInfo.estimatedTripTime
	 
		local minBussesForInterval = math.ceil(estimatedTripTime/paramHelper.getParams().targetMaximumPassengerBusInterval)
		trace("Based on the estimatedTripTime of",estimatedTripTime," the numberOfBusses needs to be at least",minBussesForInterval)
		return math.max(numberOfBusses, minBussesForInterval) 
	end  
	local shouldBuildFullBusNetwork = util.countRoadStationsForTown(townId) <= 2 
	local alreadySeen = {}
	for i, s in pairs(stations) do 
		local station = s -- avoid capturing in closures
		local details = api.engine.getComponent(station, api.type.ComponentType.STATION)
		if not details.cargo and game.interface.getEntity(station).carriers.ROAD then 
			if api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) == -1 then -- bus stops do not have a construction
				if shouldBuildFullBusNetwork then 
					local edgeId = util.getEdgeForBusStop(station)
					local streetEdge = api.engine.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
					if #api.engine.system.lineSystem.getLineStopsForStation(station) == 0 and streetEdge.tramTrackType ==0 then  	
						lineManager.addWork(function() lineManager.setupBusLine(config, mainStation, station, getMinNumberOfBusses(station, mainStation), prefix) end)
					end 
				end
			elseif station ~= mainStation and not lineManager.findLineConnectingStations(station, mainStation) and not alreadySeen[lineManager.stationHash(station, mainStation)] then 
				alreadySeen[lineManager.stationHash(station, mainStation)] =true
				lineManager.addWork(function() lineManager.setupFullStationBusLine( mainStation, station, getMinNumberOfBusses(station, mainStation), town.name, lineManager.standardCallback ) end)
			end
		end
	end
	lineManager.standardCallback(nil, true)
end


function lineManager.stationHash(station1, station2) 
	if station1 > station2 then 
		return station1*100000+station2
	else 
		return station2*100000+station1
	end 
end 

 

local function isStopOverCrowded(lineId, stop) 
	local stationId = api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP).stations[1]
	local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION)
	local cargoType = discoverLineCargoType(lineId)
	-- e.g.
	-- api.engine.system.simPersonAtTerminalSystem.getNumFreePlaces(api.engine.getComponent(51567, api.type.ComponentType.STATION).terminals[1].personEdges[1])
	local busStop = false
	local cargoTypeIdx = type(cargoType)=="number" and cargoType or api.res.cargoTypeRep.find(cargoType)
	for t, terminal in pairs(station.terminals) do 
		if stop.terminal == t-1 then -- agr 
			if #terminal.personEdges == 0 then
				-- bus stops have no personEdges, count the people, it probably starts becoming overcrowded around 40
				if #api.engine.system.simPersonSystem.getSimPersonsAtTerminalForTransportNetwork(terminal.personNodes[1].entity) > 40 then
					trace("Found overcrowded bus stop on line=",lineId)
					return true
				else 
					return false 
				end
			end
			for i, edge in pairs(terminal.personEdges) do 
				if station.cargo then
					
					if api.engine.system.simCargoAtTerminalSystem.hasFreePlaces(edge,cargoTypeIdx) then 
						return false
					end
				else 
					local numFreePlaces = api.engine.system.simPersonAtTerminalSystem.getNumFreePlaces(edge)
					trace("NumfreePlaces on line",lineId," was ",numFreePlaces)
					if  numFreePlaces > 0 then
						return false
					end
				end
				
			end
		end
	end
	trace("No free capacity on line=",lineId)
	return true
end 

local function checkForOldVehicles(lineId, line, report, params)
	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
	local cargoType = params.cargoType--discoverLineCargoType(lineId)
	local maxAge = 0
	local minAge = math.huge
	local totalCapacity = 0
	local ageFormatted 
	local currentCapacity = 0
	local gameTime = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	local transportVehicleConfig
	for i = 1, #vehicles do
		local vehicleDetail =  api.engine.getComponent(vehicles[i], api.type.ComponentType.TRANSPORT_VEHICLE)
		transportVehicleConfig = vehicleUtil.copyConfig(vehicleDetail.transportVehicleConfig)
		for j = 1, #transportVehicleConfig.vehicles do
			local vehicle = transportVehicleConfig.vehicles[j]
			local maintenanceState = vehicle.maintenanceState 
			local purchaseTime = vehicle.purchaseTime
			local modelId = vehicle.part.modelId 
			local age = (gameTime-purchaseTime)/1000
			local model = vehicleUtil.getModel(modelId) 
			local capacity = vehicleUtil.getCargoCapacityFromId(modelId, cargoType)
			local lifespan = model.metadata.maintenance.lifespan
			--trace("Comparing the age",age," to the lifespan",lifespan)
			local ageRatio = age/lifespan
			maxAge = math.max(maxAge, ageRatio)
			minAge = math.min(minAge, ageRatio)
			totalCapacity = totalCapacity + capacity
			if ageRatio > 1 then 
				ageFormatted = api.engine.util.formatAge(purchaseTime, gameTime)
			end 
		end
		if i == 1 then 
			currentCapacity = totalCapacity
		end
		if maxAge > 1 then 
			--break
		end
	end
	report.maxAge = maxAge 
	report.minAge = minAge
	if maxAge < 1 then 
		return false 
	end
	--report.targetLineRate = lineManager.getDemandRate(lineId,line, report, params )
	--if params.rateOverride then 
	--	report.targetLineRate = params.rateOverride
	--end
	--params.targetThroughput = report.targetLineRate
	--params.totalTargetThroughput = report.targetLineRate 
	report.isOk = false
	report.problems.oldVehicles = ageFormatted
	return true
	--[[
	trace("found old vehicles to replace maxAge=",maxAge) 
	local newVehicleConfig
	local vehiclesToSell 
	local vehiclesToReplace --  = 
	if params.isCargo then 
		local demandRate = report.targetLineRate
		local currentRate = game.interface.getEntity(lineId).rate 
		--if currentRate == 0 then 
		--	currentRate = demandRate 
		--end
		local capacityNeeded = totalCapacity
		if currentRate > 0 then 
			capacityNeeded =   (demandRate / currentRate)*totalCapacity
			trace("Set the capacityNeeded as ",capacityNeeded," based on demandRate",demandRate,"currentRate=",currentRate,"totalCapacity=",totalCapacity)
		end
		params.initialTargetLineRate = demandRate
		if isRailLine(line) then
			--local params = setupParamsForRailLine(cargoType, line)
			params.routeInfo = pathFindingUtil.getRouteInfo(stationFromGroup(line.stops[1].stationGroup),stationFromGroup(line.stops[2].stationGroup))
			
			local estimatedCurrentThroughput = vehicleUtil.estimateThroughputBasedOnConsist(transportVehicleConfig, params)
			local estimatedCurrentLineRate = #vehicles*estimatedCurrentThroughput.throughput
			local correctionFactor = 1 
			
			if currentRate > 0 then 
				correctionFactor = currentRate / estimatedCurrentLineRate
			end
			params.targetThroughput = demandRate  * correctionFactor
			trace("The estimatedCurrentLineRate was ",estimatedCurrentLineRate," the actual line rate was" ,currentRate, " giving a correctionFactor of",correctionFactor," targetThroughput=",params.targetThroughput)
			newVehicleConfig = vehicleUtil.buildMaximumCapacityTrain(params)
			local newThroughput = vehicleUtil.estimateThroughputBasedOnConsist(newVehicleConfig, params).throughput
			trace("The newThroughput was ",newThroughput," the currentCapacity=",currentCapacity)
			if newThroughput >= params.targetThroughput then 
				--newVehicleConfig = vehicleUtil.buildTrain(currentCapacity, params)
				vehiclesToReplace = 1
				vehiclesToSell = #vehicles-1
			else 
				local vehiclesNeeded = math.ceil(params.targetThroughput/newThroughput) 
				params.targetThroughput = params.targetThroughput / vehiclesNeeded
				newVehicleConfig = vehicleUtil.buildTrain(currentCapacity, params)
				trace("Setting vehicles needed to ",vehiclesNeeded, " reset targetThroughput to",params.targetThroughput)
				vehiclesToReplace = vehiclesNeeded
				vehiclesToSell = #vehicles-vehiclesNeeded
			end
		elseif isRoadLine(line) then 
			newVehicleConfig = vehicleUtil.buildTruck(params)
			local stations = {} 
			for i = 1, #line.stops do 
				table.insert(stations, stationFromStop(line.stops[i]))
			end 
			
			local vehiclesNeeded = lineManager.estimateRoadVehiclesRquired(newVehicleConfig, stations, params) 
			local correctionFactor = 1
			if currentRate > 0 then 
				params.initialTargetLineRate = currentRate 
				local currentEstimate =  lineManager.estimateRoadVehiclesRquired(transportVehicleConfig, stations, params)
				correctionFactor = #vehicles / currentEstimate
				trace("THe currentEstimate was",currentEstimate,"the actual number was ",#vehicles," the correctionFactor was",correctionFactor," initial estimate was",vehiclesNeeded, " new estimate=",math.ceil(vehiclesNeeded*correctionFactor))				
			end 
		
			vehiclesNeeded = math.ceil(vehiclesNeeded*correctionFactor)
			vehiclesToReplace = vehiclesNeeded
			vehiclesToSell = #vehicles-vehiclesNeeded
		else
			newVehicleConfig = vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
			local newCapacity = vehicleUtil.calculateCapacity(newVehicleConfig, cargoType)
			local vehiclesNeeded =  math.max(1, math.floor(capacityNeeded/newCapacity))
			vehiclesToReplace = vehiclesNeeded
			vehiclesToSell = #vehicles-vehiclesNeeded
		end
		
	else -- passengers
		if isRailLine(line) then
			
			newVehicleConfig = vehicleUtil.buildTrain(currentCapacity, params)
			vehiclesToReplace = #vehicles
			vehiclesToSell = 0
		else 
			newVehicleConfig = vehicleUtil.buildVehicleFromLineType(line.vehicleInfo.transportModes, params)
			local newCapacity = vehicleUtil.calculateCapacity(newVehicleConfig, cargoType)
			local vehiclesNeeded = math.max(1, math.floor(totalCapacity/newCapacity))
			vehiclesToReplace = vehiclesNeeded
			vehiclesToSell = #vehicles-vehiclesNeeded
		end
	end
	
	-- validation
	if vehiclesToReplace+vehiclesToSell ~= #vehicles or vehiclesToReplace < 1 or vehiclesToSell<0 then
		trace("Found invalid condition with vehiclesToReplace=",vehiclesToReplace," vehiclesToSell=",vehiclesToSell," #vehicles=",#vehicles, " on line ",lineId)
		vehiclesToReplace = math.max(vehiclesToReplace,1)
		vehiclesToReplace = math.min(vehiclesToReplace, #vehicles)
		vehiclesToSell = math.max(vehiclesToSell, 0)
		vehiclesToSell = #vehicles-vehiclesToReplace
	end
	
	report.newVehicleConfig = vehicleUtil.copyConfig(newVehicleConfig)
	checkForLineUpgrades(lineId, line, report, newVehicleConfig, params, transportVehicleConfig)
	report.vehicleCount = vehiclesToReplace - vehiclesToSell
	if not params.isCargo and report.vehicleCount < 2 and vehiclesToSell > 0 then 
		trace("Keeping minimum of 2 passenger vehicles")
		vehiclesToSell = vehiclesToSell - 1
		report.vehicleCount = report.vehicleCount + 1
		vehiclesToReplace = vehiclesToReplace + 1
	end 
	if vehiclesToReplace > 0 then 
		report.recommendations.vehiclesToReplace = vehiclesToReplace
	end
	if vehiclesToSell > 0 then 
		report.recommendations.vehiclesToSell = vehiclesToSell
	end	
	trace("Line report for life expired vehicles found",vehiclesToReplace,"vehiclesToReplace and",vehiclesToSell,"vehiclesToSell")
	table.insert(report.executionFns, function()
		for i = 1, vehiclesToReplace do
			local vehicleToReplace = vehicles[i]
			local replaceCommand = api.cmd.make.replaceVehicle(vehicleToReplace, vehicleUtil.copyConfigToApi(newVehicleConfig))
			api.cmd.sendCommand(replaceCommand, lineManager.standardCallback) 
		end	
	end) 
	 
	for i = 1, vehiclesToSell do 
		local vehicleToSell = vehicles [i+vehiclesToReplace]
		table.insert(report.executionFns, function()
			lineManager.addDelayedWork(function() api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleToSell), lineManager.standardCallback) end)end)
	end
		
	return true	--]]
end
local function calculateRouteLength( line, params, report)
	if #line.stops < 2 then 
		return 0 
	end 
	local routeLength = 0 
	params.stations = {} 
	for i = 1, #line.stops do 
		local station1 = stationFromStop(i==1 and line.stops[#line.stops] or line.stops[i-1])
		local station2 = stationFromStop(line.stops[i])
		table.insert(params.stations, station2)
		if isRailLine(line) then 
			local routeInfo =  pathFindingUtil.getRouteInfo(station1, station2)
			if routeInfo then 
				routeLength = routeLength +routeInfo.routeLength
				if not report.routeInfos then 
					report.routeInfos = {} 
				end 
				report.routeInfos[i]=routeInfo
			end 
		elseif isRoadLine(line) then 
			if util.isTruckStop(station1) or util.isTruckStop(station2) then 
				params.hasTruckStop = true
			end
			local roadRoute =  pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2)
			params.routeInfo=roadRoute
			if not roadRoute then
				trace("Unexpectedly could not find road route between ",station1, station2)
				routeLength = routeLength +util.distBetweenStations(station1, station2)
			else 
				routeLength = routeLength +roadRoute.actualRouteLength
			end
		else 
			routeLength = routeLength + util.distBetweenStations(station1, station2)
		end
	end 
	params.routeLength=routeLength
	return routeLength
	
	
end


function lineManager.getLineReport(lineId, line, isForVehicleReport, useRouteInfo, displayOnly, paramOverrides )
	util.lazyCacheNode2SegMaps() 
	if not line then 
		line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	end
	
	local report = {} 
	local params = getLineParams(lineId)
	if paramOverrides then 
		for k, v in pairs(paramOverrides) do 
			trace("getLineReport override: Setting params[",k,"] to",v)
			params[k]=v
		end 
	end 
	
	report.isOk = true 
	
	report.problems = {} 
	report.recommendations = {}
	report.upgrades = {}
	report.executionFns = {}

	function report.executeUpdate() 
		for i, execution in pairs(report.executionFns) do 
			trace("at i=",i," adding work to execute from line report")
			lineManager.addWork(execution)
		end
	end
	if not params.cargoType then 
		trace("WARNING! Unable to find cargoTYpe")
		return report
	end 
	if not line then 
		trace("no line for ", lineId)
		return report
	end
	report.targetLineRate =  params.rateOverride or  lineManager.getDemandRate(lineId,line, report, params )
	
	report.isBusLine = isBusLine(line)
	report.isRoadLine = isRoadLine(line)
	report.isTruckLine = isRoadLine(line)
	report.isTramLine = isTramLine(line)
	report.isElectricTramLine = isElectricTramLine(line)
	report.isElectricRailLine = isElectricRailLine(line)
	report.isRailLine = isRailLine(line)
	report.isShipLine = isShipLine(line)
	report.isAirLine = isAirLine(line)
	report.rate = game.interface.getEntity(lineId).rate
	if params.rateOverride and report.rate < params.rateOverride then 
		report.isOk = false 
	end
	report.lineId = lineId
	report.stopCount = #line.stops
	report.lineName = api.engine.getComponent(lineId, api.type.ComponentType.NAME).name
	report.useRouteInfo = true 
	report.routeLength = calculateRouteLength(line, params, report)
	report.existingTicketPrice = line.vehicleInfo and line.vehicleInfo.defaultPrice or 0
	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
	report.existingVehicleCount = #vehicles
	report.vehicleCount = #vehicles -- defaulted initially
	report.totalExistingTime = 0 
	report.currentInterval = 0
	report.impliedLoadTime = 0
	report.totalSectionTime = 0
	report.existingTimings = {}
	report.sectionTimesMissing = false
	report.topSpeed = 0
	report.cargoType = params.cargoType
	if #vehicles > 0 then 
		local transportVehicle = api.engine.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
		report.currentVehicleConfig = vehicleUtil.copyConfig(transportVehicle.transportVehicleConfig)
		report.carrier = transportVehicle.carrier
	 
		for i, t in pairs(transportVehicle.sectionTimes) do 
			report.totalSectionTime = report.totalSectionTime + t
			if t == 0 then 
				report.sectionTimesMissing=true
			end
			table.insert(report.existingTimings, t)
		end 
		local frequency = game.interface.getEntity(lineId).frequency
		
		if frequency > 0 then 
			report.currentInterval = 1 / frequency
			report.totalExistingTime = report.currentInterval * #vehicles
			report.impliedLoadTime = report.totalExistingTime - report.totalSectionTime
		else
			report.totalExistingTime = report.totalSectionTime
			report.sectionTimesMissing=true
		end
		if report.carrier == api.type.enum.Carrier.RAIL then 
			report.topSpeed = vehicleUtil.getConsistInfo(report.currentVehicleConfig, params.cargoType, params).topSpeed
		else 
			report.topSpeed = vehicleUtil.getTopSpeed(report.currentVehicleConfig) 
		end 
	else 
		report.carrier = discoverLineCarrier(line)
	end 
	if not report.carrier then 
		trace("Unable to determine carrier, aborting") 
		return report 
	end
	report.averageSpeed = report.totalExistingTime ==0 and 0 or report.routeLength/report.totalExistingTime
	report.stoppedVehiclesEnRoute = 0
	report.movingVehiclesEnRoute = 0
	for i , vehicle in pairs(vehicles) do 
		local transportVehicle = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
		if transportVehicle.state == api.type.enum.TransportVehicleState.EN_ROUTE then 
			local movePath = api.engine.getComponent(vehicle, api.type.ComponentType.MOVE_PATH)
			if not movePath then goto continue end
			if movePath.dyn.speed == 0 then 
				report.stoppedVehiclesEnRoute = 1 + report.stoppedVehiclesEnRoute
			else 
				report.movingVehiclesEnRoute = 1 + report.movingVehiclesEnRoute
			end 
		
		end 
		::continue::
	end
	local minimumInterval = isRoadLine(line) and paramHelper.getParams().minimumIntervalRoad or paramHelper.getParams().minimumInterval
	local totalVehiclesEnRoute = report.stoppedVehiclesEnRoute + report.movingVehiclesEnRoute
	if totalVehiclesEnRoute > 3 and (report.stoppedVehiclesEnRoute / totalVehiclesEnRoute) > 0.5
		or report.averageSpeed > 0 and report.topSpeed > 0 and report.averageSpeed < 0.1*report.topSpeed
		or #vehicles > 1 and report.currentInterval > 0 and report.currentInterval < minimumInterval*0.8
	then 
		report.problems.possibleCongestion = true
		report.isOk = false
	end 	
	if report.isAirLine and report.currentVehicleConfig then 
		local projectedInterval, numberOfVehicles=  lineManager.estimateAirLineTripTime(report.currentVehicleConfig , params.stations )
		trace("For the airline the projectedInterval was",util.formatTime(projectedInterval)," the actual interval was",util.formatTime(report.totalExistingTime))
		report.estimatedAirVehicles = numberOfVehicles
		if report.totalExistingTime > 1.5*projectedInterval then 
			report.problems.possibleCongestion = true
			report.isOk = false
		end
		
	end 
	
	
	
	local account = api.engine.getComponent(lineId, api.type.ComponentType.ACCOUNT)
	local oneMinute = 60875
	local now  = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	local total = 0
	for i = #account.journal, 1, -1 do 
		local journal = account.journal[i]
		if now-journal.time > 12*oneMinute then -- trying to get profitability over 1 year
			break 
		end 
		total = total + journal.amount 
	end
	trace("Total amount for line", lineId," was calculated as",total)
	report.profit = total
	if total < -100000 then 
		-- commenting out isOk, need to find something else to actually be able to resolve poor profit e.g. too high throughput
		--report.isOk = false 
		report.problems.profit = api.util.formatMoney(math.floor(total))
	end
	if isPassengerLine(line) and isAboveMaximumInterval(lineId, line, params) then
		report.isOk = false
		report.problems.isAboveMaximumInterval = _("Target")..": "..formatTime(params.targetMaximumPassengerInterval)
	end
	for i, stop in pairs(line.stops) do
		if isStopOverCrowded(lineId, stop) then 
			report.isOk = false
			report.problems.hasOvercrowdedStops = true
			break
		end
	end  
	
	if isForVehicleReport then 
		report.isForVehicleReport = true 
		addMoreVehicles(lineId, line, report, params)
		return report
	end
	
	
	
	 

	
	

	if checkForOldVehicles(lineId, line, report, params) then 
		--return report
	end
	
	if not report.isOk and not displayOnly then
		if report.minAge > 0.005 then -- bought vehicles recently needs time to have an effect
			addMoreVehicles(lineId, line, report,params )
		else 
			trace("Suppressing the update as the minAge of the vehicles was", report.minAge)
		end 
	else 
		trace("no problems detected on line ",lineId)
	end
	return report
end

function lineManager.createShipLine(industry, stationConstr1, depotConst1, stationConstr2, depotConst2, callback, cargoType, initialTargetRate)
	trace("Setting up a ship line")
	local station1 = stationFromConstruction(stationConstr1)
	local station2 = stationFromConstruction(stationConstr2)
	 
	local construction1  = constructionFromStation(station1) 
	local construction2  = constructionFromStation(station2) 
	local isCargo = util.getStation(station1).cargo
	--local allowLargeShips = construction1.params.size == 1 and construction2.params.size == 1
	--local allowLargeShips = construction1.params:at(5) == 1 and construction2.params:at(5) == 1
	local allowLargeShips =  isLargeHarbour(construction1)  and isLargeHarbour(construction2)
	
	trace("Getting ship vehicle config, allowLargeShips=",allowLargeShips, " construction1.params.size=",construction1.params.size, "construction2.params.size= ",construction2.params.size )
	local params = { cargoType = cargoType} 
	local vehicleConfig = vehicleUtil.buildShip(params, allowLargeShips)
	local maxSpeed = vehicleUtil.getTopSpeed(vehicleConfig) 
	local loadTime = vehicleUtil.getLoadTime(vehicleConfig, cargoType) 
	local capacity = vehicleUtil.calculateCapacity(vehicleConfig, cargoType)
	local distance = util.distBetweenStations(station1, station2)
	local projectedInterval = 2*(loadTime + distance / (0.8*maxSpeed))
	trace("Projecting an interval of ",projectedInterval)
	
	local depotOptions = {}
	if depotConst1 then 
		table.insert(depotOptions, { depotEntity=  depotFromConstruction(depotConst1), stopIndex = 0})
	end 
	if depotConst2 then 
		table.insert(depotOptions, { depotEntity=  depotFromConstruction(depotConst2), stopIndex = 1})
	end 
	local numberOfVehicles = 1
	if isCargo then 
		local targetThroughput=  initialTargetRate/ (12 * 60)
		local projectedThroughput = capacity / projectedInterval 
		numberOfVehicles = math.ceil(targetThroughput/projectedThroughput)
		trace("Calculated numberOfVehicles=",numberOfVehicles," based on projectedThroughput",projectedThroughput," and targetThroughput=",targetThroughput)
	else 
		local targetInterval = paramHelper.getParams().targetMaximumPassengerInterval
		numberOfVehicles = math.ceil(projectedInterval / targetInterval)
		trace("Calculated numberOfVehicles=",numberOfVehicles," based on projectedInterval",projectedInterval," and targetInterval=",targetInterval)
	end 
	trace("Got ship vehicle config cargoType=",cargoType, " set numberofVehicles to ",numberOfVehicles)
	local wrappedCallback = function(res, success) 
		trace("Result of creating ship line was ",success)
		if success then
			local line = res.resultEntity
			for i, lineId in pairs(api.engine.system.lineSystem.getProblemLines(game.interface.getPlayer())) do 
				if lineId == line then 
					trace("Line has not connected")
					callback(res, false)
					return
				end
			end
			callback(res, true)
			trace("Created ship line successfully, now building and assigning vehicles")
			buyAndAssignVechicles(vehicleConfig, depotOptions, line, numberOfVehicles, lineManager.standardCallback)
 
		else 
			callback(res, success)
		end 
	end
	lineManager.createNewLine({station1, station2}, wrappedCallback)	 
end

local function findAirportForTown(townId, isCargo)
	for i, station in pairs(api.engine.system.stationSystem.getStations(townId)) do
		local construction = util.getConstructionForStation(station)
		if construction and string.find(construction.fileName, "air") and util.getStation(station).cargo == isCargo then
			return station
		end
	end
	assert(false)
end
function lineManager.extendLine(lineId, newStation)
	local lineDetails = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local stationGroup = api.engine.system.stationGroupSystem.getStationGroup(newStation)
	trace("Exetending line",lineId," to ",newStation)
	local line = api.type.Line.new()
	local endWayPoints = {}
	for i, stopDetail in pairs(lineDetails.stops) do 	
		--[[local stop = api.type.Line.Stop.new()
		stop.stationGroup = stopDetail.stationGroup 
		stop.station = stopDetail.station 
		stop.terminal = stopDetail.terminal
		stop.loadMode = stopDetail.loadMode
		stop.minWaitingTime = stopDetail.minWaitingTime
		stop.maxWaitingTime = stopDetail.maxWaitingTime
		stop.waypoints = stopDetail.waypoints
		stop.stopConfig = stopDetail.stopConfig--]]
		
		if i == #lineDetails.stops then 
			endWayPoints = stopDetail.waypoints
			stopDetail.waypoints = {}
		end 
		line.stops[i]=stopDetail  
	end
	local newStop = api.type.Line.Stop.new()
	line.vehicleInfo = lineDetails.vehicleInfo
	newStop.stationGroup = stationGroup
	setAppropriateStationIdx(newStop, newStation)
	newStop.terminal =  getFreeTerminalForStation(newStation) 
	newStop.waypoints = endWayPoints
	line.stops[1+#line.stops]=newStop
	local updateLine = api.cmd.make.updateLine(lineId, line)
	api.cmd.sendCommand(updateLine, function(res, success) 
		if success then 
			lineManager.addDelayedWork(function() 
				lineManager.checkAndUpdateLine(lineId)
			end)
		end
	end)

end
function lineManager.setupTrucks(result, stations, params) 
	--local cargoType = util.discoverCargoType(result.industry1)
	trace("Setting up trucks for cargo type =",params.cargoType)
	--params.cargoType = cargoType
	local cargoPrefix = ""
	if  result.industry1.type == "TOWN" then 
		local cargoRepIdx = type(params.cargoType)=="number" and params.cargoType or api.res.cargoTypeRep.find(params.cargoType)
		cargoPrefix = _(api.res.cargoTypeRep.get(cargoRepIdx).name).." "
	end 
	params.lineName= result.industry1.name.." "..cargoPrefix.._("Truck Line")
	lineManager.setupTruckLine(stations, params)
end 

function lineManager.estimateRoadVehiclesRquired(truckConfig, stations, params) 
	local throughputInfo = vehicleUtil.getThroughputInfoForRoadVehicle(truckConfig, stations, params)
	local estimatedTripTime = throughputInfo.estimatedTripTime
	local capacity = throughputInfo.capacity
	local routeLength = throughputInfo.routeLength
	local throughput = capacity / estimatedTripTime
	local initialTargetRate = params.rateOverride or params.initialTargetLineRate
	if not initialTargetRate then initialTargetRate = paramHelper.getParams().initialTargetLineRate end
	local targetThroughput = initialTargetRate/ (12 * 60) -- 12 minutes is one "year", 100 is minimum industry production
	local numberOfVehicles = math.max(1, math.ceil(targetThroughput/throughput))
	trace("caluclated numberOfVehicles=",numberOfVehicles," based on throughput=",throughput, " targetThroughput=",targetThroughput, " and estimatedTripTime=",estimatedTripTime, " routeLength=",routeLength)
	return numberOfVehicles
end

function lineManager.setupTruckLine(stations, params) 
	local truckConfig = vehicleUtil.buildTruck(params)
	local numberOfVehicles = lineManager.estimateRoadVehiclesRquired(truckConfig, stations, params)  
	local lineName = params.lineName
	lineManager.createLineAndAssignVechicles(truckConfig, stations, lineName, numberOfVehicles, api.type.enum.Carrier.ROAD, params )
end

function lineManager.estimateAirLineTripTime(vehicleConfig, stations)
	
	local maxSpeed = vehicleUtil.getTopSpeed(vehicleConfig) 
	local loadTime = vehicleUtil.getLoadTime(vehicleConfig, "PASSENGERS") 
	
	local taxiAndApproachTime = 286 -- measured time of Airbus A320 travelling between airports next to each other 
	local projectedInterval = 0 
	for i = 1, #stations do 
		local priorStation = i==1 and stations[#stations] or stations[i-1]
		local station = stations[i]
		local dist = util.distBetweenStations(priorStation, station)
		local tripTime = dist / maxSpeed -- probably not worth trying to optimise, some time for accel /decel but approach may also reduce distance
		projectedInterval = projectedInterval +  tripTime + loadTime+taxiAndApproachTime
	end 
	

	local targetInterval = paramHelper.getParams().targetMaximumPassengerAirInterval

	local numberOfVehicles = math.ceil(projectedInterval / targetInterval)
	
	trace("Projecting an interval of ",projectedInterval, " based on tripTime=",tripTime,"taxiAndApproachTime=",taxiAndApproachTime,"loadTime=",loadTime, " numberOfVehicles set to ",numberOfVehicles)
	return projectedInterval, numberOfVehicles
end

function lineManager.createAirLine(town1, town2) 
	trace("Creating air line between ", town1.name, " and ",town2.name)
	local station1 = findAirportForTown(town1.id, false)
	local station2 = findAirportForTown(town2.id, false)
	local depot1 = util.getConstructionForStation(station1).depots[1]
	local depot2 = util.getConstructionForStation(station2).depots[1]
	
	local smallOnly = string.find(util.getConstructionForStation(station1).fileName, "airfield") or string.find(util.getConstructionForStation(station2).fileName, "airfield")
	local params = { cargoType = "PASSENGERS"}
	local vehicleConfig =  vehicleUtil.buildPlane(params, smallOnly)
	local projectedInterval, numberOfVehicles=  lineManager.estimateAirLineTripTime(vehicleConfig, {station1, station2} )

	trace("Projecting an interval of ",projectedInterval, " based on tripTime=",tripTime,"taxiAndApproachTime=",taxiAndApproachTime,"loadTime=",loadTime, " numberOfVehicles set to ",numberOfVehicles)
	
	local depotOptions = {}
	table.insert(depotOptions, { depotEntity= depot1, stopIndex = 0})
	table.insert(depotOptions, { depotEntity=  depot2, stopIndex = 1})
	

	local wrappedCallback = function(res, success) 
		if success then
			local line = res.resultEntity
			trace("Created air line successfully, now building and assigning vehicles")
			lineManager.addWork(function() buyAndAssignVechicles(vehicleConfig, depotOptions, line, numberOfVehicles, lineManager.standardCallback)end) 
		end
		lineManager.standardCallback(res, success)
	end
	lineManager.createNewLine({station1, station2}, wrappedCallback)	
end

function lineManager.setupCargoAirline(result, callback)
	local constr1 = util.getConstructionForStation(result.airport1)
	local constr2 = util.getConstructionForStation(result.airport2)
	local station1 
	local station2 
	for i , station in pairs(constr1.stations) do 
		if util.getStation(station).cargo then 
			station1 = station 
			break
		end 
	end 
	for i , station in pairs(constr2.stations) do 
		if util.getStation(station).cargo then 
			station2 = station 
			break
		end 
	end 
	
	local depot1 = constr1.depots[1]
	local depot2 = constr2.depots[1]
	
	local smallOnly = string.find(util.getConstructionForStation(station1).fileName, "airfield") or string.find(util.getConstructionForStation(station2).fileName, "airfield")
	local params = { cargoType = result.cargoType}
	local vehicleConfig =  vehicleUtil.buildPlane(params, smallOnly)
	local dist = util.distBetweenStations(station1, station2)
	local maxSpeed = vehicleUtil.getTopSpeed(vehicleConfig) 
	local loadTime = vehicleUtil.getLoadTime(vehicleConfig, result.cargoType) 
	local tripTime = dist / maxSpeed -- probably not worth trying to optimise
	local taxiAndApproachTime = 286 -- measured time of Airbus A320 travelling between airports next to each other 
	local projectedInterval = 2*(tripTime + loadTime+taxiAndApproachTime)
	local targetThroughput=  result.initialTargetRate/ (12 * 60)
	local capacity = vehicleUtil.calculateCapacity(vehicleConfig, cargoType)
	local projectedThroughput = capacity / projectedInterval 
	local numberOfVehicles = math.ceil(targetThroughput/projectedThroughput)
	trace("Calculated numberOfVehicles=",numberOfVehicles," based on projectedThroughput",projectedThroughput," and targetThroughput=",targetThroughput)
	
	
	local depotOptions = {}
	table.insert(depotOptions, { depotEntity= depot1, stopIndex = 0})
	table.insert(depotOptions, { depotEntity=  depot2, stopIndex = 1})
	
	local wrappedCallback = function(res, success) 
		if success then
			local line = res.resultEntity
			trace("Created air line successfully, now building and assigning vehicles")
			lineManager.addWork(function() buyAndAssignVechicles(vehicleConfig, depotOptions, line, numberOfVehicles, callback)end)
		end
		lineManager.standardCallback(res, success)
	end
	lineManager.createNewLine({station1, station2}, wrappedCallback)	
	
end

local function getLines(circle, filterFn, maxToReturn)
	local allLines
	if not maxToReturn then maxToReturn = math.huge end
	if circle and circle.radius ~= math.huge then 
		allLines = {} 
		local alreadySeen = {} 
		for i, stationId in pairs(game.interface.getEntities(circle, {type="STATION"})) do 
			for j, lineId in pairs(api.engine.system.lineSystem.getLineStopsForStation(stationId)) do 
				if not alreadySeen[lineId] then
					alreadySeen[lineId] = true 
					table.insert(allLines, lineId)
					if #allLines >= maxToReturn then 
						return allLines
					end
				end
			end 
		end		
	else 
		allLines = util.deepClone(api.engine.system.lineSystem.getLines()) -- seems to be necessary to assign this a local variable
	end
	if filterFn then 
		local filterResult = {} 
		for i, lineId in pairs(allLines) do 
			if filterFn(lineId, getLine(lineId)) then 
				table.insert(filterResult, lineId) 
				if #filterResult >= maxToReturn then 
					return allLines
				end
			end 
		end 
		return filterResult
	end 
	
	return allLines
end
lineManager.getLines = getLines
function lineManager.getLinesReport(limit, circle, filterFn, paramOverrides)
	local begin = os.clock()
	if not filterFn then filterFn = function() return true end end
	util.lazyCacheNode2SegMaps() 
	local allLines = getLines(circle)
	lineManager.cargoSourceMap = util.deepClone(api.engine.system.stockListSystem.getCargoType2stockList2sourceAndCount())
	trace("Cloned cargoSourceMap, time taken was ",(os.clock()-begin))
	local reports = {}
	if not limit then limit = math.huge end
	local count =0 
	for i, lineId in pairs(allLines) do 
		trace("about to get line for ",lineId, " count = ",count)
		if api.engine.entityExists(lineId) then
			local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
			if filterFn(lineId, line) then 
				local beginLineReport = os.clock()
				local lineReport = lineManager.getLineReport(lineId, line, false, false, false, paramOverrides)
				trace("Got reports, time taken was ",(os.clock()-beginLineReport), " for ",lineId, " ", lineReport.lineName)
				if not lineReport.isOk and util.size(lineReport.recommendations) > 0 then 
					count = count + 1
				end
				table.insert(reports, lineReport)
				if count >= limit then 
					break 
				end
			end
		else
			trace("Requested an invalid entity", lineId)
		end
	end
	lineManager.cargoSourceMap = nil
	trace("Got reports, time taken was ",(os.clock()-begin))
	return reports
end

function lineManager.checkLinesAndUpdate(param, reportFn)
	local filterFn
	if param and param.carrier ~= -1 then 
		filterFn = function(lineId, line)  
			return param.carrier == discoverLineCarrier(line)  
		end
	end 
	reportFn("Checking lines", "Analysing.")
	local reports = lineManager.getLinesReport(nil, nil, filterFn)
	local count = 0 
	local completionCount = 0
	local originalCallback = lineManager.standardCallback
	lineManager.standardCallback = function(res, success) 
		completionCount = completionCount + 1 
		reportFn("Updating line "..completionCount.." of "..count, "Updating.")
		if completionCount >= count then 
			lineManager.standardCallback = originalCallback
			reportFn("Updating line "..completionCount.." of "..count, "Complete")
		end 
	end 
	for i, report in pairs(reports) do 
		if not report.isOk then 
			count = count + 1
			report.executeUpdate() 
		end
	end	
end
function lineManager.checkAndUpdateLine(lineId, paramOverrides)
	lineManager.getLineReport(lineId, nil, false, false, false, paramOverrides).executeUpdate()
end

function lineManager.buildVehicleFilterPanel() 
	 
	local buttonGroup = api.gui.comp.ToggleButtonGroup.new(api.gui.util.Alignment.HORIZONTAL, 0, false)
	local all = util.newToggleButton("", "ui/construction/categories/all@2x.tga") 
	local road = util.newToggleButton("", "ui/hud/vehicle_bus@2x.tga") 
	local tram = util.newToggleButton("", "ui/hud/vehicle_tram@2x.tga") 
	local rail = util.newToggleButton("", "ui/hud/vehicle_train_electric@2x.tga") 
	local ship = util.newToggleButton("", "ui/hud/vehicle_ship@2x.tga") 
	local air = util.newToggleButton("", "ui/hud/vehicle_aircraft@2x.tga") 
	
	all:setTooltip(_("Show all"))
	road:setTooltip(_("Road vehicles only"))
	tram:setTooltip(_("Trams only"))
	rail:setTooltip(_("Trains only"))
	ship:setTooltip(_("Ships only"))
	air:setTooltip(_("Aircraft only"))
	 
	all:setSelected(true, false)
	buttonGroup:add(all)
	buttonGroup:add(road)
	buttonGroup:add(tram)
	buttonGroup:add(rail)
	buttonGroup:add(ship)
	buttonGroup:add(air)
	buttonGroup:setOneButtonMustAlwaysBeSelected(true)
	return {
		panel = buttonGroup,
		filterFn = function(lineId, line) 
			if road:isSelected() then 
				return isRoadLine(line) and not isTramLine(line) 
			end 
			if tram:isSelected() then 
				return isTramLine(line)  
			end 
			if rail:isSelected() then 
				return isRailLine(line) 
			end 
			if ship:isSelected() then 
				return isShipLine(line) 
			end 
			if air:isSelected() then 
				return isAirLine(line) 
			end 
			return true 
		end,
		getCarrier = function() 
			if road:isSelected() then 
				return api.type.enum.Carrier.ROAD
			end 
			if tram:isSelected() then 
				return api.type.enum.Carrier.TRAM
			end 
			if rail:isSelected() then 
				return api.type.enum.Carrier.RAIL
			end 
			if ship:isSelected() then 
				return api.type.enum.Carrier.WATER
			end 
			if air:isSelected() then 
				return api.type.enum.Carrier.AIR
			end 
			return -1
		end,
		setCallback = function(callback) 
			buttonGroup:onCurrentIndexChanged(callback)
		end 
	}
end 

local function makelocateRow(report)
	local boxLayout =  api.gui.layout.BoxLayout.new("HORIZONTAL"); 
	local imageView = api.gui.comp.ImageView.new("ui/button/xxsmall/locate.tga")
	local button = api.gui.comp.Button.new(imageView, true)
	button:onClick(function() 
		api.gui.util.getGameUI():getMainRendererComponent():getCameraController():focus(report.lineId, false)
	end)
	boxLayout:addItem(button)
	boxLayout:addItem(api.gui.comp.TextView.new(_(report.lineName)))
	local comp= api.gui.comp.Component.new("")
	comp:setLayout(boxLayout)
	return comp
end

lineManager.makelocateRow = makelocateRow


local function makeTimingsPanel(timings, rawTimings, loadTime)
	local totalTime = 0
	local tooltip 
	if rawTimings then 
		tooltip ="Timings: (uncorrected)\n"
	else 
		tooltip ="Timings:\n"
	end
	if loadTime then 
		tooltip = tooltip.."Load time: "..formatTime(loadTime).."\n"
		totalTime= totalTime+loadTime 
	end
	for i , timing in pairs(timings) do 
		totalTime = totalTime + timing
		tooltip = tooltip..formatTime(timing)
		if rawTimings then 
			tooltip = tooltip.." ("..formatTime(rawTimings[i])..")"
		end 
		tooltip = tooltip.."\n"
	end
	tooltip = string.sub(tooltip,1, -2)
	local panel = api.gui.comp.TextView.new(formatTime(totalTime))
	panel:setTooltip(tooltip)
	return panel
end

lineManager.makeTimingsPanel = makeTimingsPanel

function lineManager.buildLineDisplayTable(callbackFn) 
	local colHeaders = {
		api.gui.comp.TextView.new(_("Line")),
		api.gui.comp.TextView.new(_("Current\n rate")),
		api.gui.comp.TextView.new(_("Recommended\nrate")),
		api.gui.comp.TextView.new(_("#vehicles")),
		api.gui.comp.TextView.new(_("#stops")),
		api.gui.comp.TextView.new(_("Ticket\nprice")),
		api.gui.comp.TextView.new(_("Route\nlength")),
		api.gui.comp.TextView.new(_("Interval")),
		api.gui.comp.TextView.new(_("Totaltime")),
		api.gui.comp.TextView.new(_("topSpeed")),
		api.gui.comp.TextView.new(_("averageSpeed")),
	
		api.gui.comp.TextView.new(_("Profit")),
		api.gui.comp.TextView.new(_("Vehicle config")), 	
		api.gui.comp.TextView.new(_("Analyze")), 
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	displayTable:setHeader(colHeaders)
	local function refreshTable(linesToReport, currentLineId)
		trace("Being refresh line manager table, got " ,#linesToReport," to report")
		displayTable:deleteAll()
		local allButtons = {}
		local count = 0
		for i = 1, #linesToReport do
			trace("Building line row for ",lineId)
			local lineId = linesToReport[i]
			local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
			local isForVehicleReport = false
			local report = lineManager.getLineReport(lineId, line, isForVehicleReport, false, true)
			local button = util.newButton("Analyze","ui/icons/game-menu/help@2x.tga")
			table.insert(allButtons, button)
			if lineId  == currentLineId then 
				button:setEnabled(false)
			end
			button:onClick(function() 
				lineManager.addWork(function() 
					for j = 1, #allButtons do 
						allButtons[j]:setEnabled(i~=j)
					end 
					callbackFn(lineId)
				end )			
			end)
			displayTable:addRow({
				makelocateRow(report),
				api.gui.comp.TextView.new(tostring(math.ceil(report.rate))),				
				api.gui.comp.TextView.new(tostring(math.ceil(report.targetLineRate))),
				api.gui.comp.TextView.new(tostring(report.existingVehicleCount)),
				api.gui.comp.TextView.new(tostring(report.stopCount)),
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.existingTicketPrice))),
				api.gui.comp.TextView.new(api.util.formatLength(math.floor(report.routeLength))),
				api.gui.comp.TextView.new(formatTime(report.totalExistingTime/report.existingVehicleCount)),
				makeTimingsPanel(report.existingTimings, nil, report.impliedLoadTime),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.topSpeed)),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.averageSpeed)),
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.profit))),
				vehicleUtil.displayVehicleConfig(report.currentVehicleConfig),
				button,
			})
		end
		trace("The report found ", count, " lines needing attention")
		displayTable:setVisible( #linesToReport > 0, false)
		 
	end
	return {
		displayTable = displayTable,
		refresh = refreshTable
	}
	
end

function lineManager.replaceLineVehicles(lineId, params)
	local config= params.config
	local vehicleCount = math.max(params.vehicleCount,1)
	local existingVehicles = util.deepClone(api.engine.system.transportVehicleSystem.getLineVehicles(lineId))
	if isRailLine(api.engine.getComponent(lineId, api.type.ComponentType.LINE)) then 
		local params = getLineParams(lineId)
		local info = vehicleUtil.getConsistInfo(config, params.cargoType)
		if info.isElectric and not params.isElectricTrack or info.isHighSpeed and not params.isHighSpeedTrack  then
			trace("Vehicle replace may require upgrade, calling routeBuilder")
			params.isElectricTrack = params.isElectricTrack or info.isElectric 
			params.isHighSpeedTrack = params.isHighSpeedTrack or info.isHighSpeed
			params.isVeryHighSpeedTrain = info.isVeryHighSpeedTrain
			lineManager.addWork(function() routeBuilder.checkForTrackupgrades(getLine(lineId), lineManager.standardCallback, params, lineManager.findDepotsForLine(lineId, api.type.enum.Carrier.RAIL, true)) end)
		end
		if #existingVehicles == 1 and vehicleCount > 1 then 
			lineManager.addWork(function() routeBuilder.checkAndUpgradeToDoubleTrack( getLine(lineId), lineManager.standardCallback, params ) end)
		end		
		
	end
	
	local vehiclesToBuy = math.max(vehicleCount-#existingVehicles,0)
	local vehiclesToSell = math.max(#existingVehicles-vehicleCount, 0)
	local vehiclesToReplace = #existingVehicles-vehiclesToSell
	trace("Replacing line vehicles, vehiclesToBuy=",vehiclesToBuy,"vehiclesToSell=",vehiclesToSell,"vehiclesToReplace=",vehiclesToReplace)
	
	lineManager.addDelayedWork(function()
		for i = 1, vehiclesToReplace do 
			local replaceCommand = api.cmd.make.replaceVehicle(existingVehicles[i], vehicleUtil.copyConfigToApi(config))
			api.cmd.sendCommand(replaceCommand, lineManager.standardCallback)
		end
	end)
	if vehiclesToSell > 0 then 
		lineManager.addDelayedWork(function()
			for i = 1, vehiclesToSell do  
				local vehicleToSell = existingVehicles[i+vehiclesToReplace]
				api.cmd.sendCommand(api.cmd.make.sellVehicle(vehicleToSell), lineManager.standardCallback)  
			end
		end) 
	end
	if vehiclesToBuy > 0 then 
		lineManager.addDelayedWork(function()
			local depotOptions = lineManager.findDepotsForLine( lineId)
			for i = 1, vehiclesToBuy do 
				lineManager.buyVehicleForLine(lineId,i, depotOptions, config)
			end
		end)
	end 
end

local function cargoTypeDisplay(cargoType) 
	if type(cargoType) == "string" then cargoType = api.res.cargoTypeRep.find(cargoType) end
	local cargoTypeDetail = api.res.cargoTypeRep.get(cargoType)
	local icon = cargoTypeDetail.icon
	local iconView =  api.gui.comp.ImageView.new(icon)
	iconView:setTooltip(_(cargoTypeDetail.name))
	return iconView
end


function lineManager.buildLinePanel(circle, changeTabCallback)
 
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local button  = util.newButton(_('Check and update all lines'))
	local paramOverridesChooser = paramHelper.buildRouteOverridesChooser(true, true, true, true)
	--boxlayout:addItem(button)
	local vehicleFilter = lineManager.buildVehicleFilterPanel() 
	button:onClick(function() 
	lineManager.addWork(function()
		api.cmd.sendCommand(api.cmd.make.sendScriptEvent("bus_line_tool_script","checkLines", "", {carrier=vehicleFilter.getCarrier()}), lineManager.standardCallback)
	end)

	end)
	local railLines = {}
	
	local colHeaders = {
		api.gui.comp.TextView.new(_("Line")),
		api.gui.comp.TextView.new(_("Current\nrate")),
		api.gui.comp.TextView.new(_("Demand\nrate")),
		api.gui.comp.TextView.new(_("Cargo")),
		api.gui.comp.TextView.new(_("Top\nspeed")),
		api.gui.comp.TextView.new(_("averageSpeed")),
		api.gui.comp.TextView.new(_("Vehicles")),
		api.gui.comp.TextView.new(_("Interval")),
		api.gui.comp.TextView.new(_("Problems")),
		api.gui.comp.TextView.new(_("Recommendations")),
		api.gui.comp.TextView.new(_("Route\nUpgrades")),
		api.gui.comp.TextView.new(_("New vehicle config")),
		api.gui.comp.TextView.new(_("Execute")) 	
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	
	displayTable:setHeader(colHeaders)
	
	local function displayItems(items) 
		--trace("About to debugprint items")
		--debugPrint(items) 
		if util.size(items) == 0 then 
			return api.gui.comp.TextView.new(_("None")) 	
		end
		local text = ""
		for k,v in pairs(items) do 
			text = text.._(tostring(k))
			if type(v)~="boolean" then 
				text=text..": ".._(tostring(v))
			end
			text = text.."\n"
		end
		
		text = string.sub(text,1, -2)
		--trace("Adding text for display:",text)
		return api.gui.comp.TextView.new(text) 	
	end
	
	local function displayOldAndNewVehcileConfig(report)
		trace("Begin displayOldAndNewVehcileConfig")
		local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
		
		if report.currentVehicleConfig then 
			local topLine = api.gui.layout.BoxLayout.new("HORIZONTAL");
			topLine:addItem(api.gui.comp.TextView.new(_("Old:")))
			topLine:addItem(vehicleUtil.displayVehicleConfig(report.currentVehicleConfig))
			boxlayout:addItem(topLine)
		end
		local bottomLine = api.gui.layout.BoxLayout.new("HORIZONTAL");
	 
		if report.carrier == api.type.enum.Carrier.RAIL then 
			local button = util.newButton(_("New:")) --,"ui/icons/game-menu/help@2x.tga")
			bottomLine:addItem(button)
			button:onClick(function() 
				lineManager.addWork(function() 
					changeTabCallback(5, true)
				end)
				lineManager.addDelayedWork(function() 
					lineManager.lineDisplayTable.refresh(railLines, report.lineId)
 					lineManager.refreshVehicleTable(report.lineId)
				end)
			end)
			table.insert(railLines, report.lineId)
		else 
			bottomLine:addItem(api.gui.comp.TextView.new(_("New:")))
		end
		if not report.newVehicleConfig then report.newVehicleConfig = report.currentVehicleConfig end
		if report.newVehicleConfig then 
			bottomLine:addItem(vehicleUtil.displayVehicleConfig(report.newVehicleConfig))
		end
		boxlayout:addItem(bottomLine)
		local comp= api.gui.comp.Component.new(" ")
		comp:setLayout(boxlayout)
		trace("End displayOldAndNewVehcileConfig")
		return comp
	end
	
	boxlayout:addItem(vehicleFilter.panel)
	local noProblemsDisplay =  api.gui.comp.TextView.new(_("No problems found")) 	
	local maxReports = 10
	local function refreshTable()
		trace("Being refresh line manager table")
		displayTable:deleteAll()
		for i = 1, #railLines do 
			table.remove(railLines)
		end 
		local reports = lineManager.getLinesReport(maxReports, circle, vehicleFilter.filterFn, paramOverridesChooser.customOptions)
		reports = util.evaluateAndSortFromScores(reports, {100},{ function(report) return 10 - util.size(report.recommendations) end})
		trace("Got ",#reports," reports")
		local count = 0
		for i = 1, #reports do
			local report = reports[i]
			trace("Setting up the ",i,"th report. Was ok?",report.isOk)
			if report.isOk then 
				goto continue 
			end
			count = count + 1
			local executeButton = util.newButton("Execute", "ui/icons/build-control/accept@2x.tga")
			executeButton:setEnabled(#report.executionFns > 0)
			executeButton:onClick(function() 
				lineManager.addWork(function()
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("bus_line_tool_script","checkAndUpdateLine", "", {lineId=report.lineId, paramOverrides=paramOverridesChooser.customOptions}), lineManager.standardCallback)
				end)
				executeButton:setEnabled(false)
			end)
			 
			displayTable:addRow({
				makelocateRow(report),
				api.gui.comp.TextView.new(tostring(math.floor(report.rate))),				
				api.gui.comp.TextView.new(tostring(math.floor(report.targetLineRate))),
				cargoTypeDisplay(report.cargoType),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.topSpeed)),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.averageSpeed)),
				api.gui.comp.TextView.new(tostring(report.existingVehicleCount)),
				api.gui.comp.TextView.new(formatTime(report.totalExistingTime/report.existingVehicleCount)),
				displayItems(report.problems) ,
				displayItems(report.recommendations) ,
				displayItems(report.upgrades) ,
				displayOldAndNewVehcileConfig(report),
				executeButton
			})
			if count >= maxReports then 
				break 
			end
			::continue::
		end
		trace("The report found ", count, " lines needing attention")
		displayTable:setVisible( count > 0, false)
		noProblemsDisplay:setVisible( count == 0, false)
	end
	 
	 
	displayTable:setVisible(false, false)
	boxlayout:addItem(displayTable)
	noProblemsDisplay:setVisible(false, false)
	boxlayout:addItem(noProblemsDisplay)
	
	
	local buttonLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	local button2  = util.newButton(_('Report problem lines'),"ui/button/xxsmall/replace@2x.tga")
	buttonLayout:addItem(button2)
	buttonLayout:addItem(paramOverridesChooser.button)
	local button3  = util.newButton(_('Show More'), "ui/button/xxsmall/down_thin@2x.tga")
	button2:onClick(function() 
		button3:setVisible(true, false)
		button:setVisible(true,false)
		lineManager.addWork(refreshTable)	
	end)

	buttonLayout:addItem(button3)
	button3:onClick(function() 
		maxReports = 2*maxReports
		lineManager.addWork(refreshTable)	
	end)
	button3:setVisible(false, false)
	buttonLayout:addItem(button)
	button:setVisible(false,false)
	boxlayout:addItem(buttonLayout)
	
	
	
-- textInput:setText()
 
	local comp= api.gui.comp.Component.new("AIBuilderBuildLinePanel")
	comp:setLayout(boxlayout)
	return {
		comp = comp,
		title = util.textAndIcon("LINES", "ui/icons/game-menu/linemanager@2x.tga"),
		refresh = function()
		
		end,
		init = function() end
	}
end

 

function lineManager.buildVehiclePanel(circle)
 
	local boxlayout = api.gui.layout.BoxLayout.new("VERTICAL");
	local paramOverridesChooser = paramHelper.buildRouteOverridesChooser(true, true, true)
	
	local lineDisplayLimit = 5
	local linesLookup = {}
	
	local refreshButton = util.newButton(_("Refresh"),"ui/button/xxsmall/replace@2x.tga")
 
	
	
	
 
	local colHeaders = {
		api.gui.comp.TextView.new(_("Vehicle Config")),
		api.gui.comp.TextView.new(_("newVehicleCount")),
		api.gui.comp.TextView.new(_("projectedTime")),
		api.gui.comp.TextView.new(_("topSpeed")),
		api.gui.comp.TextView.new(_("averageSpeed")),
		api.gui.comp.TextView.new(_("throughput")),
		--api.gui.comp.TextView.new(_("projectedPayment")),
		api.gui.comp.TextView.new(_("projectedTicketPrice")),
		api.gui.comp.TextView.new(_("projectedRevenue")), 
		api.gui.comp.TextView.new(_("runningCost")), 
		--api.gui.comp.TextView.new(_("projectedPaymentPerLoad")) ,
		api.gui.comp.TextView.new(_("projectedProfit")),
		api.gui.comp.TextView.new(_("replace"))				
	}
	
	local numColumns = #colHeaders
	local selectable = "SELECTABLE"
	
	local displayTable = api.gui.comp.Table.new(numColumns, selectable)
	
	displayTable:setHeader(colHeaders)
	
	local function displayItems(items) 
		trace("About to debugprint items")
		debugPrint(items) 
		if util.size(items) == 0 then 
			return api.gui.comp.TextView.new(_("None")) 	
		end
		local text = ""
		for k,v in pairs(items) do 
			text = text.._(tostring(k))
			if type(v)~="boolean" then 
				text=text..": ".._(tostring(v))
			end
			text = text.."\n"
		end
		
		text = string.sub(text,1, -2)
		trace("Adding text for display:",text)
		return api.gui.comp.TextView.new(text) 	
	end
	 
	local header =  api.gui.comp.TextView.new(" ") 
	--boxlayout:addItem(lineInfoDisplay)
	local maxToReturn = 10
	local currentLineId
	local function refreshTable(lineId)
		--local lineIdx = lineCombobox:getCurrentIndex()
		--local lineId = linesLookup[lineIdx+1]
		if not lineId then 
			lineId = currentLineId
		else	
			currentLineId = lineId
		end 
		trace("Refreshing table to inspect lineId=",lineId, " lineIdx=",lineIdx)
		if not lineIdx then 
			debugPrint(linesLookup) 
		end
		--lineDisplayTable.refresh({lineId})
		displayTable:setVisible(true, false)
		trace("Being refresh line manager table")
		displayTable:deleteAll()
		local isForVehicleReport = true 
		local useRouteInfo = false 
		local displayOnly = false 
		local paramOverrides = paramOverridesChooser.customOptions
		local lineReport = lineManager.getLineReport(lineId, nil, isForVehicleReport, useRouteInfo, displayOnly, paramOverrides )
		--local lineReport = lineManager.getLineReport(lineId, nil, true)
		header:setText(_("Vehicle options for").." "..lineReport.lineName)
		
		local options = lineReport.newVehicleConfig
		trace("Got ",#options," reports")
		local count = 0
		for i = 1, #options do
			local report = options[i] 
			if i == 1 then 
				--lineInfoDisplay:setText(_("Route length:")..api.util.formatLength(report.p.routeLength).." ".._("Throughput demand:")..api.util.formatNumber(math.round(lineReport.lineRate)).." ".._("Vehicle count:")..api.util.formatNumber(lineReport.vehicleCount))
			end 			
			count = count + 1
			local replaceButton = util.newButton(_("Replace"), "ui/icons/build-control/accept@2x.tga") 
			replaceButton:onClick(function() 
				lineManager.addWork(function() 
					--lineManager.replaceLineVehicles(lineId, report.config) 
					api.cmd.sendCommand(api.cmd.make.sendScriptEvent("bus_line_tool_script","replaceLineVehicles", "", {lineId=lineId, config=report.config, vehicleCount=report.vehicleCount}), lineManager.standardCallback)
				end)
				replaceButton:setEnabled(false)
				--lineManager.addDelayedWork(refreshTable)
			end)
			if not report.vehicleCount then 
				report.vehicleCount = lineReport.vehicleCount or lineReport.existingVehicleCount
			end
			if vehicleUtil.checkIfVehicleConfigMatches(lineReport.currentVehicleConfig, report.config) and report.vehicleCount == lineReport.existingVehicleCount then 
				replaceButton:setEnabled(false)
				replaceButton:setTooltip(_("This is the current line config"))
			end				
			
			displayTable:addRow({
				vehicleUtil.displayVehicleConfig(report.config),
				api.gui.comp.TextView.new(api.util.formatNumber(report.vehicleCount)),
				makeTimingsPanel(report.p.projectedTimings, report.p.projectedTimingsRaw, report.p.projectedLoadTime),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.p.topSpeed)),
				api.gui.comp.TextView.new(api.util.formatSpeed(report.p.averageSpeed)),
				--api.gui.comp.TextView.new(api.util.formatMoney(math.round(report.p.projectedPayment))),
				api.gui.comp.TextView.new(api.util.formatNumber(math.floor(report.vehicleCount*report.p.maxThroughput))) ,
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.p.projectedTicketPrice))),				
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.p.projectedRevenue))),
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(-report.p.runningCost))) ,
				
				--api.gui.comp.TextView.new(api.util.formatMoney(math.round(report.p.projectedPaymentPerLoad))) ,
				api.gui.comp.TextView.new(api.util.formatMoney(math.floor(report.p.projectedProfit))),
				replaceButton
			})
			if count > maxToReturn then 	
				break 
			end
		end
		trace("The report found ", count, " lines needing attention")
		displayTable:setVisible( count > 0, false)
		 
	end 
	local lineDisplayTable = lineManager.buildLineDisplayTable(refreshTable) 
	
	local function refreshCombobox() 
		local allLines =  getLines(circle) 
		for k,v in pairs(linesLookup) do linesLookup[k]=nil end
	 
		local count = 0
		for i, lineId in pairs(allLines) do 
			
			local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
			if isRailLine(line) then 
				count = count + 1
				local name = api.engine.getComponent(lineId, api.type.ComponentType.NAME).name
			 
				table.insert(linesLookup, lineId)
				if count >= 5 then 
					break 
				end
			end
		end
		lineDisplayTable.refresh(linesLookup)
	end
	 

	refreshButton:onClick(function() lineManager.addWork(refreshCombobox)end)
	 
	 
	lineManager.refreshVehicleTable = refreshTable
	lineManager.lineDisplayTable = lineDisplayTable
	displayTable:setVisible(false, false)
	
	
	boxlayout:addItem(lineDisplayTable.displayTable)
	local buttonLayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	buttonLayout:addItem(refreshButton)

	buttonLayout:addItem(paramOverridesChooser.button)
	boxlayout:addItem(buttonLayout)
	boxlayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
	boxlayout:addItem(header)
	boxlayout:addItem(displayTable)
	 
	
	 
	local showMoreButton  = util.newButton(_('Show more'), "ui/button/xxsmall/down_thin@2x.tga")
	local clearButton  = util.newButton(_('Clear'), "ui/button/small/cancel@2x.tga")
	local buttonLayout2 = api.gui.layout.BoxLayout.new("HORIZONTAL");
	buttonLayout2:addItem(showMoreButton)
	buttonLayout2:addItem(clearButton)
	boxlayout:addItem(buttonLayout2)
	showMoreButton:onClick(function() 
		maxToReturn = maxToReturn * 2
		lineManager.addWork(refreshTable)	
	end)
	
	clearButton:onClick(function() 
		maxToReturn = 10
		lineManager.addWork(function() -- nested for error handling
			displayTable:setVisible(false, false) 
			displayTable:deleteAll()
		end)
	end)
	
	
	
-- textInput:setText()
 
	local comp= api.gui.comp.Component.new("AIBuilderBuildLinePanel")
	comp:setLayout(boxlayout)
	local isInit = false
	return {
		comp = comp,
		title = util.textAndIcon("VEHICLES", "ui/icons/game-menu/vehiclemanager@2x.tga"),
		refresh = function()
			isInit = false 
		end,
		init = function() 
			if not isInit then 
				refreshCombobox()
				isInit = true 
			end
		
		end
	}
end
function lineManager.buyAndAssignVehiclesToLine(vehicleConfig, lineId, numberOfVehicles, callback, carrier)
	local depotOptions = lineManager.findDepotsForLine(lineId, carrier)
	if #depotOptions == 0 then 
		trace("No depot options found, attempting to rectify")
		local newCallback = function(res, success) 
			if success then 
				lineManager.addWork(function() 
					depotOptions = lineManager.findDepotsForLine(lineId, carrier)
					-- The depot was built but the line still cannot reach it. An assert here
					-- killed the work item silently; say so and let the caller finish instead.
					if #depotOptions == 0 then
						print("bus_line_tool: WARNING no reachable depot for line " .. tostring(lineId))
						callback({}, false)
						return
					end
					buyAndAssignVechicles(vehicleConfig, depotOptions , lineId, numberOfVehicles, callback)
				end)
			else 
				callback(res, success)
			end 
		end 
		local line = getLine(lineId)
		local stations = {} 
		for i = 1, #line.stops do 
			table.insert(stations, stationFromStop(line.stops[i]))
		end
		-- `params` was an undeclared global here (always nil). getLineParams() is not an option:
		-- it dereferences a paramHelper this module does not have.
		constructionUtil.buildDepotAlongRoute(stations, {}, carrier, newCallback)
	else 
	
		buyAndAssignVechicles(vehicleConfig,  depotOptions, lineId, numberOfVehicles, callback)
	end
end
return lineManager