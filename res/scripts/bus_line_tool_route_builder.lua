local util = require("bus_line_tool_base_util") 
--local routePreparation = require("bus_line_tool_route_preparation")
--local routeEvaluation = require("bus_line_tool_route_evaluation")
local paramHelper = require("bus_line_tool_base_param_helper")
local vehicleUtil = require("bus_line_tool_vehicle_util")
local pathFindingUtil = require("bus_line_tool_pathfinding_util")
--local connectEval = require("bus_line_tool_new_connections_evaluation")
local vec3 = require("vec3")
local vec2 = require("vec2")

local newSignalType = "railroad/signal_path_c_one_way.mdl"
local oldSignalType = "railroad/signal_path_a_one_way.mdl"

local tryToFixTunnelPortals = true
local routeBuilder = {}
local function hypot(x,y)
	return math.sqrt(x*x+y*y)
end
function routeBuilder.setTunnel(entity)
	entity.comp.type = 2 -- tunnel
	entity.comp.typeIndex = entity.type == 0 and api.res.tunnelTypeRep.find("street_old.lua") or api.res.tunnelTypeRep.find("railroad_old.lua")
end
local newNodeWithPosition = util.newNodeWithPosition
local copySegmentAndEntity = util.copySegmentAndEntity
-- takes points
local function hypotlen(p1, p2) 
	return hypot(p2.x-p1.x, p2.y-p1.y)
end
-- takes arrays
local function hypotlen2(p1, p2) 
	return hypot(p2[1]-p1[1], p2[2]-p1[2])
end
local trace = util.trace
 
local function err(e)
	print(e)
	print(debug.traceback())				
end
local function replaceNode(entity, oldNode, newNode ) 
	if entity.comp.node0 == oldNode then 
		entity.comp.node0 = newNode
	elseif entity.comp.node1 == oldNode then
		entity.comp.node1 = newNode 
	else 
		trace("WARNING! node ",oldNode," not found on ",entity.entity)
	end 
end
local function cloneNodesToLua(nodes)
local result = {}
	for i, node in pairs(nodes) do 
		local newNode = {} 
		newNode.comp = {} 
		newNode.comp.position = util.v3(node.comp.position)
		newNode.entity = node.entity		
		table.insert(result, newNode)
	end 
	return result
end 

local function cloneEdgesToLua(edges)
	local result = {}
	for i, edge in pairs(edges) do 
		local newEdge = {}
		newEdge.entity = edge.entity
		newEdge.comp = {}
		newEdge.comp.node0 = edge.comp.node0 
		newEdge.comp.node1 = edge.comp.node1 
		newEdge.comp.tangent0 = util.v3( edge.comp.tangent0)
		newEdge.comp.tangent1 = util.v3( edge.comp.tangent1)
	 
		newEdge.type = edge.type 
		newEdge.comp.type = edge.comp.type 
		newEdge.comp.typeIndex = edge.comp.typeIndex 
		newEdge.comp.objects = util.deepClone(edge.comp.objects)
		if edge.type == 1 then 
			newEdge.trackEdge = {}
			newEdge.trackEdge.trackType = edge.trackEdge.trackType
			newEdge.trackEdge.catenary = edge.trackEdge.catenary
		else 
			newEdge.streetEdge = {}
			newEdge.streetEdge.streetType = edge.streetEdge.streetType 
			newEdge.streetEdge.hasBus = edge.streetEdge.hasBus
			newEdge.streetEdge.tramTrackType = edge.streetEdge.tramTrackType 
		end 
		if edge.playerOwned then 
			newEdge.playerOwned ={}
			newEdge.playerOwned.player =  edge.playerOwned.player  
		end 
		table.insert(result, newEdge)
	
	end 
	return result
end

local function nodePosToString(node)
	if not node then return "nil" end
	return "("..node.comp.position.x..","..node.comp.position.y..","..node.comp.position.z..")"
end
local function setTangent(tangent, t) -- because tangent is mysterious "userdata", can't give it a vec3
	tangent.x = t.x
	tangent.y = t.y
	tangent.z = t.z
end
local function setTangent2d(tangent, t)  
	tangent.x = t.x
	tangent.y = t.y 
end

local function setTangents(entity, t)
	setTangent(entity.comp.tangent0, t)
	setTangent(entity.comp.tangent1, t)
end 

local function renormalizeTangents(entity, v)
	setTangent(entity.comp.tangent0, v*vec3.normalize(util.v3(entity.comp.tangent0)))
	setTangent(entity.comp.tangent1, v*vec3.normalize(util.v3(entity.comp.tangent1)))
end 

local function posToString(p)
	if not p then return "nil" end
	return "("..p.x..","..p.y..","..p.z..")"
end
local function isDepotEdge(edgeId, maxRecursions) 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
	if constructionId ~= -1 then 
		local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
		if construction.depots[1] then 
			return true 
		end 
	elseif maxRecursions > 0 then 
		local edge = util.getEdge(edgeId) 
		for __, node in pairs({edge.node0, edge.node1}) do 
			for __, seg in pairs(util.getTrackSegmentsForNode(node)) do 
				if isDepotEdge(seg, maxRecursions-1) then
					return true
				end
			end
		end
	end	
	return false
end
local function isStationEdge(edgeId, forbidRecurse) 
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edgeId)
	if constructionId ~= -1 then 
		local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
		if construction.stations[1] then 
			return true 
		end 
	elseif not forbidRecurse then 
		local edge = util.getEdge(edgeId) 
		for __, node in pairs({edge.node0, edge.node1}) do 
			for __, seg in pairs(util.getTrackSegmentsForNode(node)) do 
				if isStationEdge(seg, true) then
					return true
				end
			end
		end
	end	 
	return false
end
local function findDepotEdge(edges, routeInfo, index, node,routeEdges)
	local edgeBefore 
	local thisEdge 
	local edgeAfter 
	local otherEdge 
	for i, edge in pairs(edges) do 
		if edge == routeInfo.edges[i].id then 
			thisEdge = edge 
		elseif routeInfo.edges[i+1] and edge == routeInfo.edges[i+1].id then 
			edgeAfter = edge
		elseif  routeInfo.edges[i-1] and edge == routeInfo.edges[i-1].id then 
			edgeBefore = edge
		elseif not routeEdges[edge] then 
			otherEdge = edge
		end  
	end
	if isDepotEdge(otherEdge, 5) then 
		return otherEdge 
	end 
	if otherEdge then 
		trace("Inspecting other edge", otherEdge)
		local otherEdgeFull = util.getEdge(otherEdge)
		local otherNode = otherEdgeFull.node1 == node and otherEdgeFull.node0 or otherEdgeFull.node1 
		local nextSegs = util.getSegmentsForNode(otherNode)
		local nextEdgeId = otherEdge == nextSegs[1] and nextSegs[2] or nextSegs[1]
		
		while nextEdgeId do 
			trace("Inspecting nextEdgeId ",nextEdgeId)
			local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(nextEdgeId)
			if constructionId ~= -1 then 
				local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
				if construction.stations[1] then 
					trace("WARNING! Found a station link masquerading as a depot link, attempting to correct") 
					if edgeAfter then 
						routeInfo.edges[i+1].id = otherEdge 
						routeInfo.edges[i+1].edge = otherEdgeFull
						return edgeAfter
					elseif edgeBefore then 
						routeInfo.edges[i-1].id = otherEdge 
						routeInfo.edges[i-1].edge = otherEdgeFull
						return edgeBefore
					end 
				end 
				if construction.depots[1] then 
					return otherEdge
				end
			end 
			local otherEdgeFull = util.getEdge(nextEdgeId)
			otherNode = otherEdgeFull.node1 == otherNode and otherEdgeFull.node0 or otherEdgeFull.node1 
			local nextSegs = util.getSegmentsForNode(otherNode)
			nextEdgeId = nextEdgeId == nextSegs[1] and nextSegs[2] or nextSegs[1]
		end
		
	end 
	
	
	return otherEdge -- most likely option 
end

local function setTangentLengths(entity, length) 
	setTangent(entity.comp.tangent0, length*vec3.normalize(util.v3(entity.comp.tangent0)))
	setTangent(entity.comp.tangent1, length*vec3.normalize(util.v3(entity.comp.tangent1)))
end

function routeBuilder.setupProposalFromLuaProposal(luaProposal)
	local result=  routeBuilder.setupProposal(
		luaProposal.streetProposal.nodesToAdd, 
		luaProposal.streetProposal.edgesToAdd, 
		luaProposal.streetProposal.edgeObjectsToAdd, 
		luaProposal.streetProposal.edgesToRemove, 
		luaProposal.streetProposal.edgeObjectsToRemove)
	for i, construction in pairs(luaProposal.constructionsToAdd) do 
		result.constructionsToAdd[i]=construction
	end 
	result.constructionsToRemove = util.deepClone(luaProposal.constructionsToRemove)
	return result
end

function routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, diagnose)
	local highSpeedTrackType = api.res.trackTypeRep.find("high_speed.lua")
	trace("Being setting up proposal for route builder")
	local oldNodesReferenced = {}
	local newNodeToSegmentMap = {}
	local function recordNodeReferenced(nodeId , newEdgeIdx)
		if nodeId > 0 then
			if not oldNodesReferenced[nodeId] then 
				oldNodesReferenced[nodeId] = {}
			end
			table.insert(oldNodesReferenced[nodeId], newEdgeIdx)
		else 
			if not newNodeToSegmentMap[nodeId] then 
				newNodeToSegmentMap[nodeId]={}
			end 
			table.insert(newNodeToSegmentMap[nodeId], newEdgeIdx)
		end 
	end
	for i, edge in pairs(edgesToAdd) do
		recordNodeReferenced(edge.comp.node0, i)
		recordNodeReferenced(edge.comp.node1, i)
	end
	
	
	
	local removedNodeToSegmentMap = {}
	local function addToMap(nodeId, edgeId)
		if not removedNodeToSegmentMap[nodeId] then
			removedNodeToSegmentMap[nodeId]={}
		end
		removedNodeToSegmentMap[nodeId][edgeId]=true
	end
	
	for i, edgeId in pairs(edgesToRemove) do 
		assert(not util.isFrozenEdge(edgeId), " attempted to remove frozen edge "..edgeId)
		local edge = util.getEdge(edgeId)
		addToMap(edge.node0, edgeId)
		addToMap(edge.node1, edgeId)
	end
	
	local function containsAllEdges(nodeId, edgeSet) 
		local edges =  util.getSegmentsForNode(nodeId) 
		for j, edgeId in pairs(edges) do
			if not edgeSet[edgeId] then
				return false
			end
		end
		return true	
	end
	
	local nextNodeId = -1000-#edgesToAdd 
	local allNodesToAdd = {}
	for i, newNode in pairs(nodesToAdd) do 
		nextNodeId = math.min(nextNodeId, newNode.entity)
		table.insert(allNodesToAdd, newNode)
	end
	local function getNextNodeId() 
		nextNodeId = nextNodeId -1 
		return nextNodeId
	end
	trace("Setting up proposal, checking nodes to remove")
	
	local function doubleSlipSwitchRemoved(nodeId, edgeSet)
		if not api.engine.getComponent(nodeId, api.type.ComponentType.BASE_NODE).doubleSlipSwitch then	
			return false
		end
		local originalCount = #util.getTrackSegmentsForNode(nodeId) 
		local removedCount = util.size(edgeSet)
		local replacedCount = oldNodesReferenced[nodeId] and util.size(oldNodesReferenced[nodeId]) or 0
		local totalNew = originalCount - removedCount + replacedCount
		local isRemoved = totalNew < originalCount
		trace("Detected doubleSlipSwitch, originalCount=",originalCount,"removedCount=",removedCount,"replacedCount=",replacedCount, "totalNew=",totalNew, " isRemoved =", isRemoved)
		return isRemoved
	end
	
	local nodesToRemove = {}
	for nodeId, edgeSet in pairs(removedNodeToSegmentMap) do 
		local removedDoubleSlipSwitch= doubleSlipSwitchRemoved(nodeId, edgeSet) 
		--trace("Double slipswitch removed?",removedDoubleSlipSwitch)
		if containsAllEdges(nodeId, edgeSet) or removedDoubleSlipSwitch then
			assert(not util.isFrozenNode(nodeId), " attempted to remove frozen node "..nodeId)
			table.insert(nodesToRemove, nodeId)
			if oldNodesReferenced[nodeId] or removedDoubleSlipSwitch then -- annoying, we are forced to replace the node if all the segment references are new
				local newNode =  api.type.NodeAndEntity.new() 
				newNode.entity = getNextNodeId() 
				newNode.comp = api.engine.getComponent(nodeId, api.type.ComponentType.BASE_NODE)
				if removedDoubleSlipSwitch then 
					newNode.comp.doubleSlipSwitch = false
					local segs = util.getSegmentsForNode(nodeId)
					for __, seg in pairs(segs) do 
						if not edgeSet[seg] then 
							local newSeg = util.copyExistingEdge(seg, -1-#edgesToAdd)
							trace("replacing ",seg," attached to a doubleSlipSwitch")
							table.insert(edgesToAdd, newSeg)
							if not oldNodesReferenced[nodeId] then 
								oldNodesReferenced[nodeId]={}
							end
							table.insert(oldNodesReferenced[nodeId], #edgesToAdd)
							table.insert(edgesToRemove, seg)
						end
					end
					
				end
				if  oldNodesReferenced[nodeId] then 
					trace("Inserting new node with id ", nextNodeId)
					table.insert(allNodesToAdd, newNode)
					for __, edgeIdx in pairs( oldNodesReferenced[nodeId]) do 
						local newEdge = edgesToAdd[edgeIdx]
						if newEdge.comp.node0 == nodeId then
							newEdge.comp.node0 = newNode.entity
						else 
							assert(newEdge.comp.node1==nodeId)
							newEdge.comp.node1 = newNode.entity						
						end
						if not newNodeToSegmentMap[newNode.entity] then 
							newNodeToSegmentMap[newNode.entity]={}
						end 
						table.insert(newNodeToSegmentMap[newNode.entity], edgeIdx)
					end
				end
			end
		end
	end
	local newNodeToPositionMap = {}
	local newNodeMap = {}
	for i, newNode in pairs(allNodesToAdd) do 
		newNodeToPositionMap[newNode.entity]=util.v3(newNode.comp.position)
		newNodeMap[newNode.entity]=newNode
	end
	local removedEdgeSet = {}
	for i , edge in pairs(edgesToRemove) do 
		removedEdgeSet[edge]=true
	end
	local function getNodePosition(node) 
		if node < 0 then 
			return newNodeToPositionMap[node]
		else 
			return util.nodePos(node)
		end
	end
	
	local function calculateMaxConnectAngle(node, tangent, thisEdgeIdx) 
		local maxAngle = 0
		if node > 0 then 
			for i, seg in pairs(util.getTrackSegmentsForNode(node)) do 
				if not removedEdgeSet[seg] then 
					local edge = util.getEdge(seg)
					local otherTangent = util.v3(edge.node0 == node and edge.tangent0 or edge.tangent1)
					maxAngle = math.max(maxAngle, math.abs(util.signedAngle(tangent, otherTangent)))
				end 
			end
		else 
			for i, edgeIdx in pairs(newNodeToSegmentMap[node]) do
				if edgeIdx ~= thisEdgeIdx then 
					local edge = edgesToAdd[edgeIdx].comp
					local otherTangent = util.v3(edge.node0 == node and edge.tangent0 or edge.tangent1)
					maxAngle = math.max(maxAngle, math.abs(util.signedAngle(tangent, otherTangent)))
				end 
			end			
		end 
		return maxAngle
	end 
	if not edgeObjectsToRemove then 
		edgeObjectsToRemove = {}
	end
	local edgeIdxToRemove
	local junctionTunnelPortals = {}
	for node, edges in pairs(newNodeToSegmentMap) do 
		local connectedNodes = { }
		local priorEdgeType
		for i, edgeIdx in pairs(edges) do 
			local entity = edgesToAdd[edgeIdx]
			if not priorEdgeType then priorEdgeType = entity.comp.type end 
			if priorEdgeType ~= entity.comp.type and #edges > 2 and (entity.comp.type == 2 or priorEdgeType == 2) and not junctionTunnelPortals[node] and tryToFixTunnelPortals and entity.type == 1 then 
				trace("Found junction tunnel portal", node)
				junctionTunnelPortals[node] = edges
			end
			
			
			priorEdgeType = entity.comp.type
			local otherNode = entity.comp.node0 == node and entity.comp.node1 or entity.comp.node0 
			if connectedNodes[otherNode] then 
				trace("WARNING! The entity ",entity.entity," appears to be double connected!")
				if util.tracelog then debugPrint({edgesToAdd=edgesToAdd, nodesToAdd=nodesToAdd}) end
				edgeIdxToRemove = edgeIdx 
			else 
				connectedNodes[otherNode]=true
			end
		end
	end
	for node, edges in pairs(junctionTunnelPortals) do  
		local tunnelEdges = {}
		local otherEdges = {}
		for i, edgeIdx in pairs(edges) do 
			local entity = edgesToAdd[edgeIdx]
			if entity.comp.type == 2 then 
				table.insert(tunnelEdges, entity)
			else 
				table.insert(otherEdges, entity)
			end 
		end 
		if #tunnelEdges >= 2 then 
			if #edges == 3 then 
				local tangent = tunnelEdges[1].comp.node0 == node and util.v3(tunnelEdges[1].comp.tangent0) or -1*util.v3(tunnelEdges[1].comp.tangent1)
				local offset = 4*vec3.normalize(tangent) 
				local newNodePos = getNodePosition(node)+offset
				local newNode = newNodeWithPosition(newNodePos, getNextNodeId())
				table.insert(allNodesToAdd, newNode)
				newNodeToPositionMap[newNode.entity]=newNodePos
				newNodeMap[newNode.entity]=newNode
				local newEdge = copySegmentAndEntity(otherEdges[1], -1-#edgesToAdd)
				table.insert(edgesToAdd, newEdge)
				newEdge.comp.objects = {}
				trace("Created newEdge for tunnel junction portal",node," newNode was ",newNode.entity)
				if newEdge.comp.node0 == node then 
					newEdge.comp.node1 = newNode.entity
					util.setTangents(newEdge, offset)
				else 
					newEdge.comp.node0 = newNode.entity
					util.setTangents(newEdge, -1*offset)
				end 
				
				newNodeToSegmentMap[newNode.entity]={} 
				newNodeToSegmentMap[node]={}
				table.insert(newNodeToSegmentMap[node],-newEdge.entity)
				table.insert(newNodeToSegmentMap[newNode.entity],-newEdge.entity)
				for i, entity in pairs(otherEdges) do 
					table.insert(newNodeToSegmentMap[node], -entity.entity)
				end
				for i, entity in pairs(tunnelEdges) do
					if entity.comp.node0 == node then 
						trace("Setting new node on tunnel at node0 ",entity.entity)
						entity.comp.node0 = newNode.entity
						--util.setTangent(entity.comp.tangent0, -1*tangent)
					else 
						trace("Setting new node on tunnel at node1 ",entity.entity)
						entity.comp.node1 = newNode.entity
						--util.setTangent(entity.comp.tangent1, -1*tangent)
					end 
					table.insert(newNodeToSegmentMap[newNode.entity], -entity.entity)
				end
			else 
				for i, entity in pairs(otherEdges) do 
					trace("Setting tunnel on ",entity.entity)
					routeBuilder.setTunnel(entity)
				end 
			end 
		end
	end
	local uniqueObjectCheck ={}
	for i, entity in pairs(edgesToAdd) do 
		if entity.type == 1 then -- track, edge objects are signals
			local newEdgeObjs = {}
			for i, edgeObj in pairs(entity.comp.objects) do 
				if edgeObj[1] > 0 then 
					trace("Removing and replacing ",edgeObj[1]," for entity ",entity.entity)
					table.insert(edgeObjectsToRemove, edgeObj[1])
					local newEdgeObj = util.copyEdgeObject(edgeObj, entity.entity, entity)
					if entity.trackEdge.trackType == highSpeedTrackType and newEdgeObj.model == oldSignalType then 
						newEdgeObj.model = newSignalType
					end
					table.insert(edgeObjectsToAdd,newEdgeObj )
					table.insert(newEdgeObjs, {-#edgeObjectsToAdd , edgeObj[2]})
				else 
					trace("Edge object already in place ",edgeObj[1]," for entity ",entity.entity)
					table.insert(newEdgeObjs, edgeObj)
				end 
				assert(edgeObj[2] == api.type.enum.EdgeObjectType.SIGNAL)
				assert(not uniqueObjectCheck[newEdgeObjs[#newEdgeObjs][1]])
				uniqueObjectCheck[newEdgeObjs[#newEdgeObjs][1]] =true
			end 
			entity.comp.objects = newEdgeObjs 
		end
	end
	for i, edgeObject in pairs(edgeObjectsToAdd) do 
		if edgeObject.edgeEntity < 0 then 
			local entity = edgesToAdd[-edgeObject.edgeEntity]
			local found = false 
			for j, edgeObj in pairs(entity.comp.objects) do  
				if edgeObj[1]==-i then 
					found = true 
					break 
				end 
			end 
			assert(found, " edgeObj"..edgeObject.edgeEntity.." found")
		end
	end
	
	
	
	if diagnose then 
		local function setupBase() 
			local testProposal  = api.type.SimpleProposal.new()
			for i, edgeId in pairs(edgesToRemove) do 
				testProposal.streetProposal.edgesToRemove[i]=edgeId
			end
			for i, nodeId in pairs(nodesToRemove) do  
				testProposal.streetProposal.nodesToRemove[i]=nodeId
			end
			for i, edgeObj in pairs(edgeObjectsToRemove) do 
				--testProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj 
			end
			return testProposal
		end
		local testData =  api.engine.util.proposal.makeProposalData(setupBase() , util.initContext())
		--assert(#testData.errorState.messages == 0 and not testData.errorState.critical)
		
		local function toApiNode(node) 
			if node then 
				return util.newNodeWithPosition(node.comp.position, node.entity)
			end
		end 
		local function toApiEdge(edge) 
			local newEdge = api.type.SegmentAndEntity.new() 
			newEdge.entity = edge.entity
			newEdge.comp.node0 = edge.comp.node0 
			newEdge.comp.node1 = edge.comp.node1 
			util.setTangent(newEdge.comp.tangent0, edge.comp.tangent0)
			util.setTangent(newEdge.comp.tangent1, edge.comp.tangent1)
			newEdge.type = edge.type 
			newEdge.comp.type = edge.comp.type 
			newEdge.comp.typeIndex = edge.comp.typeIndex 
			if edge.type == 1 then 
				newEdge.trackEdge.trackType = edge.trackEdge.trackType
				newEdge.trackEdge.catenary = edge.trackEdge.catenary
			else 
				newEdge.streetEdge.streetType = edge.streetEdge.streetType 
				newEdge.streetEdge.hasBus = edge.streetEdge.hasBus
				newEdge.streetEdge.tramTrackType = edge.streetEdge.tramTrackType 
			end 
			if edge.playerOwned then 
				local playerOwned = api.type.PlayerOwned.new()
				playerOwned.player =  edge.playerOwned.player 
				newEdge.playerOwned = playerOwned
			end 
			return newEdge
		end 
		
		local function addEdgeToProposal(testProposal, edge)
			if edge.comp.node0  < 0 then 
				testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=toApiNode(newNodeMap[edge.comp.node0])
			end 
			if edge.comp.node1 < 0 then 
				testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=toApiNode(newNodeMap[edge.comp.node1])
			end
			edge.comp.objects = {}
			testProposal.streetProposal.edgesToAdd[1+#testProposal.streetProposal.edgesToAdd]=toApiEdge(edge)
			return testProposal
		end
		
		for i, edge in pairs(edgesToAdd) do
			 collectgarbage()
			local testProposal = addEdgeToProposal(setupBase(), edge)
			
			local testData =  api.engine.util.proposal.makeProposalData(testProposal , util.initContext())
			local isError =  #testData.errorState.messages > 0 or testData.errorState.critical
			trace("Checking edge ",i," isError=",isError, " isCriticalError=",testData.errorState.critical)
			if #testData.errorState.messages > 0 then 
				debugPrint(testData.errorState.messages)
				debugPrint(testData.collisionInfo.collisionEntities)
				trace("Error message found for edge ",edge.entity)
			end 
			if testData.errorState.critical then 
				trace("Critical error found for edge ",edge.entity)
			end 
		end 
		return
	end
	
	for i, edgeObj in pairs(edgeObjectsToAdd) do 
		if edgeObj.param ~= 0.5 and edgeObj.edgeEntity <0 then 
			local edge = edgesToAdd[-edgeObj.edgeEntity]
			local p0 = getNodePosition(edge.comp.node0)
			local p1 = getNodePosition(edge.comp.node1)
			if util.distance(p0, p1)< 40 then 
				trace("Resetting edge object position for short segment at ",edgeObj.edgeEntity," param was",edgeObj.param)
				edgeObj.param=0.5
			end
		end 
	end 
	local removedEdgeObjectSet = {}
	for i, edgeObj in pairs(edgeObjectsToRemove) do 
		removedEdgeObjectSet[edgeObj]=true
	end 
	
 	for i, edgeId in pairs(edgesToRemove) do
		local edge = util.getEdge(edgeId) 
		for j, edgeObject in pairs(edge.objects) do 
			if edgeObject[2]==api.type.enum.EdgeObjectType.SIGNAL then 
--				assert(removedEdgeObjectSet[edgeObject[1]])
				if not removedEdgeObjectSet[edgeObject[1]] then 
					trace("Remove edgeObject ",edgeObject[1])
					table.insert(edgeObjectsToRemove, edgeObject[1])
					removedEdgeObjectSet[edgeObject[1]]=true
				end 
			end 
		end 
	end 
	local bridgeTypeCount = util.size(api.res.bridgeTypeRep.getAll())
	local tunnelTypeCount = util.size(api.res.tunnelTypeRep.getAll())
	for i, edge in pairs(edgesToAdd) do
		local t0 = util.v3(edge.comp.tangent0)
		local t1 = util.v3(edge.comp.tangent1)
		assert(edge.comp.node0~=edge.comp.node1, "Edge had same nodes"..edge.comp.node0.." "..edge.comp.node1.." entity="..edge.entity)
		local p0 = getNodePosition(edge.comp.node0)
		local p1 = getNodePosition(edge.comp.node1)
		if not p0 or not p1 then 
			debugPrint(nodesToAdd)
			debugPrint(edge)
			trace("WARNING! Could not find position, p0=",p0,"p1=",p1)
			local lastNode = allNodesToAdd[#allNodesToAdd] 
			if lastNode.entity == edge.comp.node1 then 
				trace("But I found it in the last node in allNodesToAdd!!") 
				p1 = util.v3(lastNode.comp.position)
			end
			local lastNode = nodesToAdd[#nodesToAdd] 
			if lastNode.entity == edge.comp.node1 then 
				trace("But I found it in the last node in nodesToAdd!!") 
				p1 = util.v3(lastNode.comp.position)
			end
		end
		local lt0 = vec3.length(t0)
		local lt1 = vec3.length(t1)
		local dist = util.distance(p0, p1)
		assert(dist>0, "Zero dist between nodes "..edge.comp.node0.." "..edge.comp.node1.." entity="..edge.entity)
		local tolerance = 0.02*dist
		local angle = math.abs(util.signedAngle(t0, t1))
		local tangentRatio = math.max(math.abs(1-(lt0/lt1)), math.abs(1-(lt1/lt0)))
		local calcLen = util.calculateTangentLength(p0, p1, t0, t1)
		local distToTangent0 =  math.max(math.abs(1-(calcLen/lt0)),math.abs(1-(lt0/calcLen)))
		local distToTangent1 =  math.max(math.abs(1-(calcLen/lt1)),math.abs(1-(lt1/calcLen)))
		local naturalTangent = p1 - p0 
		local angle1 = math.abs(util.signedAngle(t0, naturalTangent))
		local angle2 = math.abs(util.signedAngle(t1, naturalTangent))
		local isOk = true 
		local tryRenormlize = false 
		if edge.type==1 then --track 
			local connectAngle1 = math.abs(calculateMaxConnectAngle(edge.comp.node0, t0, i))
			local connectAngle2 = math.abs(calculateMaxConnectAngle(edge.comp.node1, t1, i))
			if connectAngle1 > math.rad(90) then 
				connectAngle1 = math.rad(180)-connectAngle1
			end
			if connectAngle2 > math.rad(90) then 
				connectAngle2 = math.rad(180)-connectAngle2
			end
			if connectAngle1 > math.rad(5) or connectAngle2 > math.rad(5) then 
				trace("WARNING! High connect angle detected", math.deg(connectAngle1), math.deg(connectAngle2))
				isOk = false
			end
		end
		if dist < 4 then 
			trace("WARNING!, short distance ",dist)
			isOk =false 
		end 
		if lt0~=lt0 or lt1~=lt1 then 
			trace("WARNING!, NAN tangent",lt0,lt1)
		end
		if tangentRatio > 0.1 then 
			trace("WARNING, possible tangent inconsistentcy",lt1,lt0, " true dist was",dist)
			isOk = false
			tryRenormlize = true 
		end 
		if angle1 > math.rad(45) or angle2 > math.rad(45) then 
			trace("WARNING! high angle to natural tangent", math.deg(angle1), math.deg(angle2))
			if angle1 > math.rad(160) and angle2 > math.rad(160) then
				trace("Swapping nodes")
				local temp = edge.comp.node1
				edge.comp.node1 = edge.comp.node0
				edge.comp.node0 = temp
			end
			if angle1 > math.rad(160) and angle2 < math.rad(20) then 
				trace("Inverting tangent0")
				util.setTangent(edge.comp.tangent0, -1*util.v3(edge.comp.tangent0))
			elseif angle2 > math.rad(160) and angle1 < math.rad(20) then 
				trace("Inverting tangent1")
				util.setTangent(edge.comp.tangent1, -1*util.v3(edge.comp.tangent1))
			end 
			
			isOk =  false
		end
		if lt0 < dist-tolerance or lt1 < dist-tolerance then 
			trace("WARNING! too short tangent",  lt1,lt0, " true dist was",dist)
			isOk = false
			tryRenormlize = true
		end 
		if distToTangent0 > 0.2 or distToTangent1 > 0.2 then 
			trace("WARNING, unexpected distToTangent",   lt1,lt0, " true dist was",dist, "calculated was ",calcLen)
			isOk = false
		end 
		if angle > math.rad(90) then
			trace("WARNING, unexpected angle")
			isOk = false
		end
		if not isOk then 
			trace("Possible problem detected with new edge",edge.entity," connecting ",edge.comp.node0," and ",edge.comp.node1," at ",p0.x, p0.y, p0.z, " with ",p1.x, p1.y, p1.z)
		end 
		if tryRenormlize or util.alwaysCorrectTangentLengths then 
			--local length = math.max(dist,math.max(lt0, lt1))
			trace("Attempting to fix tangents with length ",calcLen)
			if lt0 > 0 and lt1 > 0 then 
				renormalizeTangents(edge, calcLen)
			else 
				trace("WARNING! Zero length tangent detected, attempting to correct")
				util.setTangents(edge, p1-p0)
			end
		end 
		local msg = " edge"..tostring(edge.entity).." type="..tostring(edge.comp.type).." typeIndex="..tostring(edge.comp.typeIndex)
		if edge.comp.type == 0 then 
			assert(edge.comp.typeIndex == -1,msg)
		elseif edge.comp.type == 1 then 
			assert(edge.comp.typeIndex ~= -1 , msg)
			if util.tracelog then assert(edge.comp.typeIndex <= bridgeTypeCount,msg) end
			if string.find(api.res.bridgeTypeRep.getName(edge.comp.typeIndex), "lollo_cement") then 
				edge.comp.typeIndex = api.res.bridgeTypeRep.find("cement.lua")
			end 
			
		else 
			assert( edge.comp.type == 2,msg )
			assert(edge.comp.typeIndex ~= -1,msg)
			if util.tracelog then assert(edge.comp.typeIndex <= tunnelTypeCount,msg) end
		end 
	end 
	
	
	
	-- can only add to proposal when everything is finalized, it seems the underlying object is copied when put on the proposal
	local newProposal  = api.type.SimpleProposal.new()
	local uniquenessCheck = {}
	for i, node in pairs(allNodesToAdd) do
		assert(node.comp.position.x == node.comp.position.x, "NaN coordinate in x")
		assert(node.comp.position.y == node.comp.position.y, "NaN coordinate in y")
		assert(node.comp.position.z == node.comp.position.z, "NaN coordinate in z")
		assert(not uniquenessCheck[node.entity],"failed node uniquenessCheck at "..node.entity.." original node at "..nodePosToString(uniquenessCheck[node.entity]).." this node at="..nodePosToString(node))
		uniquenessCheck[node.entity]=node
		newProposal.streetProposal.nodesToAdd[i]=node 
	end
	for i, edge in pairs(edgesToAdd) do
		assert(i==-edge.entity,"new edgeId check failed for "..i.." and "..edge.entity) -- apparently this is needed for edge object lookup
		assert(not uniquenessCheck[edge.entity],"new edgeId failed uniquenessCheck at "..edge.entity)
		assert(edge.type ~= -1, " type not set" )
		if edge.type == 0 then 
			assert(edge.streetEdge.streetType ~= -1, "street type not set")
		else 
			assert(edge.trackEdge.trackType ~= -1, "track type not set")
		end
		uniquenessCheck[edge.entity]=true
		newProposal.streetProposal.edgesToAdd[i]=edge  
	end

	for i, obj in pairs(edgeObjectsToAdd) do
		newProposal.streetProposal.edgeObjectsToAdd[i] = obj
	end
	
	
	for i, edgeId in pairs(edgesToRemove) do
		assert(not util.isFrozenEdge(edgeId), " attempted to remove frozen edge "..edgeId)
		assert(not uniquenessCheck[edgeId],"failed edgeId removal uniquenessCheck at "..edgeId)
		uniquenessCheck[edgeId]=true
		newProposal.streetProposal.edgesToRemove[i]=edgeId
	end
	for i, nodeId in pairs(nodesToRemove) do 
		assert(not util.isFrozenNode(nodeId), " attempted to remove frozen node "..nodeId)
		assert(not uniquenessCheck[nodeId],"failed nodeId removal uniquenessCheck at "..nodeId)
		--assert(newNodeToSegmentMap[nodeId],"new node referenced "..nodeId)
		--assert(#newNodeToSegmentMap[nodeId]>0,"new node referenced "..nodeId)
		uniquenessCheck[nodeId]=true
		-- validate every node removed has no edges left behind
		for j, edgeId in pairs(util.getSegmentsForNode(nodeId)) do
			if not uniquenessCheck[edgeId] and util.tracelog then 
				debugPrint({edgesToRemove=edgesToRemove, nodesToRemove=nodesToRemove, removedNodeToSegmentMap=removedNodeToSegmentMap})
			end
			assert(uniquenessCheck[edgeId]," attempted to remove "..nodeId.." but it still belonged to "..edgeId)
		end
		newProposal.streetProposal.nodesToRemove[i]=nodeId
	end
	
	if edgeObjectsToRemove then 
		for i, edgeObj in pairs(edgeObjectsToRemove) do 
			newProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj 
		end
	end
	
	trace("Proposal setup complete")
	return newProposal
end

local function checkForDepotProximity(nodes, params, station)
	if not params.isTrack or params.disableDepotProximityCheck then 
		return nodes
	end
	if  #nodes == 1 then 
		trace("Only one node provided",nodes[1]," cannot do any depot checking")
		return nodes 
	end
	if  not station or #api.engine.system.lineSystem.getLineStopsForStation(station) > 0 then 
		trace("Skipping check for depot proximity for station ",station)
		return nodes 
	end
	if params.isCargo then 
		local result = {}
		for i, node in pairs(nodes) do
			local nodeDetails = util.getDeadEndNodeDetails(node)
			local testPos = nodeDetails.nodePos + 40*vec3.normalize(nodeDetails.tangent)
			local skip = false 
			for j, construction in pairs(util.searchForEntities(testPos, 50 , "CONSTRUCTION")) do
				if #nodes>1 and string.find(construction.fileName, "depot/train") then 
					local depotEdgeId = api.engine.getComponent(construction.id, api.type.ComponentType.CONSTRUCTION).frozenEdges[1]
					local depotEdge = util.getEdge(depotEdgeId)
					local angle = util.signedAngle(depotEdge.tangent1, nodeDetails.tangent)
					trace("A depot was found, the angle was ",math.deg(angle))
					if math.abs(math.rad(180)-math.abs(angle))<math.rad(1) then 
						trace("Skipping node ",node," as it appears to face directly into a depot")
						skip = true 
					end
				end
			end
			if not skip then 
				table.insert(result, node)
			end 
		end
		return result
	end
	trace("Checking for depot proximity for station ",station)
	local result = {}
	
	for i, node in pairs(nodes) do
		for j, construction in pairs(util.searchForEntities(util.nodePos(node), 85 , "CONSTRUCTION")) do
			if string.find(construction.fileName, "depot/train") then 
				local freeNodes = util.getFreeNodesForConstruction(construction.id)
				if #util.getTrackSegmentsForNode(freeNodes[1])==1 then 
					table.insert(result, node)
				end
			end
		end 
	end
	if #result == 0 then 
		trace("Warning, no depot proximity nodes were found!")
		return nodes
	end
	
	return result
end

local function isIronBridgeAvailable() 
	return util.year() >= api.res.bridgeTypeRep.get(api.res.bridgeTypeRep.find("iron.lua")).yearFrom

end 

local function getDeadEndNodesForStation(stationId, spurConnect, range, params) 
	local result = {}
	trace("Getting nodes for station",stationId)
	local freeTerminals = util.countFreeTerminalsForStation(stationId)
	
	if params and params.connectNodes and params.connectNodes[stationId] then 
		for i, nodePos in pairs(params.connectNodes[stationId]) do 
			table.insert(result, util.searchForNearestNode(nodePos).id)
		end 
		return result
	end 
	
	
	if params and params.isQuadrupleTrack and (util.getConstructionForStation(stationId).params.buildThroughTracks or util.getConstructionForStation(stationId).params.throughtracks == 1 ) and freeTerminals==2 then 
		local freeNodesForFreeTerminals = util.getFreeNodesForFreeTerminalsForStation(stationId)
		local allNodes = util.getAllFreeNodesForStation(stationId)
		trace("Filtering to central nodes") 
		for i, node in pairs(allNodes) do
			if #util.getTrackSegmentsForNode(node)==1 and not util.contains(freeNodesForFreeTerminals, node) then 
				trace("Adding node",node," for consideration as a free node free terminal for stationId",stationId)
				table.insert(result, node) 
			end 
		end
		
	elseif freeTerminals > 3 then 
		local terminalToFreeNodes  = util.getTerminalToFreeNodesMapForStation(stationId)
		local highestTerminal = 0
		local lowestTerminal = math.huge 
		for terminal, nodes in pairs(terminalToFreeNodes) do 
			if #nodes > 0 and util.isFreeTerminalOneBased(stationId, terminal)  then 
				highestTerminal = math.max(highestTerminal, terminal)
				lowestTerminal = math.min(lowestTerminal, terminal)
			end
		end 
		
		trace("Filtering for nodes between",highestTerminal ," and ",lowestTerminal)
		for terminal, nodes in pairs(terminalToFreeNodes) do 
			if terminal < highestTerminal and terminal > lowestTerminal then 
				for i, node in pairs(nodes) do 
					if #util.getTrackSegmentsForNode(node)==1 then 
						trace("Adding node",node," for consideration as a free node free terminal for stationId",stationId)
						table.insert(result, node) 
					end 
				end 
			end
		end 
	else 
		for i , node in pairs(util.getFreeNodesForFreeTerminalsForStation(stationId)) do 
			if #util.getTrackSegmentsForNode(node)==1 then 
				trace("Adding node",node," for consideration as a free node free terminal for stationId",stationId)
				table.insert(result, node) 
			end 
		end
	end
	local allStationNodes ={} 
	for i, node in pairs(util.getAllFreeNodesForStation(stationId)) do 
		allStationNodes[node]=true 
	end 
	
	--if #result == 0 then  
		for i, node in pairs(util.searchForDeadTrackNodes(util.getStationPosition(stationId), 750)) do 
			if not util.isFrozenNode(node) and #pathFindingUtil.findRailPathBetweenEdgeAndStationFreeTerminal(util.getTrackSegmentsForNode(node)[1], stationId, true) > 0 and not allStationNodes[node] and not util.isFrozenEdge(util.getTrackSegmentsForNode(node)[1]) then 
				trace("adding node",node,"for consideration as a station connect node")
				table.insert(result, node)
			end
		end 
	--end 
 
	if spurConnect then 
		local spurResult = {} 
		local exlcudeNodes = {}
		for i, node in pairs(result) do 
			exlcudeNodes[node]=true
		end
		for i, node in pairs(util.getAllFreeNodesForStation(spurConnect)) do 
			exlcudeNodes[node]=true 
		end 
		if not range then range = 350 end
		local searchPos = util.getStationPosition(stationId)
		trace("About to check joinNodePos for ",stationId)
		if params and params.joinNodePos then 
			if params.joinNodePos[stationId] then 
				trace("Found joinNodePos for ",stationId,"Searching for nodes near node ",params.joinNodePos[stationId].x, params.joinNodePos[stationId].y)
				searchPos =  params.joinNodePos[stationId]
			elseif params.joinNodePos[spurConnect] then 
		
				searchPos =   params.joinNodePos[spurConnect]
				trace("Found joinNodePos for spurConnect ",spurConnect,"Searching for nodes near node ",searchPos.x, searchPos.y)
			else 
				trace("Did not find a joinNodePos for either",stationId,"or",spurConnect)
			end			
		end
		for i ,node in pairs(util.searchForEntities(searchPos, range, "BASE_NODE")) do
			local trackEdges = util.getTrackSegmentsForNode(node.id)
			if #trackEdges==1 then -- filters for dead end track nodes
				if not exlcudeNodes[node.id] and not util.isFrozenNode(node.id) and not util.isFrozenEdge(trackEdges[1]) and util.getEdgeLength(trackEdges[1])>4  then
					trace("Adding node",node.id," for consideration as a dead end track node")
					table.insert(spurResult, node.id)
				end
			end
		end
		return spurResult
	end
	
	return result 
end
local function applyHeightOffset(splits, offset, i, maxGradient)
	if offset == 0 then 
		return 
	end
	local p = splits[i].p1
	p.z = p.z+offset
	trace("apply height offset at ",i," offset=",offset, " old height=",splits[i].newNode.comp.position.z," new height=",p.z)
	splits[i].newNode.comp.position.z = p.z
	if splits[i].doubleTrackNode then 
		trace("applying height offset to double track node")
		splits[i].doubleTrackNode.comp.position.z = p.z
	end
	if splits[i-1] then
		local p2 = splits[i-1].p1
		local deltaz = p.z - p2.z
		local dist = vec2.distance(p, p2)
		local grad =  (deltaz/dist)
		if math.abs(grad) > maxGradient +0.01 then
			local maxDeltaZ = dist * (maxGradient)
			local correction = math.abs(deltaz)-maxDeltaZ
			trace("needing to apply correction",correction, " dist=",dist," deltaz=",deltaz," maxDeltaZ=",maxDeltaZ,"grad=",grad)
			applyHeightOffset(splits, deltaz < 0 and -correction or correction, i-1, maxGradient)
		end
	end
	if splits[i+1] then
		local p2 = splits[i+1].p1
		local deltaz = p.z - p2.z
		local dist = vec2.distance(p, p2)
		local grad =  (deltaz/dist)
		if math.abs(grad) > maxGradient +0.01 then
			local maxDeltaZ = dist * (maxGradient)
			local correction = math.abs(deltaz)-maxDeltaZ
			trace("needing to apply correction",correction, " dist=",dist," deltaz=",deltaz," maxDeltaZ=",maxDeltaZ,"grad=",grad)
			applyHeightOffset(splits, deltaz < 0 and -correction or correction, i+1, maxGradient)
		end
	end
end

local function setPositionOnNode(newNode, p)
	newNode.comp.position.x = p.x
	newNode.comp.position.y = p.y
	newNode.comp.position.z = p.z
end

local function newNodeWithPosition(p, entityId)
	local newNode =  api.type.NodeAndEntity.new()
	setPositionOnNode(newNode, p)
	if entityId then 
		newNode.entity = entityId
	end
	
	return newNode
end
local function copyNodeWithZoffset(node, zoffset, entityId) 
	local newNode = newNodeWithPosition(util.nodePos(node), entityId)
	newNode.comp.position.z = newNode.comp.position.z + zoffset 
	return newNode
end 
local function newDoubleTrackNode(p, t, entityId) 
	return newNodeWithPosition(util.doubleTrackNodePoint(p, t), entityId)
end


local function trialBuildBetweenPoints(p0, p1) 
	local entity = api.type.SegmentAndEntity.new()
	local newProposal = api.type.SimpleProposal.new()
	local newNode0 = newNodeWithPosition(p0, -1)
	local newNode1 = newNodeWithPosition(p1, -2)
	entity.type=1
	entity.trackEdge.trackType = api.res.trackTypeRep.find("standard.lua")
	entity.comp.node0=-1
	entity.comp.node1=-2
	entity.entity=-3
	setTangent(entity.comp.tangent0, p1-p0)
	setTangent(entity.comp.tangent1, p1-p0)
	newProposal.streetProposal.nodesToAdd[1]=newNode0
	newProposal.streetProposal.nodesToAdd[2]=newNode1
	newProposal.streetProposal.edgesToAdd[1]=entity
	local testResult = api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	return {
		isError = #testResult.errorState.messages > 0 or testResult.errorState.critical, 
		collisionEntities = testResult.collisionInfo.collisionEntities
	}
end


local function setTangentPreservingMagnitude(tangent, t, reduction)
	local existingLength = vec3.length(tangent)
	local angle = util.signedAngle(tangent, t)
	if reduction then 
		existingLength = existingLength - reduction
	end
	trace("Setting tangent, existing length=",existingLength," angle change=",math.deg(angle))
	setTangent(tangent, existingLength*vec3.normalize(t))
end

function routeBuilder.getBridgeType()
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	if  util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom  then
		return cement
	elseif  util.year() >= api.res.bridgeTypeRep.get(iron).yearFrom  then
		return iron
	else 
		return api.res.bridgeTypeRep.find("stone.lua")
	end
end


 local function findBridgeType(entity, split, params)
	trace("Finding bridgeType, split was ",split," needsSuspensionBridge?", (split and split.needsSuspensionBridge or false))
	if split and util.isSuspensionBridgeAvailable() and 
		(--split.bridgeLength and split.bridgeLength > 5 or
		 split.bridgeHeight and split.bridgeHeight > 50
		or split.needsSuspensionBridge)
		and not (params and params.isHighway and params.isElevated)
		and not split.segmentsPassingAbove 
		and not split.forbidSuspension
	then
		if util.isCableBridgeAvailable() and params and params.isHighSpeedTrack then 
			return api.res.bridgeTypeRep.find("cable.lua")
		else 
			return api.res.bridgeTypeRep.find("suspension.lua")
		end 
	end
 
 -- see if "cement" is available, fall back to stone 
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	if  util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom 
		and (entity.type==0 or entity.trackEdge.trackType==api.res.trackTypeRep.find("high_speed.lua")) or params and params.isHighway then
		return cement
	elseif  util.year() >= api.res.bridgeTypeRep.get(iron).yearFrom  then
		return iron
	else 
		return api.res.bridgeTypeRep.find("stone.lua")
	end
end

 local function setCrossingBridge(entity, params, span, prevEntity, removeSuspension, actualDeltaz)
	-- need to avoid using stone because it very frequently has a pillar bridge collision
	local stone = api.res.bridgeTypeRep.find("stone.lua")
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local iron = api.res.bridgeTypeRep.find("iron.lua")
	local cable =  api.res.bridgeTypeRep.find("cable.lua")
	local suspension = api.res.bridgeTypeRep.find("suspension.lua")
	local cementAvailable = util.year() >= api.res.bridgeTypeRep.get(cement).yearFrom 
	local cableAvailable = util.year() >= api.res.bridgeTypeRep.get(cable).yearFrom
	local bridgeTypeToUse =  iron
	-- personal choice, the iron bridge is asthetically pleasing for crossings, use unless it would slow our trains significantly
	if cementAvailable and entity.type == 0 or 
		entity.type == 1   and (params.isHighSpeedTrack or not prevEntity and entity.trackEdge.trackType == api.res.trackTypeRep.find("high_speed.lua")) or params.isHighway then 
		bridgeTypeToUse = cement
	end
	if (not span or span > params.maxCrossingBridgeSpan) and util.isSuspensionBridgeAvailable() then 
		if not removeSuspension and actualDeltaz and math.abs(actualDeltaz) >= params.minZoffsetSuspension then 
			bridgeTypeToUse = suspension
		end
		if cableAvailable then 
			bridgeTypeToUse = cable
		end
	end 
	removeSuspension = removeSuspension or actualDeltaz and params and math.abs(actualDeltaz)<params.minZoffsetSuspension
	trace("Setting bridgetype, bridgeTypeToUse=",bridgeTypeToUse," cement=",cement," iron=",iron," removeSuspension=",removeSuspension)
	-- if it has a bridge type already do not override unless it is stone 
	if entity.comp.type ~= 1 or entity.comp.typeIndex==stone or removeSuspension and (entity.comp.typeIndex == suspension or entity.comp.typeIndex==cable) then
		entity.comp.type = 1
		entity.comp.typeIndex = bridgeTypeToUse
	else 
		trace("Not setting bridge, already had with type",entity.comp.typeIndex, " which is ",api.res.bridgeTypeRep.getName(entity.comp.typeIndex))
	end 
	if entity.type == 0 and string.find(api.res.streetTypeRep.getName(entity.streetEdge.streetType), "old")  then 
		entity.streetEdge.streetType = api.res.streetTypeRep.find(string.gsub(api.res.streetTypeRep.getName(entity.streetEdge.streetType), "old", "new")) -- dirt road textures don't look good on modern bridges
	end
	
	if prevEntity and prevEntity.comp.type == 1 then 
		if prevEntity.comp.typeIndex ~= stone and (prevEntity.comp.typeIndex~=suspension or actualDeltaz and  actualDeltaz  >= params.minZoffsetSuspension) then 
			trace("Using the existing type ",api.res.bridgeTypeRep.getName(prevEntity.comp.typeIndex)," actualDeltaz was ",actualDeltaz)
			entity.comp.typeIndex = prevEntity.comp.typeIndex -- keep the bridge type consistent if already in a bridge span
		end
	end
 
 end
local newSignalYearFrom 
local function buildSignal(edgeObjectsToAdd, entity, left, signalParam)
	if not newSignalYearFrom then 
		newSignalYearFrom =  api.res.modelRep.get(api.res.modelRep.find(newSignalType)).metadata.availability.yearFrom
	end 
	local signalType = util.year() >= newSignalYearFrom and newSignalType or oldSignalType
	if not routeBuilder.signalCount then 
		routeBuilder.signalCount = 0 
	end
	if not signalParam then 
		signalParam = 0.5
	end
	if #entity.comp.objects > 0 then 
		trace("WARNING! Attempting to place more than on edge object on entity",entity.entity," aborting") 
		return 
	end
	routeBuilder.signalCount = routeBuilder.signalCount+1
	local newSig = api.type.SimpleStreetProposal.EdgeObject.new()
	newSig.left = left
	newSig.oneWay =true
	newSig.playerEntity = api.engine.util.getPlayer()
	newSig.edgeEntity = entity.entity
	newSig.name = _("AI").." ".._("Signal").." "..tostring(routeBuilder.signalCount)
	newSig.model = signalType
	newSig.param = signalParam
	entity.comp.objects = { {-(1+#edgeObjectsToAdd), api.type.enum.EdgeObjectType.SIGNAL}}
	table.insert(edgeObjectsToAdd,newSig)
end

local function buildSignals(edgeObjectsToAdd, i, nodecount, entity, entity2, backwards)
	
	local signalParam =  i<=2 and 0.1 or i>= nodecount-1 and 0.9 or 0.5
	if backwards then
		signalParam = 1-signalParam
	end
	buildSignal(edgeObjectsToAdd, entity, backwards, signalParam)
	buildSignal(edgeObjectsToAdd, entity2,not backwards, signalParam)
	
end

local function canUseBridgeForCrossing(requiredSpan, params) 
	local result = requiredSpan <= params.maxCrossingBridgeSpan or util.isSuspensionBridgeAvailable() and requiredSpan <= params.maxCrossingBridgeSpanSuspension
	trace("Checking if bridge can be used to span ", requiredSpan, " result was ", result)
	return result
end




function routeBuilder.deconflictEdges(edges, height) 
	local nextNodeId = -1000
	
	local function getNextNodeId() 
		nextNodeId = nextNodeId - 1
		return nextNodeId
	end
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	local newNodeMap = {}
	local replacedEdgesMap = {}
	local oldToNewNodeMap = {}
	local newNode2SegMap = {}
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local function nodePos(node) 
		if node > 0 then 
			return util.nodePos(node)
		else 
			return util.v3(newNodeMap[node].comp.position)
		end 
	end 
	local function addNode(newNode, oldNode) 
		table.insert(nodesToAdd, newNode)
		newNodeMap[newNode.entity]=newNode
		oldToNewNodeMap[oldNode]=newNode
		newNode2SegMap[newNode.entity]={} 
	end 
	local function nodePos(node) 
		if node > 0 then 
			return util.nodePos(node) 
		else 
			return util.v3(newNodeMap[node].comp.position)
		end 
	end	
	  
	local function setHeightOnNode(node, z , forbidRecurse)
		local nodePos = util.nodePos(node)
		if   not oldToNewNodeMap[node] then  
			nodePos.z = math.min(z, nodePos.z)
			trace("Reducing height offset of node ",node," with height",nodePos.z, " targetHeight was",z)
			local newNode = util.newNodeWithPosition(nodePos, getNextNodeId())
			addNode(newNode, node)
			
			for __, seg in pairs(util.getSegmentsForNode(node)) do 
				if not replacedEdgesMap[seg] then 
					local replacement = util.copyExistingEdge(seg, nextEdgeId() )
					table.insert(edgesToAdd, replacement)
					table.insert(edgesToRemove, seg)
					replacedEdgesMap[seg] = replacement
				end 
				
				local replacement = replacedEdgesMap[seg]
				if not util.contains(newNode2SegMap[newNode.entity], replacement) then 
					table.insert(newNode2SegMap[newNode.entity], replacement) 
				end
				local otherNode
				if replacement.comp.node0 == node then 
					replacement.comp.node0 = newNode.entity
					otherNode = replacement.comp.node1 
				else 
					replacement.comp.node1 = newNode.entity
					otherNode = replacement.comp.node0 
				end 
				if edges[seg] then 
					replacement.comp.type = 2
					replacement.comp.typeIndex = replacement.type == 0 and api.res.tunnelTypeRep.find("street_old.lua") or api.res.tunnelTypeRep.find("railroad_old.lua")
				elseif otherNode > 0 and not forbidRecurse then 
					setHeightOnNode(otherNode, height - 7.5, true)
				end 
			end 
		end 
	end 
		
	local function replaceEdge(edgeId) 
		local edge = util.getEdge(edgeId)
		trace("Replacing edge",edgeId," nodes were",edge.node0, edge.node1)
		setHeightOnNode(edge.node0, height - 15)
		setHeightOnNode(edge.node1, height - 15)
	end
	for edge, bool in pairs(edges) do  
		local doubleTrackEdge = util.findDoubleTrackEdge(edge)
		if doubleTrackEdge and not edges[doubleTrackEdge] then 
			edges[doubleTrackEdge]=true 
		end
	end
	for edge, bool in pairs(edges) do  
		replaceEdge(edge) 
	end
	for i , newNode in pairs(nodesToAdd) do 
		local node = newNode.entity
		if #newNode2SegMap[node]==2 then 
			local leftEdge = newNode2SegMap[node][1]
			local rightEdge = newNode2SegMap[node][2]
			local leftNode0 = leftEdge.comp.node0 == node
			local rightNode0 = rightEdge.comp.node0 == node
			local leftNodePos = nodePos(leftNode0 and leftEdge.comp.node1 or leftEdge.comp.node0)
			local rightNodePos = nodePos(rightNode0 and rightEdge.comp.node1 or rightEdge.comp.node0)
			local midNodePos = nodePos(node)
			local leftTangent = util.v3(leftNode0 and leftEdge.comp.tangent0 or leftEdge.comp.tangent1)
			local rightTangent = util.v3(rightNode0 and rightEdge.comp.tangent0 or rightEdge.comp.tangent1)
			
			leftTangent.z = midNodePos.z - leftNodePos.z 
			rightTangent.z = rightNodePos.z - midNodePos.z
		 
			local len1 = vec3.length(leftTangent)
			local len2 = vec3.length(rightTangent)
			local t = vec3.normalize(leftTangent)
			local t2 = vec3.normalize(rightTangent)
			local weightedAverage = (len1*t.z + len2*t2.z)/(len1+len2)
			local leftZTangent = leftNode0 and -weightedAverage*len1 or weightedAverage*len1
			local rightZTangent = rightNode0 and  weightedAverage*len2 or -weightedAverage*len2
			trace("The leftZTangent was",leftZTangent," the rightZTangent was",rightZTangent)
			if leftNode0 then 
				leftEdge.comp.tangent0.z = leftZTangent
			else 
				leftEdge.comp.tangent1.z = leftZTangent
			end 
			
			if rightNode0 then 
				rightEdge.comp.tangent0.z = rightZTangent
			else 
				rightEdge.comp.tangent1.z = rightZTangent
			end 
			
		end 
		
		
		
	
	end 
	
	local newProposal = routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	trace(" About to sent replace edges")
	api.cmd.sendCommand(build, function(res, success) 
		trace(" attempt command result was", tostring(success))
		if not success and util.tracelog then 
			debugPrint(res) 
		end 
	end)
end 

function routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, highwayNode, highwayNodePos,highwayTangent, highwayEdgeType, connectNode, connectNodePos, params, nextEdgeId, nextNodeId, isExit, junctionTangent, validate) 
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local onRampType = routeBuilder.getOnRampType()
	local exitAngle = util.getNumberOfStreetLanes(params.preferredHighwayRoadType) >= 5 and math.rad(60) or math.rad(45)
	local exitTangent = util.rotateXY(highwayTangent, isExit and -exitAngle or exitAngle)
	local dist = util.distance(highwayNodePos, connectNodePos)
	trace("Building highway onramp from ",highwayNode," to ",connectNode," isExit=",isExit)
	local edge = {
		p0 = highwayNodePos ,
		p1 = connectNodePos,
		t0 = dist*vec3.normalize(exitTangent),
		t1 = dist*vec3.normalize(junctionTangent)	,
	}
	dist = math.max(dist, util.calculateSegmentLengthFromNewEdge(edge))
	local connectTh = util.th(connectNodePos)
	local connectNodeNeedsBridge = connectNodePos.z - connectTh > 5 or connectTh < 0 
	local connectNodeNeedsTunnel = connectNodePos.z - connectTh < -5
	trace("Determined that connectNode needs bridge?",connectNodeNeedsBridge," needs tunnel?", connectNodeNeedsTunnel," based on connectNode height=",connectNodePos.z," and terrainHeight=",connectTh)
	local splitPoint 
	local t
	for i = 3, 9 do 
		t = i/12
		local nextSplitPoint = util.solveForPositionHermiteFraction(t, edge)
		local p = nextSplitPoint.p
		if highwayEdgeType == 1 ~= connectNodeNeedsBridge then 
			if p.z - util.th(p) <= 5 and splitPoint then 
				break 
			end
		elseif highwayEdgeType == 2 ~= connectNodeNeedsTunnel then 
			if p.z - util.th(p)  > -5 and splitPoint then 
				break 
			end
		elseif i >= 6 then 
			break 
		end
		splitPoint = nextSplitPoint
	end
	trace("Setting up onRamp, split at t=",t, "dist was ",dist)
	 
	local splitNode = util.newNodeWithPosition(splitPoint.p, nextNodeId())
	
	local entity = api.type.SegmentAndEntity.new()
	entity.entity = nextEdgeId()
	entity.type = 0 
	entity.streetEdge.streetType = onRampType
	entity.comp.type = highwayEdgeType
	if highwayEdgeType == 2 then 
		entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	elseif highwayEdgeType == 1 then 
		entity.comp.typeIndex = cement
	end 
	entity.comp.node0 = highwayNode
	entity.comp.node1 = splitNode.entity 
	util.setTangent(entity.comp.tangent0,t*dist*vec3.normalize(exitTangent)) 
	util.setTangent(entity.comp.tangent1,t*dist*vec3.normalize(splitPoint.t))
	table.insert(edgesToAdd, entity)
	local entity2 = api.type.SegmentAndEntity.new()
	entity2.entity = nextEdgeId()
	entity2.type = 0 
	entity2.comp.node0 = splitNode.entity 
	entity2.comp.node1 = connectNode
	entity2.streetEdge.streetType = onRampType
	if connectNodeNeedsTunnel then 
		entity2.comp.type = 2
		entity2.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	elseif connectNodeNeedsBridge then 
		entity2.comp.type = 1
		entity2.comp.typeIndex = cement
	end 
	if validate then 
		local testProposal = api.type.SimpleProposal.new() 
		testProposal.streetProposal.nodesToAdd[1]=splitNode 
		testProposal.streetProposal.edgesToAdd[1]=entity2 
		local result =  api.engine.util.proposal.makeProposalData(testProposal, util.initContext())
		if result.errorState.messages > 0 or result.errorState.critical then 
			if util.tracelog then debugPrint(result.errorState) end
			trace("Validation failed for building on ramp, rolling back") 
			table.remove(edgesToAdd)
			return 
		end
	end 
	util.setTangent(entity2.comp.tangent0,(1-t)*dist*vec3.normalize(splitPoint.t)) 
	util.setTangent(entity2.comp.tangent1,(1-t)*dist*vec3.normalize(highwayTangent))
	table.insert(nodesToAdd, splitNode)
	table.insert(edgesToAdd, entity2)
	if not isExit then
		util.reverseNewEntity(entity)
		util.reverseNewEntity(entity2)
	end
end

 
function routeBuilder.reconnectDepotAfter(depotPos, params)
	local depot
	for i, construction in pairs(util.searchForEntities(depotPos, 400 , "CONSTRUCTION")) do
		if string.find(construction.fileName, "depot/train") then 
			depot = construction.id
			break
		end
	end
	trace("Attempting to reconnect depot for ", depot)
	routeBuilder.buildDepotConnection(routeBuilder.standardCallback, depot, params)
end 


local function connectTerminalNode(nodesToAdd, edgesToAdd, edgesToRemove, routeInfo, index, unconnectedTerminalNode, params, terminalGap, nextNodeId, edgeObjectsToAdd, constructionsToRemove)

	local otherTerminalNode = util.findDoubleTrackNode(unconnectedTerminalNode)
	if not otherTerminalNode then 
		otherTerminalNode = util.findDoubleTrackNode(unconnectedTerminalNode, nil, 2)
	end
	local halfway = (routeInfo.lastFreeEdge+routeInfo.firstFreeEdge) / 2
	local isHigh = index > halfway
	local boundryIndex = isHigh and routeInfo.lastFreeEdge or routeInfo.firstFreeEdge
	trace("The otherTerminalNode was",otherTerminalNode, " the terminalGap was ",terminalGap)
	if otherTerminalNode then 
		local edge = routeInfo.edges[boundryIndex].edge
		local distBetweenNodes = math.min( util.distBetweenNodes(edge.node0, unconnectedTerminalNode), util.distBetweenNodes(edge.node1, unconnectedTerminalNode))
		trace("The distBetweenNodes was ",distBetweenNodes)
		if distBetweenNodes < 11 then 
			terminalGap = 1
			index  = boundryIndex
			 
		end
		if #util.getSegmentsForNode(edge.node0) < 3 and #util.getSegmentsForNode(edge.node1) < 3 then 
			trace("WARNING!, edge only has one connection, aborting ",routeInfo.edges[boundryIndex].id," nodes were",edge.node0,edge.node1) 
			return
		end
	end
	local edgeAndId = routeInfo.edges[index]
	if terminalGap <= 1 then 
			
		if edgeAndId.edge.node0 ~= otherTerminalNode and edgeAndId.edge.node1~=otherTerminalNode and terminalGap <=0 then
			otherTerminalNode = util.findDoubleTrackNode(unconnectedTerminalNode, nil, 2)
		end 
		if not (edgeAndId.edge.node0 == otherTerminalNode or edgeAndId.edge.node1==otherTerminalNode) then 
			trace("WARNING! otherTerminalNode="..otherTerminalNode.." not in "..edgeAndId.edge.node0.." or "..edgeAndId.edge.node1)
			return 
		end
		assert(edgeAndId.edge.node0 == otherTerminalNode or edgeAndId.edge.node1==otherTerminalNode, "otherTerminalNode="..otherTerminalNode.." not in "..edgeAndId.edge.node0.." or "..edgeAndId.edge.node1)
		local nextNode = edgeAndId.edge.node0 == otherTerminalNode and  edgeAndId.edge.node1 or edgeAndId.edge.node0 
		local foundDoubleSlipSwitch = false 
		if api.engine.getComponent(nextNode, api.type.ComponentType.BASE_NODE).doubleSlipSwitch or not util.findDoubleTrackNode(nextNode) then 
			local nextEdgeId = util.findNextEdgeInSameDirection(edgeAndId.id, nextNode)
		
			local nextEdge = util.getEdge(nextEdgeId)
			trace("Found doubleSlipSwitch, at ",nextNode," attempting to find node from edge",nextEdgeId)
			nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
			foundDoubleSlipSwitch = true
		end
		trace("Attempting to find next node from ",nextNode)
		local oppositeDirectionRouteInfo = pathFindingUtil.getRouteInfo(routeInfo.station2, routeInfo.station1)
		local nextNode2 = oppositeDirectionRouteInfo and oppositeDirectionRouteInfo.closestFreeNode(util.nodePos(nextNode)) or util.findDoubleTrackNode(nextNode)
		if foundDoubleSlipSwitch then -- can't use route info because it sometimes paths through the slipswitch 
			nextNode2 = util.findDoubleTrackNode(nextNode)
		end 
		if not nextNode2 then return end	
		
		local terminalVec = util.vecBetweenNodes(otherTerminalNode, unconnectedTerminalNode)
		local exitVec = util.vecBetweenNodes(nextNode, nextNode2)
		local connectNode 
		local angle = math.abs(util.signedAngle(terminalVec, exitVec))
		trace("the angle between the terminalVec and exitVec was ",math.deg(angle))
		if angle > math.rad(90) then
			connectNode = nextNode
		else 
			connectNode = nextNode2
		end
		local edgeToRemove = util.findEdgeConnectingNodes(connectNode, otherTerminalNode) 
		trace("relacing edge ",edgeToRemove," swapping ",otherTerminalNode, " with ", unconnectedTerminalNode)
		trace("found edgeToRemove = ", edgeToRemove, " connecting ",connectNode," with ",otherTerminalNode)
		if not edgeToRemove then return end
		table.insert(edgesToRemove, edgeToRemove)
		local newEdge = util.copyExistingEdgeReplacingNode(edgeToRemove, otherTerminalNode, unconnectedTerminalNode, -1-#edgesToAdd) 
		table.insert(edgesToAdd, newEdge)
		return 
	end 
	if not api.engine.entityExists(edgeAndId.id) or not util.getEdge(edgeAndId.id) then
		trace("WARNING! Edge",edgeAndId.id," was not a valid edge")
		return 
	end
	local newEdgeTemplate = util.copyExistingEdge(edgeAndId.id, -1-#edgesToAdd)
	local segs = util.getTrackSegmentsForNode(otherTerminalNode)
	local edgeToFollow = util.isFrozenEdge(segs[1]) and segs[2] or segs[1]
	if edgeToFollow then
		local railDepotId =  routeBuilder.constructionUtil.searchForRailDepot(util.nodePos(unconnectedTerminalNode), 100)
		if railDepotId then -- too difficult to keep a rail depot connected with this setup 
			trace("Found railDepot with id",railDepotId)
			table.insert(constructionsToRemove, railDepotId)
			local railDepot = util.getConstruction(railDepotId)
			local limit =5 
			local count = 0
			local nextEdgeId = railDepot.frozenEdges[1]
			local nextNode = util.getEdge(nextEdgeId).node1
			local nextSegs = util.getTrackSegmentsForNode(nextNode)
			
			repeat
				nextEdgeId = util.findNextEdgeInSameDirection(nextEdgeId, nextNode)
				if not nextEdgeId then 
					break 
				end
				if nextEdgeId == edgeToFollow then 
					trace("WARNING! Found edge to follow in the ndoes")
					break
				end 
				table.insert(edgesToRemove, nextEdgeId) 
				local nextEdge = util.getEdge(nextEdgeId)
				nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node1 
				nextSegs = util.getTrackSegmentsForNode(nextNode)
			
				count = count+1 
			until #nextSegs == 3 or count == limit 
			
		end 
	
		local edgeToFollowFull= util.getEdge(edgeToFollow)
		util.setTangent(newEdgeTemplate.comp.tangent0, edgeToFollowFull.tangent0)
		util.setTangent(newEdgeTemplate.comp.tangent1, edgeToFollowFull.tangent1)
	
		
		newEdgeTemplate.comp.type=edgeToFollowFull.type
		newEdgeTemplate.comp.typeIndex = edgeToFollowFull.typeIndex
		newEdgeTemplate.comp.objects = {}
		local isNode0 = edgeToFollowFull.node0 == otherTerminalNode
		local perpSign = 1
		local tangent = isNode0 and util.v3(edgeToFollowFull.tangent0) or  util.v3(edgeToFollowFull.tangent1)
		local testP = util.doubleTrackNodePoint(util.nodePos(otherTerminalNode), tangent) 
		if util.distance(testP, util.nodePos(unconnectedTerminalNode)) > util.distance(util.nodePos(otherTerminalNode), util.nodePos(unconnectedTerminalNode)) then 
			perpSign = -1
		end
		local edgeToFollowNodePos = isNode0 and util.nodePos(edgeToFollowFull.node1) or util.nodePos(edgeToFollowFull.node0)
		local newNode
		local entryTangent 
		local startZ = util.th(util.nodePos(unconnectedTerminalNode))
		local endZ = edgeToFollowNodePos.z 
		
		local canGoUnder = startZ - endZ < 5 and (util.th(edgeToFollowNodePos) > 0 or endZ > 15)
		trace("Can go under=",canGoUnder)
		local zoffset = canGoUnder and -10 or 10
		local newNodePos
		local uncorrectedEntryTangent
		if isNode0 then 
			newEdgeTemplate.comp.node0 = unconnectedTerminalNode 
			newNodePos = util.nodePointPerpendicularOffset(edgeToFollowNodePos,perpSign* util.v3(edgeToFollowFull.tangent1), 1.5*params.trackWidth) 
			newEdgeTemplate.comp.tangent1.z = zoffset/2
			entryTangent = -1*util.v3(edgeToFollowFull.tangent1)
			uncorrectedEntryTangent = util.v3(edgeToFollowFull.tangent1)
		else 
			newEdgeTemplate.comp.node1 = unconnectedTerminalNode 
			newNodePos = util.nodePointPerpendicularOffset(edgeToFollowNodePos,perpSign* util.v3(edgeToFollowFull.tangent0), 1.5*params.trackWidth)
			newEdgeTemplate.comp.tangent0.z = -zoffset/2
			entryTangent =  util.v3(edgeToFollowFull.tangent0)
			uncorrectedEntryTangent = entryTangent
		end 
		local theirOtherNode = isNode0 and edgeToFollowFull.node1 or edgeToFollowFull.node0 
		local theirNextEdgeId = util.findNextEdgeInSameDirection(edgeToFollow, theirOtherNode)
		if #util.getTrackSegmentsForNode(theirOtherNode)==4 then 
			
			for i, seg  in pairs(util.getTrackSegmentsForNode(theirOtherNode)) do 
				if seg ~= theirNextEdgeId and seg ~= edgeToFollow and not util.contains(edgesToRemove, seg) then 
					table.insert(edgesToRemove, seg)
				end
			end 
		end 
		 
		newNodePos.z = newNodePos.z + zoffset
		newNode = newNodeWithPosition(newNodePos, nextNodeId())
		table.insert(nodesToAdd, newNode)
		if isNode0 then 
			newEdgeTemplate.comp.node1 = newNode.entity
		else 
			newEdgeTemplate.comp.node0 = newNode.entity
		end
		
		table.insert(edgesToAdd, newEdgeTemplate)
		
		local startAt 
		local endAt 
		local keepNode
	
		local increment = isHigh and -1 or 1 
		local function edgeIsSuitable(edgeAndId) 
			local distToNode = util.distance(util.getEdgeMidPoint(routeInfo.edges[index].id), newNodePos)
			if distToNode < 90 then 
				return false 
			end 
			if util.calculateSegmentLengthFromEdge(edgeAndId.edge) < 70 then 
				return false 
			end
			if #util.getSegmentsForNode(edgeAndId.edge.node1) > 2 or  #util.getSegmentsForNode(edgeAndId.edge.node0) > 2 then 
				return false 
			end 
			return true
		end 
		
		while not edgeIsSuitable(routeInfo.edges[index] ) do
			index = index + increment
			trace("Edge was not suitable, trying next",index)
		end 
		
		
		
		if isHigh  then 
			 
			startAt = index 
			endAt = routeInfo.lastFreeEdge
			keepNode = routeInfo.edges[index].edge.node1 == routeInfo.edges[index-1].edge.node0 and routeInfo.edges[index].edge.node1 or routeInfo.edges[index].edge.node0
		else  
			startAt = routeInfo.firstFreeEdge
			endAt = index 
			keepNode = routeInfo.edges[index].edge.node1 == routeInfo.edges[index+1].edge.node0 and routeInfo.edges[index].edge.node1 or routeInfo.edges[index].edge.node0
		end
		local edgeToReplace = routeInfo.edges[index].id 
		local oppositeDirectionRouteInfo = pathFindingUtil.getRouteInfo(routeInfo.station2, routeInfo.station1)
		local doubleTrackNode = oppositeDirectionRouteInfo.closestFreeNode(util.nodePos(keepNode))
		
		local perpVec = util.vecBetweenNodes(doubleTrackNode, keepNode)
		local otherVec = util.vecBetweenNodes(unconnectedTerminalNode, otherTerminalNode)
		local isRightHanded = util.signedAngle(otherVec, util.getDeadEndNodeDetails(unconnectedTerminalNode).tangent) < 0
		local angle = util.signedAngle(perpVec, otherVec)
		local useDoubleTrackNode = math.abs(angle) < math.rad(90) 
		local intoStationRouteInfo = isHigh and routeInfo or oppositeDirectionRouteInfo
		local alternativeUseDoubleTrackNodeOld = isRightHanded ~=  intoStationRouteInfo.containsNode(keepNode)
		local alternativeUseDoubleTrackNode = isRightHanded ~=  isHigh
		trace("The angle between the perpVec and other vec was",math.deg(angle), " useDoubleTrackNode=",useDoubleTrackNode, " alternativeUseDoubleTrackNode=",alternativeUseDoubleTrackNode,"isRightHanded =",isRightHanded, " alternativeUseDoubleTrackNodeOld=",alternativeUseDoubleTrackNodeOld, " index=",index)
		if useDoubleTrackNode ~= alternativeUseDoubleTrackNode then 
			trace("WARNING! useDoubleTrackNode and alternativeUseDoubleTrackNode are in conflict")
		end
		--if math.abs(angle) > math.rad(135) or math.abs(angle)< math.rad(45) then 
			trace("Using alternativeUseDoubleTrackNode")
			useDoubleTrackNode = alternativeUseDoubleTrackNode
		--end
		
		
		local alreadySeenNodes = {}
		for i = startAt, endAt do 
			local edgeId = routeInfo.edges[i].id
			if useDoubleTrackNode then 
				local theirIndex = oppositeDirectionRouteInfo.getIndexOfClosestApproach(util.getEdgeMidPoint(edgeId))
				edgeId = oppositeDirectionRouteInfo.edges[theirIndex].id
				trace("TheirIndex was ",theirIndex," at ",i," for closet approach of edge",edgeId, "they had a total of ",#oppositeDirectionRouteInfo.edges,"edges")
			end
			trace("Removing edge",edgeId, " at i=",i )
			if not util.contains(edgesToRemove, edgeId) then 
				table.insert(edgesToRemove, edgeId)
			end
			local edge = util.getEdge(edgeId)
			for __, node in pairs({edge.node0, edge.node1}) do 
				if not alreadySeenNodes[node] then 
					alreadySeenNodes[node]=true 
					local edgeToKeep 
					local edgeToRemove 
					local replacementNode 
					local otherTangent 
					local isNode0 
					-- we are not allowed to leave a street segment in place for the gap between double track edges
					for __, seg in pairs(util.getStreetSegmentsForNode(node)) do 
						local edge = util.getEdge(seg) 
						isNode0 = node == edge.node0
						local otherNode =  isNode0 and edge.node1 or edge.node0 
						if #util.getTrackSegmentsForNode(otherNode) > 0 then 
							trace("Found another grade crossing")
							edgeToRemove = seg
							replacementNode = otherNode
							otherTangent = util.v3(otherNode == edge.node0 and edge.tangent0 or edge.tangent1)
						else 
							edgeToKeep = seg 
						end 
					end 
					if edgeToRemove then 
						table.insert(edgesToRemove, edgeToRemove)
						if edgeToKeep then 
							local replacementEdge = util.copyExistingEdge(edgeToKeep, -1-#edgesToAdd)
							if replacementEdge.comp.node0 == node then 
								replacementEdge.comp.node0 = replacementNode
								--util.setTangent(replacementEdge.comp.tangent0, isNode0 and -1*otherTangent or otherTangent)
							else 
								assert(replacementEdge.comp.node1 == node)
								replacementEdge.comp.node1 = replacementNode
								--util.setTangent(replacementEdge.comp.tangent1, isNode0 and otherTangent or -1*otherTangent)
							end 
						
							util.correctTangentLengths(replacementEdge)
							trace("Replacing edge for ",edgeToKeep," the node was",node," the replacementNode was",replacementNode)
							table.insert(edgesToRemove, edgeToKeep)
							table.insert(edgesToAdd, replacementEdge)
						end 
					end 
				end 
			end 
			
		end 
	
		if useDoubleTrackNode then 
			edgeToReplace = oppositeDirectionRouteInfo.edges[oppositeDirectionRouteInfo.getIndexOfClosestApproach(util.getEdgeMidPoint(edgeToReplace))].id
			keepNode = doubleTrackNode 
		end 
		local replacementEdge = util.copyExistingEdge(edgeToReplace, -1-#edgesToAdd)
		replacementEdge.comp.objects = {}
		table.insert(edgesToAdd, replacementEdge)
		local nodeToReplace = keepNode == replacementEdge.comp.node0 and replacementEdge.comp.node1 or replacementEdge.comp.node0 
		local nodePos = util.nodePos(nodeToReplace)
		nodePos.z = nodePos.z+ zoffset
		local newNode2 = newNodeWithPosition(nodePos, nextNodeId())
		table.insert(nodesToAdd, newNode2)
		local exitTangent 
		local actualExitTangent
		if keepNode == replacementEdge.comp.node0 then 
			replacementEdge.comp.node1 = newNode2.entity 
			replacementEdge.comp.tangent1.z = zoffset/2
			exitTangent = util.v3(replacementEdge.comp.tangent1)
			actualExitTangent = exitTangent
		else 
			replacementEdge.comp.node0 = newNode2.entity 
			replacementEdge.comp.tangent0.z = -zoffset/2
			exitTangent =  -1*util.v3(replacementEdge.comp.tangent0)
			actualExitTangent = util.v3(replacementEdge.comp.tangent0)
		end
--		local leftHandAngle = util.signedAngle(perpVec, actualExitTangent) 
		local leftHandAngle = util.signedAngle(otherVec, util.getDeadEndNodeDetails(unconnectedTerminalNode).tangent)
		local isLeft = leftHandAngle < 0
		trace("The leftHandAngle was ",math.deg(leftHandAngle)," isLeft=",isLeft, "isNode0=",isNode0, "unconnectedTerminalNode=",unconnectedTerminalNode )
		local relativeAngleChange = math.abs(util.signedAngle(entryTangent ,exitTangent))
		local naturalTangent = nodePos - newNodePos  
		local relativeAngleChange2 = math.abs(util.signedAngle(entryTangent ,naturalTangent))
		local relativeAngleChange3 = math.abs(util.signedAngle(exitTangent ,naturalTangent))
		local maxAngleChange = math.max(relativeAngleChange,math.max(relativeAngleChange2, relativeAngleChange3))
		local isAdverseAngle =  maxAngleChange > math.rad(60)
		trace("The relativeAngleChange was ",math.deg(relativeAngleChange),math.deg(relativeAngleChange2),math.deg(relativeAngleChange3)," isAdverseAngle?",isAdverseAngle," maxAngleChange=",math.deg(maxAngleChange))
		if isAdverseAngle then 
			local rotation = -util.signedAngle(entryTangent ,naturalTangent)
			local maxRotation = math.rad(15)
			rotation = math.min(maxRotation, math.max(rotation, -maxRotation))
			entryTangent = util.rotateXYkeepingZ(entryTangent, rotation)
			trace("Attempting to correct with rotation",math.deg(rotation), " isNode0=",isNode0,"unconnectedTerminalNode=",unconnectedTerminalNode)
			if isNode0 then 	
				util.setTangent(newEdgeTemplate.comp.tangent1, util.rotateXYkeepingZ(newEdgeTemplate.comp.tangent1, rotation))  
			else 
				util.setTangent(newEdgeTemplate.comp.tangent0, util.rotateXYkeepingZ(newEdgeTemplate.comp.tangent0, rotation))  
			end 

		end 
		
		buildSignal(edgeObjectsToAdd, newEdgeTemplate, isLeft ==  isNode0, 0.5)	
		local length = util.calculateTangentLength(newNodePos, nodePos, exitTangent, entryTangent)
		local connectEdge = copySegmentAndEntity(replacementEdge, -1-#edgesToAdd)
		connectEdge.comp.objects = {}
		connectEdge.comp.node0 = newNode2.entity 
		connectEdge.comp.node1 = newNode.entity 
		setTangent(connectEdge.comp.tangent0, length*vec3.normalize(exitTangent))
		setTangent(connectEdge.comp.tangent1, length*vec3.normalize(entryTangent))
		local theirNextEdge = util.getEdge(theirNextEdgeId)
	
		trace("Added the connect edge with entity", connectEdge.entity)
		table.insert(edgesToAdd, connectEdge)
		
		--if length > 2*params.targetSeglenth then 
		trace("Splitting the edge") 
		local solution =  util.solveForPositionHermiteFraction2(0.5, nodePos, util.v3(connectEdge.comp.tangent0), newNodePos, util.v3(connectEdge.comp.tangent1))
		local startingBridge = util.th(nodePos) < 0
		local endingBridge = util.th(newNodePos) < 0
		if startingBridge ~= endingBridge then 
			trace("Searching for bridge portal, startingBridge=",startingBridge," endingBridge=",endingBridge)
			local nextSolution  
			for i = 6, 26 do 
				nextSolution = util.solveForPositionHermiteFraction2(i/32, nodePos, util.v3(connectEdge.comp.tangent0), newNodePos, util.v3(connectEdge.comp.tangent1))
				local needsBridge = util.th(nextSolution.p) < 0
				trace("Inspecting point at ",nextSolution.p.x, nextSolution.p.y, "needsBridge?",needsBridge)
				if not startingBridge then 
					if needsBridge then 
						trace("Found the bridge portal at i=",i)
						break 
					else 
						solution = nextSolution
					end 
				else 
					if not needsBridge then 
						solution = nextSolution
						trace("Found the bridge portal at i=",i)
						break 
					else 
					
					end 
				end 
			
			end 
		end 
		
		local midPoint = newNodeWithPosition(solution.p, nextNodeId())
		table.insert(nodesToAdd, midPoint)
		local secondEdge = copySegmentAndEntity(connectEdge, -1-#edgesToAdd)
		
		connectEdge.comp.node1 = midPoint.entity 
		secondEdge.comp.node0 = midPoint.entity
		setTangent(connectEdge.comp.tangent0, solution.t0)
		setTangent(connectEdge.comp.tangent1, solution.t1)	
		setTangent(secondEdge.comp.tangent0, solution.t2)
		setTangent(secondEdge.comp.tangent1, solution.t3)
		table.insert(edgesToAdd, secondEdge)
		--end
		
		if theirNextEdge.type == 1 or util.th(nodePos)<0 or util.th(solution.p)<0 or not canGoUnder then 
			if solution.p.z-util.th(solution.p)> 10 and nodePos.z-util.th(nodePos) > 10 or util.th(nodePos)<0 or util.th(solution.p)<0 or not canGoUnder then 
				connectEdge.comp.type = 1 
				connectEdge.comp.typeIndex = theirNextEdge.type == 1  and theirNextEdge.typeIndex or isIronBridgeAvailable() and api.res.bridgeTypeRep.find("iron.lua") or api.res.bridgeTypeRep.find("stone.lua")
			end 
		else 
			connectEdge.comp.type = 2 
			connectEdge.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
		end
		
		if solution.p.z-util.th(solution.p)> 10 and newNodePos.z-util.th(newNodePos) > 10 or util.th(newNodePos)<0 or util.th(solution.p)<0 or not canGoUnder then 
			secondEdge.comp.type = 1 
			secondEdge.comp.typeIndex = theirNextEdge.type == 1 and theirNextEdge.typeIndex or isIronBridgeAvailable() and api.res.bridgeTypeRep.find("iron.lua") or api.res.bridgeTypeRep.find("stone.lua")
		elseif theirNextEdge.type ~= 1 then 
			secondEdge.comp.type = 2 
			secondEdge.comp.typeIndex = api.res.tunnelTypeRep.find("railroad_old.lua")
		else 
			secondEdge.comp.type = 0
			secondEdge.comp.typeIndex = -1	
		end		
		
	end	
		
end


local function tryConnectTerminalNodes(routeInfo, callback, params, terminalGap, attemptNumber)
	
	if not params then params = paramHelper.getDefaultRouteBuildingParams() end
	trace("connecting terminal nodes")
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local constructionsToRemove = {}
	local nextId = -1000
	local function nextNodeId() 
		nextId = nextId - 1
		return nextId
	end 
	local offset = terminalGap > 1 and 2+attemptNumber or 0
	if routeInfo.firstUnconnectedTerminalNode and #util.getSegmentsForNode(routeInfo.firstUnconnectedTerminalNode)==1 then 
		trace("connecting firstUnconnectedTerminalNode ",routeInfo.firstUnconnectedTerminalNode , " segmentsForNode?", #util.getSegmentsForNode(routeInfo.firstUnconnectedTerminalNode))
		connectTerminalNode(nodesToAdd, edgesToAdd, edgesToRemove, routeInfo,routeInfo.firstFreeEdge+offset, routeInfo.firstUnconnectedTerminalNode, params, terminalGap, nextNodeId, edgeObjectsToAdd, constructionsToRemove)
	end
	if routeInfo.lastUnconnectedTerminalNode and #util.getSegmentsForNode(routeInfo.lastUnconnectedTerminalNode)==1 then
		trace("connecting lastUnconnectedTerminalNode",routeInfo.lastUnconnectedTerminalNode , "segments for node", #util.getSegmentsForNode(routeInfo.lastUnconnectedTerminalNode))
		connectTerminalNode(nodesToAdd, edgesToAdd, edgesToRemove, routeInfo, routeInfo.lastFreeEdge-offset, routeInfo.lastUnconnectedTerminalNode, params, terminalGap,nextNodeId, edgeObjectsToAdd, constructionsToRemove)
	end
	local newProposal = routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove)
	--newProposal.constructionsToRemove = constructionsToRemove
	local proposalData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
	if proposalData.errorState.critical and util.tracelog then
		trace("Critical error seen in connectTerminalNodes")
		debugPrint(proposalData.errorState)
		debugPrint(newProposal)
		return false
		--routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove , true)
	end 
	
	if util.tracelog then debugPrint(newProposal) end
	util.clearCacheNode2SegMaps()
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
	api.cmd.sendCommand(build, callback)
	if #constructionsToRemove > 0 then -- turns out removing constructions with edges causes issues when mixed in with other edge add/remove
		routeBuilder.addWork(function() 
			local newProposal = api.type.SimpleProposal.new() 
			newProposal.constructionsToRemove = constructionsToRemove
			local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
			api.cmd.sendCommand(build, routeBuilder.standardCallback)
		end)
	end 
	trace("Connection complete")
	return true
end

local function connectTerminalNodes(routeInfo, callback, params, terminalGap)
	util.cacheNode2SegMaps()
	for i = 1, 6 do 
		local success =  tryConnectTerminalNodes(routeInfo, callback, params, terminalGap, i)
		if success then 
			break 
		end
	end 
	if not success then 
		callback({}, false)
	end
end 



function routeBuilder.getIndexOfClosestApproach(routeInfo, p)
	local options = {} 
	for i =1, #routeInfo.edges do 
		table.insert(options, 
			{
				idx =i ,
				scores = { util.distance(p, util.getEdgeMidPoint(routeInfo.edges[i].id))}
			})
	end 
	return util.evaluateWinnerFromScores(options).idx
end 


local function getDeadEndNodesInVicinity(nodePos, range) 
	local result = {}
	if not range then range =350 end
	for i, node in pairs(util.searchForEntities(nodePos, range, "BASE_NODE")) do
		local edges = util.getTrackSegmentsForNode(node.id)
		if #edges == 1 and -1 == api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edges[1]) then
			table.insert(result, node.id)
		end
	end
	trace("found ",#result," dead end nodes near ", nodePos.x,nodePos.y)
	return result
end


function routeBuilder.tryRoadRouteForUpgrade(routeInfo, callback, params) 
	trace("Begin road route upgrade, the street type was ",params.preferredCountryRoadType, " smoothingPasses was ",params.smoothingPasses)
	local routeSections = {}
	local allEdgeIds = {}
	util.lazyCacheNode2SegMaps()
	local currentSectionStreetCategory
	local currentRouteSection
	local currentSectionBackwards
	local currentSectionIsBridge = false
	local currentSectionIsTunnel = false

	if not routeInfo then 
		trace("WARNING! no routeInfo found") 
		return false 
	end
	if params.addBusLanes then 
		params.preferredCountryRoadType=params.preferredCountryRoadTypeWithBus
		params.preferredUrbanRoadType = params.preferredUrbanRoadTypeWithBus
	end 
	trace("About to get edge",routeInfo.firstFreeEdge, " of a total of ",#routeInfo.edges)
	local firstEdge = routeInfo.edges[routeInfo.firstFreeEdge].edge
	local preferredCountryStreetType = api.res.streetTypeRep.find(params.preferredCountryRoadType)
	local preferredCountryStreetWidth = util.getStreetWidth(preferredCountryStreetType)
	local preferredUrbanRoadType = api.res.streetTypeRep.find(params.preferredUrbanRoadType)
	local preferredUrbanStreetWidth = util.getStreetWidth(preferredUrbanRoadType)
 
 
	local nodesToAdd = {}
	local edgesToAdd = {}
	local edgeObjectsToAdd = {}
	local edgesToRemove = {}
	local edgeObjectsToRemove = {}
	


	local function isValid()
		local edgesToAddCopy = {} -- copy in case we rollback
		for i, edge in pairs(edgesToAdd) do 	
			table.insert(edgesToAddCopy, copySegmentAndEntity(edge, edge.entity)) -- cant use deepClone because of userdata 
		end 
		local newProposal = false 
		pcall(function() newProposal = routeBuilder.setupProposal(nodesToAdd, edgesToAddCopy, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) end)
		if not newProposal then 
			return false 
		end
		local testData =  api.engine.util.proposal.makeProposalData(newProposal, util.initContext())
		if testData.errorState.critical then
			if util.tracelog then 
				debugPrint(testData.collisionInfo)
				debugPrint(testData.errorState)
				debugPrint(newProposal)
			end
			trace("Critical error seen in the test data")
			return false 
		elseif #testData.errorState.messages > 0 and not (params.ignoreErrors or params.tramOnlyUpgrade) then
			if util.tracelog then 
				debugPrint(testData.collisionInfo)
				debugPrint(testData.errorState)
			end
			trace("Ignorable error seen in the test data")		
			return false
		end 
		return true
	end
	
	local function nextEdgeId() 
		return -1-#edgesToAdd
	end
	
	local replacedEdgesMap = {}  
	
	local function getOrMakeReplacedEdge(edgeId)  
		if  not replacedEdgesMap[edgeId] then  
			local entity = util.copyExistingEdge(edgeId, nextEdgeId())
			table.insert(edgesToRemove, edgeId)
			table.insert(edgesToAdd, entity)
			replacedEdgesMap[edgeId]=entity
	 
		end
		return replacedEdgesMap[edgeId]
	end
	
	local function initEntity(edgeId)
		local entity = getOrMakeReplacedEdge(edgeId)  
		trace("Replacing ",edgeId," with",entity.entity)
		local streetCategory = util.getStreetTypeCategory(edgeId)
		local preferredStreetType
		if (streetCategory == "urban" or streetCategory == "country") and not params.tramOnlyUpgrade then 
			if streetCategory == "urban" then 
				preferredStreetType = preferredUrbanRoadType
			else 
				preferredStreetType = preferredCountryStreetType
			end 
			if util.getStreetWidth(preferredStreetType) < util.getStreetWidth(entity.streetEdge.streetType) then 
				preferredStreetType = entity.streetEdge.streetType -- don't downgrade
			end
		else 
			preferredStreetType = entity.streetEdge.streetType 
		end
		entity.streetEdge.streetType = preferredStreetType
		if not params.tramOnlyUpgrade then 
			entity.streetEdge.hasBus = entity.streetEdge.hasBus or params.addBusLanes 
		end
		entity.streetEdge.tramTrackType = math.max(entity.streetEdge.tramTrackType, params.tramTrackType)
		return entity
	end
	
	local nextNodeId = -1000
	local function getNextNodeId() 
		nextNodeId = nextNodeId-1
		return nextNodeId
	end
	
	local alreadySeen = {}
 
	local skipValidation = params.tramTrackType > 0 -- requires all sections to upgrade
	 
	
	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
		local entity = initEntity(routeInfo.edges[i].id)
		if not skipValidation and not isValid() then 
			local failedEdges = {}
				 
			table.insert(failedEdges, { 
				edgeToAdd = table.remove(edgesToAdd),
				edgeToRemove = table.remove(edgesToRemove)
			})
				 
			routeBuilder.addWork(function() 
				for __, failedEdge in pairs(failedEdges) do 
					if failedEdge.edgeToAdd.comp.node0 > 0 and failedEdge.edgeToAdd.comp.node1 > 0 and api.engine.entityExists(failedEdge.edgeToRemove) and util.getEdge(failedEdge.edgeToRemove) then 
						trace("Attempting individual upgrade for ",failedEdge.edgeToRemove)
						local proposal = api.type.SimpleProposal.new() 
						proposal.streetProposal.edgesToAdd[1] = failedEdge.edgeToAdd
						proposal.streetProposal.edgesToRemove[1] = failedEdge.edgeToRemove
						local build = api.cmd.make.buildProposal(proposal, util.initContext(), true)
						api.cmd.sendCommand(build, function(res, success) 
							trace("Attempt of individula upgrade to edge",failedEdge.edgeToRemove," was ",success)
						end)
					end 
				end 
				util.clearCacheNode2SegMaps()
			end)
		end
	end 
	 
  
	if not isValid() then 
		debugPrint({nodesToAdd=nodesToAdd, edgesToAdd=edgesToAdd})
		return false
	end
 
	local newProposal = routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove) 
	--if util.tracelog then debugPrint(newProposal) end
	trace("About to build command to build street upgrade")
	
	local ignoreErrors = (params.ignoreErrors or params.tramOnlyUpgrade) and true or false -- need explicit boolean type
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), ignoreErrors)
	trace("Built proposal now to send command to build street upgrade")
	api.cmd.sendCommand(build, callback)
	util.clearCacheNode2SegMaps()
	trace("Send command to build street upgrade")
	return true
end
local function checkForHighwayJunction(edge)
	 
	for i, node in pairs({edge.node0, edge.node1}) do
		local segs = util.getStreetSegmentsForNode(node)
		if #segs >= 3 then 
			for j, seg in pairs(segs) do 
				if util.getStreetTypeCategory(seg)~="highway" then 
					return true 
				end
 			end 
		end
	end
	return false 
end

function routeBuilder.checkForNearbyHighwayAtPosition(callback, params, p, p2)
	util.cacheNode2SegMapsIfNecessary() 
	local options = {}
	for edgeId, edge in pairs(util.searchForEntities(p, 750, "BASE_EDGE")) do 
		if not edge.track and util.getStreetTypeCategory(edgeId)=="highway" then 
			if checkForHighwayJunction(edge)  then 
				return
			end
			if #util.getStreetSegmentsForNode(edge.node0)==2 and #util.getStreetSegmentsForNode(edge.node1)==2 and util.findParallelHighwayEdge(edgeId) and util.distance(p, util.getEdgeMidPoint(edgeId)) > 100 and not util.searchForFirstEntity(util.getEdgeMidPoint(edgeId), 200, "SIM_BUILDING") then
				table.insert(options, {
					edgeId=edgeId, 
						scores={
							util.distance(p, util.getEdgeMidPoint(edgeId)),
							util.distance(p2, util.getEdgeMidPoint(edgeId)),
					}
				})
			end
		end
	end 
	if #options == 0 then 
		return false
	end 
	if util.tracelog then debugPrint({highwayJunctionOptions=options}) end
	local edgeId = util.evaluateWinnerFromScores(options, {60,40}).edgeId
	local midPoint = util.getEdgeMidPoint(edgeId)
	local wrappedCallback = function(res, success)
		if success then
			routeBuilder.addWork(function()
				local roadNode = util.searchForNearestNode(p, 100, function(node) return #util.getStreetSegmentsForNode(node.id) == 1 and not util.isFrozenNode(node.id) end)
				if not roadNode then 
					roadNode = util.searchForNearestNode(p, 100, function(node) return #util.getStreetSegmentsForNode(node.id) > 0 and not util.isFrozenNode(node.id) end)
				end
				local otherNodes = util.searchForDeadEndNodes(midPoint, 100, false, function(node) return node ~= roadNode.id end)
				if #otherNodes == 0 then 
					callback(res, true)
					return					
				end
				local nodePair = findShortestDistanceNodePair({roadNode.id}, otherNodes, params)
				trace("The roadNode was ",roadNode," the number of other nodes was ",#otherNodes," nodePair was ",nodePair)
				routeBuilder.buildRoute(routeEvaluation.evaluateRoadRouteOptions(nodePair, nil, params), params, callback)
			end)
		else 
			callback(res, true)-- pass back true because this should not block the building of the next stage
		end
	end 
		
	routeBuilder.buildHighwayJunction(edgeId, params, wrappedCallback)
	return true
end

function routeBuilder.checkForNearbyHighway(callback, params, routeFn, stations) 
	local p1
	local p2
	if stations then 
		p1 = util.getStationPosition(stations[1])
		p2 = util.getStationPosition(stations[2])
	else 
		local routeInfo = routeFn()
		if not routeInfo then 
			trace("WARNING! No routeInfo found in checkForNearbyHighway")
			return
		end 
		p1 = util.getEdgeMidPoint(routeInfo.edges[1].id)
		p2 =  util.getEdgeMidPoint(routeInfo.edges[#routeInfo.edges].id) 
	end 
	local found = routeBuilder.checkForNearbyHighwayAtPosition(callback, params, p1, p2)
	found = routeBuilder.checkForNearbyHighwayAtPosition(callback, params, p2, p1) or found 
	return found
end 
function routeBuilder.checkRoadLineForUpgrade(callback, params, lineId)
	local line = util.getLine(lineId)
	for i = 1, #line.stops do
		local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
		local stop = line.stops[i]
		local priorStation = util.stationFromStop(priorStop)
		local station = util.stationFromStop(stop)
		routeBuilder.constructionUtil.checkStationForUpgrades(priorStation, params)
		routeBuilder.constructionUtil.checkStationForUpgrades(station, params)
		routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgrade(callback, params, 
			function() 
				return pathFindingUtil.getRoadRouteInfoBetweenStations(priorStation, station) 
			end,
			{priorStation, station})
		end) 
		
		if #line.stops ==2 then 
			break
		end 
			
	end
end 
function routeBuilder.checkRoadRouteForUpgrade(callback, params, routeFn, stations) 
	trace("Begin checking route for upgrade")
	util.lazyCacheNode2SegMaps()
	 
	 
 
	local originalPreferredCountryRoadType = params.preferredCountryRoadType
	if util.getStreetWidth(params.preferredCountryRoadType) > 16 then 
		params.preferredCountryRoadType = util.year() >= 1925 and "standard/country_medium_new.lua" or "standard/country_medium_old.lua"
		trace("Doing initial upgrade with ",params.preferredCountryRoadType, " then ",originalPreferredCountryRoadType)
		params.firstPass = true
	end  
	if not routeFn() then 
		trace("WARNING! no route info found, aborting")
		callback({}, false)
		return 
	end
	
 
	local success = routeBuilder.tryRoadRouteForUpgrade(routeFn(), callback, params)   
	if success then 
		if originalPreferredCountryRoadType ~= params.preferredCountryRoadType then 
			util.lazyCacheNode2SegMaps()
			params.firstPass =  false
			params.preferredCountryRoadType = originalPreferredCountryRoadType
			success = routeBuilder.tryRoadRouteForUpgrade(routeFn(), callback, params)   
		end 
	end
  
	if not success and params.tramTrackType > 0 then 
		trace("Attempting tram only upgrade") 
		params.tramOnlyUpgrade = true 
		success= routeBuilder.tryRoadRouteForUpgrade(routeFn(), callback, params)  
		if success then 
			local newParams = util.deepClone(params) 
			newParams.tramTrackType = 0
			newParams.tramOnlyUpgrade = false 
			routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgrade(routeBuilder.standardCallback, newParams, routeFn, stations)end ) -- try to upgrade the remianing route
		end
		
	end
	
	if not success then 
		callback({}, false)
	end
	util.clearCacheNode2SegMaps()
	
end 

function routeBuilder.checkRoadRouteForUpgradeBetweenNodes(node1, node2, params) 
	trace("Checking for upgrades between nodes ",station, node)
	
	 
	routeBuilder.checkRoadRouteForUpgrade(routeBuilder.standardCallback, params, function() return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenNodes(node1, node2)) end) 
end

function routeBuilder.checkRoadRouteForUpgradeBetweenStationAndNode(station, node, params, nodePos)
	trace("Checking for upgrades between nodes ",station, node)
	
	 
	routeBuilder.checkRoadRouteForUpgrade(routeBuilder.standardCallback, params, function() return pathFindingUtil.getRouteInfoFromEdges(pathFindingUtil.findRoadPathBetweenStationAndNode(station, node, nodePos)) end) 
end
 
function routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, callback, params, isCircle) 
	
	local function routeInfoFn() 
		local startFrom = isCircle and 1 or 2
		startFrom = 1
		local result = {}
		result.edges = {}
		local alreadySeen = {}
		for i = startFrom, #stations do
			local priorStation = i == 1 and stations[#stations] or stations[i-1]
			local routeInfo =  pathFindingUtil.getRoadRouteInfoBetweenStations(priorStation, stations[i])
			for j = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
				if not alreadySeen[routeInfo.edges[j].id]  then 
					table.insert(result.edges, routeInfo.edges[j])
					alreadySeen[routeInfo.edges[j].id] = true 
				end
				if i == #stations and j == routeInfo.lastFreeEdge then 
					result.lastFreeEdge = #result.edges
				end 
			end 
			if i == startFrom then 
				result.firstFreeEdge = routeInfo.firstFreeEdge
			end
		end
		return result
	end 
	routeBuilder.checkRoadRouteForUpgrade(callback, params, routeInfoFn, stations) 
end 

function routeBuilder.buildRoadRouteBetweenStations(stations, callback, params,result, hasEntranceB, index)
	util.lazyCacheNode2SegMaps()
	local nodePair
	if params.isCargo then 
		if result.needsTranshipment1 and index ==1  then
			local leftNodes = util.getAllFreeNodesForStation(stations[1])
			local otherPos = { position = util.v3ToArr(util.getStationPosition(stations[1])) }
			local rightNodes = { connectEval.getBestNodeForIndusty(result.industry1, otherPos, hasEntranceB[1]) }
			nodePair = util.findShortestDistanceNodePair(leftNodes, rightNodes)
			params.alreadyCheckedForHighway = true -- disable creating highway connections
		elseif result.needsTranshipment2 and index ==2  then
			--local leftNodes = util.getAllFreeNodesForStation(result.industry2.type=="TOWN" and stations[1] or stations[2])
			--local otherPos = { position = util.v3ToArr(util.getStationPosition(stations[1])) }
			--local rightNodes = { connectEval.getBestNodeForIndusty(result.industry2, otherPos, hasEntranceB[2]) }
			local leftNodes = util.getAllFreeNodesForStation(stations[1])
			local otherPos = { position = util.v3ToArr(util.getStationPosition(stations[1])) }
			local rightNodes = { connectEval.getBestNodeForIndusty(result.industry2, otherPos, hasEntranceB[2]) }
			nodePair = util.findShortestDistanceNodePair(leftNodes, rightNodes)
			params.alreadyCheckedForHighway = true 
		else  
			nodePair = connectEval.findNodePairForResult(result, hasEntranceB)
		end
	else 
		local town1 =  api.engine.system.stationSystem.getStation2TownMap()[stations[1]]
		local town2 =  api.engine.system.stationSystem.getStation2TownMap()[stations[2]]
		nodePair = { connectEval.findBestConnectionNodeForTown(town1, town2), connectEval.findBestConnectionNodeForTown(town2, town1)}
	end
	local routeFn = function() return pathFindingUtil.getRoadRouteInfoBetweenStations(stations[1], stations[2]) end
	local function wrappedCallback(res, success) 
		params.alreadyCheckedForHighway = true
		if success then
			routeBuilder.addDelayedWork(function() 
				local routeInfo = routeFn()
				trace("after construction of the highway the routeInfo was ",routeInfo)
				if routeInfo then 
					routeBuilder.checkRoadRouteForUpgrade(callback, params, routeFn, stations) 
				else
					routeBuilder.buildRoadRouteBetweenStations(stations, callback, params,result, hasEntranceB)
				end
				
			end)
		else
			callback(res, success)
		end
	end
	if not params.alreadyCheckedForHighway and routeBuilder.checkForNearbyHighway(wrappedCallback, params, routeFn, stations) then
		return 
	end

	local newNodePair = routeEvaluation.evaluateRoadRouteOptions(nodePair, stations, params)
	local nodePos1 = util.nodePos(newNodePair[1])
	local nodePos2 = util.nodePos(newNodePair[2])
	local function wrappedCallback(res, success) 
		if success then 
			if nodePair[1]~=newNodePair[1] then 
				routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgradeBetweenStationAndNode(stations[1], newNodePair[1], params, nodePos1) end)
			end
			if nodePair[2]~=newNodePair[2] then 
				routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgradeBetweenStationAndNode(stations[2], newNodePair[2], params, nodePos2) end)
			end
		
		end
		callback(res, success)
	end
	if newNodePair[1] == newNodePair[2] then 
		trace("new node pair had the same node, skipping routebuild")
		wrappedCallback({}, true)
	else 	
		routeBuilder.buildRoute(newNodePair, params, wrappedCallback)
	end
end

function routeBuilder.buildHighway(town1, town2, callback, params)
	util.lazyCacheNode2SegMaps()
	local town1SearchPos = util.v3fromArr(town1.position)
	local town2SearchPos = util.v3fromArr(town2.position)
	if params.searchMap then 
		if params.searchMap[town1.id] then 
			town1SearchPos = params.searchMap[town1.id]
		end
		if params.searchMap[town2.id] then 
			town2SearchPos = params.searchMap[town2.id]
		end
	end
	local vecBetweenTowns = town2SearchPos-town1SearchPos
	local distBetweenTowns = vec3.length(vecBetweenTowns)
    local searchRadius = math.min(750, distBetweenTowns/2.1)
	params.isHighway=true 
	params.isDoubleTrack = true
	params.routeDeviationPerSegment = 30
	params.edgeWidth = 2*util.getStreetWidth(params.preferredHighwayRoadType)+params.highwayMedianSize
	params.maxGradient = paramHelper.getParams().maxGradientHighway
	params.routeScoreWeighting = util.deepClone(paramHelper.getParams().routeScoreWeighting) -- reset to standard track route scores
	local function getFilterFn(town)
		return function(node) 
			local townNode = util.searchForNearestNode(town.position, 150, function(node) return #util.getTrackSegmentsForNode(node.id)==0 end).id
			return #pathFindingUtil.findRoadPathBetweenNodes(townNode, node) > 0 or #pathFindingUtil.findRoadPathBetweenNodes(node, townNode) > 0
		end
	end
	local deadEndNodesLeft = util.searchForDeadEndHighwayNodes(town1SearchPos, searchRadius, getFilterFn(town1)) 
	local deadEndNodesRight = util.searchForDeadEndHighwayNodes(town2SearchPos, searchRadius,getFilterFn(town2)) 
	local midPoint = town1SearchPos+0.5*vecBetweenTowns
	local midSearchRadius = math.max(1000,  distBetweenTowns/2.1)
	
	local function notInLeftOrRight(node) 
		return not util.contains(deadEndNodesLeft, node) and not util.contains(deadEndNodesRight, node)
	end
	local deadEndNodesMid = util.searchForDeadEndHighwayNodes(midPoint, midSearchRadius, notInLeftOrRight) 
	if #deadEndNodesMid >=4 then 
		local trialLeftNodePair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesMid, params)	
		local trialRightNodePair = findShortestDistanceNodePair(deadEndNodesMid, deadEndNodesRight, params)	
		trace("Inspecting possible mid point node route")
		if util.tracelog then debugPrint({trialLeftNodePair=trialLeftNodePair, trialRightNodePair=trialRightNodePair, deadEndNodesLeft=deadEndNodesLeft, deadEndNodesRight=deadEndNodesRight}) end
		if pathFindingUtil.validateHighwayPathFromNodes(trialLeftNodePair[2], trialRightNodePair[1]) then 
			trace("DID Find path using mid point nodes")
			local count =0 
			local wrappedCallback = function(res, success)
				if success then 
					count = count+1 
					if count == 2 then 	
						callback(res, success)
					end
				else 
					callback(res, success)
				end 
			end 
			routeBuilder.addWork(function() routeBuilder.buildRoute(trialLeftNodePair, params, wrappedCallback) end)
			routeBuilder.addWork(function() routeBuilder.buildRoute(trialRightNodePair, params, wrappedCallback) end)
			return
		else	 
			trace("Unable to find path using mid point nodes")
		end 
	end 
	
	
	trace("Building highway, found ",#deadEndNodesLeft, " and ", #deadEndNodesRight)
	local nodePair = findShortestDistanceNodePair(deadEndNodesLeft, deadEndNodesRight, params)	
	routeBuilder.buildRoute(nodePair, params, callback)
end

function routeBuilder.buildOrUpgradeRoadRouteBetweenTowns(town1, town2, callback, params)
	local nodePair = { connectEval.findBestConnectionNodeForTown(town1, town2), connectEval.findBestConnectionNodeForTown(town2, town1)}
	local newNodePair = routeEvaluation.evaluateRoadRouteOptions(nodePair, nil, params)
	local function wrappedCallback(res, success) 
	if success then 
		if nodePair[1]~=newNodePair[1] then 
			routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgradeBetweenNodes(nodePair[1], newNodePair[1], params) end)
		end
		if nodePair[2]~=newNodePair[2] then 
			routeBuilder.addWork(function() routeBuilder.checkRoadRouteForUpgradeBetweenNodes(nodePair[2], newNodePair[2], params) end)
		end
	
	end
	callback(res, success)
	end
	if newNodePair[1] == newNodePair[2] then 
		trace("new node pair had the same node, skipping routebuild")
		wrappedCallback({}, true)
	else 	
		routeBuilder.buildRoute(newNodePair, params, wrappedCallback)
	end
end
function routeBuilder.buildOrUpgradeForBusRoute(station1, station2, callback,params)
	--local params = paramHelper.getDefaultRouteBuildingParams(false, false)
	local result = pathFindingUtil.findRoadPathStations(station1, station2)
	if #result >0then 
		local count = 0 
		local success = false
		repeat
			count = count + 1
			success = xpcall(function()  routeBuilder.checkRoadRouteForUpgradeBetweenStations({station1, station2}, callback, params) end, err)
			if not success then 
				trace("Error found upgrading route, attmpt ",count," trying again")
				
			end
		until success or count > 10
	else 
		routeBuilder.buildRoadRouteBetweenStations({station1, station2}, callback, params, hasEntranceB)
	end
end

return routeBuilder