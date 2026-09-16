local util = require("bus_line_tool_base_util")
local transf = require("transf")
local vec3 = require("vec3")
local vec2 = require("vec2")
local paramHelper = require("bus_line_tool_base_param_helper") 
local pathFindingUtil = {}

local function trace(...)
	util.trace(...)
end


function pathFindingUtil.getStartingEdgesForEdge(edgeId, transportMode) 
	local startingEdges = {}
	if transportMode == api.type.enum.TransportMode.TRAIN then -- performance shortcut , train edges only have one tn edge
		local fullEdgeId = api.type.EdgeId.new(edgeId, 0)
		
		table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(fullEdgeId, true, 0))
		table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(fullEdgeId, false, 0))
		return startingEdges
	end 
	
	local tn = api.engine.getComponent(edgeId, api.type.ComponentType.TRANSPORT_NETWORK)
	local tnEdges = tn.edges -- trying to prevent premature gc
	for i, tn in pairs(tnEdges) do
		if tn.transportModes[transportMode+1]==1 then
			local length = util.getEdgeLength(edgeId)/2
			local fullEdgeId = api.type.EdgeId.new(edgeId, i-1)
			table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(fullEdgeId, true, length))
			table.insert(startingEdges,api.type.EdgeIdDirAndLength.new(fullEdgeId, false, length))
			 
			--break
		end
	end
	return startingEdges
end

local function getStartingEdgesForStation(stationId, terminal)
	if terminal then 
		return pathFindingUtil.getStartingEdgesForStationAndTerminal(stationId, terminal)
	end

	local startingEdges = {} 
	local found = false
	local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then
		constructionId = stationId
	end
	trace("About to get frozenEdges for construction ",constructionId)
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	for ___, edgeId in pairs(construction.frozenEdges) do  
		for i, startingEdge in pairs(pathFindingUtil.getStartingEdgesForEdge(edgeId, api.type.enum.TransportMode.TRAIN)) do
			table.insert(startingEdges, startingEdge)
			found = true
		end
		--if found then break end
	end
	return startingEdges 
end
function pathFindingUtil.getDestinationNodesForNode(node, transportMode)
	local destNodes = {}
	for i, tn in pairs(api.engine.getComponent(edge, api.type.ComponentType.TRANSPORT_NETWORK).nodes) do
	end
	return destNodes
end
function pathFindingUtil.getDestinationNodesForEdge(edge, transportMode, targetNode)
	local destNodes = {}
	local tn = api.engine.getComponent(edge, api.type.ComponentType.TRANSPORT_NETWORK)
	local tnEdges = tn.edges -- trying to encourage this not to be gc'd half way through
	local found = false
	for i, tn in pairs(tnEdges) do
			if tn.transportModes[transportMode+1]==1 then
				if targetNode == tn.conns[1].entity then
					found = true
					table.insert(destNodes, api.type.NodeId.new(tn.conns[1].entity, tn.conns[1].index))
				end
				if targetNode == tn.conns[2].entity then
					found = true
					table.insert(destNodes, api.type.NodeId.new(tn.conns[2].entity, tn.conns[2].index))
				end
				
				--if found then break end
			end
		end
	return destNodes
end
function pathFindingUtil.getDestinationNodesForStationAndTerminal(stationId, terminal)

	local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION)
	return {station.terminals[terminal+1].vehicleNodeId }
end

 
function pathFindingUtil.getDestinationNodesForStation(stationId, terminal)
	if terminal then 
		return pathFindingUtil.getDestinationNodesForStationAndTerminal(stationId, terminal)
	end
	local destNodes = {}
	local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION)
	for i, terminal in pairs(station.terminals) do 
		table.insert(destNodes, terminal.vehicleNodeId)
	end
	
	return destNodes
	--[[local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then
		constructionId = stationId
	end
	for ___, edge in pairs(api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION).frozenEdges) do  
		for i, destNode in pairs(getDestinationNodesForEdge(edge, api.type.enum.TransportMode.TRAIN)) do
			table.insert(destNodes, destNode)
		end
		--if found then break end
	end
	return destNodes]]--
end



function pathFindingUtil.findRailPathBetweenStations(station1, station2,   terminal1, terminal2,maxDistance)
	collectgarbage()
	if not maxDistance then
		maxDistance = 3* util.distBetweenStations(station1, station2) 
	end
	
	local startingEdges =  getStartingEdgesForStation(station1, terminal1)
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station2, terminal2)
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	trace("Attempting to find rail path between stations ", station1, station2)
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	end
	--debugPrint(answer)
	return answer
end

