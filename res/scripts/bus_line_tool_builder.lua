local util = require("bus_line_tool_base_util")
local vehicleUtil = require("bus_line_tool_vehicle_util")
local lineManager = require("bus_line_tool_line_manager")
local paramHelper = require("bus_line_tool_base_param_helper")
local routeBuilder = require("bus_line_tool_route_builder")
local helper = require("bus_line_tool_station_template_helper")
local stationModules = require("bus_line_tool_station_modules")
local function tryLoadUndo() 
	local res 
	pcall(function() res = require "undo_base_util" end)
	return res 
end 
local undo_script = tryLoadUndo() 
local trace = util.trace

local builder = {}

local nextLineColor

local function checkIfCanAddPlatform(constructionId, left, templateIndex)
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local params = util.deepClone(construction.params)
	if left then
		params.platL = params.platL + 1
	else 
		params.platR = params.platR + 1
	end
	params.templateIndex =  templateIndex
	params.modules =  util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params))   
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	newConstruction.name=api.engine.getComponent(constructionId, api.type.ComponentType.NAME).name
		
	newConstruction.fileName = construction.fileName
	newConstruction.playerEntity = api.engine.util.getPlayer() 
		 
	newConstruction.params = params  
	newConstruction.transf = construction.transf
	local testProposal = api.type.SimpleProposal.new()
	local freeNodes = util.getFreeNodesForConstruction(constructionId)
	local alreadySeen = {}
	trace("Found ",util.size(freeNodes)," for construction",constructionId)
	for i, node in pairs(freeNodes) do
		local segs = util.getStreetSegmentsForNode(node)
		for j, seg in pairs(segs) do 
			if not util.isFrozenEdge(seg) and not alreadySeen[seg] then 
				alreadySeen[seg]=true
				trace("Removing segment ",seg," for platform check")
				testProposal.streetProposal.edgesToRemove[1+#testProposal.streetProposal.edgesToRemove]=seg
			end
		end
		if #segs > 1 then 
			trace("Removing node ",node," for platform check")
			testProposal.streetProposal.nodesToRemove[1+#testProposal.streetProposal.nodesToRemove]=node
		end
		if #segs > 2 then 
			trace("Skipping check for large number of segments")-- seems to cause a game crash not clear why
			return true 
		end
	end
	
	
	testProposal.constructionsToRemove = { constructionId} 
	testProposal.constructionsToAdd[1+#testProposal.constructionsToAdd] = newConstruction
	local result = checkProposalForErrors(testProposal, true)
	trace("The check of whether to build on the ",(left and "left" or "right")," was ",result.isError)
	
	return not result.isError
end
local function upgradeRoadStation( station, addTerminal,  needsTram)
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
		if constructionId == -1 then 
			return
		end
		
		trace("Anout to get construction for station ", station, " constructionId = ",constructionId)
		local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
		local params = util.deepClone(construction.params)
		if not params.templateIndex then 
			params.templateIndex = util.getStation(station).cargo and 3 or 2
		end
		local needsUpgrade = addTerminal 
		if needsTram then 
			if params.tramTrack < util.getCurrentTramTrackType() then 
				needsUpgrade = true 
			end
			params.tramTrack = util.getCurrentTramTrackType()
	 	end
		
		
		if addEntranceB then 
			if params.entrance_exit_b ~= 1 then 
				needsUpgrade = true 
			end
			params.entrance_exit_b = 1
		end
		if not needsUpgrade then 
			return 
		end
		helper.determineActualRoadStationParams(params)
		trace("Entrance exit b",params.entrance_exit_b," addEntranceB?",addEntranceB)
		if addTerminal then 
			if not util.getStation(station).cargo then -- passenger
				local fileName = ""
				for __, otherStation in pairs(util.searchForEntities(util.getStationPosition(station), 150, "STATION")) do 
					if not otherStation.cargo and otherStation.id~=station and  util.getConstructionForStation(otherStation.id) then 
						fileName = util.getConstructionForStation(otherStation.id).fileName 
						break
					end 
				end  
				if  fileName == "station/water/harbor_modular.con" then 
					params.platL = params.platL + 1 -- away from the harbor
				else 
					if string.find(fileName, "elevated") or string.find(fileName, "underground") then 
						if params.platR < params.platL then  
							params.platR = params.platR + 1
						else 
							params.platL = params.platL + 1
						end
					else  
						if params.platR > params.platL then --always build on the side with more terminals already, as this is not touching the other station
							params.platR = params.platR + 1
						else 
							params.platL = params.platL + 1
						end
					end
				end
				if params.platL > 3 then 
					if not params.includeEntryExit then params.includeEntryExit = {} end 
					params.includeEntryExit[-2] = true
				end
				if params.platR > 3 then 
					if not params.includeEntryExit then params.includeEntryExit = {} end 
					params.includeEntryExit[2] = true
					if params.platR > 5 then 
						params.includeEntryExit[4] = true
					end
				end				
			else 
				if params.platR > params.platL then 
					if checkIfCanAddPlatform(constructionId,true, params.templateIndex) or not checkIfCanAddPlatform(constructionId,false, params.templateIndex) then
						params.platL = params.platL + 1
					else 
						params.platR = params.platR + 1
					end
				else 
					if checkIfCanAddPlatform(constructionId,false, params.templateIndex) or not checkIfCanAddPlatform(constructionId,true, params.templateIndex)  then
						params.platR = params.platR + 1
					else 
						params.platL = params.platL + 1
					end
				end
			end
		end  
		local generated = util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params))
		-- keep every module the station already has (truck platforms included); add only new slots
		params.modules = stationModules.merge(params.modules, generated)
 
		trace("About to execute upgradeConstruction for constructionId ",constructionId)
	params.seed = nil
		if not pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end) and params.includeEntryExit then 
			params.includeEntryExit = nil
			pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end)
		end 
		trace("About set player")
		game.interface.setPlayer(constructionId, game.interface.getPlayer())
		util.clearCacheNode2SegMaps()
 end

