local util = require("bus_line_tool_base_util")
local transf = require("transf")
local vec2 = require("vec2")
local vec3 = require("vec3")
--local paramHelper = require("bus_line_tool_base_param_helper")
--local helper = require("bus_line_tool_station_template_helper")
--local connectEval = require("bus_line_tool_new_connections_evaluation")
local routeBuilder = require("bus_line_tool_route_builder")
local pathFindingUtil = require("bus_line_tool_pathfinding_util")

local constructionUtil = {}
routeBuilder.constructionUtil = constructionUtil
local function trace(...)
	util.trace(...)
end

local function rotZTransl(rotation, position)
	if rotation > math.rad(360) then 
		rotation = rotation - math.rad(360)
	end 
	if rotation < -math.rad(360) then 
		rotation = rotation + math.rad(360)
	end 
	return transf.rotZTransl(rotation, position)
end 

local function getTownStreetType(numlanes) 
	local streetTypeName = util.year() >= 1925 and "standard/town_medium_new.lua" or "standard/town_medium_old.lua"
	if numlanes and numlanes > 4 then  
		streetTypeName = util.year() >= 1925 and "standard/town_large_new.lua" or "standard/town_large_old.lua"
	end 
	return api.res.streetTypeRep.find(streetTypeName)
end
local function initNewEntity(newProposal, numlanes) 
	local newEntity = api.type.SegmentAndEntity.new()
	newEntity.streetEdge.streetType = getTownStreetType(numlanes) 
	newEntity.entity=  -1-#newProposal.streetProposal.edgesToAdd
	newEntity.type = 0
	return newEntity
end	

local function checkProposalForErrors(proposal, printErrors, tryRemoveCollisionEdges, allowExtendedRemoval, ignoreWaterMesh)
	local resultData = api.engine.util.proposal.makeProposalData(proposal, util.initContext())
	--debugPrint({proposalErrorState=resultData.errorState, tpNetLinkProposal=resultData.tpNetLinkProposal})
	local isError = #resultData.errorState.messages > 0 or resultData.errorState.critical
	local isConnected = #resultData.tpNetLinkProposal.toAdd > 0
	local isBuggedError = false 
	local isCriticalError = resultData.errorState.critical
	local allWereWaterMesh = #resultData.collisionInfo.collisionEntities > 0 
	local hasWaterMeshCollisions = false
	if isError and  #resultData.errorState.messages == 1 and resultData.errorState.messages[1]=="Collision" then
		local alreadySeen = {} 
		local collisionEdges = {}
		local removedMap = {}
		for i, edgeId in pairs(proposal.streetProposal.edgesToRemove) do 
			removedMap[edgeId]=true
		end
		local foundAll = true 
		local allowSelfCollisions = util.tracelog
		for i, entity in pairs(resultData.collisionInfo.collisionEntities) do 
			if not removedMap[entity.entity] then 
				if entity.entity> 0 or not allowSelfCollisions then 
					foundAll = false
				end
				if  util.isWaterMeshEntity(entity.entity) then 
					hasWaterMeshCollisions = true 
				else 
					trace("Entity ",entity.entity," was NOT a water mesh")
					allWereWaterMesh = false 
				end
				 
			end
			if not alreadySeen[entity.entity] and not removedMap[entity.entity] then 
				alreadySeen[entity.entity]=true 
				if entity.entity > 0 then 
					if tryRemoveCollisionEdges then 
						local fullEntity = game.interface.getEntity(entity.entity) 
						if fullEntity and fullEntity.type == "BASE_EDGE" and not fullEntity.track then 
							table.insert(collisionEdges, entity.entity)
						end
					end 
				end 
			end 
		end
		if foundAll then 
			isBuggedError = true
			trace("Found all entities in the removed collision set")
		elseif tryRemoveCollisionEdges then 
		 
			local removedEdges = {} 
			for i, edgeId in pairs(collisionEdges)  do 
				if (util.isDeadEndEdgeNotIndustry(edgeId) or allowExtendedRemoval) and util.getStreetTypeCategory(edgeId)~="highway" and not util.isFrozenEdge(edgeId) and #util.getEdge(edgeId).objects==0 then 
					proposal.streetProposal.edgesToRemove[1+#proposal.streetProposal.edgesToRemove]=edgeId
					trace("Removing edge",edgeId," to allow proposal test build")
					table.insert(removedEdges, edgeId)
				end 
			end
			 
			local referencedNodes = {} 
			for i, edgeId in pairs(removedEdges) do 
			 
				local edge = util.getEdge(edgeId) 
				for j, node in pairs({edge.node0, edge.node1}) do 
					if not referencedNodes[node] then 
						referencedNodes[node] = 1 
					else 
						referencedNodes[node] = referencedNodes[node] + 1
					end 
				end 
			end 
			local removedNodes = {} 
			local remainingNodes = {}
			for node, count in pairs(referencedNodes) do 
				if count == #util.getSegmentsForNode(node) then 
					table.insert(removedNodes, node)
					proposal.streetProposal.nodesToRemove[1+#proposal.streetProposal.nodesToRemove]=node
				else 
					table.insert(remainingNodes, node)
				end
			end 
			
			  
		 
			local result =  checkProposalForErrors(proposal, printErrors, false, false, ignoreWaterMesh)
			result.removedEdges = removedEdges 
			result.removedNodes = removedNodes 
		 
			result.remainingNodes = remainingNodes
			return result
		end
		
	end
	local isActualError = (isError and not isBuggedError) or isCriticalError
	if ignoreWaterMesh and allWereWaterMesh and not isCriticalError then 
		isActualError = false 
	end
	local isOnlyBridgePillarCollision =  not isCriticalError and #resultData.errorState.messages == 1  and resultData.errorState.messages[1]== "Bridge pillar collision"
	trace("Collision result, isError=",isError," isConnected=",isConnected, " isActualError=",isActualError, " isCriticalError=",isCriticalError, " isBuggedError=",isBuggedError, " ignoreWaterMesh=",ignoreWaterMesh," allWereWaterMesh=",allWereWaterMesh)
	if isError and printErrors and util.tracelog then 
		--debugPrint(proposal)
		debugPrint(resultData.errorState)
		debugPrint(resultData.collisionInfo.collisionEntities)
		if isCriticalError then 
			debugPrint(proposal)
		end
	end
	return { isError = isError, isConnected = isConnected, costs=resultData.costs, isBuggedError=isBuggedError, isActualError = isActualError, isCriticalError=isCriticalError, isOnlyBridgePillarCollision=isOnlyBridgePillarCollision, collisionEntities=resultData.collisionInfo.collisionEntities, errorState = resultData.errorState, hasWaterMeshCollisions= hasWaterMeshCollisions }
end

local function checkTrainStationForCollision(positionAndRotation, params, stationConstr, depotConstr, disableTestTrack)
	local testProposal = api.type.SimpleProposal.new() 
	--if not disableTestTrack then 
		trace("Adding test track segment")
		constructionUtil.buildTestTrackSegment(testProposal, positionAndRotation, false, 80, params)
	--end
	testProposal.constructionsToAdd[1]=stationConstr
	if depotConstr then 
		testProposal.constructionsToAdd[2]=depotConstr
	end
	local testResult =  checkProposalForErrors(testProposal)
	if params.ignoreErrors and testResult.isError and not testResult.isCriticalError then 
		trace("overriding error as we are ignoring errors IsConnnected?",testResult.isConnected) 
		testResult.isError = false 
		if testResult.isConnected then 
			debugPrint({collisionEntities=testResult.collisionEntities})
		end
	end 
	return testResult
end

local function checkConstructionForCollision(...) 
	trace("checking construction for collision")
	local dummyProposal = api.type.SimpleProposal.new()
	for i, c in pairs({...}) do 
		dummyProposal.constructionsToAdd[i]=c
	end
	
	return checkProposalForErrors(dummyProposal,true)
end


local function trialBuildConnectRoad(leftNodeOrPos, rightNodeOrPos)
	local leftNode 
	local leftNodePos 
	local rightNode 
	local rightNodePos 
	local testProposal = api.type.SimpleProposal.new()
	if type(leftNodeOrPos) == "number" then 
		leftNode = leftNodeOrPos
		leftNodePos  = util.nodePos(leftNode)
	else 
		leftNodePos = leftNodeOrPos
		local newNode =util.newNodeWithPosition(leftNodePos, -3)
		leftNode = newNode.entity 
		testProposal.streetProposal.nodesToAdd[1]=newNode 
	end 
	if type(rightNodeOrPos) == "number" then 
		rightNode = rightNodePos
		rightNodePos  = util.nodePos(rightNode)
	else 
		rightNodePos = rightNodeOrPos
		local newNode =util.newNodeWithPosition(rightNodePos, -4)
		rightNode = newNode.entity 
		testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]=newNode 
	end
	local entity = initNewEntity(testProposal)
	entity.streetEdge.streetType = api.res.streetTypeRep.find("standard/country_small_new.lua")
	entity.comp.node0 = leftNode 
	entity.comp.node1 = rightNode
	util.setTangent(entity.comp.tangent0, rightNodePos-leftNodePos)
	util.setTangent(entity.comp.tangent1, rightNodePos-leftNodePos)
	testProposal.streetProposal.edgesToAdd[1]=entity
	local result=  checkProposalForErrors(testProposal, true).isError
	trace("result of trial build for link was",result)
	return result 
end 

function constructionUtil.createRoadDepotConstruction(naming, position, angle)
	local roadDepotConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	roadDepotConstruction.fileName = "depot/road_depot_era_a.con"
	roadDepotConstruction.playerEntity = api.engine.util.getPlayer()
	 roadDepotConstruction.params={
		paramX = 0,  
		paramY = 0, 
		seed = 0, -- TODO check this might need to be 1
		year = util.year()}
	roadDepotConstruction.name = naming.name.." ".._("Road depot")
	local trnsf = rotZTransl(angle, position)
	roadDepotConstruction.transf = util.transf2Mat4f(trnsf)
	return roadDepotConstruction
end
  

 

function constructionUtil.createHighwayJunction(town, positions, otherTown, callback, params, thirdTown)
	util.lazyCacheNode2SegMaps()
	local filterFn = function(node) 
		local townNode = util.searchForNearestNode(town.position, 150, function(node) return #util.getTrackSegmentsForNode(node.id)==0 end).id
		local foundPath= #pathFindingUtil.findRoadPathBetweenNodes(townNode, node) > 0 or #pathFindingUtil.findRoadPathBetweenNodes(node, townNode) > 0
		trace("createHighwayJunction looking for path between",townNode,node," foundPath?",foundPath)
		return foundPath
	end
	local searchRadius = 1000
	if #util.searchForDeadEndHighwayNodes(town.position, searchRadius, filterFn) > 0 then 
		if not params.searchMap then 
			params.searchMap = {} 
		end  
		params.searchMap[town.id]=util.nodePos(util.searchForDeadEndHighwayNodes(town.position, searchRadius+300, filterFn)[1])-- add 300 to ensure we capture both sides of a junction if it is right at the edge 
		callback({}, true) 
		return
	end 
	
	local junctionNodes = util.searchForJunctionHighwayNodes(town.position, searchRadius, filterFn)
	if #junctionNodes > 0 then 
		searchRadius = searchRadius + 1000-- may be a junction construction nearby check again for dead end nodes at greater distance
		trace("Searching for dead end highway nodes at radius",searchRadius," for town ",town.name)
		if #util.searchForDeadEndHighwayNodes(town.position, searchRadius, filterFn) > 0 then 
			if not params.searchMap then 
				params.searchMap = {} 
			end  
			params.searchMap[town.id]=util.nodePos(util.searchForDeadEndHighwayNodes(town.position, searchRadius+300, filterFn)[1])
			callback({}, true) 
			return
		end 
		routeBuilder.buildTJunction(town, otherTown, callback, params,junctionNodes)
		return
	end 

	if not params.townJunctionOffset then 
		params.townJunctionOffset = 90
	end
	
	local cement = api.res.bridgeTypeRep.find("cement.lua")
	local highwayType = api.res.streetTypeRep.find(params.preferredHighwayRoadType)
	local isThreeLane = params.preferredHighwayRoadType == "standard/country_large_one_way_new.lua"

	local isTerminus =  false
	if params.buildTerminus then  
		isTerminus = params.buildTerminus[town.id] 
	end
	local townType = api.res.streetTypeRep.find(params.preferredUrbanRoadType)
	local offset = util.getStreetWidth(highwayType)+params.highwayMedianSize
	local onRampType = routeBuilder.getOnRampType()
	local townPos = util.v3fromArr(town.position)
	local function buildHiwayJunction(positionAndRotation) 
		local tangent = positionAndRotation.stationParallelTangent
		local perpTangent = positionAndRotation.stationPerpTangent
		
		local junctionOffset = params.townJunctionOffset
		local minDistToTown = math.huge
		
		for i = -350, 350, 10 do 
			local testP = junctionOffset*perpTangent + i*tangent + positionAndRotation.position
			minDistToTown = math.min(minDistToTown, util.distance(testP, townPos))
		end 
		trace("The minDistToTown was ",minDistToTown, " for ",junctionOffset)
		if minDistToTown < 200 and not params.isUnderground then -- avoid blasting through the middle of a town 	
			junctionOffset = junctionOffset+(200-minDistToTown)
			trace("Increasing the junctionOffset to ",junctionOffset)
		end 
		local nodesToAdd = {}
		local edgesToAdd = {}
		local edgeObjectsToAdd = {}
		local edgesToRemove = {} 
		local alreadySeen = {}
		local removedEdges = {}
		local nodeToPositionMap = {}
		local newNodeMap = {}
		local function nextEdgeId() 
			return -1-#edgesToAdd
		end
		local nodeId = -1000
		local function nextNodeId()
			nodeId = nodeId -1
			return nodeId
		end 
		
		local function nodePos(node) 
			if node > 0 then 
				return util.nodePos(node) 
			else 
				return nodeToPositionMap[node]
			end 
		end 
		
		local function newEntity(node0, node1, streetType, doNotInsert) 
			local entity = api.type.SegmentAndEntity.new() 
			entity.type = 0
			entity.entity = nextEdgeId() 
			entity.comp.node0 = node0
			entity.comp.node1 = node1
			local p0 = nodePos(node0) 
			local p1 = nodePos(node1) 
			if p0.z - util.th(p0) > 5 and p1.z - util.th(p1) > 5 or util.th(p0)< 0 or util.th(p1)<0 then 
				entity.comp.type = 1
				entity.comp.typeIndex = cement 
			elseif  p0.z - util.th(p0) < -10 and p1.z - util.th(p1) <-10 then 
				entity.comp.type = 2 
				entity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")			
			end
			local t = p1 - p0
			util.setTangents(entity, t)  
			entity.streetEdge.streetType = streetType
			if not doNotInsert then 
				table.insert(edgesToAdd, entity)
			end
			return entity
		end 
		local exitRampLength = 35
		local function newHighwaySegment(newNode0, newNode1) 
			local entity = newEntity(newNode0, newNode1)
			entity.streetEdge.streetType = highwayType			
			return entity
		end 
		
		local function makeNewNode(p) 
			local newNode = util.newNodeWithPosition(p, nextNodeId())
			table.insert(nodesToAdd, newNode)
			nodeToPositionMap[newNode.entity]=p 
			newNodeMap[newNode.entity]=newNode
			return newNode.entity
		end 
		
		local function toEdge(entity) 
			return { 
				p0 = nodePos(entity.comp.node0),
				p1 = nodePos(entity.comp.node1),
				t0 = util.v3(entity.comp.tangent0),
				t1 = util.v3(entity.comp.tangent1)			
			}
		end 
		
		local linkEntity
		local innerJoinNode = positionAndRotation.originalNode
		local innerJoinNodePos = util.nodePos(innerJoinNode)
		local outerJoinNode
		local outerJoinNodePos
		local position = positionAndRotation.position
		if isTerminus then 
			local r = isThreeLane and 60 or 40
			local length = r * 4 * (math.sqrt(2)-1)
			local startNode = makeNewNode(position)
			local circleMidPoint = position + r*perpTangent
			newEntity(positionAndRotation.originalNode, startNode, townType)
			local sign = positionAndRotation.stationRelativeAngle < 0 and -1 or 1
			tangent = sign*tangent
			local node2 = makeNewNode(position + r*tangent + r*perpTangent)
			local entity1 = newEntity(startNode, node2, highwayType)
			util.setTangent(entity1.comp.tangent0, length*tangent)
			util.setTangent(entity1.comp.tangent1, length*perpTangent)
			local node3 = makeNewNode(position + 2*r*perpTangent)
			local entity2 = newEntity(node2, node3, highwayType)
			util.setTangent(entity2.comp.tangent0, length*perpTangent)
			util.setTangent(entity2.comp.tangent1, -length*tangent)
			local node4 = makeNewNode(position + r*perpTangent-r*tangent)
			local entity3 = newEntity(node3, node4, highwayType)
			util.setTangent(entity3.comp.tangent0, -length*tangent)
			util.setTangent(entity3.comp.tangent1, -length*perpTangent)
			local entity4 = newEntity(node4, startNode, highwayType)
			util.setTangent(entity4.comp.tangent0, -length*perpTangent)
			util.setTangent(entity4.comp.tangent1, length*tangent)
		
			local tangentToOtherTown = vec3.normalize(util.v3fromArr(otherTown.position)-circleMidPoint)
			local doNotBuildConnectPeice = true
			
			local startHighwayPos = circleMidPoint + 2*r * tangentToOtherTown
			if params.isElevated then 
				tangentToOtherTown.z = 0.1
				doNotBuildConnectPeice = false
				startHighwayPos.z = startHighwayPos.z + tangentToOtherTown.z*r				
			elseif params.isUnderground then 
				tangentToOtherTown.z = -0.1
				doNotBuildConnectPeice = false
				startHighwayPos.z = startHighwayPos.z - tangentToOtherTown.z*r
			end 
			local rightPos = util.nodePointPerpendicularOffset(startHighwayPos, tangentToOtherTown, -0.5*offset)
			local leftPos = util.nodePointPerpendicularOffset(startHighwayPos, tangentToOtherTown, 0.5*offset)
		 
			local outbound = newEntity( makeNewNode(rightPos), makeNewNode(rightPos+40*tangentToOtherTown), highwayType, doNotBuildConnectPeice)
		 
			local inbound = newEntity( makeNewNode(leftPos),makeNewNode(leftPos+40*tangentToOtherTown), highwayType, doNotBuildConnectPeice)
			local collisionEntityIds = {}
			local entities = {entity1, entity2, entity3, entity4}
			local leftConnect = circleMidPoint + 2*r * util.rotateXY(tangentToOtherTown, math.rad(35))
			local rightConnect = circleMidPoint + 2*r * util.rotateXY(tangentToOtherTown, -math.rad(35))
			local exitEntities = {inbound, outbound}
			local idx
			local collissionNodes = {} 
			collissionNodes[startNode]=true
			for j, connect in pairs({leftConnect, rightConnect}) do 
				local c 
				local collisionEntity 
				local function findCollisionPoint(extraOffset)
					for i , entity in pairs(entities) do 
						local p1 = nodePos(entity.comp.node0)
						local p2 = nodePos(entity.comp.node1)
						if extraOffset then 
							p1 = p1 - extraOffset*vec3.normalize(util.v3(entity.comp.tangent0))
							p2 = p2 + extraOffset*vec3.normalize(util.v3(entity.comp.tangent1))
						end 
						
						c = util.checkFor2dCollisionBetweenPoints(p1,p2 , circleMidPoint, connect) 
						if c then
							idx = i
							collisionEntity=entity 
							collisionEntityIds[entity.entity]=true
							break 
						end
					end 
				end 
				findCollisionPoint()
				if not c then 
					trace("First attempt to find collsion point failed, attempting again") 
					for extraOffset = 1, 20 do 
						findCollisionPoint(extraOffset) 
						trace("On ",extraOffset,"th attempt it was ",c)
						if c then break end
					end 
				end
				if not c then break end
				assert(c)
				local connectNode
				local edge =  toEdge(collisionEntity)
				local t = util.solveForPositionHermite(util.v2ToV3(c, connect.z),edge)
				local fullC = util.hermite2(t, edge) 
				local node0 = collisionEntity.comp.node0 
				local node1 = collisionEntity.comp.node1
				local tangent0 = util.v3(collisionEntity.comp.tangent0)
				local tangent1 = util.v3(collisionEntity.comp.tangent1)
				local isNode0 = false 
				local isNode1 = false 
				local connectTangent  = vec3.normalize(fullC.t)
				if collissionNodes[node0] and collissionNodes[node1] then 
					connectNode = makeNewNode(fullC.p)
					trace("Creating new connectNode ",connectNode)
					local entity2 = newEntity(node0, connectNode, highwayType)
					util.setTangent(collisionEntity.comp.tangent0, t*tangent0)
					util.setTangent(collisionEntity.comp.tangent1, t*vec3.length(tangent1)*connectTangent)
					util.setTangent(entity2.comp.tangent0,(t-1)*vec3.length(tangent1)*connectTangent)
					util.setTangent(entity2.comp.tangent1, (t-1)*tangent1) 					
				elseif collissionNodes[node0] then 
					isNode1 = true 
					connectNode = node1
				elseif  collissionNodes[node1] then 
					isNode0 = true 
					connectNode = node0
				else 
					local isNode0 = vec2.distance(c, nodePos(node0)) < vec2.distance(c, nodePos(node1)) 
					isNode1 = not isNode0
					if isNode0 then
						connectNode = node0
					else 
						connectNode = node1 
					end 					
				end
				collissionNodes[connectNode]=true
	
				--[[local mint = offset / (0.5*math.pi*r)
				local maxt = 1-mint 
				if t < mint or t > maxt then 
					trace("Adjusting t as it was too close. t=",t," maxt=",maxt,"mint=",mint)
					t= math.min(maxt, math.max(t, mint))
					trace("t is now",t)
				end ]]--
				
				util.setPositionOnNode(newNodeMap[connectNode], fullC.p)
				
				--local entity2 = newEntity(node0, connectNode, highwayType)
				 trace("At j=",j," the connectNode was ",connectNode," the collisionEntity was ", collisionEntity.entity, " isNode0=",isNode0," idx=",idx)
				if isNode0 then 
					local lengthToEnd = t*vec3.length(tangent1)
					util.setTangent(collisionEntity.comp.tangent0, (1-t)*vec3.length(tangent0)*connectTangent)
					util.setTangent(collisionEntity.comp.tangent1, (1-t)*tangent1)
					local adjacentEdge = entities[idx-1]
					
					local currentLength = vec3.length(util.v3(adjacentEdge.comp.tangent0))
					local newLength = lengthToEnd + currentLength
					util.setTangent(adjacentEdge.comp.tangent0, (newLength/currentLength)*util.v3(adjacentEdge.comp.tangent0))
					util.setTangent(adjacentEdge.comp.tangent1, newLength*connectTangent)
				elseif isNode1 then
					local lengthToStart = (t-1)*vec3.length(tangent1)
					util.setTangent(collisionEntity.comp.tangent0, t*tangent0)
					util.setTangent(collisionEntity.comp.tangent1, t*vec3.length(tangent1)*connectTangent) 
					local adjacentEdge = entities[idx+1]
					local currentLength = vec3.length(util.v3(adjacentEdge.comp.tangent0))
					local newLength = lengthToStart + currentLength
					util.setTangent(adjacentEdge.comp.tangent0, newLength*connectTangent)
					util.setTangent(adjacentEdge.comp.tangent1, (newLength/currentLength)*util.v3(adjacentEdge.comp.tangent1))
				end
							  
				local exitEntity = exitEntities[j]
				local connectEntity = newEntity(connectNode, exitEntity.comp.node0, highwayType)
				local rotate = j == 1 and -math.rad(135) or -math.rad(45)
				local startTangent = util.rotateXY(util.v3(connectTangent), rotate)
				local exitTangent = util.v3(exitEntity.comp.tangent1)
				local connectLength = util.calculateTangentLength(nodePos(connectNode), nodePos(connectEntity.comp.node1), startTangent, exitTangent)
				util.setTangent(connectEntity.comp.tangent1,  connectLength*vec3.normalize(exitTangent))
				local sign = -1 
				
				util.setTangent(connectEntity.comp.tangent0, connectLength*vec3.normalize(startTangent))
				if j == 1 then 
					util.reverseNewEntity(connectEntity)
					
				end 
				--break
			end
			util.reverseNewEntity(inbound)
			
			for i = 2, #entities do 
				if not collisionEntityIds[entities[i-1].entity] and not collisionEntityIds[entities[i]] then 
					trace("Attempting to build link road at i=",i)
					for k, node in pairs({entities[i].comp.node0, entities[i].comp.node1}) do  
						if not collissionNodes[node] then
							local tangent = vec3.normalize(util.rotateXY(util.v3(entities[i].comp.tangent0), -math.rad(90)))
							local newProposal = {} 
							newProposal.streetProposal = {} 
							newProposal.streetProposal.edgesToAdd = {}
							newProposal.streetProposal.edgesToRemove = {}
							newProposal.streetProposal.nodesToAdd = { newNodeMap[node] }
							constructionUtil.buildLinkRoad(newProposal, node, tangent, 0, nodePos(node), nextNodeId)
							for i =1 , #newProposal.streetProposal.edgesToAdd do 
								local entity = newProposal.streetProposal.edgesToAdd[i]
								entity.entity  = nextEdgeId()
								table.insert(edgesToAdd, entity)
							end 
							for i = 2, #newProposal.streetProposal.nodesToAdd do 
								local newNode = newProposal.streetProposal.nodesToAdd[i]
								table.insert(nodesToAdd, newNode)
							end
						end
					end
				end 
			end
			
			--local outboundConnect = newEntity(collisionEntity.comp.node0, outbound.comp.node0, highwayType)
			--util.setTangent(outboundConnect.comp.tangent1, vec3.length(util.v3(outboundConnect.comp.tangent1))*vec3.normalize(util.v3(outbound.comp.tangent0)))
			--local inboundConnect = newEntity(inbound.comp.node1, collisionEntity.comp.node1, highwayType)
			--util.setTangent(inboundConnect.comp.tangent0, vec3.length(util.v3(inboundConnect.comp.tangent0))*vec3.normalize(util.v3(inbound.comp.tangent1)))
		elseif not (positionAndRotation.isVirtualDeadEnd and positionAndRotation.edgeToRemove) then 
			
			local testP = positionAndRotation.position + (junctionOffset + offset+ util.getStreetWidth(townType)) *perpTangent 
			while util.th(testP) < 0  and junctionOffset >= 35 do
				junctionOffset = junctionOffset - 5
				trace("Reduced junctionOffset to ", junctionOffset)
				testP = positionAndRotation.position + (junctionOffset + offset+ util.getStreetWidth(townType)) *perpTangent 
			end
			if junctionOffset > 40 then 
				position = positionAndRotation.position + junctionOffset*perpTangent
				innerJoinNodePos = position -35*perpTangent
				innerJoinNode = makeNewNode(innerJoinNodePos)
				newEntity(positionAndRotation.originalNode, innerJoinNode, townType ) 
			end
			local p = position + (offset+35)*perpTangent
			outerJoinNode = makeNewNode(p) 
			outerJoinNodePos = p
			linkEntity = newEntity(innerJoinNode, outerJoinNode, townType) 
			 
		else 
			local edge = util.getEdge(positionAndRotation.edgeToRemove)
			outerJoinNode = edge.node1 == innerJoinNode and edge.node0 or edge.node1 
			if util.calculateSegmentLengthFromEdge(edge) < 2*offset then 
				trace("Short segment detecting, using next node")
				local nextSegs = util.getStreetSegmentsForNode(outerJoinNode) 
				local nextEdgeId = nextSegs[1] == positionAndRotation.edgeToRemove and nextSegs[2] or nextSegs[1]
				local nextEdge = util.getEdge(nextEdgeId)
				outerJoinNode = outerJoinNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0
			end
			outerJoinNodePos = util.nodePos(outerJoinNode)
		end
		trace("Building hiway junction, the innerJoinNode was ", innerJoinNode, " the outerJoinNode was ", outerJoinNode, " stationRelativeAngle was ",math.deg(positionAndRotation.stationRelativeAngle))
		local reversed = positionAndRotation.stationRelativeAngle < 0 
		if reversed then 
			tangent = -1*tangent 
		end
		if not isTerminus then 
			local prevNewNode
			local prevNewNode2
			for __ , i in pairs({-130, -90, 0, 90, 130}) do 
				local p = position + i*tangent
				p.z = p.z + (params.isUnderground and -params.elevationHeight or params.elevationHeight)
				local newNode =  makeNewNode(p)  
				local p2 = p + offset * perpTangent
				local newNode2 =  makeNewNode(p2)  
				--params.leftHandTraffic
				local entity 
				local entity2 
				if prevNewNode then 
					entity = newEntity(prevNewNode, newNode, highwayType)
					entity2 = newEntity(newNode2, prevNewNode2, highwayType)
				end 
				if i == 0 then 
					if (entity.comp.type == 0 or entity2.comp.type == 0) and linkEntity then 
						if params.isUnderground then 
							linkEntity.comp.type = 1 
							linkEntity.comp.typeIndex = cement
						else 
							linkEntity.comp.type = 2 
							linkEntity.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
						end
					end
				end 
				if math.abs(i) == 90  then
					local tangentForRamp = tangent 
					if i > 0 then 
						tangentForRamp = -1*tangent 
					end
					routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, newNode , p,tangentForRamp, entity.comp.type, innerJoinNode, innerJoinNodePos, params, nextEdgeId, nextNodeId, i<0, tangentForRamp)
					 routeBuilder.buildHiwayOnRamp(edgesToAdd, nodesToAdd, newNode2 , p2,tangentForRamp, entity2.comp.type, outerJoinNode, outerJoinNodePos, params, nextEdgeId, nextNodeId, i > 0, tangentForRamp) 				
				
				 
				end
				prevNewNode = newNode 
				prevNewNode2 = newNode2 
			end
			--if positionAndRotation.stationRelativeAngle < 0 or  true then
			--	for i, newEdge in pairs(edgesToAdd) do 
			--		util.reverseNewEntity(newEdge)
			--	end 
			--end 
		end 
		
		routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove, edgeObjectsToRemove, true)
		return routeBuilder.setupProposal(nodesToAdd, edgesToAdd, edgeObjectsToAdd, edgesToRemove)
	end
	
	
	for i=1, #positions do
		for extraOffset = 45, 180, 45 do 
			params.townJunctionOffset=extraOffset
			local positionAndRotation = connectEval.getStationPositionAndRotation(town, positions[i], otherTown, params,0 ,thirdTown)
			local newProposal = buildHiwayJunction(positionAndRotation) 
			local checkResult = checkProposalForErrors(newProposal, true)
			 
			if util.tracelog then debugPrint(newProposal) end
			if checkResult.isCriticalError then 
				
			end
			
			local canBuild = not checkResult.isCriticalError and (not checkResult.isError or params.ignoreErrors)
			local ignoreErrors = params.ignoreErrors
			if checkResult.isOnlyBridgePillarCollision then 
				canBuild = true 
				ignoreErrors = true 
			end
			if not canBuild and not checkResult.isCriticalError and not checkResult.isActualError then 
				canBuild = true 
				ignoreErrors = true 
			end
			
			if canBuild then 
				if not params.searchMap then 
					params.searchMap = {}
				end
				params.searchMap[town.id]=positionAndRotation.position
				api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), ignoreErrors),callback)
				util.clearCacheNode2SegMaps()
				return
			else 
				trace("Station proposal for town",town.name," had an error, trying next")
			end
			::continue::
		end
	end
 
	if not params.ignoreErrors then 
		trace("Unable to find a build, ignoring errrors")
		params.ignoreErrors  = true
		constructionUtil.createHighwayJunction(town, positions, otherTown, callback, params)
		return 
	end 
	callback({}, false)
 end