function pathFindingUtil.findRailPathBetweenEdgeAndStationFreeTerminal(edge, station, tryDoubleTrackEdge) 
	local maxDistance = 3* util.distance(util.getStationPosition(station), util.getEdgeMidPoint(edge))
	local startingEdges =  pathFindingUtil.getStartingEdgesForEdge(edge, api.type.enum.TransportMode.TRAIN)
	
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	trace("Attempting to find rail path between edge and station", edge, station)
	local answer = {}
	for i, t in pairs(util.getFreeTerminals(station)) do 
		local destNodes = pathFindingUtil.getDestinationNodesForStationAndTerminal(station, t-1)
		if #destNodes>0 and #startingEdges>0 then 
			--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
			answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
		end
		if #answer > 0 then 
			return answer 
		end
		if tryDoubleTrackEdge then 
			local doubleTrackEdge = util.findDoubleTrackEdge(edge)
			if doubleTrackEdge then 
				local startingEdges =  pathFindingUtil.getStartingEdgesForEdge(doubleTrackEdge, api.type.enum.TransportMode.TRAIN)
				answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
				if #answer > 0 then 
					return answer 
				end
			end 
		
		end 
	end
	--[[
	if #answer == 0 then 
		local constructionId  = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) 
		local edgeFull = util.getEdge(edge)
		for i, node in pairs(util.getFreeNodesForConstruction(constructionId)) do
			if node == edgeFull.node0 or node == edgeFull.node1 then 
				trace("Original path answer was empty, but edge is connected directly to station, returning edge")
				return {{entity=edge, index = 0}}
			end
		end 
	end ]]--
	
	--debugPrint(answer)
	return answer
	
end
function pathFindingUtil.findRailPathBetweenNodeAndStation(node, station, maxDistance, tryDoubleTrackEdge)
	return pathFindingUtil.findRailPathBetweenEdgeAndStation(util.getTrackSegmentsForNode(node)[1], station, maxDistance, tryDoubleTrackEdge)
end
function pathFindingUtil.findRailPathBetweenEdgeAndStation(edge, station, maxDistance, tryDoubleTrackEdge)
	collectgarbage()
		if not maxDistance then
		maxDistance = 3* util.distance(util.getStationPosition(station), util.getEdgeMidPoint(edge))
	end
	
	local startingEdges =  pathFindingUtil.getStartingEdgesForEdge(edge, api.type.enum.TransportMode.TRAIN)
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station)
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	trace("Attempting to find rail path between edge and station", edge, station)
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
		if #answer == 0 and tryDoubleTrackEdge then 
			local doubleTrackEdge = util.findDoubleTrackEdge(edge) 
			if doubleTrackEdge then 
				answer = pathFindingUtil.findPath( pathFindingUtil.getStartingEdgesForEdge(doubleTrackEdge, api.type.enum.TransportMode.TRAIN) , destNodes, transportModes, maxDistance)
			end 
		end 
	end
	--[[
	if #answer == 0 then 
		local constructionId  = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station) 
		local edgeFull = util.getEdge(edge)
		for i, node in pairs(util.getFreeNodesForConstruction(constructionId)) do
			if node == edgeFull.node0 or node == edgeFull.node1 then 
				trace("Original path answer was empty, but edge is connected directly to station, returning edge")
				return {{entity=edge, index = 0}}
			end
		end 
	end ]]--
	
	--debugPrint(answer)
	return answer
	
end

local function getClosestEdge(node1, node2, isTrack)
	local segmentFn = isTrack and util.getTrackSegmentsForNode or util.getStreetSegmentsForNode
	local options = {}
	for __, seg in pairs(segmentFn(node1)) do 
		table.insert(options, { 
			seg = seg, 
			scores = { util.distance(util.nodePos(node2), util.getEdgeMidPoint(seg)) } 				
		})
	end 
	return util.evaluateWinnerFromScores(options).seg
end 

function pathFindingUtil.findRailPathBetweenNodes(node1, node2, maxDistance)
	if not node1 or not node2 then 
		return {}
	end

	return pathFindingUtil.findRailPathBetweenEdges(getClosestEdge(node1, node2, true) , getClosestEdge(node2, node1, true) , maxDistance, node2)
end 

function pathFindingUtil.getRailRouteInfoBetweenNodesIncludingReversed(node1, node2, maxDistance)
	local answer =pathFindingUtil.findRailPathBetweenNodes(node1, node2, maxDistance)
	if #answer == 0 then 
		answer = pathFindingUtil.findRailPathBetweenNodes(node2, node1, maxDistance)
	end 
	return pathFindingUtil.getRouteInfoFromEdges(answer)
end
	
function pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(node1, node2, maxDistance, forbidRecurse)
	if not node1 or not node2 then 
		return {}
	end
	local answer =  pathFindingUtil.findRailPathBetweenNodes(node1, node2)
	if #answer > 0 then 
		return answer 
	end
	answer =  pathFindingUtil.findRailPathBetweenNodes(util.findDoubleTrackNode(node1), node2)
	if #answer > 0 then 
		return answer 
	end
	answer =  pathFindingUtil.findRailPathBetweenNodes(node1, util.findDoubleTrackNode(node2))
	if #answer > 0 then 
		return answer 
	end
	
	answer =  pathFindingUtil.findRailPathBetweenNodes(util.findDoubleTrackNode(node1), util.findDoubleTrackNode(node2))
	if #answer > 0 then 
		return answer 
	end
	if not forbidRecurse then 
		pathFindingUtil.findRailPathBetweenNodesIncludingDoubleTrack(node1, node2, maxDistance, true)
	end
	return answer
end 

function pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edge1, edge2, maxDistance, forbidRecurse) 
	if not edge1 or not edge2 then 
		return {}
	end
	local answer =  pathFindingUtil.findRailPathBetweenEdges(edge1, edge2, maxDistance)
	if #answer > 0 then 
		return answer 
	end
	local doubleTrackEdge1 = util.findDoubleTrackEdge(edge1)
	local doubleTrackEdge2 = util.findDoubleTrackEdge(edge2)
	if doubleTrackEdge1 then 
		answer =  pathFindingUtil.findRailPathBetweenEdges(doubleTrackEdge1, edge2, maxDistance)
	end 
	if #answer > 0 then 
		return answer 
	end
	if doubleTrackEdge2 then 
		answer =  pathFindingUtil.findRailPathBetweenEdges(edge1, doubleTrackEdge2, maxDistance)
	end
	if #answer > 0 then 
		return answer 
	end
	if doubleTrackEdge1 and doubleTrackEdge2 then 
		answer =  pathFindingUtil.findRailPathBetweenEdges(doubleTrackEdge1, doubleTrackEdge2, maxDistance)
	end
	if #answer > 0 then 
		return answer 
	end
	if not forbidRecurse then 
		--trace("Dropping into finding path between ",edge2,edge1, " maxDistance=",maxDistance)
		return pathFindingUtil.findRailPathBetweenEdgesIncludingDoubleTrack(edge2, edge1, maxDistance, true) 
	end
	return answer

end

function pathFindingUtil.cacheDestinationEdgesAndNodes() 
	pathFindingUtil.destNodesByEdge = {} 
	pathFindingUtil.startingEdgesByEdge = {}
end 
function pathFindingUtil.clearCaches() 
	pathFindingUtil.destNodesByEdge = nil
	pathFindingUtil.startingEdgesByEdge = nil
end 
function pathFindingUtil.findRailPathBetweenEdges(edge1, edge2, maxDistance, useNode)
	--collectgarbage()
	if not maxDistance then
		maxDistance = 3* util.distance(util.getEdgeMidPoint(edge1), util.getEdgeMidPoint(edge2))
	end
	
	local startingEdges
	if startingEdgesByEdge and startingEdgesByEdge[edge1] then  
		startingEdges  =  startingEdgesByEdge[edge1] 
	else 
		startingEdges = pathFindingUtil.getStartingEdgesForEdge(edge1, api.type.enum.TransportMode.TRAIN)
		if startingEdgesByEdge then 
			startingEdgesByEdge[edge1]=startingEdges
		end
	end 
	local destNodes 
	if destNodesByEdge and destNodesByEdge[edge2] then  
		destNodes  =  destNodesByEdge[edge2] 
	else 
		if not useNode then useNode = util.getEdge(edge2).node0 end
		destNodes =  {api.type.NodeId.new(useNode, 0 )}
		if destNodesByEdge then 
			destNodesByEdge[edge2]=destNodes
		end
	end

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	--trace("Attempting to find rail path between edge and edge", edge1, edge2)
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	end
	--debugPrint(answer)
	return answer
	
end
function pathFindingUtil.getRailRouteInfoBetweenTerminalAndStation(station1, station1Terminal, station2)
	local answer = pathFindingUtil.findRailPathBetweenTerminalAndStation(station1, station1Terminal, station2)
	if #answer > 0 then 
		return pathFindingUtil.getRouteInfoFromEdges(answer)
	end
end
function pathFindingUtil.getStartingEdgesForStationAndTerminal(station, terminal)
	local vehicleNodeId = api.engine.getComponent(station, api.type.ComponentType.STATION).terminals[terminal+1].vehicleNodeId
	local edgeId = util.getTrackSegmentsForNode(vehicleNodeId.entity)[1]
	return {
		-- NB tracks only have one transport network for the rail path, the edge index is always zero
		api.type.EdgeIdDirAndLength.new(api.type.EdgeId.new(edgeId, 0), true, 0),
		api.type.EdgeIdDirAndLength.new(api.type.EdgeId.new(edgeId, 0), false, 0)
		} 
end
function pathFindingUtil.findRailPathBetweenTerminalAndStation(station1, station1Terminal, station2)
	collectgarbage()
	local maxDistance = 3* util.distBetweenStations(station1, station2)
	
	local startingEdges = pathFindingUtil.getStartingEdgesForStationAndTerminal(station1, station1Terminal)
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station2)
	

	local transportModes = {   api.type.enum.TransportMode.TRAIN} 
	--trace("Attempting to find rail path between station and station", station1, station2)
	local answer = {}
	if #destNodes>0 and #startingEdges>0 then 
		--debugPrint({startingEdges=startingEdges , destNodes=destNodes, transportModes=transportModes})
		answer = pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	end
	return answer
end

function pathFindingUtil.checkForRailPathBetweenTerminalAndStation(station1, station1Terminal, station2)

	return #pathFindingUtil.findRailPathBetweenTerminalAndStation(station1, station1Terminal, station2) >0
end