local function getFreeTerminalsForStation(stationId ) 
	local result = {}
	for i = 1, #api.engine.getComponent(stationId, api.type.ComponentType.STATION).terminals do
		local terminal = i-1
		local numstops =  #api.engine.system.lineSystem.getLineStopsForTerminal(stationId, terminal)
		trace("Inspecting station ",stationId," the numstops at terminal ", terminal , " was ",numstops)
		if 0 == numstops then 
			table.insert(result, terminal)
		end
	end 

	return result
end

local usedTerminals = {}


local function getTangentOfNode(vehicleNode)
	for i , tn in pairs(api.engine.getComponent(vehicleNode.entity, api.type.ComponentType.TRANSPORT_NETWORK).edges) do 
		if tn.conns[1].index == vehicleNode.index then 
			return util.v2ToV3(tn.geometry.params.tangent[1])
		end 
	end 
	trace("WARNING! No matching tangent for vehicleNode")
	debugPrint(vehicleNode)
end 

local function chooseFreeTerminal(stationId, nextStopPos) 
	local options = {}
	if not usedTerminals[stationId] then 
		usedTerminals[stationId] = {}
	end
	local station = util.getStation(stationId)
	--debugPrint(station)
	for i, terminal in pairs(getFreeTerminalsForStation(stationId)) do 
		if nextStopPos then
			trace("Inspecting terminal ",terminal, " for ",stationId)
			local vehicleNode =  station.terminals[terminal+1].vehicleNodeId 
			local tangent = getTangentOfNode(vehicleNode)
			local naturalTangent = nextStopPos-util.getStationPosition(stationId)
			local angle = math.abs(util.signedAngle(naturalTangent, tangent))
			trace("The angle at terminal ",terminal," was ",math.deg(angle))
			table.insert(options, {terminal = terminal, scores = { angle }})
		elseif not usedTerminals[stationId][terminal] then 
			return terminal
		end
		
	end 
	if #options > 0 then 
		local result = util.evaluateWinnerFromScores(options).terminal
		usedTerminals[stationId][result]=true 
		return result
	end 
	
	return 0 -- fallback
end 

