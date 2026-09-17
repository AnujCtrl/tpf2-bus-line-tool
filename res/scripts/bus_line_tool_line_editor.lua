-- Editing existing bus and tram lines. Pure planning functions at the top (unit-tested);
-- game-facing load/list (GUI state) and applyEdit (engine state) below.
local function tryLoadUndo()
	local res
	pcall(function() res = require "undo_base_util" end)
	return res
end
local undo_script = tryLoadUndo()

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

-- resolveStation(entityId) -> stationId or nil (nil drops the stop, e.g. a street stop that failed
-- to build). Returns the surviving entries and their stations, same index in both lists.
function lineEditor.resolvePlan(plan, resolveStation)
	local entries, stations = {}, {}
	for __, entry in ipairs(plan) do
		local station = resolveStation(entry.entityId)
		if station then
			entries[#entries + 1] = entry
			stations[#stations + 1] = station
		end
	end
	return entries, stations
end

function lineEditor.stationsOnly(plan, resolveStation)
	local _, stations = lineEditor.resolvePlan(plan, resolveStation)
	return stations
end

-- Does the stop at position k lead somewhere else than it used to? A stop's waypoints describe the
-- leg from that stop to the next one, so they are only still valid when both ends are unchanged.
-- Lines are cyclic: the last stop's successor is the first one.
function lineEditor.successorChanged(plan, k, originalStopCount)
	if #plan == 0 or originalStopCount < 1 then return true end
	local entry = plan[k]
	if not entry or not entry.origIndex then return true end -- a stop the user just added
	local origNext = entry.origIndex % originalStopCount + 1
	local nextEntry = plan[k % #plan + 1]
	return not (nextEntry and nextEntry.origIndex == origNext)
end

-- How many free terminals a station needs to serve this stop, mirroring createBusLine: an end stop
-- of a there-and-back line is visited once, every other stop (and every stop of a circle line, whose
-- reverse line visits it again) is visited twice.
function lineEditor.requiredTerminals(position, count, isCircle)
	return (position > 1 and position < count or isCircle) and 2 or 1
end

---------------------------------------------------------------------------------------------
-- GUI side

function lineEditor.listLines(lineManager)
	local result = {}
	local player = api.engine.util.getPlayer()
	for __, lineId in pairs(api.engine.system.lineSystem.getLines()) do
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
	-- Only the entries that resolved to a station become stops; that filtered order is the new line.
	local resolved, stations = lineEditor.resolvePlan(plan, resolveStation)
	for k, entry in ipairs(resolved) do
		if entry.origIndex and original.stops[entry.origIndex] then
			local stop = original.stops[entry.origIndex]
			-- Waypoints belong to the leg leaving this stop (see lineManager.extendLine): once that
			-- leg goes somewhere else they describe a route the line no longer takes.
			if lineEditor.successorChanged(resolved, k, #original.stops) then stop.waypoints = {} end
			line.stops[k] = stop
		else
			local nextStation = stations[k % #stations + 1]
			line.stops[k] = builder.createStopForStation(stations[k], util.getStationPosition(nextStation))
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
	for __, entry in ipairs(plan) do
		if util.getEdge(entry.entityId) then
			edgeIds[#edgeIds + 1] = entry.entityId
			isNewEdge[entry.entityId] = true
		end
	end

	-- Stations the user added to the line need the same examine/upgrade pass new lines get
	-- (spec section 9 step 1): without a free terminal the stop would silently land on terminal 0.
	-- Stops that were already on the line keep the terminal they have.
	local stationsToExamine = {}
	for position, entry in ipairs(plan) do
		if not isNewEdge[entry.entityId] and entry.origIndex == nil then
			local required = lineEditor.requiredTerminals(position, #plan, loaded.isCircle)
			stationsToExamine[#stationsToExamine + 1] = {
				stationId = entry.entityId,
				terminalsToAdd = math.max(0, required - util.countFreeTerminalsForStation(entry.entityId)),
				needsTram = loaded.isTram,
			}
		end
	end
	local function examine()
		builder.examineStations(stationsToExamine, { createTramLine = loaded.isTram })
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
		for __, edgeId in ipairs(edgeIds) do
			local pos = positions[edgeId]
			if pos then
				local nextEntity
				for i, entry in ipairs(plan) do
					if entry.entityId == edgeId then
						nextEntity = (plan[i % #plan + 1] or entry).entityId
						break
					end
				end
				local nextPos = nextEntity and positionOf(nextEntity) or pos.p
				builtStation[edgeId] = builder.stationForBuiltStop(pos, nextPos)
				if not builtStation[edgeId] then
					print("bus_line_tool: WARNING could not find the built stop for edge " .. tostring(edgeId) .. "; it was left out of the line")
				end
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

	-- Same ordering as createBusLine: examine via addWork (popped first), finish via addDelayedWork.
	if #edgeIds == 0 then
		deps.addWork(examine)
		deps.addDelayedWork(finish)
		return
	end
	local proposal = builder.buildStopsProposal(edgeIds, positions)
	if undo_script then
		pcall(function() undo_script.saveBuildDetailsForUndo(proposal) end)
	end
	api.cmd.sendCommand(api.cmd.make.buildProposal(proposal, util.initContext(), param.ignoreErrors), function(res, success)
		print("bus_line_tool: built " .. #edgeIds .. " new stops: " .. tostring(success))
		if success then
			if undo_script then undo_script.lastResult = res end
			deps.addWork(examine)
			deps.addDelayedWork(finish)
		end
	end)
end

return lineEditor