function pathFindingUtil.validateShipPath(station1, station2)
	local distance = util.distBetweenStations(station1, station2)
	local maxDist = distance*paramHelper.getParams().shipRouteToDistanceLimit
	local station1Full = api.engine.getComponent(station1, api.type.ComponentType.STATION)
	local station1Node = station1Full.terminals[1].vehicleNodeId
	local startingEdge = api.type.EdgeId.new(station1Node.entity, station1Node.index)
	local statingEdgesAndId = { api.type.EdgeIdDirAndLength.new(startingEdge, true, 0)} 
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station2)
	local transportModes = { api.type.enum.TransportMode.SMALL_SHIP }
	local answer = pathFindingUtil.findPath( statingEdgesAndId , destNodes, transportModes, maxDist)
	trace("The path between ", station1, " and ", station2, " had ",#answer," results")
	return #answer > 0
end
function pathFindingUtil.findRoadPathBetweenEdges(edge1, edge2, preferredNode)
	--trace("Getting startingEdges  for ",edge1)
	local startingEdges = pathFindingUtil.getStartingEdgesForEdge(edge1,  api.type.enum.TransportMode.BUS)
	--trace("Getting destination nodes for",edge2)
	local fullEdge2 = util.getEdge(edge2) 
	local targetNode = preferredNode 
	if not targetNode then 
		local startEdgePos = util.getEdgeMidPoint(edge1)
		if vec2.distance(util.nodePos(fullEdge2.node0), startEdgePos) > vec2.distance(util.nodePos(fullEdge2.node1), startEdgePos) and not util.isOneWayStreet(edge2) then 
			targetNode = fullEdge2.node0
		else 
			targetNode = fullEdge2.node1
		end
	end
	local destNodes = pathFindingUtil.getDestinationNodesForEdge(edge2,  api.type.enum.TransportMode.BUS, targetNode)
	local maxDistance = pathFindingUtil.calculateMaxRoadDistance(util.getEdgeMidPoint(edge1), util.getEdgeMidPoint(edge2))
	local transportModes = {   api.type.enum.TransportMode.BUS} 
	--trace("Attempting to find path between edges ", edge1," and ",edge2)
	return pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
end

function pathFindingUtil.findRoadPathBetweenNodes(node1, node2)
	local edge1 = getClosestEdge(node1, node2, false)  
	local edge2 = getClosestEdge(node2, node1, false)
	local answer =  pathFindingUtil.findRoadPathBetweenEdges(edge1, edge2)
	if #answer > 0 then 
		local edge
		for i = #answer, 1 , -1 do 
			local lastEdge = answer[i] 
			edge = util.getEdge(lastEdge.entity)
			if edge then 
				break
			else
				trace("No edge found for ",lastEdge.entity," index=",lastEdge.index," at ",i, " of ",#answer)
			end
		end
		if not edge then 
			trace("Route appears to ccontain no edges!") 
			return answer
		end
		if edge.node0 ~= node2 and edge.node1 ~= node2 then 
			trace("attempting to find last edge for path")
			local newAnswer = {} -- need to copy it out into a lua table 
			for i , entity in pairs(answer) do 
				table.insert(newAnswer, entity)
			end
			local found = false
			for i, nextSeg in pairs(util.getStreetSegmentsForNode(edge.node0)) do 
				local nextEdge = util.getEdge(nextSeg)
				if nextEdge.node0 == node2 or nextEdge.node1 == node2 then 
					table.insert(newAnswer, {entity=nextSeg} ) 
					found = true 
					break
				end
			end
			if not found then 
				for i, nextSeg in pairs(util.getStreetSegmentsForNode(edge.node1)) do 
					local nextEdge = util.getEdge(nextSeg)
					if nextEdge.node0 == node2 or nextEdge.node1 == node2 then 
						table.insert(newAnswer, {entity=nextSeg} ) 
						found = true 
						break
					end
				end
			end
			if not found then 
				trace("Failed to find the last edge for node ",node2)
			else 
				trace("Found and added the last edge for node ",node2)
			end
			return newAnswer
		end
	end
	
	return answer
end

local function findStreetEdgeForStation(station)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	if constructionId ~= -1 then 
		return api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION).frozenEdges[1]
	end
	return api.engine.getComponent(station, api.type.ComponentType.STATION).terminals[1].vehicleNodeId.entity
end

-- Road path between two entities that are each either a station id or a street edge id.
-- Returns the list from findPath ({entity=, index=} per lane edge), possibly empty.
function pathFindingUtil.findRoadPathBetweenEntities(a, b, isTram)
	local function isEdge(id) return util.getEdge(id) ~= nil end
	local mode = isTram and api.type.enum.TransportMode.TRAM or api.type.enum.TransportMode.BUS
	local startingEdges
	if isEdge(a) then
		startingEdges = pathFindingUtil.getStartingEdgesForEdge(a, mode)
	else
		startingEdges = pathFindingUtil.getStartingEdgesForEdge(findStreetEdgeForStation(a), mode)
	end
	local destNodes
	if isEdge(b) then
		local edge = util.getEdge(b)
		local startPos = isEdge(a) and util.getEdgeMidPoint(a) or util.getStationPosition(a)
		local targetNode = edge.node1
		if util.distance(util.nodePos(edge.node0), startPos) > util.distance(util.nodePos(edge.node1), startPos) and not util.isOneWayStreet(b) then
			targetNode = edge.node0
		end
		destNodes = pathFindingUtil.getDestinationNodesForEdge(b, mode, targetNode)
	else
		destNodes = pathFindingUtil.getDestinationNodesForStation(b)
	end
	local ok, answer = pcall(pathFindingUtil.findPath, startingEdges, destNodes, { mode }, math.huge)
	if not ok then
		trace("findRoadPathBetweenEntities failed", answer)
		return {}
	end
	return answer
end

function pathFindingUtil.findRoadPathBetweenStationAndNode(station, node, nodePos )
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station)
	if (not api.engine.entityExists(node) or not api.engine.getComponent(node, api.type.ComponentType.BASE_NODE)) and nodePos then 
		trace("Node",node," no longer existists attempting to use position")
		node = util.searchForNearestNode(nodePos, 50) 
		if not node then return {} end 
		node = node.id
		trace("Using node ",node)
		debugPrint({segmentsForNode=util.getSegmentsForNode(node)})
	end
	
	local startingEdges = pathFindingUtil.getStartingEdgesForEdge(util.getSegmentsForNode(node)[1],  api.type.enum.TransportMode.CAR)
	--local destNodes = getDestinationNodesForEdge(edge2)
	local maxDistance = pathFindingUtil.calculateMaxRoadDistance(util.nodePos(node), util.getStationPosition(station))
	local transportModes = {   api.type.enum.TransportMode.CAR, api.type.enum.TransportMode.TRUCK ,api.type.enum.TransportMode.BUS} 
	--trace("Attempting to find path between edges ", edge1," and ",edge2)
	local answer=  pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	--trace("There were ",#answer," edges")
	return answer
end

function pathFindingUtil.calculateMaxRoadDistance(p0, p1) 
	local initialDist = 500 + paramHelper.getParams().truckRouteToDistanceLimit*util.distance(p0, p1)
	local minGradientDist = 250+math.abs(p0.z-p1.z)/paramHelper.getParams().maxGradientRoad 
	return math.max(initialDist, minGradientDist)
end 

function pathFindingUtil.findRoadPathStations(station1, station2, isTram)
	local edge1 = findStreetEdgeForStation(station1)
	local edge2 = findStreetEdgeForStation(station2)
	trace("Getting starting edges and destination nodes for",edge1,edge2, " from stations",station1, station2)
	local startingEdges
	if util.isBusStop(station1) and false then
		local vehicleNodeId = api.engine.getComponent(station1, api.type.ComponentType.STATION).terminals[1].vehicleNodeId
		local edgeId = vehicleNodeId.entity
		local edge = util.getEdge(edgeId)
		local isLeft
		for __, edgeObj in pairs(edge.objects) do 
			if edgeObj[1]==station1 then 
				isLeft = edgeObj[2] == api.type.enum.EdgeObjectType.STOP_LEFT
				break 
			end 
		end 
		local index = isLeft and 1 or util.getNumberOfStreetLanes(edgeId)-2
		local fullEdgeId = api.type.EdgeId.new(edgeId, index)
		trace("Gotten full edgeId for starting edge at ",edgeId, index)
		local length = util.getEdgeLength(edgeId) 
--		startingEdges = {api.type.EdgeIdDirAndLength.new(fullEdgeId, true, 0), api.type.EdgeIdDirAndLength.new(fullEdgeId, false, 0)}
		startingEdges = {api.type.EdgeIdDirAndLength.new(fullEdgeId, true, 0), api.type.EdgeIdDirAndLength.new(fullEdgeId, false, 0)}
	else 
		startingEdges = pathFindingUtil.getStartingEdgesForEdge(edge1,  api.type.enum.TransportMode.BUS)
	end
	local destNodes = pathFindingUtil.getDestinationNodesForStation(station2)
	if util.isBusStop(station2) and false then 
		local vehicleNodeId = api.engine.getComponent(station2, api.type.ComponentType.STATION).terminals[1].vehicleNodeId
		local edgeId = vehicleNodeId.entity
		local edge = util.getEdge(edgeId)
		local isLeft
		for __, edgeObj in pairs(edge.objects) do 
			if edgeObj[1]==station2 then 
				isLeft = edgeObj[2] == api.type.enum.EdgeObjectType.STOP_LEFT
				break 
			end 
		end 
		local index =   isLeft and 1 or util.getNumberOfStreetLanes(edgeId)-2
	--local fullEdgeId = 
		 trace("Gotten full edgeId for end edge at ",edgeId, index)
--		startingEdges = {api.type.EdgeIdDirAndLength.new(fullEdgeId, true, 0), api.type.EdgeIdDirAndLength.new(fullEdgeId, false, 0)}
		destNodes = {api.type.NodeId.new(edgeId, index) }
		local destNodes = {}
		local group = api.engine.system.stationGroupSystem.getStationGroup(station2) 
		for i, station in pairs(api.engine.getComponent(group, api.type.ComponentType.STATION_GROUP).stations) do 
			table.insert(destNodes, api.engine.getComponent(station, api.type.ComponentType.STATION).terminals[1].vehicleNodeId)
		end 
	end 
	--local destNodes = pathFindingUtil.getDestinationNodesForEdge(edge2,  api.type.enum.TransportMode.BUS)
	local maxDistance = math.huge -- pathFindingUtil.calculateMaxRoadDistance(util.getStationPosition(station1), util.getStationPosition(station2)) 
	local transportModes = {   api.type.enum.TransportMode.CAR,   api.type.enum.TransportMode.TRUCK ,api.type.enum.TransportMode.BUS} 
	local transportModes = {  api.type.enum.TransportMode.BUS} 
	if isTram then 
		transportModes = { api.type.enum.TransportMode.TRAM} 
	end
	
	--trace("Attempting to find path between edges ", edge1," and ",edge2)
	local answer=  pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDistance)
	trace("There were ",#answer," edges between ",station1,station2)
	if #answer == 0 then 
		trace("WARNING! No path found between ",station1,station2)
	end
	
	return answer
end

function pathFindingUtil.getRouteInfoForRoadPathBetweenStationAndNode(station, node)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenStationAndNode(station, node))
end 
function pathFindingUtil.getRouteInfoForRoadPathBetweenNodes(node1, node2)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(node1, node2))
end
function pathFindingUtil.getRouteInfoForRailPathBetweenEdges(edge1, edge2)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRailPathBetweenEdges(edge1, edge2))
end