local function createStopForStation(stationId, nextStopPos) 
	local stationGroupId = api.engine.system.stationGroupSystem.getStationGroup(stationId)
	local stationIdx = util.indexOf(api.engine.getComponent(stationGroupId, api.type.ComponentType.STATION_GROUP).stations, stationId)
	local stop = api.type.Line.Stop.new()
	stop.stationGroup = stationGroupId 
	stop.station = stationIdx - 1
	stop.terminal = chooseFreeTerminal(stationId, nextStopPos) 
	return stop
end

builder.createStopForStation = createStopForStation

local function lineColorFn()  
	local colors = api.res.getBaseConfig().gui.lineColors
	if not nextLineColor then 
		nextLineColor = math.random(1, #colors)
	end
	
	local color = colors[nextLineColor]
	color = api.type.Vec3f.new(color[1],color[2],color[3])
	nextLineColor = nextLineColor+1
	if nextLineColor > #colors then
		nextLineColor = 1
	end
	return color
end

local function getPosition(p) 
	if type(p) == "number" then 
		return util.getStationPosition(p)
	else 
		return p.p
	end 
end 

local function setupLine(positions, param, isCircleReturn)
	local line = api.type.Line.new() 
	local returnStops = {}
	local townName = ""
	local stations = {}
	trace("Begin setting up line for bus line tool")
	for i, p in pairs(positions) do
		local nextStop = i == #positions and positions[1]  or positions[i+1]
		local nextStopPos = getPosition(nextStop) 
		if type(p) == "number" then 
			line.stops[1+#line.stops]=createStopForStation( p, nextStopPos)  
			table.insert(stations, p)
			if i> 1 and i<#positions then  
				table.insert(returnStops, p)
			end 
		else 
			local edgeId = util.findEdgeConnectingPoints(p.p0, p.p1) --util.searchForFirstEntity(p, 20, "BASE_EDGE")
			if not edgeId then 
				trace("WARNING! No edge found")
				goto continue 
			end
			local edge = util.getEdge(edgeId)
		
			local left= util.distance(nextStopPos, p.p0) < util.distance(nextStopPos, p.p1)
		 
			local target = left and api.type.enum.EdgeObjectType.STOP_LEFT  or api.type.enum.EdgeObjectType.STOP_RIGHT 
			for __, edgeObj in pairs(edge.objects) do 
				if townName == "" then 
					townName = api.engine.getComponent(api.engine.system.stationSystem.getTown(edgeObj[1]), api.type.ComponentType.NAME).name
				end
				if edgeObj[2]==target then 
					line.stops[1+#line.stops]=createStopForStation( edgeObj[1])  
					table.insert(stations, edgeObj[1])
				elseif i> 1 and i<#positions then  
					table.insert(returnStops, edgeObj[1])
				end 
			end 
		end
		::continue::
	end 
	if not param.circleLine then 
		for i = #returnStops, 1, -1 do 
			line.stops[1+#line.stops]=createStopForStation(returnStops[i])
		end 
	end 
	local lineCount = #api.engine.system.lineSystem.getLines()
	local name = param.lineName
	if not name or name == "" then
		name = townName.." ".._("line").." "..tostring(lineCount+1)
	end
	local colour
	if param.lineColour and param.lineColour[1] then
		colour = api.type.Vec3f.new(param.lineColour[1], param.lineColour[2], param.lineColour[3])
	else
		colour = lineColorFn()
	end
	usedTerminals = {}
	if #line.stops > 1 then
		trace("Creating line for bus stop")
		api.cmd.sendCommand(api.cmd.make.createLine(name, colour, game.interface.getPlayer(), line),
			function(res, success) 
				trace("Result of create line command was",success)
				if success then 
					
					local function buyAndAssignVehicles() 
						builder.addWork(function()
							local carrier = param.createTramLine and api.type.enum.Carrier.TRAM or api.type.enum.Carrier.ROAD
							local vehicleConfig = param.vehicleConfig
							local numberOfVehicles = param.numberOfVehicles 
							local lineId = res.resultEntity
							local isProblemLine = false
							for i, problemLine in pairs(api.engine.system.lineSystem.getProblemLines(api.engine.util.getPlayer())) do 
								if lineId == problemLine then 
									isProblemLine = true 
									break 
								end
							end 
							local callback = function(res, success) 
								trace("Result of assigning vehicles was",success)
							end
							if isProblemLine then 
								trace("Suppressed buy and assign due to problem line",lineId)
							else 
								lineManager.buyAndAssignVehiclesToLine(vehicleConfig, lineId, numberOfVehicles, callback, carrier)
							end
						end)
					end
					if (param.addBusLanes or param.createTramLine) and not isCircleReturn then 
						local callback = function(res, success) 
								trace("Result of route upgrade was",success)
								if success or not param.createTramLine then 
									buyAndAssignVehicles()
								end 
						end
						builder.addWork(function() 
							local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", false, param.ignoreErrors) 
							params.setAddBusLanes(param.addBusLanes) 
							if param.createTramLine then 
								params.tramTrackType = util.year() >= api.res.getBaseConfig().tramCatenaryYearFrom and vehicleUtil.isElectricTram(param.vehicleConfig) and 2 or 1
							end 
							
							routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, callback, params, param.circleLine) 
						
						end)
					else 
						buyAndAssignVehicles()
					end 
				end
			end 
		) 
	end
end
local function findMatchingAvailableModel(models)
	for i, name in pairs(models) do
		-- api.res.modelRep.get(api.res.modelRep.find("station/bus/small_old.mdl"))
		local modelId = api.res.modelRep.find(name)
		local modelDetail = api.res.modelRep.get(modelId)
		--if tracelog then debugPrint({name=name,modelId=modelId,modelDetail=modelDetail}) end
		if util.filterYearFromAndTo(modelDetail.metadata.availability) then
			--trace("using model ",modelId," name=",name," for bus stop")
			return name
			
		end
	end
end

local function getBusStopModel() 
	local bustopmodels = {"station/bus/small_old.mdl","station/bus/small_mid.mdl","station/bus/small_new.mdl"}
	return findMatchingAvailableModel(bustopmodels)
end

local function examineStations(stationsToExamine, param)
	for i, station in pairs(stationsToExamine) do 
		local addTerminal = station.terminalsToAdd > 0
		upgradeRoadStation( station.stationId, addTerminal,  station.needsTram)
		if station.terminalsToAdd == 2 then 
			upgradeRoadStation( station.stationId, addTerminal,  station.needsTram)
		end		
	end 	
end 

-- Builds the street proposal that places a bus stop pair on each edge. positionsOut[edgeId] = {p=, p0=, p1=}.
function builder.buildStopsProposal(edgeIds, positionsOut)
	local busStopModel = getBusStopModel()
	local edgeObjectsToAdd = {}
	local newProposal = api.type.SimpleProposal.new()
	local countByTown = {}
	for _, edgeId in ipairs(edgeIds) do
		local j = 1 + #newProposal.streetProposal.edgesToAdd
		local entity = util.copyExistingEdge(edgeId, -j)
		local p = util.getEdgeMidPoint(edgeId)
		local objects = {}
		local town = util.searchForNearestEntity(p, math.huge, "TOWN")
		if not countByTown[town.id] then
			countByTown[town.id] = util.countBusStopsForTown(town) + 1
		else
			countByTown[town.id] = countByTown[town.id] + 1
		end
		local name = town.name .. " " .. _("stop") .. " " .. tostring(countByTown[town.id])
		for _, left in pairs({ true, false }) do
			table.insert(objects, { -1 - #edgeObjectsToAdd, left and 0 or 1 })
			local newStop = api.type.SimpleStreetProposal.EdgeObject.new()
			newStop.left = left
			newStop.oneWay = false
			newStop.playerEntity = api.engine.util.getPlayer()
			newStop.edgeEntity = entity.entity
			newStop.name = name
			newStop.model = busStopModel
			newStop.param = 0.5
			table.insert(edgeObjectsToAdd, newStop)
		end
		entity.comp.objects = objects
		newProposal.streetProposal.edgesToAdd[j] = entity
		newProposal.streetProposal.edgesToRemove[j] = edgeId
		local edge = util.getEdge(edgeId)
		positionsOut[edgeId] = { p = p, p0 = util.nodePos(edge.node0), p1 = util.nodePos(edge.node1) }
	end
	for i, edgeObj in pairs(edgeObjectsToAdd) do
		newProposal.streetProposal.edgeObjectsToAdd[i] = edgeObj
	end
	return newProposal
end

-- After a stop pair was built on an edge, returns the station on the side facing nextStopPos.
function builder.stationForBuiltStop(position, nextStopPos)
	local edgeId = util.findEdgeConnectingPoints(position.p0, position.p1)
	if not edgeId then return nil end
	local edge = util.getEdge(edgeId)
	local left = util.distance(nextStopPos, position.p0) < util.distance(nextStopPos, position.p1)
	local target = left and api.type.enum.EdgeObjectType.STOP_LEFT or api.type.enum.EdgeObjectType.STOP_RIGHT
	for _, edgeObj in pairs(edge.objects) do
		if edgeObj[2] == target then return edgeObj[1] end
	end
	return nil
end

function builder.createBusLine(param)
	trace("Received call to build busLine")
	local createTramLine = param.createTramLine 
	local addBusLanes = param.addBusLanes  
	local circleLine = param.circleLine  
	local selectedEntities = param.selectedEntities  
	local ignoreErrors = param.ignoreErrors 
	local busStopModel = getBusStopModel() 
	local edgeObjectsToAdd = {}
	local nameList = api.res.getBaseConfig().nameList.folder
	local newProposal = api.type.SimpleProposal.new()
	local positions = {}
	local countByTown = {}
	local stationsToExamine = {}
	for i , entityId in pairs(selectedEntities) do 
		if util.getEdge(entityId) then 
			local edgeId = entityId
			local j = 1+#newProposal.streetProposal.edgesToAdd
			local entity = util.copyExistingEdge(edgeId, -j)
			local p = util.getEdgeMidPoint(edgeId)
			local objects = {}
			local town =  util.searchForNearestEntity(p, math.huge, "TOWN")
			if not countByTown[town.id] then 
				countByTown[town.id] = util.countBusStopsForTown(town) + 1
			else 
				countByTown[town.id] = countByTown[town.id] + 1
			end 
			local name = town.name.." ".._("stop").." "..tostring(countByTown[town.id])
			for __, left in pairs({true, false}) do 
				table.insert(objects,  { -1-#edgeObjectsToAdd, left and 0 or 1})
				
			
				
				local newStop = api.type.SimpleStreetProposal.EdgeObject.new()
				newStop.left = left
				newStop.oneWay = false
				newStop.playerEntity = api.engine.util.getPlayer()
				newStop.edgeEntity = entity.entity
				newStop.name = name
				newStop.model = busStopModel
				newStop.param = 0.5
				table.insert(edgeObjectsToAdd, newStop)
			end
			
			entity.comp.objects = objects
			newProposal.streetProposal.edgesToAdd[j]=entity
			newProposal.streetProposal.edgesToRemove[j]=edgeId
			local edge = util.getEdge(edgeId)
			positions[i]= { p = p, p0 = util.nodePos(edge.node0), p1 = util.nodePos(edge.node1)}
		else 
			positions[i]= entityId
			local requiredFreeTerminals = (i > 1 and i < #selectedEntities or circleLine) and 2 or 1
			local terminalsToAdd = math.max(0, requiredFreeTerminals-util.countFreeTerminalsForStation(entityId))
			table.insert(stationsToExamine, {stationId = entityId, terminalsToAdd=terminalsToAdd, needsTram = createTramLine})
		end 	
	end 
	for i, edgeObj in pairs(edgeObjectsToAdd) do 
		newProposal.streetProposal.edgeObjectsToAdd[i]=edgeObj
	
	end
	if undo_script then 
		pcall(function() undo_script.saveBuildDetailsForUndo(newProposal) end)
	end 
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), ignoreErrors)
	api.cmd.sendCommand(build, function(res, success) 
		trace("Result of building bus stops was ",success)
		if success then 
			if undo_script then 
				undo_script.lastResult = res 
			end
			builder.addWork(function() examineStations(stationsToExamine, param) end)
			builder.addDelayedWork(function() 
				setupLine(positions, param)
			end)
			if param.circleLine then 
				builder.addDelayedWork(function() 
					local reversed = {}
					for i = #positions, 1, -1 do 
						table.insert(reversed, positions[i])
					end 
					setupLine(reversed, param, true)
				end) 
			end 
		end
	end)
end 

return builder