function constructionUtil.createRoadStationConstruction(position, rotation, params, naming, hasEntranceB, platL,platR, namePrefix, length)
	if not length then length = 2 end
	if length > 2 then 
		trace("WARNING! Max length >2",length)
		trace(debug.traceback())
		length = 2
	end
	local isCargo = params.isCargo
	local stationParams = { 
			catenary = 0,  
			length = length, 
			length2 = length,
			paramX = 0,  
			paramY = 0, 
			platL = platL and platL or 1,
			platR = platR and platR or 1,
			seed = 0, 
			templateIndex = isCargo and 3 or 2 , -- truck  
			tramTrack = 0,
			year = util.year(),}
	if hasEntranceB then
		stationParams.entrance_exit_b = 1
	end
	if params.isForTownTranshipment or params.includeLargeBuilding then 
		stationParams.includeLargeBuilding = true 
	end
	stationParams.includeSmallBuilding = params.includeSmallBuilding

	local modulebasics =  helper.createRoadTemplateFn(stationParams)
	local modules =  util.setupModuleDetailsForTemplate(modulebasics)  
	local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
	newConstruction.name=naming.name..(namePrefix and " "..namePrefix.." " or " ")..(isCargo and _("Truck Station") or _("Bus Station"))
	local station = "station/street/modular_terminal.con"
	
	newConstruction.fileName = station
	newConstruction.playerEntity = api.engine.util.getPlayer()
	stationParams.modules = modules
	newConstruction.params = stationParams
	
			 
	local trnsf = rotZTransl(rotation, position)
	newConstruction.transf = util.transf2Mat4f(trnsf)
	return newConstruction
end

function constructionUtil.buildRoadStation(newProposal, position, rotation, params, naming, hasEntranceB, platL,platR, namePrefix, length)
	local newConstruction = constructionUtil.createRoadStationConstruction(position, rotation, params, naming, hasEntranceB, platL,platR, namePrefix, length)
	newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=newConstruction
end

local function getTypeFromMode(transportModes)
	if type(transportModes)=="string" then
		return transportModes
	end
	local TransportMode = api.type.enum.TransportMode
	for i, v in pairs(transportModes) do
		if type(i)=="string" then
			debugPrint({transportModes=transportModes}) 
			print(debug.traceback())
		end 
		local mode = i-1
		if v == 1 then
			if mode == TransportMode.BUS or mode == TransportMode.TRUCK then
				return "road"
			elseif mode == TransportMode.TRAIN or mode == TransportMode.ELECTRIC_TRAIN then
				return "train"
			elseif mode == TransportMode.SHIP or mode == TransportMode.SMALL_SHIP then
				return "ship"
			elseif mode == TransportMode.AIRCRAFT or mode == TransportMode.SMALL_AIRCRAFT then
				return "air"
			else 
				trace("unsupported transport type",mode)
			end
		end
	end
end
local function searchForDepotOfType(pos, depotType, range)
	if not depotType then
		trace("No depot type specified")
		return
	end
	if pos.x then
		pos = util.v3ToArr(pos)--needs to be an array
	end
	if not range then range = 200 end
	local circle = {radius=range, pos=pos}
	--debugPrint({searchCircle=circle})
	for i, constr in pairs(game.interface.getEntities(circle,{type="CONSTRUCTION", includeData=true})) do 
		if constr.depots[1] and string.find(constr.fileName, depotType) then
			return constr.id
		end
	end