function pathFindingUtil.validateHighwayPathFromNodes(node1, node2) 
	local node1other = util.findParallelHighwayNode(node1)
	local node2other = util.findParallelHighwayNode(node2)
	if not node1other or not node2other then 
		trace("Could not find parallel node",node1other, node2other)
		return false 
	end 
	
	local fromNode1 = util.getDeadEndNodeDetails(node1).isNode0 and node1 or node1other
	local toNode2 = util.getDeadEndNodeDetails(node2).isNode0 and node2other or node2 
	
	local toNode1 = fromNode1 == node1 and node1other or node1
	local fromNode2 = toNode2 == node2 and node2other or node2 
	
	trace("Checking for path between",fromNode1," to ",toNode2," and ",fromNode2," to ",toNode1)
	return #pathFindingUtil.findRoadPathBetweenNodes(fromNode1, toNode2) > 0 and #pathFindingUtil.findRoadPathBetweenNodes(fromNode2, toNode1) > 0
end 

function pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2, isTram)
	return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathStations(station1, station2, isTram))
end

local function trytoFindUnconnectedTerminalNode(edgeId)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
	if constructionId == -1 then
		trace("Warning, the construcitonId was unexpectedly -1 for edge ",edgeId)
		return
	end
	local edge = util.getEdge(edgeId)
	local searchNode = util.isFrozenNode(edge.node0) and edge.node1 or edge.node0
	
	local result =  util.findNearestAdjacentUnconnectedFreeNode(constructionId, searchNode)
	trace("Search node for unconnectedTerminalNode was ",searchNode, " constructionId=",constructionId, " result=",result)
	return result
