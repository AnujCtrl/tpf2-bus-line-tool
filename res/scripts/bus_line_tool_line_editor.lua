-- Editing existing bus and tram lines. Pure planning functions at the top (unit-tested);
-- game-facing load/list (GUI state) and applyEdit (engine state) below.
local lineEditor = {}

-- entities: working list of entity ids in stop order; stopMeta[i] = { origIndex = n } for stops
-- that came from the line, { pending = true } for stops the user added.
function lineEditor.plan(originalStopCount, entities, stopMeta)
	local plan = {}
	for i, entityId in ipairs(entities) do
		local meta = stopMeta[i] or {}
		local origIndex = meta.origIndex
		if origIndex and (origIndex < 1 or origIndex > originalStopCount) then origIndex = nil end
		plan[i] = { entityId = entityId, origIndex = origIndex }
	end
	return plan
end

-- resolveStation(entityId) -> stationId or nil (nil drops the stop, e.g. a street stop that failed to build)
function lineEditor.stationsOnly(plan, resolveStation)
	local stations = {}
	for _, entry in ipairs(plan) do
		local station = resolveStation(entry.entityId)
		if station then stations[#stations + 1] = station end
	end
	return stations
end

---------------------------------------------------------------------------------------------
-- GUI side

function lineEditor.listLines(lineManager)
	local result = {}
	local player = api.engine.util.getPlayer()
	for _, lineId in pairs(api.engine.system.lineSystem.getLines()) do
		local ok = pcall(function()
			local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
			if not line or not lineManager.isBusOrTramLine(line) then return end
			local owned = api.engine.getComponent(lineId, api.type.ComponentType.PLAYER_OWNED)
			if owned and owned.player ~= player then return end
			local name = api.engine.getComponent(lineId, api.type.ComponentType.NAME)
			local firstStation = #line.stops > 0 and lineManager.stationFromStop(line.stops[1]) or nil
			result[#result + 1] = { id = lineId, name = name and name.name or ("line " .. lineId), firstStation = firstStation }
		end)
		if not ok then print("bus_line_tool: could not read line " .. tostring(lineId)) end
	end
	table.sort(result, function(a, b) return a.name < b.name end)
	return result
end

function lineEditor.load(lineId, lineManager)
	local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local name = api.engine.getComponent(lineId, api.type.ComponentType.NAME)
	local stations = {}
	for i, stop in ipairs(line.stops) do stations[i] = lineManager.stationFromStop(stop) end
	return {
		stations = stations,
		name = name and name.name or "",
		isTram = lineManager.isTramLine(line),
		isCircle = lineManager.isCircleLine(line),
		stopCount = #line.stops,
	}
end

---------------------------------------------------------------------------------------------
-- Engine side

local function buildLine(lineId, plan, resolveStation, builder, util)
	local original = api.engine.getComponent(lineId, api.type.ComponentType.LINE)
	local line = api.type.Line.new()
	line.vehicleInfo = original.vehicleInfo
	pcall(function() line.waitingTime = original.waitingTime end)
	local stations = lineEditor.stationsOnly(plan, resolveStation)
	local k = 0
	for i, entry in ipairs(plan) do
		local station = resolveStation(entry.entityId)
		if station then
			k = k + 1
			if entry.origIndex and original.stops[entry.origIndex] then
				line.stops[k] = original.stops[entry.origIndex]
			else
				local nextStation = stations[k % #stations + 1]
				line.stops[k] = builder.createStopForStation(station, util.getStationPosition(nextStation))
			end
		end
	end
	return line, stations
end

function lineEditor.applyEdit(param, deps)
	local builder, util, routeBuilder, paramHelper, lineManager = deps.builder, deps.util, deps.routeBuilder, deps.paramHelper, deps.lineManager
	if not api.engine.entityExists(param.lineId) then
		print("bus_line_tool: line " .. tostring(param.lineId) .. " no longer exists, edit cancelled")
		return
	end
	local loaded = lineEditor.load(param.lineId, lineManager)
	local plan = lineEditor.plan(loaded.stopCount, param.entities, param.stopMeta or {})

	-- Entities that still need a stop pair built on them. Remembered as a set, because once the
	-- proposal is built the old edge ids are gone and util.getEdge() can no longer identify them.
	local edgeIds, positions, isNewEdge = {}, {}, {}
	for _, entry in ipairs(plan) do
		if util.getEdge(entry.entityId) then
			edgeIds[#edgeIds + 1] = entry.entityId
			isNewEdge[entry.entityId] = true
		end
	end

	local function positionOf(entityId)
		if isNewEdge[entityId] then
			local pos = positions[entityId]
			return pos and pos.p or util.getEdgeMidPoint(entityId)
		end
		return util.getStationPosition(entityId)
	end

	local function finish()
		local builtStation = {}
		for _, edgeId in ipairs(edgeIds) do
			local pos = positions[edgeId]
			if pos then
				local nextEntity
				for i, entry in ipairs(plan) do
					if entry.entityId == edgeId then nextEntity = (plan[i % #plan + 1] or entry).entityId end
				end
				local nextPos = nextEntity and positionOf(nextEntity) or pos.p
				builtStation[edgeId] = builder.stationForBuiltStop(pos, nextPos)
			end
		end
		local function resolveStation(entityId)
			if builtStation[entityId] then return builtStation[entityId] end
			if isNewEdge[entityId] then return nil end -- its stop pair could not be found
			return entityId
		end
		local line, stations = buildLine(param.lineId, plan, resolveStation, builder, util)
		if #stations < 2 then
			print("bus_line_tool: edit would leave fewer than two stops, cancelled")
			return
		end
		api.cmd.sendCommand(api.cmd.make.updateLine(param.lineId, line), function(res, success)
			print("bus_line_tool: updateLine " .. tostring(success))
			if not success then return end
			if param.name and param.name ~= "" and param.name ~= loaded.name then
				local ok, err = pcall(function()
					api.cmd.sendCommand(api.cmd.make.setName(param.lineId, param.name), function(_, ok2) print("bus_line_tool: rename " .. tostring(ok2)) end)
				end)
				if not ok then print("bus_line_tool: rename not supported: " .. tostring(err)) end
			end
			if param.addBusLanes or loaded.isTram then
				deps.addWork(function()
					local params = paramHelper.getDefaultRouteBuildingParams("PASSENGERS", false, param.ignoreErrors)
					params.setAddBusLanes(param.addBusLanes)
					if loaded.isTram then params.tramTrackType = util.getCurrentTramTrackType() end
					routeBuilder.checkRoadRouteForUpgradeBetweenStations(stations, deps.standardCallback, params, loaded.isCircle)
				end)
			end
		end)
	end

	if #edgeIds == 0 then
		finish()
		return
	end
	local proposal = builder.buildStopsProposal(edgeIds, positions)
	api.cmd.sendCommand(api.cmd.make.buildProposal(proposal, util.initContext(), param.ignoreErrors), function(res, success)
		print("bus_line_tool: built " .. #edgeIds .. " new stops: " .. tostring(success))
		if success then
			deps.addDelayedWork(finish)
		end
	end)
end

return lineEditor