end
function constructionUtil.searchForDepot(pos, transportModes, range)
	local depotType = getTypeFromMode(transportModes)
	return searchForDepotOfType(pos, depotType, range)
end

function constructionUtil.searchForRoadDepot(pos, range)
	return searchForDepotOfType(pos, "road", range)
end
function constructionUtil.searchForTramDepot(pos, range)
	return searchForDepotOfType(pos, "tram", range)
end
function constructionUtil.searchForShipDepot(pos, range)
	if not range then range = 500 end
	return searchForDepotOfType(pos, "ship", range)
end
function constructionUtil.searchForRailDepot(pos, arg2)
	local range = 200	
	local pos2 
	if arg2 then 
		if type(arg2)=="number" then 
			range = arg2
		else 
			pos2 = arg2
		end 
	
	end 
	
	local result =  searchForDepotOfType(pos, "train", range)
	if not result and pos2 then
		return searchForDepotOfType(pos2, "train", range)
	end
	return result
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

local function getTruckStopModel()  
	return "station/road/small_cargo.mdl"
end

local function buildStop(edgeId, newProposal, modelType, param, name)
	if not name then name = "stop" end
	trace("begin building bus stop for edge",edgeId)
	local leftCopy = util.copyExistingEdge(edgeId)
	local nextEdgeId = -(1+#newProposal.streetProposal.edgesToAdd)
	local nextObjectId = -(1+#newProposal.streetProposal.edgeObjectsToAdd)
	leftCopy.entity = nextEdgeId
	local objects = util.deepClone(leftCopy.comp.objects)
	if #objects >= 2 then 
		trace("Unable to build stop for edgeId ",edgeId," already has two stops")
		return 
	end
	local left = #objects == 1
	
	table.insert(objects,  { nextObjectId, left and 0 or 1})
	leftCopy.comp.objects = objects -- for some reason have to reassign the table

	trace("about to set edges to remove on proposal at ",-nextEdgeId)
	newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=edgeId
	trace("about to set edges to add on proposal")
	newProposal.streetProposal.edgesToAdd[-nextEdgeId]=leftCopy
	local newStop = api.type.SimpleStreetProposal.EdgeObject.new()
	newStop.left = left
	newStop.oneWay = false
	newStop.playerEntity = api.engine.util.getPlayer()
	newStop.edgeEntity = nextEdgeId
	newStop.name = name
	newStop.model = modelType 
	newStop.param = param
	newProposal.streetProposal.edgeObjectsToAdd[-nextObjectId]=newStop  
end

function constructionUtil.buildBusStopOnProposal(edgeId, newProposal, name)
	 buildStop(edgeId, newProposal,getBusStopModel(), 0.5, name )
end

function constructionUtil.buildTruckStopOnProposal(edgeId, name, callback)
	local newProposal = api.type.SimpleProposal.new()
	buildStop(edgeId, newProposal,getTruckStopModel(), 0.5, name)
	util.clearCacheNode2SegMaps()
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), callback)
end

function constructionUtil.createHarborConstruction(newProposal, industry, waterVerticies, includeRoadStation, indexes, isCargo)
	if not indexes then indexes = {} end
	util.lazyCacheNode2SegMaps()
	local params = { isCargo = isCargo, isForTownTranshipment=isCargo }
	local stationPos
	local actualStationTangent
	local needsRoad
	local newConstruction 
	local depotConstruction
	local roadStationConstruction
	local roadDepotConstruction
	local otherRoadStation
	local existingBusStation = not isCargo and util.findBusStationForTown(industry.id)
	trace("ExistingBusStation?",existingBusStation)
	local existingBusStationPos 
	local includeRoadDepot = includeRoadStation and not constructionUtil.searchForRoadDepot(industry.position, 750)
	local includeTramDepot = includeRoadStation and not includeRoadDepot and existingBusStation
	local stationTangent = vec3.new(0,1,0)
	local industryOrTownPos = util.v3fromArr(industry.position)
	local stationCount = util.countRoadStationsForTown(industry.id)
	local constructionResult
	local isError
	local backupOptions = {}
	local maxAtttempts = 500
	local lastAttempt = math.min(maxAtttempts,#waterVerticies)
	for i = 1, #waterVerticies do 
		trace("attempt ",i," of ",#waterVerticies," to place harbour")
		local position = vec3.new(waterVerticies[i].p.x, waterVerticies[i].p.y, 2)
			
		--local stationWaterOffset = 25
		--local stationWaterOffset = 30
		local stationWaterOffset = 28
		local industryVector = position - industryOrTownPos
		
		local industryDistance = vec3.length(industryVector)
		--debugPrint(waterVerticies)
		
		local industryRelativeRotation = util.signedAngle(stationTangent, industryVector)
		--local signedVertexAngle3 = util.signedAngle(stationTangent, vec3.new(waterVerticies[i].t.x, waterVerticies[i].t.y,0))
		local signedVertexAngle3 = util.signedAngle(stationTangent, waterVerticies[i].t)
		--local rotation = math.rad(90)+signedVertexAngle3
		local rotation =  signedVertexAngle3
		if math.abs(industryRelativeRotation-rotation) > math.rad(90) then
			trace("flipping harbour rotation")
			--rotation = rotation + math.rad(180)
		end
		actualStationTangent = util.rotateXY(stationTangent, rotation)
		
		local stationConnectOffset = 35
		--local stationPos = position - stationWaterOffset*vec3.normalize(industryVector)
		--local stationConnectNode = stationPos - stationConnectOffset*vec3.normalize(industryVector)
		stationPos = position + stationWaterOffset*actualStationTangent
		local includeShipYard = not constructionUtil.searchForShipDepot(stationPos, 1000)
		local thisIncludeRoadStation = includeRoadStation
		for i, otherStation in pairs(util.searchForEntities(stationPos, 150, "STATION")) do 
			local stationConstr = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(otherStation.id)
			if otherStation.cargo == isCargo and stationConstr ~= -1 and otherStation.carriers.ROAD then 
 				thisIncludeRoadStation = false 
				otherRoadStation = stationConstr
				break 
			end
		end
		
		needsRoad = not thisIncludeRoadStation
		
		for __, edge in pairs(util.searchForEntities(stationPos, 50, "BASE_EDGE")) do
			local midDist = util.distance(stationPos, util.getEdgeMidPoint(edge.id))
			local node0Dist = util.distance(stationPos,util.nodePos(edge.node0))
			local node1Dist = util.distance(stationPos,util.nodePos(edge.node1))
			local minDist = math.min(midDist, math.min(node0Dist, node1Dist))
			if not edge.track then 
				minDist = minDist - util.getStreetWidth(edge.streetType)/2
				if minDist < stationConnectOffset then
					local adjustment = minDist-stationConnectOffset  
					trace("found collision edge near by, adjusting position by",adjustment)
					stationPos = stationPos + adjustment*actualStationTangent
					needsRoad=false
				end
			end
		end
		
		local baseParams={  
				  paramX = 0,
				  paramY = 0,
				  seed = 0,
				  templateIndex = isCargo and 1 or 0, --0 passenger, 1 cargo
				  size = paramHelper.isBuildBigHarbour(isCargo) and 1 or 0, -- 0 small, 1 big
				  terminals = 0, -- conversion is math.pow(2, params.terminals)
				  year = util.year(),
		}
		if not isCargo and stationCount >= 2 then 
			baseParams.includeSecondPassengerEntrance = true
		end 
		local modulebasics = helper.createHarbourTemplateFn(baseParams)
		baseParams.modules = util.setupModuleDetailsForTemplate(modulebasics)
		newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
		--debugPrint({town=town, positionAndRotation=positionAndRotation})
		newConstruction.name=industry.name.." ".._("Harbour")
		local station = "station/water/harbor_modular.con"
		 
		newConstruction.fileName = station
		newConstruction.playerEntity = api.engine.util.getPlayer()
	 
		newConstruction.params = baseParams
		local stationtransf = rotZTransl(rotation, stationPos) 
		newConstruction.transf = util.transf2Mat4f(stationtransf)
		
	

		if thisIncludeRoadStation then 
			local platR = isCargo and 1 or 2 
			local platL =1 
			local offset = isCargo and 55 or 58
			  
			
			local namePrefix = _("Port")
			local hasEntranceB = true 
			local busStationRotation = rotation -math.rad(90)
			if not isCargo  then 
				
				trace("The stationCount for ",industry.name," was ",stationCount) 
				if stationCount >= 2 then 
					platL = 0 
					offset = offset + 8 -- tram depot is longer, needed along with second pedestrian entrance
					--params.includeLargeBuilding = true 
					--busStationRotation = busStationRotation + math.rad(180)
				elseif stationCount == 1 then 
					platR = platR + 1 
					offset = offset + 8
				end 
			else 
				params.includeSmallBuilding = true 
			end 
			local busStationPos = stationPos + offset*actualStationTangent
			roadStationConstruction = constructionUtil.createRoadStationConstruction(busStationPos, busStationRotation, params, industry, hasEntranceB, platL,platR, namePrefix)
			local perpTangent = util.rotateXY(actualStationTangent, math.rad(90))
			--local depotPos = stationPos+65*perpTangent + 25*actualStationTangent
			--local depotPos = busStationPos+45*perpTangent - 49*actualStationTangent
			local depotOffset =   -50
			local depotPos = busStationPos+45*perpTangent + depotOffset*actualStationTangent
			local depotPos2 = busStationPos-45*perpTangent + depotOffset*actualStationTangent
			
			if util.distance(industryOrTownPos, depotPos) < util.distance(industryOrTownPos, depotPos2) then 
				depotPos = depotPos2 -- keep the depot on the other side in case we need to build a route
			end 
			if includeRoadDepot  then 
				roadDepotConstruction=constructionUtil.createRoadDepotConstruction(industry, depotPos, rotation+math.rad(180))
			elseif includeTramDepot then 
				roadDepotConstruction=constructionUtil.createTramDepotConstruction(industry, depotPos, rotation+math.rad(180))
			end			
		end
		constructionResult = checkConstructionForCollision(newConstruction, roadStationConstruction, roadDepotConstruction)
		isError = constructionResult.isError
		if includeShipYard and (not isError or i == lastAttempt) then 
			local wasOriginalError = isError 
			local originalErrorMessages = #constructionResult.errorState.messages 
			local originalCollisionCount = #constructionResult.collisionEntities
			depotConstruction = api.type.SimpleProposal.ConstructionEntity.new() 
			local depotParams={  
				  paramX = 0,
				  paramY = 0,
				  seed = 0,
				  year = util.year(),
			}
			depotConstruction.params = depotParams
			depotConstruction.name=industry.name.." ".._("Shipyard")
			depotConstruction.fileName = "depot/shipyard_era_a.con"
			depotConstruction.playerEntity = api.engine.util.getPlayer()
			
			local function shouldBreak()
				if wasOriginalError then 
					return #constructionResult.errorState.messages == originalErrorMessages and #constructionResult.collisionEntities == originalCollisionCount
				else 
					return not isError 
				end 
			end 
			
			
		
		
			local nextIndex = i
			local count = 0
			local depotOffset = 35
			repeat
			
				if nextIndex == #waterVerticies then 
					nextIndex = 0 
				end
				count = count +1
				trace("Checking shipyard construction attempt number ",count)
				local depotPos = vec3.new(waterVerticies[nextIndex+1].p.x, waterVerticies[nextIndex+1].p.y, 2)--we know this is a water mesh point
				local depotRot= util.signedAngle(stationTangent, vec3.new(waterVerticies[nextIndex+1].t.x, waterVerticies[nextIndex+1].t.y,0))
				local mesh =  api.engine.getComponent(waterVerticies[nextIndex+1].mesh, api.type.ComponentType.WATER_MESH)
				local contour = mesh.contours[waterVerticies[nextIndex+1].contour]
				if util.distance(depotPos, stationPos) > 120 then
					depotConstruction.transf = util.transf2Mat4f(rotZTransl(depotRot,depotPos ))
					constructionResult = checkConstructionForCollision(newConstruction, depotConstruction, roadStationConstruction, roadDepotConstruction)
					isError = constructionResult.isError
				end
				local nextVertex = 1
				while not shouldBreak() do 
					trace("Harbour depot collision detected, attempting to correct ", nextVertex, nextIndex)
					if nextVertex <=#contour.vertices  then  
						local p = contour.vertices[nextVertex]
						local t = contour.normals[nextVertex]
						for depotOffset = -40, 40, 5 do 
							depotPos = vec3.new(p.x, p.y, 2)+ depotOffset*vec3.normalize(vec3.new(t.x, t.y,0))
							depotRot= util.signedAngle(stationTangent, vec3.new(t.x, t.y,0))
							if util.distance(depotPos, stationPos) > 120 then
								depotConstruction.transf = util.transf2Mat4f(rotZTransl(depotRot,depotPos ))
								constructionResult = checkConstructionForCollision(newConstruction, depotConstruction, roadStationConstruction, roadDepotConstruction)
								isError = constructionResult.isError
							end
							if shouldBreak() then 
								break 
							end
						end
						nextVertex= nextVertex +1
						
					else
						nextVertex = 1
						nextIndex = nextIndex + 1
						break
					end
				end			
			until shouldBreak() or count >= lastAttempt
		else 
			trace("Collision detected between harbour, road station and road depot")
		end
		if depotConstruction then 
			constructionResult = checkConstructionForCollision(newConstruction, depotConstruction, roadStationConstruction, roadDepotConstruction)
			isError = constructionResult.isError
			if not isError then
				break
			end 
		elseif not includeShipYard and not isError then 
			break 
		end
		if constructionResult.isError and not constructionResult.isCriticalError then 
			table.insert(backupOptions, {
				newConstruction = newConstruction, 
				depotConstruction = depotConstruction,
				roadStationConstruction = roadStationConstruction,
				roadDepotConstruction = roadDepotConstruction,
				stationPos = stationPos,
				actualStationTangent = actualStationTangent,
				needsRoad = needsRoad,
				otherRoadStation= otherRoadStation,
				scores = {
					constructionResult.costs,
					#constructionResult.collisionEntities,
					#constructionResult.errorState.messages,
					i -- sorted in original score
				}
			})
		
		end 
		
		if i > maxAtttempts then 
			trace("Still not found after 1000, exiting")
			break 
		end 
	end
	
	if isError  and #backupOptions > 0 then 
		trace("No result without error found attempting to use backup")
		local best = util.evaluateWinnerFromScores(backupOptions)
		if util.tracelog then debugPrint(best) end
		newConstruction = best.newConstruction
		depotConstruction = best.depotConstruction
		roadStationConstruction = best.roadStationConstruction
		roadDepotConstruction = best.roadDepotConstruction
		stationPos = best.stationPos
		actualStationTangent = best.actualStationTangent
		needsRoad = best.needsRoad
		otherRoadStation= best.therRoadStation
	end 
	
	newProposal.constructionsToAdd[1 + #newProposal.constructionsToAdd]=newConstruction
	indexes.harbourIdx = #newProposal.constructionsToAdd
	if depotConstruction then 
		newProposal.constructionsToAdd[1 + #newProposal.constructionsToAdd]=depotConstruction
		indexes.shipyardIdx = #newProposal.constructionsToAdd
	end
	if roadStationConstruction then 
		newProposal.constructionsToAdd[1 + #newProposal.constructionsToAdd]=roadStationConstruction
		indexes.harbourRoadStationIdx = #newProposal.constructionsToAdd
	end
	if roadDepotConstruction then 
		newProposal.constructionsToAdd[1 + #newProposal.constructionsToAdd]=roadDepotConstruction
		indexes.harbourRoadDepotIdx = #newProposal.constructionsToAdd
	end
	
	return stationPos, actualStationTangent, needsRoad, otherRoadStation
end


local function inverseMapStationLengthParam(length) 
	local lmap = { 0, 1, 2, 3, 5, 7, 9 } -- from stationTemplateFn
	local lmapinv = {}
	for i, v in pairs(lmap) do 
		lmapinv[v]=i
	end 
	if not lmapinv[length] then	
		return length 
	end
	return lmapinv[length]- 2
end
function constructionUtil.getStationLengthParam(stationId) 
	local constructionId= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	if not util.supportedRailStations()[construction.fileName] then 
		trace("Non standard station detected, defaulting")
		return 1
	end
	return construction.params.templateIndex and  inverseMapStationLengthParam(construction.params.length) or construction.params.length
end 
function constructionUtil.getStationLength(stationId)
	local constructionId= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION) 
	if construction.fileName == "station/rail/modular_station/elevated_modular_station.con" then 
		--return (construction.params.length+1)*40
	end 
	--return paramHelper.getStationLength(constructionUtil.getStationLengthParam(stationId)  )
	local countModules = 0
	for i, mod in pairs(util.deepClone(construction.params.modules)) do 
		if string.find(mod.name, "_track") then
			countModules = countModules + 1
		end
	end 
	local terminalCount = #util.getStation(stationId).terminals
	local lengthFactor = math.ceil(countModules/terminalCount)
	trace("The length factor was calculated as",lengthFactor, "based on moduleCount:",moduleCount,"terminalCount=",terminalCount)
	--return paramHelper.getStationLength(constructionUtil.getStationLengthParam(stationId)  )
	return lengthFactor * 40
end 

function constructionUtil.mapStationParamsTracks(stationParams)
	if stationParams.templateIndex then
		stationParams.length = inverseMapStationLengthParam(stationParams.length) -- need to invert the length param to retreive the original
	end
end

function constructionUtil.checkRailDepotForUpgrades(constructionId, params)
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local depotParams = util.deepClone(construction.params)
	local needsUpgrade = false
	if depotParams.catenary == 0 and params.isElectricTrack then 
		needsUpgrade = true
		depotParams.catenary = 1
	end
	if depotParams.trackType == 0 and params.isHighSpeedTrack then 
		needsUpgrade = true
		depotParams.trackType = 1
	end
	if needsUpgrade then  
		trace("About to execute upgradeConstruction for constructionId ",constructionId)
		depotParams.seed = nil
		pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, depotParams)end)
		trace("About set player")
		game.interface.setPlayer(constructionId, game.interface.getPlayer())
		util.clearCacheNode2SegMaps()
	end
end
function constructionUtil.checkStationForUpgrades(stationId, params)
	local constructionId= api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then 
		return 
	end
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	if util.supportedRailStations()[construction.fileName]  then 
		constructionUtil.checkRailStationForUpgrades(stationId,constructionId ,construction,params)
		return 
	end
	if construction.fileName == "station/street/modular_terminal.con" and params.tramTrackType>0 then 
		constructionUtil.checkBusStationForUpgradeTramOnly(stationId) 
		return
	end
	trace("Non standard station detected, skipping")
end
function constructionUtil.checkRailStationForUpgrades(stationId,constructionId ,construction,params)
	local stationParams = util.deepClone(construction.params)
	local inputLength = stationParams.length
	local needsUpgrade = false
	local isElectricUpgrade = false 
	local isHighSpeedUpgrade = false
	if stationParams.catenary ~= 1 and params.isElectricTrack then 
		needsUpgrade = true
		isElectricUpgrade = true
		stationParams.catenary = 1
	end
	if stationParams.trackType ~= 1 and params.isHighSpeedTrack then 
		needsUpgrade = true
		isHighSpeedUpgrade = true
		stationParams.trackType = 1
	end
	local isCargo = util.getStation(stationId).cargo
	if needsUpgrade then 
		local stationPos = util.getStationPosition(stationId)
		constructionUtil.mapStationParamsTracks(stationParams)
		if not stationParams.templateIndex then 
			stationParams.length = inputLength
			isTerminus = stationParams.modules[3699960]
			if isCargo then 
				if isTerminus then 
					stationParams.templateIndex = 7
				else 
					stationParams.templateIndex = 6
				end 
			else 
				if isTerminus then 
					stationParams.templateIndex = 1
				else 
					stationParams.templateIndex = 2
				end 
			end 
		end
		--local modulebasics = helper.createTemplateFn(stationParams, construction.fileName)
		--local modules = util.setupModuleDetailsForTemplate(modulebasics)  
		
		local target
		if isElectricUpgrade and isHighSpeedUpgrade then 
			target = "_high_speed_track_catenary"
		elseif isElectricUpgrade then
			target = "_track_catenary"
		else 
			assert(isHighSpeedUpgrade)
			target = "_high_speed_track"
		end 
		
		for i , mod in pairs(stationParams.modules) do 
			if string.find(mod.name, "_track") and not string.find(mod.name, target) then
				local result = string.gsub(mod.name, "_track", target)
				trace("Changing ",mod.name," to ",result)
				if api.res.moduleRep.find(result) ~= -1 then -- guard against doing something invalid
					mod.name = result
				else 
					trace("WARNING! Invalid result for module upgrade:",result)
				end 
			end
		end 
		trace("About to execute upgradeConstruction for constructionId ",constructionId)
		stationParams.seed = nil
		pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)end)
		trace("About set player")
		game.interface.setPlayer(constructionId, game.interface.getPlayer())
		util.clearCacheNode2SegMaps()
		local depotConstr = constructionUtil.searchForRailDepot(stationPos)
		if depotConstr then 
			constructionUtil.checkRailDepotForUpgrades(depotConstr, params)
		end
	end
	
end

function constructionUtil.searchForNearestRoadStation(p, r , isCargo)
local options = {} 
	for i , station in pairs(util.searchForEntities(p,r, "STATION")) do 
		if station.carriers.ROAD and station.cargo==isCargo then 
			table.insert(options, { station=station.id, scores = { util.distance(p, util.getStationPosition(station.id))}})
		end
	end 
	if #options > 0 then 
		return util.evaluateWinnerFromScores(options).station 
	end
end
function constructionUtil.searchForNearestCargoRoadStation(p, r)
	return constructionUtil.searchForNearestRoadStation(p, r , true)
end

function constructionUtil.validateHarbourConnection(buildResult, result)
	if result.station1 and result.station2 and not result.needsTranshipment1 and not result.needsTranshipment2 then 
		return true 
	end

	if not result.needsTranshipment1 and not result.needsTranshipment2 then 
		local hasTwoStations = #buildResult.resultEntities > 2
		local station1 = api.engine.system.streetConnectorSystem.getConstructionEntityForStation( buildResult.resultEntities[1])
		local edge1 = result.edge1
		local edge2 = result.edge2
		local construction1 = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(result.industry1.id)
		local construction2 = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(result.industry2.id)
		local valid
		local station1 = api.engine.getComponent(buildResult.resultEntities[1], api.type.ComponentType.CONSTRUCTION).stations[1]
		local station2
		if hasTwoStations then 
			station2 = api.engine.getComponent(buildResult.resultEntities[3], api.type.ComponentType.CONSTRUCTION).stations[1]
			valid = util.checkIfStationInCatchmentArea(station1, construction1)  and util.checkIfStationInCatchmentArea(station2, construction2)  
		else 
			-- not sure which one we build for, so check both		 
			valid = util.checkIfStationInCatchmentArea(station1, construction1) or util.checkIfStationInCatchmentArea(station1, construction2) 
			station2 = result.station2 and result.station2 or result.station1 
		end
	 
		if not pathFindingUtil.validateShipPath(station1, station2) then 
			trace("WARNING! Did not make a connection, rolling back")
			constructionUtil.rollbackHarbourConstruction(buildResult)
			return false 
		end
		if valid then 
			return valid
		end
	end 
	
	local function completeTranshipmentRoute(index) 
		local isTown = result.industry2.type == "TOWN" and index == 2
		local indexes = result.constructionIdxs and result.constructionIdxs[index]
		local station1Constr
		local station2Constr  
		if indexes then 
			station1Constr = indexes.harbourRoadStationIdx and buildResult.resultEntities[indexes.harbourRoadStationIdx]
			if indexes.roadStationIdx then 
				station2Constr = buildResult.resultEntities[indexes.roadStationIdx]
				
			elseif not isTown then 
				station2Constr = result.existingRoadStations[index]
			end
		end 
		local harbor = index == 1 and result.station1 or result.station2 
		local industry = index == 1 and result.industry1 or result.industry2
		local newProposal = api.type.SimpleProposal.new()
		if not station1Constr and harbor then 
			local station1 = constructionUtil.searchForNearestCargoRoadStation(util.getStationPosition(harbor),250)
			constructionUtil.checkRoadStationForUpgrade(newProposal, station1, industry, result)
			station1Constr = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station1)
	 
		end 
		if not station2Constr and not isTown then 
			local station2 = constructionUtil.searchForNearestCargoRoadStation(util.v3fromArr(industry.position),250)
			constructionUtil.checkRoadStationForUpgrade(newProposal, station2, industry, result)
			station2Constr = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station2)
		end 
		trace("Completing transhipment route, station constructions were",station1Constr,station2Constr)
		local stations = { 
			util.getConstruction(station1Constr).stations[1],
			isTown and result.truckStop or util.getConstruction(station2Constr).stations[1],
		}
		local hasEntranceB = {
			util.getConstruction(station1Constr).params.entrance_exit_b==1,
			not isTown and util.getConstruction(station2Constr).params.entrance_exit_b==1,
		}
		local params = paramHelper.getDefaultRouteBuildingParams(result.cargoType, false, false) 
		local callback = function(res, success) 
			if success then 
				constructionUtil.addWork(function() 
					local callback2 = function(res, success) 
						if success  then	
							constructionUtil.addWork(function() constructionUtil.lineManager.setupTrucks(result, stations, params) end)	 
						end
						constructionUtil.standardCallback(res, success)
					end 
					local routeInfo =  pathFindingUtil.getRoadRouteInfoBetweenStations(stations[1], stations[2])
					if not routeInfo or routeInfo.exceedsRouteToDistLimitForTrucks and not isTown then 
						routeBuilder.buildRoadRouteBetweenStations(stations, callback2, params,result,hasEntranceB, index)
					else 
						routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, callback2, params) 
					end
				end)
			else 
				trace("Callback to link the road station failed")
			end 
		end

	 
		if indexes then 
			if not isTown and indexes.connectNode then 
				trace("Adding link for connectNode")
				newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=util.buildConnectingRoadToNearestNode(indexes.connectNode, -1, true, newProposal)
			end 
			if  indexes.harbourRoadDepotIdx then 
				trace("Adding link for harbourRoadDepotIdx")
				local depotConstr = buildResult.resultEntities[indexes.harbourRoadDepotIdx]
				local depotNode = util.getEdge(util.getConstruction(depotConstr).frozenEdges[1]).node1
				newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=util.buildConnectingRoadToNearestNode(depotNode, -2, true, newProposal)
			end 
			if indexes.roadDepotIdx then 
				trace("Adding link for roadDepotIdx")
				local depotConstr = buildResult.resultEntities[indexes.roadDepotIdx]
				local depotNode = util.getEdge(util.getConstruction(depotConstr).frozenEdges[1]).node1
				trace("Got depot node it was",depotNode)
				newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=util.buildConnectingRoadToNearestNode(depotNode, -3, false, newProposal)
			end 
			if indexes.harbourConnectNode then
				trace("Adding link for harbourConnectNode")
				newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=util.buildConnectingRoadToNearestNode(indexes.harbourConnectNode, -4, true, newProposal)
			end
		end
		
		
		

		trace("Sending command to link the stations") 
		api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),callback)
	end 
	
	if result.needsTranshipment1 then 
		completeTranshipmentRoute(1)
	end 
	
	if result.needsTranshipment2 then 
		completeTranshipmentRoute(2)
	end 
	
	
	
	return true -- TODO 