end

function pathFindingUtil.getGradientRouteSectionsFromEdges(edges)
	local routeSections = {} 
	local currentRouteSection
	local currentRouteSectionDist = 0
	local previousGradientCategory 
	local maxGradient = paramHelper.getParams().maxGradientTrack
	local gradientCategoryFn = function(gradient) -- group the sections by rising, falling or roughly flat
		if gradient > maxGradient/2 then 
			return 1 
		end
		if gradient < -maxGradient/2 then
			return -1
		end
		return 0
	end
	for i =1, #edges do
		local edge = edges[i]
		local gradient = util.calculateEdgeGradient(edge)
		local gradientCategory = gradientCategoryFn(gradient)
		local length = util.calculateSegmentLengthFromEdge(edge)
		if i == 1 or gradientCategory ~= previousGradientCategory then 
			table.insert(routeSections, {
				startIndex = i,
				length = length,
				gradients = { gradient }
			})
			currentRouteSection = #routeSections
		else 
			local rs = routeSections[currentRouteSection]
			table.insert(rs.gradients, gradient)
			rs.length = rs.length + length
		end
		previousGradientCategory = gradientCategory
	end
	for i, routeSection in pairs(routeSections) do 
		routeSection.avgGradient = util.average(routeSection.gradients)
	end
	--debugPrint({routeSections=routeSections})
	trace("There were ",#routeSections," from ",#edges," edges")
	
	return routeSections
end


function pathFindingUtil.getRouteInfoFromEdges(inputEdges) 
	if #inputEdges==0 then return end
	util.lazyCacheNode2SegMaps()
	local firstFreeEdge
	local lastFreeEdge
	local firstUnconnectedTerminalNode
	local lastUnconnectedTerminalNode
	local edges = {}
	local edgesAndIds = {}
	local alreadySeen = {}
	for i, segOrNode in pairs(inputEdges) do
		local edgeId
		local edge 
		if segOrNode.node0 then 
			edge = segOrNode
			edgeId = util.getEdgeIdFromEdge(edge) 
		else 
			edgeId = segOrNode.entity
			edge = api.engine.getComponent(edgeId , api.type.ComponentType.BASE_EDGE)
		end
		if edge and not alreadySeen[edgeId] then
			alreadySeen[edgeId]=true
			local constructionId =  api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
			if not firstFreeEdge then
				if constructionId == -1 then 
					firstFreeEdge = 1+#edges
					if #edges > 0 then
						firstUnconnectedTerminalNode = trytoFindUnconnectedTerminalNode(edgesAndIds[#edges].id)
					end
				end
			elseif not lastFreeEdge and constructionId ~= -1 then
				lastUnconnectedTerminalNode = trytoFindUnconnectedTerminalNode(edgeId)
				lastFreeEdge = #edges
			end
			table.insert(edges, edge)
			table.insert(edgesAndIds, {id=edgeId, edge=edge})
		end
	end
	if not lastFreeEdge  then
		lastFreeEdge = #edges
	end
	local startPoint = util.getEdgeMidPoint(edgesAndIds[1].id)
	local endPoint = util.getEdgeMidPoint(edgesAndIds[#edgesAndIds].id)
	local straightDistance = util.distance(startPoint, endPoint)
	local routeLength = 0
	local actualRouteLength = 0
	local isHighSpeedTrack = false 
	local isElectricTrack = false
	local routeSections
	if api.engine.getComponent(edgesAndIds[1].id, api.type.ComponentType.BASE_EDGE_STREET) then 
		local urbanRoadPenaltyFactor = paramHelper.getParams().urbanRoadPenaltyFactor
		local highwayRoadBonusFactor = paramHelper.getParams().highwayRoadBonusFactor
		for i = 1, #edges do 
			local edgeLength = util.calculateSegmentLengthFromEdge(edges[i])
			actualRouteLength = actualRouteLength + edgeLength
			local streetCategory = util.getStreetTypeCategory(edgesAndIds[i].id)
			if streetCategory == "urban" and edgesAndIds[i].edge.type == 0 then 
				edgeLength = edgeLength * urbanRoadPenaltyFactor
			elseif streetCategory == "highway" then 
				edgeLength = edgeLength * highwayRoadBonusFactor
			end			
			
			routeLength = routeLength + edgeLength
		end
	else 
		routeLength = util.calculateRouteLength(edges)
		actualRouteLength = routeLength
		routeSections = pathFindingUtil.getGradientRouteSectionsFromEdges(edges)
		isHighSpeedTrack = #edges>0
		isElectricTrack = #edges>0
		local highSpeedTrackType = api.res.trackTypeRep.find("high_speed.lua")
		for i = 1, #edges do 
			local trackEdge = api.engine.getComponent(edgesAndIds[i].id, api.type.ComponentType.BASE_EDGE_TRACK)
			if trackEdge.trackType ~= highSpeedTrackType then 
				isHighSpeedTrack = false 
			end 
			if not trackEdge.catenary then 
				isElectricTrack = false 
			end 
			if (not isElectricTrack) and (not isHighSpeedTrack) then 
				break 
			end
		end 
	end
	
	
	local stationToStationGradient = (endPoint.z - startPoint.z) /  util.calculateRouteLength2d(edges)
	local avgHeight = 0
	local maxHeight = -2^16
	local minHeight = 2^16
	local nodeCount = 0 
	local uniqueNodes = {}
	local indexLookup = {}	
	for i = 1, #edges do 
		for __, node in pairs({ edges[i].node0, edges[i].node1}) do 
			if not uniqueNodes[node] then	
				uniqueNodes[node] = true
				nodeCount = nodeCount + 1
				local nodePos = util.nodePos(node) 
				local height = nodePos.z
				avgHeight = avgHeight+height
				maxHeight = math.max(maxHeight, height)
				minHeight = math.min(minHeight, height)
			end
		end
		indexLookup[edgesAndIds[i].id]=i
	end
	avgHeight = avgHeight / nodeCount
	 
	
	
	local routeToDist = routeLength / straightDistance
	local maxGradient = util.calculateMaxGradient(edges)
	local signalIndexes = util.getSignalIndexes(edges)
	local numSignals = #signalIndexes
	
	
	return {
		edges=edgesAndIds,
		edgesOnly = edges,
		firstFreeEdge = firstFreeEdge,
		lastFreeEdge = lastFreeEdge,
		routeLength = routeLength,
		straightDistance = straightDistance,
		routeToDist = routeToDist,
		maxGradient = maxGradient,
		numSignals = numSignals,
		firstUnconnectedTerminalNode = firstUnconnectedTerminalNode,
		lastUnconnectedTerminalNode = lastUnconnectedTerminalNode,
		exceedsRouteToDistLimitForTrucks = routeLength > 200 and routeToDist > paramHelper.getParams().truckRouteToDistanceLimit+200,
		routeSections = routeSections,
		stationToStationGradient = stationToStationGradient,
		avgHeight = avgHeight,
		maxHeight = maxHeight,
		minHeight = minHeight,
		signalIndexes = signalIndexes,
		actualRouteLength = actualRouteLength,
		isHighSpeedTrack = isHighSpeedTrack,
		isElectricTrack = isElectricTrack,
		isDoubleTrack = numSignals > 0, -- simplistic 
		getIndexOfClosestApproach = function(p)
			local options = {} 
			for i =firstFreeEdge, lastFreeEdge do 
				if api.engine.entityExists(edgesAndIds[i].id) and util.getEdge(edgesAndIds[i].id) then 
					table.insert(options, 
						{
							idx =i ,
							scores = { util.distance(p, util.getEdgeMidPoint(edgesAndIds[i].id))}
						})
				end
			end 
			return util.evaluateWinnerFromScores(options).idx
		end,
		indexOf = function(edgeId) 
			return indexLookup[edgeId]
		end ,
		containsNode = function(node)  
			for i = 1, #edges do
				local node0 =edges[i].node0 
				local node1 =edges[i].node1
			
				if node0 == node or  node1 == node 	then
					return true
				end
			end
			return false
		end ,
		closestFreeNode = function(p) 
			local nodes = {} 
			for i = firstFreeEdge, lastFreeEdge do
				local edge = edges[i]
				for __, node in pairs({edge.node0, edge.node1}) do 
					table.insert(nodes, node)
				end 
			end 
			return util.evaluateWinnerFromSingleScore(nodes, function(node) return util.distance(util.nodePos(node),p) end)
		end 
		
	}
end

function pathFindingUtil.findPathFromDepotToStop(depotEntity, stop, nonStrict, line, isElectric, range)

	local carrier = api.engine.getComponent(depotEntity, api.type.ComponentType.VEHICLE_DEPOT).carrier
	--trace("Finding path from ",depotEntity," to stop isElectric?",isElectric, " carrier=",carrier, " nonStrict=",nonStrict)
	local transportModes 
	if carrier == api.type.enum.Carrier.RAIL then	
		if nonStrict or line.vehicleInfo.transportModes[api.type.enum.TransportMode.ELECTRIC_TRAIN+1]==0 and not isElectric then 
			transportModes =  {api.type.enum.TransportMode.TRAIN}
		else 
			trace("Using the ELECTRIC_TRAIN as the transport mode")
			transportModes = {api.type.enum.TransportMode.ELECTRIC_TRAIN} 
		end 
	elseif carrier == api.type.enum.Carrier.ROAD then 
		transportModes = {api.type.enum.TransportMode.BUS, api.type.enum.TransportMode.TRUCK}
	elseif carrier == api.type.enum.Carrier.AIR then 
		transportModes = {api.type.enum.TransportMode.SMALL_AIRCRAFT}
	elseif carrier == api.type.enum.Carrier.SHIP  then 
		transportModes = {api.type.enum.TransportMode.SMALL_SHIP}
	elseif carrier == api.type.enum.Carrier.TRAM then  
		if nonStrict then 
			transportModes = {api.type.enum.TransportMode.TRAM, api.type.enum.TransportMode.BUS}
		else 
			transportModes = {api.type.enum.TransportMode.TRAM}
		end 
	else
		trace("warning unable to determine transport type from",construction.fileName)
		return false
	end
	local stationGroupId = stop.stationGroup
	local stationGroup =  api.engine.getComponent(stationGroupId, api.type.ComponentType.STATION_GROUP)
	local stationId = stationGroup.stations[stop.station+1]
	local terminal = stop.terminal
	return pathFindingUtil.findPathFromDepotToStation(depotEntity, transportModes, stationId, terminal, carrier, range)
end 

function pathFindingUtil.findPathFromDepotToStation(depotEntity, transportModes, stationId, terminal, carrier, range)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(depotEntity)
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local edgeId = construction.frozenEdges[1]
	
	local depotPos = util.v3(construction.transf:cols(3))


	local stationPos = util.getStationPosition(stationId)
	local station =  api.engine.getComponent(stationId, api.type.ComponentType.STATION)
	
	local dist = util.distance(depotPos, stationPos) 
	if range and dist > range then --performance optimisation
		return {} 
	end
	local startingEdges = pathFindingUtil.getStartingEdgesForEdge(edgeId, transportModes[1]) 
	local destNodes = pathFindingUtil.getDestinationNodesForStation(stationId, terminal)
	local maxDist = 3*dist
	--trace("About to find path from depot to stop")
	return  pathFindingUtil.findPath( startingEdges , destNodes, transportModes, maxDist)  
end
function pathFindingUtil.findStopIndexesForDepot(depotEntity, line, nonStrict, isElectric, range) 
	local result = {}
	for i = 1, #line.stops do 
		--trace("About to find path stop = ",i-1)
		local path = pathFindingUtil.findPathFromDepotToStop(depotEntity, line.stops[i], nonStrict, line, isElectric, range)
		--trace("result of depotEntity was ",#path)
		if #path > 0 then 
			table.insert(result, i-1) 
		
		end		
	end	
	return result
end 
function pathFindingUtil.findClosestStopIndexForDepot(depotEntity, line, nonStrict, isElectric) 
	local options ={} 
	for i = 1, #line.stops do 
		--trace("About to find path stop = ",i-1)
		local path = pathFindingUtil.findPathFromDepotToStop(depotEntity, line.stops[i], nonStrict, line, isElectric)
		--trace("result of depotEntity was ",#path)
		if #path > 0 then 
			table.insert(options,{ 
				stopIndex = i-1,
				scores = { #path } 
			})
		end		
	end	
	--trace("Closest stop index options were ",#options)
	if #options > 0 then 
		
		return util.evaluateWinnerFromScores(options).stopIndex
	end
end

function pathFindingUtil.getRouteInfo(station1, station2, terminal1, terminal2)
	
	local answer = pathFindingUtil.findRailPathBetweenStations(station1, station2, terminal1, terminal2)
	if #answer == 0 then
		trace("no route found between ", station1, " and ", station2)
		return 
	end
	local routeInfo =  pathFindingUtil.getRouteInfoFromEdges(answer) 
	routeInfo.station1 = station1 
	routeInfo.station2 = station2 
	return routeInfo
end
function pathFindingUtil.findPath( startingEdges , destNodes, transportModes, distance)
	local answer = api.engine.util.pathfinding.findPath( startingEdges , destNodes, transportModes, distance)
	local result = {} 
	for i = 1, #answer do 
		table.insert(result, { entity = answer[i].entity, index = answer[i].index })-- clone into lua objects to make it safe to serialize
	end
	
	return result
end

function pathFindingUtil.getRouteInfoFromTrackNode(node)
	local edges = util.findAllConnectedFreeTrackEdges(node)
	return pathFindingUtil.getRouteInfoFromEdges(edges) 
end
 
return pathFindingUtil