end

function constructionUtil.rollbackHarbourConstruction(buildResult)
	local constructionsToRemove = util.deepClone(buildResult.resultEntities)
	local newProposal = api.type.SimpleProposal.new()
	newProposal.constructionsToRemove = constructionsToRemove
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback)
end

function constructionUtil.isTrainStationTerminus(stationId)
	local construction = util.getConstructionForStation(stationId)
	local stationParams = util.deepClone(construction.params)
	if  stationParams.templateIndex then 
		return  stationParams.templateIndex % 2 == 1
	else 
		return  stationParams.modules[3699960]
	end 
end 

 
 
function constructionUtil.buildBusNetworkInitialInfrastructure(newProposal,town, stationPosAndRot, params)
	local perpTangent = stationPosAndRot.busStationPerpTangent
	local tangent = stationPosAndRot.busStationParallelTangent 
	local rotation = stationPosAndRot.busStationRotation
	local busStationPos = stationPosAndRot.originalNodePos - 45*tangent
	
	local busStationRelativeAngle = stationPosAndRot.busStationRelativeAngle
	local platL = params.isCargo and 1 or 2
	local platR = 1
	if busStationRelativeAngle < 0 then
		rotation = math.rad(180)+rotation
		platL = 1
		platR = params.isCargo and 1 or 2
	end
	trace("Bus station relativeAngle for ",town.name," was ",math.deg(busStationRelativeAngle)," removing edge",stationPosAndRot.originalEdgeId)
	
	constructionUtil.buildRoadStation(newProposal, busStationPos, rotation, params, town, true,platL, platR)
	stationPosAndRot.roadStationIdx = #newProposal.constructionsToAdd
	local roadDepotPos = stationPosAndRot.originalNodePos-50*perpTangent+50*tangent
	roadDepotPos.z =  (stationPosAndRot.originalNodePos.z + util.nodePos(stationPosAndRot.otherNode).z)/2
	newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=constructionUtil.createRoadDepotConstruction(town, roadDepotPos, rotation+
	math.rad(180))
	stationPosAndRot.roadDepotIdx = #newProposal.constructionsToAdd
	if #util.getSegmentsForNode(stationPosAndRot.originalNode) <= 2 and not stationPosAndRot.isVirtualDeadEndForTerminus then 
		newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=stationPosAndRot.originalEdgeId
		newProposal.streetProposal.nodesToRemove[1+#newProposal.streetProposal.nodesToRemove]=stationPosAndRot.originalNode
	end
	--[[
	local midPointPos =  util.getEdgeMidPoint(stationPosAndRot.originalEdgeId)
	for __, construction in pairs(util.searchForEntities(midPointPos, 50, "CONSTRUCTION")) do
		trace("Inspecting construction ",construction.id)
		local townBuildingId = construction.townBuildings[1]
		if townBuildingId then 
			local townBuilding = api.engine.getComponent(townBuildingId, api.type.ComponentType.TOWN_BUILDING)
			for ___, parcelId in pairs(townBuilding.parcels) do 
				local parcel = api.engine.getComponent(parcelId, api.type.ComponentType.PARCEL)
				if parcel.streetSegment == stationPosAndRot.originalEdgeId then
					local constructionsToRemove = util.deepClone(newProposal.constructionsToRemove)
					table.insert(constructionsToRemove, construction.id)
					newProposal.constructionsToRemove = constructionsToRemove
					debugPrint({constructionsToRemove=newProposal.constructionsToRemove})
					break
				end
			end
		end
	end
	]]--
	
	--local newNode = util.newNodeWithPosition(stationPosAndRot.originalNodePos)
	--newNode.entity = -stationPosAndRot.originalNode
	
	
	--debugPrint(newProposal)
	
end

function constructionUtil.buildBusStopEdge(edgeId, name, callback) 
	local newProposal =  api.type.SimpleProposal.new()
	constructionUtil.buildBusStopOnProposal(edgeId, newProposal, name)
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	api.cmd.sendCommand(build, callback)
end



function constructionUtil.buildLinkRoad(newProposal, startNode, tangent, maxRemaining, startNodePos, nextNodeId, params, costLimit)
	if not maxRemaining then maxRemaining = paramHelper.getDefaultRouteBuildingParams().maxBusLinkBuildLimit end
	if not costLimit then costLimit = 500000 end 
	if not startNodePos then startNodePos =  util.nodePos(startNode) end
	if not nextNodeId then 
		local nextId = -1000-#newProposal.streetProposal.nodesToAdd
		nextNodeId = function() 
			nextId = nextId -1 
			return nextId
		end
	end
	
	local linkNodePos = startNodePos +90*vec3.normalize(tangent)
	linkNodePos.z = util.th(linkNodePos, true)
	if linkNodePos.z - startNodePos.z > 15 then
		linkNodePos.z = startNodePos.z+15
	elseif startNodePos.z - linkNodePos.z > 15 then 
		linkNodePos.z = startNodePos.z-15
	end 
	local stationLink = initNewEntity(newProposal)
	local linkNode 
	local found = false
	for j = 20, 90, 10 do -- try to find another base node to make a connection with
		
		local testNodePos =  startNodePos +j*vec3.normalize(tangent)
		for i, node in pairs(util.searchForEntities(testNodePos, 25, "BASE_NODE")) do
			local streetSegments = util.getStreetSegmentsForNode(node.id) 
			if not streetSegments then 
			 
				streetSegments = util.getStreetSegmentsForNode(node.id) 
			end
			local hasStreetSegments = #streetSegments > 0
			local canJoin = hasStreetSegments
			for __, seg in pairs(streetSegments) do 
				if util.getStreetTypeCategory(seg)=="highway" then 
					canJoin = false 
					break 
				end
				if util.getEdge(seg).type == 2 then 
					canJoin = false 
					break 
				end
			end 
			
			if canJoin and startNode~=node.id and not util.isNodeConnectedToFrozenEdge(node.id) then
				linkNode = node.id
				linkNodePos = util.nodePos(node.id)
				found=true
				
			end
			
		end
		if found then break end
	end
	local testProposal = api.type.SimpleProposal.new()
	for i, edge in pairs(newProposal.streetProposal.edgesToAdd) do 
		testProposal.streetProposal.edgesToAdd[i]=edge
	end
	for i, edge in pairs(newProposal.streetProposal.edgesToRemove) do 
		testProposal.streetProposal.edgesToRemove[i]=edge
	end
	for i, node in pairs(newProposal.streetProposal.nodesToAdd) do 
		testProposal.streetProposal.nodesToAdd[i]=node
	end
	
	local newNode
	if not linkNode then
		for i, node in pairs(newProposal.streetProposal.nodesToAdd) do 
			if util.positionsEqual(linkNodePos, node.comp.position) then 
				trace("Found a node with the postion")
				linkNode = node.entity 
				break 
			end 
		
		end 
		if not linkNode then 
			newNode = util.newNodeWithPosition(linkNodePos, nextNodeId())
			testProposal.streetProposal.nodesToAdd[1+#testProposal.streetProposal.nodesToAdd]= newNode
		
			linkNode = newNode.entity
		end
	end
	trace("building station link ,linking ",startNode," with ",linkNode)
	stationLink.comp.node0= startNode
	stationLink.comp.node1= linkNode
	local needsTunnel = math.max(util.th(linkNodePos, true),util.th(linkNodePos)) - linkNodePos.z > 10 and math.max(util.th(startNodePos, true),util.th(startNodePos)) - startNodePos.z > 10
	if needsTunnel then 
		stationLink.comp.type = 2 
		stationLink.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	end 
	
	util.setTangentsForStraightEdgeBetweenPositionsFlattened(stationLink, startNodePos, linkNodePos)
	--trace("Setting link on test  proposal")
	testProposal.streetProposal.edgesToAdd[1+#testProposal.streetProposal.edgesToAdd]=stationLink
	--trace("checking test proposal for errors")
	--debugPrint(testProposal)
	local testResult = checkProposalForErrors(testProposal, true)
	 
	if not testResult.isError and (testResult.costs < costLimit or params and params.ignoreCosts) or 
		params and params.ignoreErrors and not testResult.isCriticalError and not testResult.hasWaterMeshCollisions
		and (startNode > 0 or linkNode > 0)

		then 
		--trace("success, adding to main proposal")
		newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=stationLink
		if newNode then 
			newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode 
		end
		if not found  and maxRemaining > 0 then
			-- keep building out in a grid pattern until we make a connection
			found = constructionUtil.buildLinkRoad(newProposal, linkNode, tangent, maxRemaining-1, linkNodePos, nextNodeId, params, costLimit)
			found = found or constructionUtil.buildLinkRoad(newProposal, linkNode, util.rotateXY(tangent, math.rad(90)), maxRemaining-1, linkNodePos, nextNodeId, params, costLimit) 
			found = found or constructionUtil.buildLinkRoad(newProposal, linkNode, util.rotateXY(tangent, -math.rad(90)), maxRemaining-1, linkNodePos, nextNodeId, params, costLimit)
		end
			
	else 
		 trace("not success, not adding to main proposal, linkNode=",linkNode)
		found = false
		if util.tracelog then debugPrint(testResult) end 
	end
	
	return found
end
	

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
	for i, node in pairs(freeNodes) do
		local segs = util.getStreetSegmentsForNode(node)
		for j, seg in pairs(segs) do 
			if not util.isFrozenEdge(seg) and not alreadySeen[seg] then 
				alreadySeen[seg]=true
				testProposal.streetProposal.edgesToRemove[1+#testProposal.streetProposal.edgesToRemove]=seg
			end
		end
		if #segs > 1 then 
			testProposal.streetProposal.nodesToRemove[1+#testProposal.streetProposal.nodesToRemove]=node
		end
	end
	
	
	testProposal.constructionsToRemove = { constructionId} 
	testProposal.constructionsToAdd[1+#testProposal.constructionsToAdd] = newConstruction
	local result = checkProposalForErrors(testProposal, true)
	trace("The check of whether to build on the ",(left and "left" or "right")," was ",result.isError)
	
	return not result.isError
end


function constructionUtil.buildTramOrBusStopsAlongRoute(station1, station2, params, callback, isTram)
	local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(station1, station2)
	local town = api.engine.system.stationSystem.getTown(station1)
	local segmentCount = routeInfo.lastFreeEdge - routeInfo.firstFreeEdge
	trace("The segmentCount of the route was ",segmentCount)
	local halfway = math.floor((routeInfo.firstFreeEdge+routeInfo.lastFreeEdge)/2)
	local startFrom = (segmentCount % 3 == 0 and 3 or 4)+routeInfo.firstFreeEdge  
	local buildEdges = {} 
	if segmentCount <= 6 then 
		buildEdges = { routeInfo.edges[halfway]}
	else 
		local lastIdx =0
		local function edgeIsSuitable(index)
			local edge = routeInfo.edges[index].edge
			local edgeId = routeInfo.edges[index].id
			if edge.type ~= 0 then 
				return false 
			end 
			local minLength = 40 
			local edgeWidth = util.getEdgeWidth(edgeId)
			for __, node in pairs({edge.node0 , edge.node1}) do
				if #util.getTrackSegmentsForNode(node)  > 0 then 
					return false 
				end 
				if #util.getSegmentsForNode(node) > 2  then -- obtuse angle junctions can prevent build
					if #util.getSegmentsForNode(node) == 3 then 
						local details = util.getOutboundNodeDetailsForTJunction(node)
						for __, seg in pairs(util.getSegmentsForNode(node)) do 
							if seg ~= details.edgeId then 
								local otherEdge = util.getEdge(seg)
								local otherTangent = otherEdge.node0 == node and otherEdge.tangent0 or otherEdge.tangent1 
								local angle = math.abs(util.signedAngle(otherTangent, details.tangent)) 
								if angle > math.rad(90) then 
									angle = math.rad(180)- angle
								end 
								local minNodeSize = edgeWidth * (1/math.tan(angle))
								if angle == math.rad(90) then 
									minNodeSize = 0
								end 
								trace("Calculated the minNodeSize as ",minNodeSize," for angle",math.deg(angle))
								minLength = math.max(minLength, edgeWidth+minNodeSize)
							end 
						end 
					else  -- simplified calculation for bigger junctions as calculating the node size is much harder
						local ourTangent = edge.node0 == node and edge.tangent1 or edge.tangent0
						for __, seg in pairs(util.getSegmentsForNode(node)) do 
							if seg ~= edgeId then 
								local otherEdge = util.getEdge(seg)
								local otherTangent = otherEdge.node0 == node and otherEdge.tangent0 or otherEdge.tangent1 
								local angle = math.abs(util.signedAngle(otherTangent,ourTangent)) 
								local angleMod90 = (angle+math.rad(5)) % math.rad(90)
								local overThreashold = angleMod90 > math.rad(10)
								trace("For a multi crossing junction, the angle was",math.deg(angle)," the angleMod90 was",math.deg(angleMod90), " overThreashold?",overThreashold)
								if overThreashold then 
									minLength = math.max(minLength, 70)
								end
							end 
						end 
						
						
					end
				end 
			end
			if util.calculateSegmentLengthFromEdge(edge) < minLength then 
				return false 
			end 
			if #edge.objects > 0 or #routeInfo.edges[index-1].edge.objects > 0 or #routeInfo.edges[index+1].edge.objects > 0 then 
				return false 
			end
			if index - lastIdx <= 1 then 
				return false 
			end
			return util.getStreetTypeCategory(edgeId) == "urban" 
		end
		local function insert(idx) 
			table.insert(buildEdges,routeInfo.edges[idx])
			lastIdx = idx
		end 
		
		for i = startFrom, routeInfo.lastFreeEdge-2, 3 do 
			trace("Building a tram stop on edgeIdx",(i-routeInfo.firstFreeEdge )," of ",segmentCount)
			if edgeIsSuitable(i)then 
				insert(i)
			elseif  edgeIsSuitable(i-1) then 
				insert(i-1)
			elseif edgeIsSuitable(i+1) then
				insert(i+1)
			end
		end 
	end 
	for i , edge in pairs(buildEdges) do 
		local edgeToUse = edge.edge 
		local edgeId = edge.id
		local node0 = edgeToUse.node0 
		local node1 = edgeToUse.node1
		local mode = isTram and _("Tram") or _("Bus")
		local name = api.engine.getComponent(town, api.type.ComponentType.NAME).name.." "..mode.." ".._("stop").." "..tostring(i)
		local newProposal = api.type.SimpleProposal.new()
		constructionUtil.buildBusStopOnProposal(edgeId, newProposal, name)
		local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
		trace("Building tram stops")
		api.cmd.sendCommand(build,function(res, success) 
			util.clearCacheNode2SegMaps()
			if success then 
				constructionUtil.addWork(function() 
					util.lazyCacheNode2SegMaps() 
					local newProposal = api.type.SimpleProposal.new()
					local newEdge = util.findEdgeConnectingNodes(node0, node1)
					constructionUtil.buildBusStopOnProposal(newEdge, newProposal, name)
					--local callbackToUse = i == #buildEdges and callback or constructionUtil.standardCallback
					local callbackToUse = i == 1 and callback or constructionUtil.standardCallback -- work executed in reverse order
					trace("Building second bus stop, will be calling back?",i==1)
					api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), false), callbackToUse)
				end)
			else 
				trace("The tramp stop build failed")
				debugPrint(res)
				callback(res, success)
			end
		end) 
	end
end
function constructionUtil.buildTrainDepotAlongRoute(station1, station2, params, callback,offset )
	local routeInfo = pathFindingUtil.getRouteInfo(station1, station2)
	local town1 = game.interface.getEntity(api.engine.system.stationSystem.getTown(station1))
	local town2 = game.interface.getEntity(api.engine.system.stationSystem.getTown(station2))
	local options = {} 
	if not offset then offset = 15 end
	for i = routeInfo.firstFreeEdge+3, routeInfo.lastFreeEdge-3 do 
		local edge = routeInfo.edges[i].edge
		local newPosAndRot = {}
		local stationParallelTangent = vec3.normalize(util.v3(edge.tangent1))
		local tangentAngle= math.abs(util.signedAngle(edge.tangent0, edge.tangent1))
		local perpTangent = util.rotateXY(stationParallelTangent, math.rad(90))
		local stationRelativeAngle = 0
		newPosAndRot.position = util.nodePos(edge.node1) + offset *perpTangent
		newPosAndRot.rotation= math.rad(90)-util.signedAngle(perpTangent, vec3.new(0, 1,0))
		newPosAndRot.stationPerpTangent = perpTangent
		newPosAndRot.stationParallelTangent = stationParallelTangent
		newPosAndRot.stationRelativeAngle = stationRelativeAngle
		local town 
		if i > 0.5*(routeInfo.firstFreeEdge + routeInfo.lastFreeEdge) then 
			town = town1
 		else 
			town = town2
		end
		local isElectricTrack = util.getTrackEdge(routeInfo.edges[i].id).catenary	
		params.isElectricTrack = params.isElectricTrack or isElectricTrack
		local depot = constructionUtil.createRailDepotConstruction(newPosAndRot, town,  params, forceTerminus)
	
		local checkResult = checkConstructionForCollision(depot)  
		if not checkResult.isError then 
			table.insert(options, { depot = depot , scores = {
				checkResult.costs, 
				util.countNearbyEntities (newPosAndRot.position, 100, "BASE_EDGE"),
				tangentAngle
			}})
		end
			  
		
	end
	trace("Depot along route got ",#options)
	if #options == 0 and offset < 50 then 
		trace("Attempting again")
		constructionUtil.buildTrainDepotAlongRoute(station1, station2, params, callback,offset+5 )
		return
	end 
	local option = util.evaluateWinnerFromScores(options) 
	local newProposal = api.type.SimpleProposal.new()
	newProposal.constructionsToAdd[1]=option.depot
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	trace("Building train depot")
	api.cmd.sendCommand(build,function(res, success) 
		if success then 
			constructionUtil.addWork(function() 
				routeBuilder.buildDepotConnection(callback, res.resultEntities[1], params) 
			end)
		else 
			debugPrint(res)
			callback(res, success)
		end
	end) 
end
function constructionUtil.buildDepotAlongRoute(stations, params, carrier, callback)
	trace("Got command to build depot along route for",carrier)
	local town = api.engine.system.stationSystem.getTown(stations[1])

	local function routeInfoFn() 
		local startFrom = isCircle and 1 or 2
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
	if carrier	 == api.type.enum.Carrier.TRAM then 
		constructionUtil.buildTramDepotAlongRoute(routeInfoFn(),town, params, callback)
	elseif  carrier	 == api.type.enum.Carrier.ROAD then 
		constructionUtil.buildRoadDepotAlongRoute(routeInfoFn(),town, params, callback)
	else 
		assert(false)
	end
end

function constructionUtil.createTramDepotConstruction(naming, position, angle)
	if angle > math.rad(360) then 
		angle = angle - math.rad(360)
	end 
	if angle < -math.rad(360) then 
		angle = angle + math.rad(360)
	end
	local tramDepot = api.type.SimpleProposal.ConstructionEntity.new()
	tramDepot.fileName = "depot/tram_depot_era_a.con"
	tramDepot.playerEntity = api.engine.util.getPlayer()
	 tramDepot.params={
		paramX = 0,  
		paramY = 0, 
		seed = 0, 
		tramCatenary = util.year()>=game.config.tramCatenaryYearFrom and 1 or 0,			
		year = util.year()}
	tramDepot.name = naming.name.." ".._("Tram depot")
	local trnsf = rotZTransl(angle, position)
	tramDepot.transf = util.transf2Mat4f(trnsf)
	return tramDepot
end 

function constructionUtil.upgradeToElectricTramDepot(depotEntity)
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(depotEntity)
	local construction = util.getConstruction(constructionId) 
	local params = util.deepClone(construction.params) 
	params.tramCatenary = 1
	params.seed = nil
	game.interface.upgradeConstruction(constructionId, construction.fileName, params)
	game.interface.setPlayer(constructionId, game.interface.getPlayer())
end 

function constructionUtil.replaceRoadDepotWithTramDepot(roadDepot)
	local roadDepotConstruction = util.getConstruction(roadDepot)
	local tramDepot = api.type.SimpleProposal.ConstructionEntity.new()
	tramDepot.fileName = "depot/tram_depot_era_a.con"
	tramDepot.playerEntity = api.engine.util.getPlayer()
	tramDepot.params={
		paramX = 0,  
		paramY = 0, 
		seed = 0, 
		tramCatenary = util.year()>=game.config.tramCatenaryYearFrom and 1 or 0,			
		year = util.year()}
	local name = api.engine.getComponent(roadDepot, api.type.ComponentType.NAME).name
	tramDepot.name = string.gsub(name,_("Road"),_("Tram"))
	tramDepot.transf = roadDepotConstruction.transf
	
	local roadDepotEdge = util.getEdge(roadDepotConstruction.frozenEdges[1])
	local exitNode = util.isFrozenNode(roadDepotEdge.node0) and roadDepotEdge.node1 or roadDepotEdge.node0 
	local newProposal = api.type.SimpleProposal.new()
	local segs = util.getSegmentsForNode(exitNode)
	local connectNode 
	local frozenEdgeCount = 0
	if #segs > 1 then 
		for __, seg in pairs(segs) do 
			trace("Inspecting ",seg," connected to road depot",roadDepot)
			if not util.isFrozenEdge(seg) then 
				newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=seg 
				local edge = util.getEdge(seg) 
				connectNode = edge.node0 == exitNode and edge.node1 or edge.node0 
			else 
				frozenEdgeCount = frozenEdgeCount + 1
				if frozenEdgeCount > 1 then 
					trace("Found another frozenEdge, aborting!",seg)
					return 
				end
			end 
		end 
		newProposal.streetProposal.nodesToRemove[1]=exitNode
	end 
	newProposal.constructionsToRemove = { roadDepot } 
	newProposal.constructionsToAdd[1] = tramDepot
	
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), false)
	trace("Building tram depot replacement")
	api.cmd.sendCommand(build,function(res, success) 
		trace("Success was:",success)
		if success then 
			constructionUtil.addWork(function() 
				local newProposal = api.type.SimpleProposal.new()
				newProposal.streetProposal.edgesToAdd[1]=util.buildConnectingRoadToNearestNode(connectNode, 1, true, newProposal)
				local build = api.cmd.make.buildProposal(newProposal, util.initContext(), true)
				trace("Building tram depot replacement")
				api.cmd.sendCommand(build,function(res, success) 
					trace("Built linkRoad success was",success)
					constructionUtil.standardCallback(res,success)
				end)
			end)
		else 
			debugPrint(res)
			callback(res, success)
		end
	end) 
end 

function constructionUtil.buildTramDepotAlongRoute(routeInfo, town, params, callback, allowErrors)
	 
	 
	
	local townName = api.engine.getComponent(town, api.type.ComponentType.NAME) 
	local options = {} 
	local offset = 50

	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
		collectgarbage()
		local node = routeInfo.edges[i].edge.node1 
		local nodeDetails = util.getPerpendicularTangentAndDetailsForEdge(routeInfo.edges[i].id)
		for offset = 50, 70, 2 do 
			for j = -1, 1, 2 do 
				--if j==-1 and #util.getSegmentsForNode(node) == 3 or  then goto continue end
				local tangent = j*vec3.normalize(nodeDetails.tangent)
				local position = nodeDetails.nodePos + offset*tangent
				local angle = util.signedAngle(tangent, vec3.new(0,1,0)) --+math.rad(90)
				--if j == -1 then angle = angle + math.rad(180) end
				trace("Checking if can build tram depot for ",townName.name)
				local tramDepot = constructionUtil.createTramDepotConstruction(townName, position, -angle)
				trace("Checking tram depot for collision")
				local checkResult = checkConstructionForCollision(tramDepot) 
				if not checkResult.isError or allowErrors and not checkResult.isCriticalError and #util.getSegmentsForNode(node) < 4 then 
					table.insert(options, { tramDepot = tramDepot, node=nodeDetails.node, scores = {checkResult.costs}})
				end
				
				local edgeId = routeInfo.edges[i].id
				local edge = routeInfo.edges[i].edge
				local p0 = util.nodePos(edge.node0)
				local p1 = util.nodePos(edge.node1)
				local t0 = util.v3(edge.tangent0)
				local t1 = util.v3(edge.tangent1)
				local sol = util.hermite(0.5, p0, t0, p1, t1)
				local tangent = vec3.normalize(util.rotateXY(sol.t, j*math.rad(90)))
				local position = sol.p + offset*tangent
				local angle = util.signedAngle(tangent, vec3.new(0,1,0)) --+math.rad(90)
				--if j == -1 then angle = angle + math.rad(180) end
				trace("Checking if can build tram depot for ",townName.name)
				local tramDepot = constructionUtil.createTramDepotConstruction(townName, position, -angle)
				trace("Checking tram depot for collision")
				local checkResult = checkConstructionForCollision(tramDepot) 
				if not checkResult.isError or allowErrors and not checkResult.isCriticalError then 
					if #edge.objects==0 then 
						table.insert(options, { tramDepot = tramDepot, node=sol.p, isSplit=true, tangent=sol.t, edgeId=edgeId, scores = {checkResult.costs}})
					end
				end
				--if #options > 3 then 
				--	break 
				--end
				::continue:: 
			end
		end
		
	end
	if #options == 0 and not allowErrors then 
		constructionUtil.buildTramDepotAlongRoute(routeInfo, town, params, callback, true)
		return
	end 
	local option = util.evaluateWinnerFromScores(options) 
	local newProposal = api.type.SimpleProposal.new()
	trace("Gotten winner, setting up new proprosal")
	--debugPrint(option.tramDepot)
	newProposal.constructionsToAdd[1]=option.tramDepot
	
	if option.isSplit then 
		local edgeId = option.edgeId
		newProposal.streetProposal.edgesToRemove[1] = edgeId 
		local newNode = util.newNodeWithPosition(option.node, -1000)
		newProposal.streetProposal.nodesToAdd[1]=newNode
		local newEdge1 = util.copyExistingEdge(edgeId, -1)
		local newEdge2 = util.copyExistingEdge(edgeId, -2)
		newEdge1.comp.node1 = newNode.entity
		newEdge2.comp.node0 = newNode.entity
		util.setTangent(newEdge1.comp.tangent1, option.tangent)
		util.setTangent(newEdge2.comp.tangent0, option.tangent)
		--util.rescaleTangents(newEdge1, 0.5)
		--util.rescaleTangents(newEdge2, 0.5)
		local function correctTangentLength(newEntity, p0, p1)
			local tangentLength = util.calculateTangentLength(
				p0, 
				p1, 
				newEntity.comp.tangent0,
				newEntity.comp.tangent1)
				trace("The new tangentLength was calculated as ",tangentLength, " dist p0-p1=", util.distance(p0,p1))
			util.setTangent(newEntity.comp.tangent0, tangentLength*vec3.normalize(util.v3(newEntity.comp.tangent0)))
			util.setTangent(newEntity.comp.tangent1, tangentLength*vec3.normalize(util.v3(newEntity.comp.tangent1)))
		end
		correctTangentLength(newEdge1, util.nodePos(newEdge1.comp.node0), option.node)
		correctTangentLength(newEdge2,  option.node, util.nodePos(newEdge2.comp.node1))
		newProposal.streetProposal.edgesToAdd[1] = newEdge1 
		newProposal.streetProposal.edgesToAdd[2] = newEdge2 
	end
	trace("About to build proposal")
	if allowErrors == nil then 
		allowErrors = false 
	end
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), allowErrors)
	trace("Building tram depot")
	api.cmd.sendCommand(build,function(res, success) 
		if success then 
			constructionUtil.addWork(function() 
				local newProposal = api.type.SimpleProposal.new()
				newProposal.streetProposal.edgesToAdd[1]=util.buildConnectingRoadToNearestNode(option.node, -1) 
				api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), callback)
			end)
		else 
			debugPrint(res)
			callback(res, success)
		end
	end) 
end
function constructionUtil.buildRoadDepotAlongRoute(routeInfo, town, params, callback, allowErrors) 
	local existingDepot =  searchForDepotOfType(game.interface.getEntity(town).position, "road", 500) 
	if existingDepot and false then 
		local depotEntity = api.engine.getComponent(existingDepot, api.type.ComponentType.CONSTRUCTION).depots[1]
		trace("Found a tram road already")
		return
	end
	
	local townName = api.engine.getComponent(town, api.type.ComponentType.NAME) 
	local options = {} 
	local offset = 50

	for i = routeInfo.firstFreeEdge, routeInfo.lastFreeEdge do 
		collectgarbage()
		local node = routeInfo.edges[i].edge.node1 
		local nodeDetails = util.getPerpendicularTangentAndDetailsForEdge(routeInfo.edges[i].id)
		for offset = 40, 70, 2 do 
			for j = -1, 1, 2 do 
				--if j == 1 or offset > 40 then goto continue end
				 
				--if j==-1 and #util.getSegmentsForNode(node) == 3 or #util.getSegmentsForNode(node) > 3 then goto continue end
				local tangent = j*vec3.normalize(nodeDetails.tangent)
				local position = nodeDetails.nodePos + offset*tangent
				local angle = util.signedAngle(tangent, vec3.new(0,1,0)) --+math.rad(90)
				trace("Checking if can build tram road for ",townName.name)
				local tramDepot = constructionUtil.createRoadDepotConstruction(townName, position, -angle)
				trace("Checking road depot for collision")
				local checkResult = checkConstructionForCollision(tramDepot) 
				if not checkResult.isError  and #util.getSegmentsForNode(node) < 4  then 
					table.insert(options, { tramDepot = tramDepot, node=nodeDetails.node, scores = {checkResult.costs}})
				end
				local edgeId = routeInfo.edges[i].id
				local edge = routeInfo.edges[i].edge
				local p0 = util.nodePos(edge.node0)
				local p1 = util.nodePos(edge.node1)
				local t0 = util.v3(edge.tangent0)
				local t1 = util.v3(edge.tangent1)
				local sol = util.hermite(0.5, p0, t0, p1, t1)
				local tangent = vec3.normalize(util.rotateXY(sol.t, j*math.rad(90)))
				--local position = sol.p + offset*
				 local position = sol.p + offset*tangent
				local angle = util.signedAngle(tangent, vec3.new(0,1,0)) --+math.rad(90)
				--if j == -1 then angle = angle + math.rad(180) end
				trace("Checking if can build tram depot for ",townName.name)
				local tramDepot = constructionUtil.createRoadDepotConstruction(townName, position, -angle)
				trace("Checking tram depot for collision")
				local checkResult = checkConstructionForCollision(tramDepot) 
				if not checkResult.isError or allowErrors and not checkResult.isCriticalError  then 
					if #edge.objects==0 then 
						table.insert(options, { tramDepot = tramDepot, node=sol.p, isSplit=true, tangent=sol.t, edgeId=edgeId, scores = {checkResult.costs}})
					end
				end
				--if #options > 3 then 
				--	break 
				--end
				::continue:: 
			end
		end
	end
	if #options == 0 and not allowErrors then 
		constructionUtil.buildRoadDepotAlongRoute(routeInfo, town, params, callback, true)
		return
	end 
	local option = util.evaluateWinnerFromScores(options) 
	local newProposal = api.type.SimpleProposal.new()
	trace("Gotten winner, setting up new proprosal")
	--debugPrint(option.tramDepot)
	newProposal.constructionsToAdd[1]=option.tramDepot
	if option.isSplit then 
		local edgeId = option.edgeId
		newProposal.streetProposal.edgesToRemove[1] = edgeId 
		local newNode = util.newNodeWithPosition(option.node, -1000)
		newProposal.streetProposal.nodesToAdd[1]=newNode
		local newEdge1 = util.copyExistingEdge(edgeId, -1)
		local newEdge2 = util.copyExistingEdge(edgeId, -2)
		newEdge1.comp.node1 = newNode.entity
		newEdge2.comp.node0 = newNode.entity
		util.setTangent(newEdge1.comp.tangent1, option.tangent)
		util.setTangent(newEdge2.comp.tangent0, option.tangent)
		--util.rescaleTangents(newEdge1, 0.5)
		--util.rescaleTangents(newEdge2, 0.5)
		local function correctTangentLength(newEntity, p0, p1)
			local tangentLength = util.calculateTangentLength(
				p0, 
				p1, 
				newEntity.comp.tangent0,
				newEntity.comp.tangent1)
			util.setTangent(newEntity.comp.tangent0, tangentLength*vec3.normalize(util.v3(newEntity.comp.tangent0)))
			util.setTangent(newEntity.comp.tangent1, tangentLength*vec3.normalize(util.v3(newEntity.comp.tangent1)))
		end
		correctTangentLength(newEdge1, util.nodePos(newEdge1.comp.node0), option.node)
		correctTangentLength(newEdge2,  option.node, util.nodePos(newEdge2.comp.node1))
		newProposal.streetProposal.edgesToAdd[1] = newEdge1 
		newProposal.streetProposal.edgesToAdd[2] = newEdge2 
	end
	if allowErrors == nil then 
		allowErrors = false 
	end
	trace("About to build proposal")
	if util.tracelog then debugPrint(newProposal) end
	local build = api.cmd.make.buildProposal(newProposal, util.initContext(), allowErrors)
	trace("Building tram depot")
	api.cmd.sendCommand(build,function(res, success) 
		if success then 
			constructionUtil.addWork(function() 
				local newProposal = api.type.SimpleProposal.new()
				newProposal.streetProposal.edgesToAdd[1]=util.buildConnectingRoadToNearestNode(option.node, -1) 
				api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), false), callback)
			end)
		else 
			debugPrint(res)
			callback(res, success)
		end
	end) 
end
function constructionUtil.upgradeRoadStation(newProposal, station, addTerminal, addEntranceB, executeImmediately, needsTram)
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
		local modules = util.setupModuleDetailsForTemplate(helper.createRoadTemplateFn(params))   
		--[[for k, v in pairs(modules) do 
			if not params.modules[k] then 
				params.modules[k]=v 
			end 
		end ]]--
		params.modules = modules
		if executeImmediately then
			if not needsUpgrade then 
				trace("Skipping as no upgrades were needed", station)
				return 
			end
			trace("About to execute upgradeConstruction for constructionId ",constructionId)
			params.seed = nil
			if not pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end) and params.includeEntryExit then 
				params.includeEntryExit = nil
				pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, params) end)
			end 
			trace("About set player")
			game.interface.setPlayer(constructionId, game.interface.getPlayer())
			util.clearCacheNode2SegMaps()
			return 
		end
		
		local newConstruction = api.type.SimpleProposal.ConstructionEntity.new()
		newConstruction.name=api.engine.getComponent(station, api.type.ComponentType.NAME).name
		
		newConstruction.fileName = construction.fileName
		newConstruction.playerEntity = api.engine.util.getPlayer() 
		 
		newConstruction.params = params  
		newConstruction.transf = construction.transf
	
		
		
		local constructionsToRemove = util.deepClone(newProposal.constructionsToRemove)
		table.insert(constructionsToRemove, constructionId)
		newProposal.constructionsToRemove = constructionsToRemove -- note reassignment of table necessary
		newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd] = newConstruction
		local freeNode
		for i, edgeId in pairs(construction.frozenEdges) do 
			local edge = api.engine.getComponent(edgeId, api.type.ComponentType.BASE_EDGE)
			  freeNode = util.isFrozenNode(edge.node0) and edge.node1 or edge.node0 
			local otherSegs = util.getStreetSegmentsForNode(freeNode)
			if #otherSegs > 1 then 
				local otherEdge = otherSegs[1] == edgeId and otherSegs[2] or otherSegs[1]
				newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=otherEdge
			end
		end

end

function constructionUtil.checkBusStationForUpgrade(station, needsTram) 
	local addTerminal = util.countFreeTerminalsForStation(station) == 0 
	if addTerminal or needsTram then 
		constructionUtil.upgradeRoadStation(nil, station, addTerminal, false, true, needsTram)
	end
end

function constructionUtil.checkBusStationForUpgradeTramOnly(station) 
	constructionUtil.upgradeRoadStation(nil, station, false, false, true, true)
end


function constructionUtil.checkRoadStationForUpgrade(newProposal, station, industry, result)
	local needsExitB = false

	local freeTerminalCount = util.countFreeTerminalsForStation(station)
	local needsTerminal = freeTerminalCount == 0
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	if constructionId == -1 then 
		return false 		
	end
	local otherIndustry = industry == result.industry1 and result.industry2 or result.industry1
	trace("Anout to get construction for station ", station, " constructionId = ",constructionId)
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	if result.needsNewRoute and construction.params.entrance_exit_b ~= 1 and industry.type~="TOWN" then 
		local vectorToIndustry = util.v3fromArr(otherIndustry.position) - util.getStationPosition(station)
		
		local frozenEdges =construction.frozenEdges
		if #frozenEdges == 1 then
			local frozenEdgeTangent = api.engine.getComponent(frozenEdges[1], api.type.ComponentType.BASE_EDGE).tangent1 
			local angle = util.signedAngle(util.v3(frozenEdgeTangent), vectorToIndustry)
			trace("Inspecting station the angle was ",math.deg(angle))
			if math.abs(angle) > math.rad(90) then 
				trace("Determined needs exit b")
				needsExitB = true
			end
		end
		
	end
	if not needsExitB and construction.params.entrance_exit_b ~= 1  and industry.type~="TOWN" then 
		for i, otherStation in pairs(util.searchForEntities(util.getStationPosition(station), 150, "STATION")) do 
			if otherStation.id ~= station then 
				if otherStation.carriers.RAIL then 
					needsExitB = true 
					break 
				end
			end 
		end
	end
	
	local upgraded = false 
	if industry.type=="TOWN" then 
		needsExitB = false 
	end
	if needsExitB or needsTerminal then 
		trace("Upgrading road station",station," for ",industry.name,"needsExitB=",needsExitB,"needsTerminal=",needsTerminal, "freeTerminalCount=",freeTerminalCount)
		constructionUtil.upgradeRoadStation(newProposal, station, needsTerminal, needsExitB, true)
		upgraded = {
			connectNode = freeNode,
			hasEntranceB = needsExitB
		}
	end
	
	local otherIndustryPos = util.v3fromArr(otherIndustry.position)
	local foundSuitableNode = false
	local deadEndNodes = util.searchForDeadEndNodes(util.getStationPosition(station), 200)
	for i, node in pairs(deadEndNodes) do
		
		local vectorToOtherIndustry = otherIndustryPos - util.getStationPosition(station)
		local nodeDetails = util.getDeadEndTangentAndDetailsForEdge(util.getStreetSegmentsForNode(node)[1])
		local angleToVector = util.signedAngle(vectorToOtherIndustry, nodeDetails.tangent) 
		trace("Looking for suitable dead end nodes, for node ",node," the angle to vector was",math.deg(angleToVector))
		if math.abs(angleToVector) < math.rad(60) then 
			foundSuitableNode = true
			break
		end
		
	end
	if result.needsNewRoute and not foundSuitableNode and industry.type~="TOWN" then
		local rotations = { 0, math.rad(90), -math.rad(90) }
		for i = 1, 3 do 
			trace("Determined no dead end nodes near ",industry.name)
			local node = util.getFreeNodesForConstruction(constructionId)[1]
			local segs = util.getStreetSegmentsForNode(node)
			local nextEdgeId = util.isFrozenEdge(segs[1]) and segs[2] or segs[1]
			local nextEdge = util.getEdge(nextEdgeId)
			local nextNode = nextEdge.node0 == node and nextEdge.node1 or nextEdge.node0 
			local tangent = nextEdge.node0 == node and util.v3(nextEdge.tangent1) or -1*util.v3(nextEdge.tangent0)
			tangent = util.rotateXY(tangent, rotations[i])
			local nodePos = util.nodePos(nextNode)
			local newNodePos = nodePos + 160 * vec3.normalize(tangent)
			if util.distance(newNodePos, otherIndustryPos) > util.distance(nodePos, otherIndustryPos) or util.isFrozenNode(nextNode) then 
				goto continue
			end
			local newNode = util.newNodeWithPosition(newNodePos, -1000-#newProposal.streetProposal.edgesToAdd)
			local newEntity = util.copyExistingEdge(nextEdgeId, -1-#newProposal.streetProposal.edgesToAdd)
			newEntity.comp.node0 = nextNode
			newEntity.comp.node1 = newNode.entity
			util.setTangent(newEntity.comp.tangent0, newNodePos-nodePos)
			util.setTangent(newEntity.comp.tangent1, newNodePos-nodePos)
			local testProposal = api.type.SimpleProposal.new()
			testProposal.streetProposal.edgesToAdd[1]=newEntity
			testProposal.streetProposal.nodesToAdd[1]=newNode
			local result = checkProposalForErrors(testProposal)
			if result.isError then 
				trace("Could not build a stub road near industry")
			else 
				trace("Building stub road near industry")
				newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=newEntity
				newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode
				if util.tracelog then debugPrint(newProposal) end
				break
			end
			::continue::
		end
	end
	
	return upgraded
end
 
function constructionUtil.buildRoadStationSplitEdge(edgeId ,params, naming)
	local edge = util.getEdge(edgeId)
	local baseTangent = vec3.new(0,1,0)
	local tangent = util.rotateXY(vec3.normalize(util.v3(edge.tangent0)+util.v3(edge.tangent1)), math.rad(90))
	local angle = util.signedAngle(tangent, baseTangent)
 
	trace("Attempting to place station at mid point")
	local midPoint = 0.5*(util.nodePos(edge.node0) + util.nodePos(edge.node1))
	local offset = 44+0.5*util.getEdgeWidth(edgeId)
	local length = 1
	local stationPos = midPoint +   offset * tangent
	local newProposal = api.type.SimpleProposal.new()
	constructionUtil.buildRoadStation(newProposal, stationPos, -angle, params, naming, hasEntranceB, 1, 2,"",length)
	local isError = checkProposalForErrors(newProposal).isError
	if isError then 
		newProposal = api.type.SimpleProposal.new()
		stationPos = midPoint - offset*tangent 
		angle = angle+math.rad(180)
		constructionUtil.buildRoadStation(newProposal, stationPos, -angle, params, naming, hasEntranceB, 1, 2,"",length)
		isError = checkProposalForErrors(newProposal).isError
	end
	newProposal.streetProposal.edgesToRemove[1] = edgeId 
	local newNode = util.newNodeWithPosition(midPoint, -1000)
	newProposal.streetProposal.nodesToAdd[1]=newNode
	local newEdge1 = util.copyExistingEdge(edgeId, -1)
	local newEdge2 = util.copyExistingEdge(edgeId, -2)
	newEdge1.comp.node1 = newNode.entity
	newEdge2.comp.node0 = newNode.entity
	util.rescaleTangents(newEdge1, 0.5)
	util.rescaleTangents(newEdge2, 0.5)
	newProposal.streetProposal.edgesToAdd[1] = newEdge1 
	newProposal.streetProposal.edgesToAdd[2] = newEdge2 
	return newProposal, isError,midPoint
end  

function constructionUtil.buildBusStationNearestEdge(townId, p, existingStation, callback)
	local naming = api.engine.getComponent(townId, api.type.ComponentType.NAME)
	local options = {}
	if existingStation then 
		for i, edgeIdFull in pairs( api.engine.system.catchmentAreaSystem.getStation2edgesMap()[existingStation]) do
			if util.getEdge(edgeIdFull.entity) then 
				table.insert(options, {
					edgeId = edgeIdFull.entity, 
					scores = { util.distance(p, util.getEdgeMidPoint(edgeIdFull.entity))}
				})
			end 
		end 
	else 
		for edgeId, edge in pairs(util.searchForEntities(p, 250, "BASE_EDGE")) do 
			if not edge.track then 
				table.insert(options, {
					edgeId = edgeId, 
					scores = { util.distance(p, util.getEdgeMidPoint(edgeId))}
				})
			end
		end 
	end 
	local params = {isCargo=false}
	for i, option in pairs(util.evaluateAndSortFromScores(options)) do 
		local newProposal, isError , midPoint = constructionUtil.buildRoadStationSplitEdge(option.edgeId,params, naming)
		trace("Looking at the ",i,"th option, isError?",isError)
		if not isError then 
			api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),
				function(res, success)
					trace("Command to build bus station   was ",success)
					if   success then 
						constructionUtil.addWork(function() 
							local connectNode = util.searchForNearestNode(midPoint)
							local newProposal = api.type.SimpleProposal.new()
							newProposal.streetProposal.edgesToAdd[1]=util.buildConnectingRoadToNearestNode(connectNode, -1-#newProposal.streetProposal.edgesToAdd, true, newProposal)
							api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),function(res2, success)
								callback(res, success)
							end) 
						end)
						if not constructionUtil.searchForNearestRoadStation(p, 750) then 
							constructionUtil.addWork(function() constructionUtil.buildRoadDepotForTownComplete(townId) end)
						end 
					else
						callback(res, success)
						if util.tracelog then 
							debugPrint(res)
						end					
					end
				end)
			break
		end 
	end 
end
function constructionUtil.buildRoadDepotForTownComplete(townId)	
	local town = game.interface.getEntity(townId)
	for i, node in pairs(util.searchForDeadEndNodes(town.position, 750)) do 
		local nodeDetails = util.getDeadEndNodeDetails(node)
		local tangent = vec3.normalize(nodeDetails.tangent)
		local baseTangent = vec3.new(0,1,0)
 
		
		local perpTangent = util.rotateXY(tangent, math.rad(90))
		local angle = util.signedAngle(perpTangent, baseTangent)
		local depotPos = util.nodePos(node) + 60*perpTangent
		local roadDepotConstruction = constructionUtil.createRoadDepotConstruction(town, depotPos, -angle)
		local isError = checkConstructionForCollision(roadDepotConstruction).isError
		trace("Checking road depot for ",node,"isError=",isError)
		if not isError then 
			local newProposal = api.type.SimpleProposal.new() 
			newProposal.constructionsToAdd[1] = roadDepotConstruction
			api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),
				function(res, success)
					trace("Command to build road depot was ",success)
					if   success then 
						constructionUtil.addWork(function() 
							 
							local newProposal = api.type.SimpleProposal.new()
							newProposal.streetProposal.edgesToAdd[1]=util.buildConnectingRoadToNearestNode(node, -1, true, newProposal)
							api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback) 
						end)
					end
				end)
			break 
		end 
	end 
	

end
function constructionUtil.buildTruckStationForIndustry(newProposal,details, result,params, tryOtherNode)
	local offset = 80
	local length = 2
	local townSource=  details.index == 1 and result.industry1.type=="TOWN"
	local town
	if townSource then
		local streetWidth = util.getEdgeWidth(details.edge.id)
		trace("reducing offset for town source, streetWidth was ",streetWidth)
		--offset = 52 
		offset = 44+0.5*streetWidth
		length = 1
		town = result.industry1
	end
	
	local baseTangent = vec3.new(0,1,0)
	local nodedetails = util.getDeadEndTangentAndDetailsForEdge(details.edge.id)
	if tryOtherNode then 
		nodedetails = util.getDeadEndNodeDetails(tryOtherNode)
		if not result.usedNodes then 
			result.usedNodes = {} 
		end 
		result.usedNodes[tryOtherNode]=true
	end
	local originalNodeDetails = nodedetails
	local edge = details.edge
	local tangent =  vec3.normalize(nodedetails.tangent) 
	local perpTangent =  util.rotateXY(tangent, math.rad(90))
	
	if nodedetails.isDeadEnd then 
		tangent = perpTangent
		perpTangent =  util.rotateXY(tangent, -math.rad(90))
	end
	local function nextEntityId() 
		return  -1-#newProposal.streetProposal.edgesToAdd
	end
	
	local stationPos = nodedetails.nodePos + offset * tangent
	local thisIndustry = details.position
	if util.distance(stationPos, thisIndustry) < util.distance(nodedetails.nodePos, thisIndustry) then -- moved into the industry, need to go the other way
		trace("inverting the depot position")
		tangent = -1*tangent
		stationPos = nodedetails.nodePos + offset * tangent
		
	end 
	local baseAngle = util.signedAngle(tangent, baseTangent)
	local angle = baseAngle
	local angleToVector = util.signedAngle(tangent, details.routeVector)
	local angleOfDeadEnd = util.signedAngle(nodedetails.tangent, details.routeVector)
	trace("angle to vector of ",details.name," to route vector was ",math.deg(angleToVector), " connect node was ",nodedetails.node," result.needsNewRoute=",result.needsNewRoute, " angleOfDeadEnd=",math.deg(angleOfDeadEnd))
	local hasStubRoad = false
	local hasEntranceB = false
	if not townSource then 
		for __, station in pairs(util.searchForEntities(stationPos, 200, "STATION")) do 
			if station.carriers.RAIL then 
				trace("Discovered nearby rail station") 
				hasEntranceB = true -- gives more connect options in potentially congested area 
				break
			end
		end
	end
	
	if math.abs(angleToVector) < math.rad(60) and result.needsNewRoute  then
		if not townSource then 
			hasEntranceB=true
		end
	elseif nodedetails.isDeadEnd and result.needsNewRoute and math.abs(angleOfDeadEnd)> math.rad(120) then 
		local nextEdge = details.edge.id
		local nextNode =  nodedetails.otherNode
		local options ={} 
		for i = 1, 5 do 
			local nextEdgeId = util.findNextEdgeInSameDirection(nextEdge, nextNode)
			if not nextEdgeId then break end
			local nextEdge = util.getEdge(nextEdgeId)
			if nextEdge.type ~= 0 then 
				trace("Encountered a non standard edge", nextEdge.type, " exiting")
				break
			end
			nextNode = nextNode == nextEdge.node0 and nextEdge.node1 or nextEdge.node0 
			if i > 2 then 
				if #util.getSegmentsForNode(nextNode) <= 2 then
					local tangent = util.v3(nextNode == nextEdge.node0 and nextEdge.tangent0 or nextEdge.tangent1)
					local angle = util.signedAngle(details.routeVector, tangent)
					local thisOptions = {}
					for j, rotation in pairs({math.rad(90), -math.rad(90)}) do 
						local perpTangent = util.rotateXY(vec3.normalize(tangent), rotation)
						local stubAngleToVector = util.signedAngle(perpTangent, details.routeVector)
						local stubAngleForScoring = math.abs(stubAngleToVector)--math.abs(math.rad(180)-math.abs(stubAngleToVector))
						local position = util.nodePos(nextNode) + 40* perpTangent
						local distance = util.distance(position, details.otherPosition)
						trace("The proposed angle was ",  math.deg(stubAngleToVector), " the angle for scoring was ", math.deg(stubAngleForScoring), " distance=",distance)
						local testOtherPos 
						local testProposal = api.type.SimpleProposal.new()
						util.buildShortStubRoadWithPosition(testProposal, nextNode, position,util.defaultStreetType(), nextEntityId())
						if not checkProposalForErrors(testProposal).isError then 
							table.insert(thisOptions, { 
								proposal = testProposal,
								distance = distance,
								scores = {
									stubAngleForScoring,
									distance
								}
							
							})
						end
					end
					if #thisOptions == 2 then 
						if thisOptions[1].distance < thisOptions[2].distance then 
							table.insert(options, thisOptions[1])
						else 
							table.insert(options, thisOptions[2])
						end
					elseif #thisOptions == 1 then 
						table.insert(options, thisOptions[1])
					end
				end
			end 
			if #util.getSegmentsForNode(nextNode) == 1 then 
				trace("Hit a dead end trying to find another node, exiting")
				break
			end
		end
		if #options > 0 then 
			trace("Building short stub road") 	
			local proposal = util.evaluateWinnerFromScores(options).proposal
			newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=proposal.streetProposal.edgesToAdd[1]
			newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=proposal.streetProposal.nodesToAdd[1]
			hasStubRoad = true
		end
	end
	local count = 0
	local connectNode = nodedetails.node
	local isError = false
	repeat
		trace("Checking road station for collision")
		local dummyProposal = api.type.SimpleProposal.new()
		constructionUtil.buildRoadStation(dummyProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
		isError = checkProposalForErrors(dummyProposal).isError
		if not isError then 
			isError = trialBuildConnectRoad(connectNode, stationPos)
			trace("Was not error but result of trying to build connect road from ",connectNode," to ", stationPos.x, stationPos.y, " was ",isError)
		end 
		if isError and count == 0 then 
			local edgeToChecks = townSource and connectEval.findCentralCargoEdges(town)  or {util.getEdgeIdFromEdge(edge)}
			for i, edgeId in pairs(edgeToChecks) do 
				for j = -1, 1, 2 do 
					local nodedetails=  util.getDeadEndTangentAndDetailsForEdge(edgeId)
					local tangent =  vec3.normalize(nodedetails.tangent) 
					local perpTangent =  util.rotateXY(tangent, j*math.rad(90))
					
					if nodedetails.isDeadEnd then 
						tangent = perpTangent
						perpTangent =  util.rotateXY(tangent, -j*math.rad(90))
					end
					local edge = util.getEdge(edgeId)
					dummyProposal = api.type.SimpleProposal.new()
					angle = util.signedAngle(tangent, baseTangent)
					trace("Attempting to place station at mid point")
					local midPoint = 0.5*(util.nodePos(edge.node0) + util.nodePos(edge.node1))
					if townSource then 
						offset = 44+0.5*util.getEdgeWidth(edgeId)
					end
					stationPos = midPoint +   offset * tangent
					constructionUtil.buildRoadStation(dummyProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
					isError = checkProposalForErrors(dummyProposal).isError
					if isError then 
						dummyProposal = api.type.SimpleProposal.new()
						stationPos = midPoint - offset*tangent 
						angle = angle+math.rad(180)
						constructionUtil.buildRoadStation(dummyProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
						isError = checkProposalForErrors(dummyProposal).isError
					end
					if not isError then 
						trace("Error resolved at the midpoint, splitting road")
						local newNode = util.newNodeWithPosition(midPoint, -edge.node0)
						newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=newNode
						local entity1 = util.copyExistingEdge(edgeId, -1-#newProposal.streetProposal.edgesToAdd)
						entity1.comp.node1=newNode.entity
						local t =  midPoint-util.nodePos(edge.node0)
						util.setTangent(entity1.comp.tangent0,t)
						util.setTangent(entity1.comp.tangent1,t)
						newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity1
						local entity2 = util.copyExistingEdge(edgeId,-1-#newProposal.streetProposal.edgesToAdd)
						entity2.comp.node0=newNode.entity
						util.setTangent(entity2.comp.tangent0,t)
						util.setTangent(entity2.comp.tangent1,t)
						newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=entity2
						newProposal.streetProposal.edgesToRemove[1+#newProposal.streetProposal.edgesToRemove]=edgeId
						connectNode=midPoint
						break
					end 
				end 
				if not isError then 
					break 
				end
			end
			if not isError then 
				break 
			end
		end
		
		if isError then 
			
			 
			local newOffset = offset
			local perpOffset = (count % 4)*20
			if count <= 8 then 
				angle = nodedetails.isDeadEnd and baseAngle+math.rad(90) or baseAngle
				hasEntranceB = not townSource and (perpOffset > 0 or util.signedAngle(perpTangent, details.routeVector) < math.rad(60))
				newOffset = 0
			elseif count <= 16 then
				newOffset = - (count % 4)*20
				angle = baseAngle+ (baseAngle>0 and -math.rad(180) or math.rad(180))
			end 
			 			 
			stationPos = nodedetails.nodePos + perpOffset * perpTangent + newOffset * tangent
			trace("A collsion was detected, attempting to adjust. perpOffset=",perpOffset," angle=",math.deg(angle), " baseAngle = ", math.deg(baseAngle), " newOffset=",newOffset, " trialPos=",stationPos.x,stationPos.y)
		end
		count = count + 1
		--if count == 3 then break end
	until not isError or count > 24
	while isError and count < 32 do
		count = count +1
		angle = baseAngle
		hasEntranceB = not townSource -- helps give us more options in a potentially congested area
		trace("Road station still error, trying another node")
		local segs = util.getStreetSegmentsForNode(nodedetails.otherNode and nodedetails.otherNode or nodedetails.node)
		local nextEdgeId = segs[1] == nodedetails.edgeId and segs[2] or segs[1]
		local nextEdge = util.getEdge(nextEdgeId)
		if nextEdge.type ~= 0 then 
			trace("Found bridge or tunnel, attempting other side")
			nodedetails.edgeId = details.edge.id
			nodedetails.otherNode = originalNodeDetails.node
			goto continue
		end
		connectNode = nextEdge.node0 == nodedetails.otherNode and nextEdge.node1 or nextEdge.node0
		trace("Using connectNode=",connectNode,"nextEdgeId=",nextEdgeId," originalNode=",nodedetails.node," otherNode=",nodedetails.otherNode)
		if #util.getStreetSegmentsForNode(connectNode) == 3 then 
			nodedetails = util.getOutboundNodeDetailsForTJunction(connectNode) 
		elseif #util.getStreetSegmentsForNode(connectNode) == 2  then
			nodedetails = util.getPerpendicularTangentAndDetailsForEdge(nextEdgeId, connectNode)
		end
		nodedetails.tangent.z=0
		for sign = -1, 1, 2 do 
			stationPos = nodedetails.nodePos +sign*offset * vec3.normalize(nodedetails.tangent)
			trace("Attempting to place station at ",stationPos.x, stationPos.y, " offsetSign was ", sign)
			angle =  util.signedAngle(nodedetails.tangent, baseTangent)
			local dummyProposal = api.type.SimpleProposal.new()
			constructionUtil.buildRoadStation(dummyProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
			isError = checkProposalForErrors(dummyProposal).isError
			if not isError then 
				isError = trialBuildConnectRoad(connectNode, stationPos) 
			end 
			if not isError then 
				break 
			end
		end
		::continue::
	end
	if isError and not tryOtherNode and nodedetails.otherNode then 
		trace("Still error, trying other node")
		return constructionUtil.buildTruckStationForIndustry(newProposal,details, result, params,nodedetails.otherNode) 
	end 
	
	
	constructionUtil.buildRoadStation(newProposal, stationPos, -angle, params, details, hasEntranceB, 1, 1,"",length)
	 
	
	if  not hasEntranceB and nodedetails.isDeadEnd and not hasStubRoad and not townSource then
		local testProposal = api.type.SimpleProposal.new()
		util.buildShortStubRoad(testProposal, nodedetails.node, util.smallCountryStreetType(), nextEntityId()) 
		if not checkProposalForErrors(testProposal).isError then 
			util.buildShortStubRoad(newProposal,nodedetails.node, util.smallCountryStreetType(), nextEntityId()) 
		end
	end
	if not result.usedNodes then 
			result.usedNodes = {} 
	end 
	result.usedNodes[connectNode]=true 
	trace("Built road station, the connect node was ",connectNode, " the angle was",math.deg(-angle))
	return  { 
		connectNode = connectNode, 
		hasEntranceB = hasEntranceB ,
		index = details.index,
		isDeadEnd = nodedetails.isDeadEnd ,
		hasStubRoad = hasStubRoad
	}
end

function constructionUtil.buildRoadDepotForSingleIndustry(newProposal, industry, edge,result , stationConstr)
	local offset = 60
	local baseTangent = vec3.new(0,1,0)
	
	if constructionUtil.searchForRoadDepot(industry.position, 500) or industry.type=="TOWN" then 
		return 
	end
	if not edge then return end 
	local edgeId
	if type(edge)=="number" then 
		edgeId = edge 
		edge = util.getEdge(edgeId)
	else 
		edgeId = edge.id 
	end 
    local nodedetails = util.getDeadEndTangentAndDetailsForEdge(edgeId)
	local roadDepotConnectNode = edge.node0 == nodedetails.node and edge.node1 or edge.node0
	if result.usedNodes and result.usedNodes[roadDepotConnectNode] then 
		trace("Aborting road depot build, depot node already used")
		return 
	end
	local tangentRotation = nodedetails.isDeadEnd and math.rad(90) or 0
	local tangent = util.rotateXY(vec3.normalize(nodedetails.tangent), tangentRotation)
	local perpTangent = util.rotateXY(tangent, math.rad(90))
	local roadDepotConnectPos = util.nodePos(roadDepotConnectNode)
	local junctionEdge = util.isJunctionEdge(edgeId)
	if junctionEdge then 
		trace("Aborting road depot build, junctionEdge discovered")
		return 
	end
	local depotPos = roadDepotConnectPos + offset * tangent
	trace("set roadDepotConnectNode=",roadDepotConnectNode, "depotPos=",depotPos.x,depotPos.y)
	local baseAngle = util.signedAngle(tangent, baseTangent) 
	local industryPos = util.v3fromArr(industry.position)
	if util.distance(depotPos, industryPos) < util.distance(nodedetails.nodePos, industryPos) then -- moved into the industry, need to go the other way
		tangent = -1*tangent
		perpTangent = -1*perpTangent
		depotPos = roadDepotConnectPos + offset * tangent
		trace("inverting the depot position, depotPos=",depotPos.x,depotPos.y)
		baseAngle = baseAngle + (baseAngle>0 and -math.rad(180) or math.rad(180))
	end
	local angle = baseAngle
	local roadDepotConstruction
	local isError = false
	local count = 0
	local perpOffsets = { 30, -30 , 60, -60 }
	repeat 
		roadDepotConstruction = constructionUtil.createRoadDepotConstruction(industry, depotPos, -angle)
		isError = checkConstructionForCollision(roadDepotConstruction , stationConstr).isError
		if not isError then 
			isError = trialBuildConnectRoad(roadDepotConnectNode, depotPos) 
		end 
		if  isError then 
			trace("Road depot had a collision, adjusting")
			angle = baseAngle + (count==0 and -math.rad(90) or math.rad(90))
			local perpOffset = perpOffsets[count%#perpOffsets+1]
			offset = 24
			 
			depotPos = roadDepotConnectPos + offset * tangent+ perpOffset * perpTangent
		
		end
		count = count + 1 
	until not isError or count > 4 
	local nextNode = roadDepotConnectNode
	local nextEdge = edgeId 
	while isError and count < 10 do 
		count = count + 1
		local segs = util.getStreetSegmentsForNode(nextNode)
		nextEdge = segs[1]==nextEdge and segs[2] or segs[1] 
		local edge = util.getEdge(nextEdge)
		nextNode = nextNode == edge.node0 and edge.node1 or edge.node0 
		if #util.getSegmentsForNode(nextNode) > 2 then 
			goto continue 
		end 
		local nodeDetails = util.getPerpendicularTangentAndDetailsForEdge(nextEdge, nextNode)

		if result.usedNodes and result.usedNodes[nodeDetails.node] or #util.getSegmentsForNode(nodeDetails.node)>2 or util.isFrozenNode(nodeDetails.node) then 
			goto continue 
		end
		roadDepotConnectNode = nodeDetails.node
		roadDepotConnectPos = nodeDetails.nodePos
		if constructionUtil.searchForRoadDepot(roadDepotConnectPos) then 
			trace("A depot was already discovered, no need to build")
			return
		end
		local offset = 60
		for sign = -1, 1, 2 do 
			local tangent = sign * vec3.normalize(nodeDetails.tangent)
			local depotPos = roadDepotConnectPos + offset * vec3.normalize(tangent)
			
			local angle = util.signedAngle(tangent, baseTangent) 
			trace("set roadDepotConnectNode=",roadDepotConnectNode, "depotPos=",depotPos.x,depotPos.y, " sign=",sign," angle=",math.deg(angle))
			roadDepotConstruction = constructionUtil.createRoadDepotConstruction(industry, depotPos, -angle)
			isError = checkConstructionForCollision(roadDepotConstruction , stationConstr).isError
			if not isError then 
				isError = trialBuildConnectRoad(roadDepotConnectNode, depotPos) 
			end 
			if not isError then break end 
		end
	
		
		::continue::
	end 
	if isError then 
		trace("Skipping construciton of road depot") 
		return 
	end
	trace("Used roadDepotConnectNode",roadDepotConnectNode)
	newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=roadDepotConstruction
	return junctionEdge and roadDepotConnectPos or roadDepotConnectNode
end

function constructionUtil.buildRoadDepotForIndustry(newProposal, result)
	local nodes = {}
 
	if result.industry1.type~="TOWN" then	
		local node = constructionUtil.buildRoadDepotForSingleIndustry(newProposal, result.industry1, result.edge1, result, newProposal.constructionsToAdd[1])
		if node then 
			table.insert(nodes, { node = node, constructionIdx = #newProposal.constructionsToAdd })
		end
	end
 
	if result.industry2.type~="TOWN" then
		local node =constructionUtil.buildRoadDepotForSingleIndustry(newProposal, result.industry2, result.edge2, result, newProposal.constructionsToAdd[#newProposal.constructionsToAdd])
		if node then 	
			table.insert(nodes, { node = node, constructionIdx = #newProposal.constructionsToAdd })
		end
	end
	return nodes
end

function constructionUtil.connectRoadDepotForTown(town)
	local depot = constructionUtil.searchForRoadDepot(town.position, 500)
	local depotNode = util.getFreeNodesForConstruction(depot)[1]
	if #util.getStreetSegmentsForNode(depotNode)==1 then 
		local newProposal = api.type.SimpleProposal.new()
		newProposal.streetProposal.edgesToAdd[1]=util.buildConnectingRoadToNearestNode(depotNode)
		api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true),
			function(res, success)
				trace("Command to build connecting road was ",success)
				if not success then 
					debugPrint(res) 
				end
			end)
	end
end

function constructionUtil.removeStation(stationId)	
	local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	if constructionId == -1 then 
		local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION)
		local edgeId = station.terminals[1].vehicleNodeId.entity
		local newEdge = util.copyExistingEdge(edgeId) 
		local newProposal =api.type.SimpleProposal.new()
		for i, edgeObj in pairs(newEdge.comp.objects) do 
			newProposal.streetProposal.edgeObjectsToRemove[i]=edgeObj[1]
		end
		newEdge.comp.objects = {}
		newProposal.streetProposal.edgesToAdd[1]=newEdge
		newProposal.streetProposal.edgesToRemove[1]=edgeId
		api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback)
	else 
		local newProposal =api.type.SimpleProposal.new()
		newProposal.constructionsToRemove = { constructionId }
		api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback)
	end


end

function constructionUtil.developStationOffside(params) 
	local stationId = params.stationId 
	local stationPos = util.getStationPosition(stationId)
	local busStation = constructionUtil.searchForNearestRoadStation(stationPos, 100 , false)
	local stationLength = constructionUtil.getStationLength(stationId) 
	local constructionId =  api.engine.system.streetConnectorSystem.getConstructionEntityForStation(stationId)
	local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
	local stationParallelTangent = util.v3(construction.transf:cols(1))
	local stationOffset = (stationLength / 40) % 2 == 0 and 20 or 0
	if busStation then 
		local busStationPos = util.getStationPosition(busStation)
		local testP = stationPos - 10 * stationParallelTangent
		if util.distance(testP, busStationPos) > util.distance(stationPos, busStationPos) then 
			trace("Inverting the stationParallelTangent")
			stationParallelTangent = -1*stationParallelTangent
			stationOffset = -stationOffset
		else 
			trace("NOT inverting the stationParallelTangent")
		end 
	
	else 
		trace("WARNING! No bus station found")
	end 
	
	local stationPerpTangent = util.v3(construction.transf:cols(0))
	local stationParams = util.deepClone(construction.params)
	local inputLength = stationParams.length
	local isCargo = util.getStation(stationId).cargo
	trace("Input stationparams.length  was ",stationParams.length," isCargo=",isCargo )
	
	stationParams.includeOffsideBuildings = true
 
	trace("Output stationparams.length  was ", stationParams.length)
	local isTerminus = stationParams.templateIndex and stationParams.templateIndex % 2 == 1
	if not stationParams.templateIndex then 
		stationParams.length = inputLength
		isTerminus = stationParams.modules[3699960]
		if isCargo then 
			if isTerminus then 
				stationParams.templateIndex = 7
			else 
				stationParams.templateIndex = 6
			end 
		else 
			if isTerminus then 
				stationParams.templateIndex = 1
			else 
				stationParams.templateIndex = 2
			end 
		end 
	else 
		constructionUtil.mapStationParamsTracks(stationParams)
	end
	stationParams.tracks = #util.getStation(stationId).terminals - 1
	local modulebasics =helper.createTemplateFn(stationParams, construction.fileName)
	
	local modules = util.setupModuleDetailsForTemplate(modulebasics)   
	stationParams.modules = modules 
	trace("About to execute upgradeConstruction for constructionId ",constructionId)
	stationParams.seed = nil
	pcall(function()game.interface.upgradeConstruction(constructionId, construction.fileName, stationParams)end)
	trace("About set player")
	game.interface.setPlayer(constructionId, game.interface.getPlayer())
	util.lazyCacheNode2SegMaps()
	
	local stationWidth = 5 * (stationParams.tracks+1)*1.5 
	if stationParams.buildThroughTracks then 
		stationWidth = stationWidth + 10
	end 
	local stationPerpOffset = 38
	local offset = stationWidth + stationPerpOffset 
	local smallStreet = util.year() >= 1925 and api.res.streetTypeRep.find("standard/town_small_old.lua") or api.res.streetTypeRep.find("standard/town_small_new.lua")
	local startPoint = offset*stationPerpTangent + stationOffset*stationParallelTangent + stationPos
		
	trace("The calculated station width was", stationWidth, " startPoint was ",startPoint.x, startPoint.y, "stationPerpTangent length=",vec3.length(stationPerpTangent)," stationParallelTangent length=",vec3.length(stationParallelTangent), " stationPos was",stationPos.x, stationPos.y)
	local newProposal = api.type.SimpleProposal.new()
	local nextNodeId = -1000
	local function getNextNodeId() 
		nextNodeId = nextNodeId-1
		return nextNodeId
	end 
	
	
	local startNode = util.newNodeWithPosition(startPoint,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1]=startNode 
	local maxLinks = 3
	constructionUtil.buildLinkRoad(newProposal, startNode.entity, -1*stationParallelTangent, maxLinks, startPoint,  getNextNodeId)
	constructionUtil.buildLinkRoad(newProposal, startNode.entity, stationParallelTangent, maxLinks, startPoint,  getNextNodeId)
	constructionUtil.buildLinkRoad(newProposal, startNode.entity, stationPerpTangent, maxLinks, startPoint,  getNextNodeId)
	local firstNode = newProposal.streetProposal.nodesToAdd[2]
	firstNode.comp.position.z = stationPos.z 
	newProposal.streetProposal.nodesToAdd[2]=firstNode -- seems necessary to copy it back with these objects
	local firstNodePos = util.v3(firstNode.comp.position)
	local streetWidth = 16
	local roadApproach = stationPerpOffset - 0.75*streetWidth
	local roadApproachPos = firstNodePos + roadApproach*stationParallelTangent - roadApproach*stationPerpTangent
	roadApproachPos.z = roadApproachPos.z - 4
	trace("The roadApproachPos was",roadApproachPos.x, roadApproachPos.y)
	local underPassSurfaceNode = util.newNodeWithPosition(roadApproachPos,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=underPassSurfaceNode 
	local underPassLink = initNewEntity(newProposal)
	underPassLink.comp.node0 = firstNode.entity
	underPassLink.comp.node1 = underPassSurfaceNode.entity
	underPassLink.streetEdge.streetType = smallStreet
	local length = roadApproach  * 4 * (math.sqrt(2)-1)
	util.setTangent(underPassLink.comp.tangent0, -length*stationPerpTangent)
	util.setTangent(underPassLink.comp.tangent1, length*stationParallelTangent)
	underPassLink.comp.tangent1.z = -2
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassLink 
	
	local underPassStartPos = roadApproachPos + 25 * vec3.normalize(util.v3(underPassLink.comp.tangent1))
	underPassStartPos.z = underPassStartPos.z - 4
	trace("The underPassStartPos was",underPassStartPos.x, underPassStartPos.y, underPassStartPos.z)
	local underPassRamp = initNewEntity(newProposal) 
	local underPassStartNode = util.newNodeWithPosition(underPassStartPos,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=underPassStartNode  
	underPassRamp.comp.node0 = underPassSurfaceNode.entity 
	underPassRamp.comp.node1 = underPassStartNode.entity 
	underPassRamp.streetEdge.streetType = smallStreet
	local tangent =  underPassStartPos-roadApproachPos
	util.setTangent(underPassRamp.comp.tangent0,tangent)
	util.setTangent(underPassRamp.comp.tangent1,tangent)
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassRamp  
	
	local roadStationOffset = 1.5*streetWidth + stationWidth
	
	local underPassEndPos = underPassStartPos - roadStationOffset*stationPerpTangent
	local underPassEndNode = util.newNodeWithPosition(underPassEndPos,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=underPassEndNode  
	local underPass = initNewEntity(newProposal) 
	underPass.comp.node0 = underPassStartNode.entity 
	underPass.comp.node1 = underPassEndNode.entity 
	local length = roadStationOffset  * 4 * (math.sqrt(2)-1)
	
	util.setTangent(underPass.comp.tangent0, length*vec3.normalize(tangent))
	util.setTangent(underPass.comp.tangent1, -length*vec3.normalize(tangent))
	underPass.comp.type=2
	underPass.comp.typeIndex = api.res.tunnelTypeRep.find("street_old.lua")
	underPass.streetEdge.streetType = smallStreet
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPass  
	
	local roadApproachPos2 = firstNodePos - (roadStationOffset+roadApproach)*stationPerpTangent
	trace("The roadApproachPos2 was",roadApproachPos2.x, roadApproachPos2.y)
	local connectNode =util.searchForNearestNode(roadApproachPos2, 40, function(otherNode) 
		return #util.getTrackSegmentsForNode(otherNode.id)==0 and not util.isFrozenNode(otherNode.id)
	end).id
	trace("The connect node was",connectNode)
	roadApproachPos2.z = util.nodePos(connectNode).z
	
	local underPassSurfaceNode2 = util.newNodeWithPosition(roadApproachPos2,  getNextNodeId() )
	newProposal.streetProposal.nodesToAdd[1+#newProposal.streetProposal.nodesToAdd]=underPassSurfaceNode2 
	local underPassRamp2 = initNewEntity(newProposal)
	underPassRamp2.comp.node0 = underPassEndNode.entity
	underPassRamp2.comp.node1 = underPassSurfaceNode2.entity
	underPassRamp2.streetEdge.streetType = smallStreet
	util.setTangent(underPassRamp2.comp.tangent0,roadApproachPos2-underPassEndPos)
	util.setTangent(underPassRamp2.comp.tangent1,roadApproachPos2-underPassEndPos)
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassRamp2  
	
	
	local underPassLink2 = initNewEntity(newProposal)
	underPassLink2.comp.node0 = underPassSurfaceNode2.entity
	underPassLink2.comp.node1 = connectNode
	underPassLink2.streetEdge.streetType = smallStreet
	local length = roadApproach  * 4 * (math.sqrt(2)-1)
	local tangent= util.nodePos(connectNode)-roadApproachPos2
	util.setTangent(underPassLink2.comp.tangent0, tangent)
	util.setTangent(underPassLink2.comp.tangent1, tangent)
	--underPassLink2.comp.tangent1.z = 2
	newProposal.streetProposal.edgesToAdd[1+#newProposal.streetProposal.edgesToAdd]=underPassLink2 
--	debugPrint(newProposal)
	for i = 1 , #newProposal.streetProposal.nodesToAdd do
		local node = newProposal.streetProposal.nodesToAdd[1]
		local pos2f = api.type.Vec2f.new(node.comp.position.x,node.comp.position.y)
		constructionUtil.addWork(function() 
			api.cmd.sendCommand(api.cmd.make.developTown(pos2f), constructionUtil.standardCallback)
		end)
	end
	api.cmd.sendCommand(api.cmd.make.buildProposal(newProposal, util.initContext(), true), constructionUtil.standardCallback)
 
	
end 

function constructionUtil.buildRoadDepotForTown(newProposal, town)
	if constructionUtil.searchForRoadDepot(town.position, 500) then 
		return
	end
	local options = {}
	 
	for node , nodepos in pairs(connectEval.findDeadEndNodes(town, 500)) do 
		local testProposal = api.type.SimpleProposal.new()
		local nodeDetails = util.getDeadEndTangentAndDetailsForEdge(util.getStreetSegmentsForNode(node)[1])
		local depotPos = nodeDetails.nodePos + 30*vec3.normalize(nodeDetails.tangent) + 30*vec3.normalize(util.rotateXY(nodeDetails.tangent, math.rad(90)))
		local angle = util.signedAngle(vec3.new(0,1,0), vec3.normalize(nodeDetails.tangent))+math.rad(90)
		local roadDepotConstruction = constructionUtil.createRoadDepotConstruction(town, depotPos, angle)
		local testResult = checkConstructionForCollision(roadDepotConstruction , stationConstr)
		if not testResult.isError then 
			table.insert(options, { roadDepotConstruction=roadDepotConstruction, scores={ testResult.costs}})
		end
	end
	if #options > 0 then 
		local roadDepotConstruction = util.evaluateWinnerFromScores(options).roadDepotConstruction
		newProposal.constructionsToAdd[1+#newProposal.constructionsToAdd]=roadDepotConstruction
	end
end

return constructionUtil