local util = require("bus_line_tool_base_util") 
local paramHelper = require("bus_line_tool_base_param_helper")
local pathFindingUtil = require("bus_line_tool_pathfinding_util")
local discovery = require("bus_line_tool_vehicle_discovery")
local vehicleUtil = {}
local trace = util.trace
local reportInconsistent = false
local climate
local g = 9.8
local climateRestrictionsInForce
local function discoverClimate() 
	-- game.config references the default, not the current climate. Not sure about api.res.getGameConfig() this may reference the saved game climate
	for i, fileName in pairs(api.res.autoGroundTexRep.getAll()) do
		if string.find(fileName, "usa") then
			climate = "usa" 
			break
		end
		if string.find(fileName, "tropical") then
			climate = "asia" 
			break
		end
	end
	if not climate then
		climate = "europe"
	end
	climateRestrictionsInForce = true 
	for __, name in pairs(api.res.multipleUnitRep.getAll()) do -- for some reason the muRep seems to be prefiltered, not the model rep
		if climate == "usa" and string.find(name, "asia/") then 
			climateRestrictionsInForce  = false
			break 
		elseif climate == "asia" and string.find(name, "usa/") then 
			climateRestrictionsInForce = false 
			break 
		elseif climate == "europe" and (string.find(name, "usa/") or string.find(name, "asia/")) then 
			climateRestrictionsInForce = false 
			break
		end
	end
	trace("Climate was ", climate," climateRestrictionsInForce=",climateRestrictionsInForce)
end
local function isElectricTrain(transportModes) 
	local mode =  api.type.enum.TransportMode.ELECTRIC_TRAIN + 1 
	return transportModes[mode]==1
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
			if mode == TransportMode.BUS then 
				return "bus"
			elseif mode == TransportMode.TRUCK then
				return "truck"
			elseif mode == TransportMode.TRAIN or mode == TransportMode.ELECTRIC_TRAIN then
				return "train"
			elseif mode == TransportMode.SHIP or mode == TransportMode.SMALL_SHIP then
				return "ship"
			elseif mode == TransportMode.AIRCRAFT or mode == TransportMode.SMALL_AIRCRAFT then
				return "plane"
			elseif mode == TransportMode.TRAM or mode == TransportMode.ELECTRIC_TRAM then
				return "tram"
			else 
				trace("unsupported transport type",mode)
			end
		end
	end
	trace("WARNING! No matching vehicles found")
end
local alwaysAllow = { -- annoying there doesn't seem to be a way to access the vehicle set from the api
	["vehicle/truck/opel_blitz_1930.mdl"]=true ,
	["vehicle/truck/opel_blitz_tanker.mdl"]=true,
	["vehicle/truck/opel_blitz_tipper.mdl"]=true,
	["vehicle/truck/benz1912_lkw.mdl"]=true,
	["vehicle/truck/benz1912_lkw_stake.mdl"]=true,
	["vehicle/truck/man_19_304_1970.mdl"]=true,
	["vehicle/truck/man_19_304_tanker.mdl"]=true,
	["vehicle/truck/man_19_304_tipper.mdl"]=true,
	["vehicle/truck/urban_etruck.mdl"]=true,
	 
	["vehicle/truck/asia/isuzu_elf_tld20_tanker.mdl"]=true, -- europe + usa confirmed
	["vehicle/truck/asia/isuzu_elf_tld20_universal.mdl"]=true,-- europe + usa confirmed
	["vehicle/truck/asia/faw_jiefang_j6p_stake.mdl"]=true,
	["vehicle/truck/asia/faw_jiefang_j6p_tanker.mdl"]=true,
	["vehicle/truck/asia/faw_jiefang_j6p_tipper.mdl"]=true,
	["vehicle/truck/asia/faw_jiefang_j6p_universal.mdl"]=true,

	
	-- buses 
	["vehicle/bus/ecitaro.mdl"]=true,
	["vehicle/bus/volvo_5000.mdl"]=true, -- allowed in USA need to check Asia
	["vehicle/bus/asia/maz_103.mdl"]=true, -- allowed in USA + Europe confirmed
} 

local asiaAllow = {  
	["vehicle/truck/40_tons.mdl"]=true ,
	["vehicle/truck/40_tons_stake.mdl"]=true,
	["vehicle/truck/40_tons_tanker.mdl"]=true, 
} 
local usaAllow = {  
	["vehicle/truck/asia/gaz_3307_tanker.mdl"]=true,
	["vehicle/truck/asia/gaz_3307_tipper.mdl"]=true,
	["vehicle/truck/asia/gaz_3307_universal.mdl"]=true,
} 


local function filterClimateOverride(name, vehicleType, model, climate)
	if climate == "all" then 
		return true 
	end
	if alwaysAllow[name] then return true end
	if vehicleType == "ship" or vehicleType == "plane" then
		return true -- these do not have climate specific vehicles
	end
	
	if (vehicleType == "waggon" or vehicleType=="tram") and model and model.metadata and model.metadata.availability and model.metadata.availability.yearFrom >= 2000 and 
		(vehicleUtil.getCargoCapacity(model, "PASSENGERS") == 0 or vehicleType=="tram") then
		return true
	end
	if climate == "asia" and asiaAllow[name] then 
		return true 
	end
	if climate == "usa" and usaAllow[name] then 
		return true 
	end
	
	if climate == "europe" then
		return not string.find(name, "asia") and not string.find(name,"usa")
	else 
		return string.find(name, climate)
	end
end 

local function filterClimate(name, vehicleType, model)
	
	if not climate then
		discoverClimate() 
	end
	if not climateRestrictionsInForce then 
		return true
	end
	return filterClimateOverride(name, vehicleType, model, climate)
	
end
local function getMuTypeNames() 
	local result = {}
	for __, name in pairs(util.deepClone(api.res.multipleUnitRep.getAll())) do 
		local muType = api.res.multipleUnitRep.find(name)
		local muDetail = api.res.multipleUnitRep.get(muType)
		for ___, vehicle in pairs(muDetail.vehicles) do 
			if not result[vehicle.name] then 
				result[vehicle.name]=true 
			end 
		end 
	end 
	return result
end 

local function getMultipleUnitTypes(params)
	if params.banMu then return {} end
	if not vehicleUtil.muTypes then 
		local result  ={} 
		for __, name in pairs(util.deepClone(api.res.multipleUnitRep.getAll())) do 
			local muType = api.res.multipleUnitRep.find(name)
	
			local muDetail = api.res.multipleUnitRep.get(muType)
			local vehicleDetails = {}
			for ___, vehicle in pairs(muDetail.vehicles) do 
				local modelId = api.res.modelRep.find(vehicle.name)
				local model = api.res.modelRep.get(modelId)
				local isAsia = string.find(name, "asia/")
				local isUsa = string.find(name, "usa/")
				table.insert(vehicleDetails, {model=model, modelId=modelId,isAsia=isAsia, isUsa=isUsa, reversed = not vehicle.forward})
			end 
			table.insert(result, vehicleDetails)
 			
		end
		trace("multiple units found  ",#result)
		vehicleUtil.muTypes = result
	end
	local result = {}
	for i, muType in pairs(vehicleUtil.muTypes) do
		if muType[1].model and muType[1].model.metadata and util.filterYearFromAndTo(muType[1].model.metadata.availability) then
			local isOk = true 
			if params.vehicleRestriction == "usa"   then 
				isOk = muType.isUsa 
			end 
			if params.vehicleRestriction == "asia"   then 
				isOk =  muType.isAsia 
			end 
			if params.vehicleRestriction == "europe"   then 
				isOk = not muType.isAsia and not muType.isUsa
			end 
			if muType[2] and muType[2].model and muType[2].model.metadata then 
				if not util.filterYearFromAndTo(muType[2].model.metadata.availability) then -- HST power car is apparently available from 1850!
					isOk = false
				end 
			end 
			if isOk then 
				table.insert(result, muType)
			end
		end
	end
	return result	
end

local function firstNonNil(...)
	local args = table.pack(...)
    for i=1,args.n do
		if args[i] then
			return args[i]
		end
    end
end

local function trace(...)
	util.trace(...)
end

local function initVehiclePart(params)
	local vehiclePart = api.type.TransportVehiclePart.new()
	vehiclePart.part.loadConfig={0}
	vehiclePart.autoLoadConfig={1} 
	vehiclePart.purchaseTime=api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	if params and params.targetMaintenanceState then 
		vehiclePart.targetMaintenanceState = params.targetMaintenanceState
	else 
		vehiclePart.targetMaintenanceState = paramHelper.getParams().targetMaintenanceState
	end 
	return vehiclePart
end

local function getModelLengthx(model) 
	return model.boundingInfo.bbMax.x - model.boundingInfo.bbMin.x
end

local function getVehicleConfig(vehicle)
	return firstNonNil(vehicle.metadata.railVehicle, vehicle.metadata.roadVehicle, vehicle.metadata.waterVehicle, vehicle.metadata.airVehicle)
end

local function getVehicleMass(vehicle)
	return getVehicleConfig(vehicle).weight
end

local function getVehicleEngine(vehicle)
	local config = getVehicleConfig(vehicle)
	local engine = config.engine and config.engine or config.engines and config.engines[1]
	if not engine then 
		if config.availPower then 
			engine = { power = config.availPower, tractiveEffort = config.availPower } -- ship
		end
		if config.maxThrust then 
			engine = { power = config.maxThrust, tractiveEffort = config.maxThrust } -- plane
		end
	end
	return engine
end

local function getStandardTrackSpeed() 
	return api.res.trackTypeRep.get(api.res.trackTypeRep.find("standard.lua")).speedLimit
end
local function getHighSpeedTrackSpeed() 
	return api.res.trackTypeRep.get(api.res.trackTypeRep.find("high_speed.lua")).speedLimit
end
local function calculateDistanceToAccelerate(power, mass, speed)
	return ((1/3) * mass * speed^3)/power
end
local function calculateDistanceToAccelerateGradient(power, mass, speed, downHillForce )
	--https://physics.stackexchange.com/questions/389945/for-a-car-engine-why-does-velocity-increase-as-force-decreases
	return calculateDistanceToAccelerate(power, mass, speed)-(mass*speed^2 / 2*downHillForce)
end
local function calculateSpeedAtDistance(power, mass, distance)
	return (3*distance*power/mass)^(1/3)
end
local function calculateSpeedAtDistanceWithStartSpeed(power, mass, distance, startSpeed)
	-- https://www.wolframalpha.com/input?i2d=true&i=d%3DIntegrate%5B%5C%2840%29Divide%5Bmv%2Cp%5D%5C%2841%29v%2C%7Bv%2Ca%2Cb%7D%5D+solve+for+b
	return ((mass*startSpeed^3+3*distance*power)/mass)^(1/3)
end

local function calculateDistanceToAccelerateDelta(power, mass, lowSpeed, highSpeed, downHillForce)
	if downHillForce and math.abs(downHillForce) > 1 then 
		local a = lowSpeed
		local b = highSpeed 
		local f = downHillForce
		local p = power
		
		--https://www.wolframalpha.com/input?i2d=true&i=Integrate%5Bv%5C%2840%29Divide%5Bmv%2Cp%5D-Divide%5Bm%2Cf%5D%5C%2841%29%2C%7Bv%2Ca%2Cb%7D%5D
		return (mass *(-2* a^3* f + b^2 *(2* b *f - 3 *p) + 3* a^2 *p))/(6 *f* p)
		--return calculateDistanceToAccelerateGradient(power, mass, highSpeed, downHillForce )-calculateDistanceToAccelerateGradient(power, mass, lowSpeed, downHillForce )
	end
	return calculateDistanceToAccelerate(power, mass, highSpeed)-calculateDistanceToAccelerate(power, mass, lowSpeed)
end

local function calculateTimeToAccelerate(power, mass, lowSpeed, highSpeed)
	local a = lowSpeed
	local b = highSpeed  
	local p = power
	local m= mass
	--https://www.wolframalpha.com/input?i2d=true&i=Integrate%5B%5C%2840%29Divide%5Bmv%2Cp%5D%5C%2841%29%2C%7Bv%2Ca%2Cb%7D%5D
	return ((-a^2 + b^2)*m)/(2*p)
end

local function calculateTimeToAccelerateWithDownHillForce(power, mass, lowSpeed, highSpeed, downHillForce)
	local a = lowSpeed
	local b = highSpeed 
	local f = downHillForce
	local p = power
	local m= mass
	if f == 0 then  
		return calculateTimeToAccelerate(power, mass, lowSpeed, highSpeed)
	end
    --	https://www.wolframalpha.com/input?i2d=true&i=Integrate%5B%5C%2840%29Divide%5Bmv%2Cp%5D-Divide%5Bm%2Cf%5D%5C%2841%29%2C%7Bv%2Ca%2Cb%7D%5D
	return -((a - b) *m *(a* f + b* f - 2* p))/(2* f* p)
end

local function calculateVehicleAcceleration2(power, tractiveEffort, topSpeed, totalMass)
	 
	local fudgeFactor = 0.9 -- seems to be needed to get my numbers in agreement with TPF2
	power = fudgeFactor *power -- units kW
	  
	-- the lowSpeed is the transition point between tractiveEffort and power being the limiting factor 
	local lowSpeed  = power/tractiveEffort
	local initialAcceleration = tractiveEffort / totalMass  -- f = ma -> a = f/m
	local initialTime = lowSpeed/initialAcceleration
	local initialDistance  = 0.5*lowSpeed*initialTime -- distance at lowspeed
	
	
	local d = initialDistance + calculateDistanceToAccelerateDelta(power, totalMass, lowSpeed, topSpeed)
	--trace("time taken to reach the lowspeed of ",lowSpeed," (",api.util.formatSpeed(lowSpeed),") was ",initialTime, " estimated distance=",initialDistance) 
	local lowEnergy = 0.5*totalMass*lowSpeed^2
	local highEnergy = 0.5*totalMass*topSpeed^2
	local difference = highEnergy - lowEnergy
	local t = initialTime + (difference / power) -- time taken to add kinetic energy
	return { 
		t=t, 
		d=d,
		mass = totalMass,
		power=power,
		tractiveEffort=tractiveEffort,
		initialDistance = initialDistance,
		initialTime = initialTime,
		lowSpeed = lowSpeed,
		initialAcceleration =initialAcceleration
	}
end
local function calculateVehicleAcceleration(vehicle, totalMass, numberOfLocomotives) 
	local engine =	getVehicleEngine(vehicle)
	local power = engine.power*numberOfLocomotives -- units kW
	local tractiveEffort = engine.tractiveEffort*numberOfLocomotives -- units kN
	local topSpeed = getVehicleConfig(vehicle).topSpeed -- units m/s
	return calculateVehicleAcceleration2(power, tractiveEffort, topSpeed, totalMass)
end
local function calculateTripTimeOnRouteSection(power, tractiveEffort, topSpeed, totalMass, gradient, distance, startSpeed, debugOutput)
	local theta = math.atan(gradient)
	local downHillForce =  totalMass * math.sin(theta) * g
	if math.abs(gradient) < 0.001 then 
		downHillForce = 0
	end
	-- https://www.reddit.com/r/TransportFever/comments/7h8gvd/fixed_slope_track_gradients/
	local fudgeFactor = 1/3 
	downHillForce = downHillForce * fudgeFactor
	if downHillForce <= 0 then 
		downHillForce = 0 -- not sure the calculations are correct for negatives
		gradient =0
	end
	-- the tfSpeed is the transition point between tractiveEffort and power being the limiting factor 
	local tfSpeed  = power/tractiveEffort
	local initialAcceleration = (tractiveEffort-downHillForce) / totalMass  -- f = ma -> a = f/m
	local initialTime = startSpeed < tfSpeed and (tfSpeed-startSpeed)/initialAcceleration or 0
	if initialTime < 0 or initialTime ~= initialTime then
		-- might happen if insufficient tractive effort, the game behaviour is to crawl at 1km/h 
		local assumedSpeed = 1/3.6 -- 1km/h
		local t = distance / assumedSpeed
		if debugOutput then
			trace(" a low tractive effort was detected, ",tractiveEffort, " vs downHillForce ", downHillForce," crawling, assumedSpeed=",assumedSpeed, " t=",t)
		end
		return {
			speed = assumedSpeed,
			time = t
		}
	end
	local initialDistance  = 0.5*(tfSpeed+startSpeed)*initialTime -- distance at lowspeed
	if initialDistance > distance then 
		local endSpeed = (2*distance*initialAcceleration+startSpeed^2)^0.5
		local t = (endSpeed-startSpeed)/initialAcceleration
		if debugOutput then 
			trace("Vehicle did not reach lowspeed. Calculated endspeed=",endSpeed,"t=",t, " distance=",distance,"gradient=",gradient)
		end
		return {
			speed = endSpeed,
			time = t
		}
	end
	local remainingDistance = distance - initialDistance
	
	local lowerSpeed = math.max(tfSpeed, startSpeed)
	
	
	local balancingSpeed = downHillForce > 0 and math.min(topSpeed, power/downHillForce) or topSpeed
	
	if math.abs(balancingSpeed-startSpeed) <  0.01 then 
		return {
			speed=startSpeed,
			time = distance/startSpeed
		}
	end
	local upperSpeed = balancingSpeed
	if balancingSpeed < lowerSpeed then 
		if debugOutput then 
			local d1 = calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed,balancingSpeed, downHillForce)
			local d2 = calculateDistanceToAccelerateDelta(power, totalMass, balancingSpeed,lowerSpeed, downHillForce)
			local d3 = calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed,balancingSpeed, -downHillForce)
			local d4 = calculateDistanceToAccelerateDelta(power, totalMass, balancingSpeed,lowerSpeed, -downHillForce)
			local d5 = calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed,balancingSpeed, 0)
			local d6 = calculateDistanceToAccelerateDelta(power, totalMass, balancingSpeed,lowerSpeed, 0)
			trace("BalancingSpeed=",balancingSpeed," lowSpeed=",lowerSpeed," d1=",d1,"d2=",d2, " d3=",d3,"d4=",d4, " d5=",d5, " d6=",d6)
			local t1= calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, balancingSpeed, downHillForce)
			local t2= calculateTimeToAccelerateWithDownHillForce(power, totalMass, balancingSpeed, lowerSpeed, downHillForce)
			local t3= calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, balancingSpeed, -downHillForce)
			local t4= calculateTimeToAccelerateWithDownHillForce(power, totalMass, balancingSpeed, lowerSpeed, -downHillForce)
			local t5= calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, balancingSpeed, 0)
			local t6= calculateTimeToAccelerateWithDownHillForce(power, totalMass, balancingSpeed, lowerSpeed, 0)
			trace("t1=",t1,"t2=",t2,"t3=",t3,"t4=",t4, "t5=",t5, " t6=",t6)
		end
		upperSpeed = lowerSpeed
		lowerSpeed = balancingSpeed
		downHillForce = -downHillForce
	end
	
	local potentialEnergy = remainingDistance*gradient*totalMass*g
	local lowEnergy = 0.5*totalMass*lowerSpeed^2
	local highEnergy = 0.5*totalMass*upperSpeed^2+potentialEnergy
	local difference = highEnergy - lowEnergy
	local t = initialTime + math.abs(difference / power) -- time taken to add kinetic energy
	local d = initialDistance + math.abs(calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed,upperSpeed, downHillForce))
	if d > distance  then 
		if downHillForce == 0 then -- analytic solution possible
			local endSpeed = calculateSpeedAtDistanceWithStartSpeed(power, totalMass, distance-initialDistance, lowerSpeed)
			local sectionTime = initialTime + calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, endSpeed, downHillForce)
			if debugOutput then 
				trace("For downHillForce==0 calculated sectiontime =",sectionTime,"  endSpeed=",endSpeed, " over distance " , distance)
			end
			return {
				speed = endSpeed,
				time = sectionTime
			}
		end
		local vlow = lowerSpeed
		local vhigh =upperSpeed
  
		local distanceFn = function(v)
			return initialDistance + math.abs(calculateDistanceToAccelerateDelta(power, totalMass, lowerSpeed , v, downHillForce))
		end
		--if startSpeed > balancingSpeed then 
		--	distanceFn = function(v)
		--		return initialDistance + math.abs(calculateDistanceToAccelerateDelta(power, totalMass, v , upperSpeed, downHillForce))
		--	end
		--end
		local solutionFn = function(v)
			return distanceFn(v)-distance
		end
		local maxIteration = 128
		--local maxRecursions = precision
		local iteration = 1
		local vmid = (vhigh+vlow)/2
		repeat 
			 
			local temp = vmid
			if solutionFn(vmid) > 0 then
				vmid = (vlow+vmid)/2
				vhigh = temp
			else
				vmid = (vhigh+vmid)/2
				vlow = temp
			end
 
			iteration = iteration + 1
		until iteration == maxIteration or math.abs(solutionFn(vmid)) < 1 
		if debugOutput then 
			trace("Solved vlow=",vlow," vhigh=",vhigh," vmid=",vmid," after ", iteration,"iterations tfSpeed=",tfSpeed," balancingSpeed=",balancingSpeed, " initialDistance=",initialDistance, " downHillForce=",downHillForce)
		end
		local endSpeed =vmid
		lowEnergy = 0.5*totalMass*lowerSpeed^2
		highEnergy = 0.5*totalMass*endSpeed^2+potentialEnergy 
		difference = highEnergy - lowEnergy
		t = initialTime + math.abs(difference / power)
		 
 
		local alternativeTime = initialTime + math.abs(calculateTimeToAccelerateWithDownHillForce(power, totalMass,lowerSpeed,upperSpeed, math.abs(downHillForce)))
		local minTime = distance / upperSpeed
		local maxTime = distance / lowerSpeed
		if alternativeTime > maxTime or alternativeTime < minTime then 
			if debugOutput then 
				trace("WARNING! Time calculated not in valid range, min=",minTime, " max=",maxTime, " calculated=",alternativeTime)
			end
			alternativeTime = (minTime+maxTime)/2
		end
		if debugOutput then 
			trace("Vehicle did not reach balancingSpeed. After ",d," Calculated endspeed=",endSpeed,"t=",t, " distance=",distance,"gradient=",gradient, " startSpeed=",startSpeed," recalculated distance=",distanceFn(endSpeed), " alternativeTime=",alternativeTime, " solutionFn(vmid)=",solutionFn(vmid))
		end
		return {
			speed = endSpeed,
			time = alternativeTime
		}
	else 
		
		local remainingDistance = distance - d 
		local remainingTime = remainingDistance / balancingSpeed
		local totalTime = t+remainingTime
		local alternativeTime = remainingTime + calculateTimeToAccelerateWithDownHillForce(power, totalMass, lowerSpeed, upperSpeed, downHillForce)
		if debugOutput then 
			trace("Vehicle DID reach balancingSpeed. Calculated endspeed=",balancingSpeed,"t=",t, " totalTime=",totalTime, " distance=",distance,"gradient=",gradient,"d=",d, " startSpeed=",startSpeed, " initialDistance=",initialDistance, " alternativeTime=",alternativeTime, "remainingTime=",remainingTime)
		end
		local minSpeed = math.min(startSpeed, balancingSpeed)
		local maxSpeed = math.max(startSpeed, balancingSpeed)
		local minTime = distance / maxSpeed
		local maxTime = distance / minSpeed
		if totalTime > maxTime or totalTime < minTime then 
			if debugOutput then 
				trace("WARNING! Time calculated not in valid range, min=",minTime, " max=",maxTime, " calculated=",totalTime)
			end
			totalTime = (minTime+maxTime)/2
		end
		
		return {
			speed = balancingSpeed, 
			time = totalTime
		}
		
		
	end
	

end

local function calculateTripTimeFromRouteSections(params, power, tractiveEffort, topSpeed, mass, gradient, length, speed, isOutbound, debugOutput, zeroGradients)
	local routeSections 
	if isOutbound then 
		routeSections = params.routeInfo.routeSections
	else 
		routeSections = {} 
		for i = #params.routeInfo.routeSections, 1, -1 do 
			local reversedSection = util.deepClone(params.routeInfo.routeSections[i])
			reversedSection.avgGradient = -reversedSection.avgGradient
			table.insert(routeSections, reversedSection) -- reverse the order
		end
	end
	local totalTime = 0
	local speed = 0
	local routeLength = 0
	for i = 1, #routeSections do 
		local length = routeSections[i].length
		local gradient = routeSections[i].avgGradient
		if zeroGradients then 
			gradient =0
		end
		local info = calculateTripTimeOnRouteSection(power, tractiveEffort, topSpeed, mass, gradient, length, speed, debugOutput)
		speed = info.speed
		totalTime = totalTime + info.time 
		routeLength = routeLength + length
	end
	return totalTime
end

local function calculateTripTime(acceleration, params, topSpeed, isOutbound, info)
	local distance = params.distance
	local initialTime = acceleration.t 
	local initialDistance = acceleration.d
	local totalTime = 0
	local power = acceleration.power
	local mass = acceleration.mass
	local lowSpeed = acceleration.lowSpeed 
	local tractiveEffort = acceleration.tractiveEffort
	if initialDistance > distance then 
		local tractiveEffortDistance = acceleration.initialDistance
		if tractiveEffortDistance > distance then 
			totalTime = (2*distance / acceleration.initialAcceleration)^0.5
			trace("The tractiveEffortDistance was greater than distance", tractiveEffortDistance, " vs ",distance, " calculated time=",t)
			 
		else 
			local tractiveEffortTime = acceleration.initialTime	
		
			local terminalSpeed = lowSpeed + calculateSpeedAtDistance(power, mass, distance)-calculateSpeedAtDistance(power, mass, tractiveEffortDistance) 
			totalTime = tractiveEffortTime +  calculateTimeToAccelerate(power, mass, lowSpeed, terminalSpeed)
			--trace("The distance ",distance," was not long enough to reach full speed, terminalSpeed=",terminalSpeed," time =",t)
		end
	else 
		local remainingDistance = distance - initialDistance
		local remainingTime = remainingDistance / topSpeed
		totalTime = initialTime + remainingTime
	end
	local originalTotalTime = totalTime
	if params.routeInfo then 
		totalTime = calculateTripTimeFromRouteSections(params, power, tractiveEffort, topSpeed, mass, gradient, length, speed, isOutbound)
		if reportInconsistent then 
			if math.abs(originalTotalTime-totalTime)/originalTotalTime > 1.5 or math.abs(originalTotalTime-totalTime)/totalTime > 1.5 or totalTime~=totalTime or originalTotalTime~=originalTotalTime or math.abs(totalTime) == math.huge then
				trace("WARNING! Considering actual route parameters, recalculated trip time from ", originalTotalTime, " to ",totalTime, " routeLength was=",routeLength, " vs distance=",distance, " for the consist ",info.leadName)
				local testTime = calculateTripTimeFromRouteSections(params, power, tractiveEffort, topSpeed, mass, gradient, length, speed, isOutbound,true)
				trace("The caclulation a second time gave ", testTime)
				local testTime2 = calculateTripTimeFromRouteSections(params, power, tractiveEffort, topSpeed, mass, gradient, length, speed, isOutbound,true, true)
				trace("The caclulation a third time gave ", testTime2)
			end
		end
	end
	
	return { totalTime = totalTime, originalTotalTime = originalTotalTime }
end 


local function calculateMaxSlope(vehicle, totalMass)
	local tractiveEffort = getVehicleEngine(vehicle).tractiveEffort
	local weight = g*totalMass
	if tractiveEffort > weight then
		return math.huge
	end
	local theta = math.asin(tractiveEffort / weight)
	return math.tan(theta)
end 

local function calculateMaxMassForLocomotive(vehicle)
	local tractiveEffort = getVehicleEngine(vehicle).tractiveEffort
	local maxGradient = paramHelper.getParams().maxGradientTrack
	local theta = math.atan(maxGradient)
	return tractiveEffort / (math.sin(theta) * g)
end 

local function calculateTractiveEffortForMass(mass) 
	local maxGradient = paramHelper.getParams().maxGradientTrack
	local theta = math.atan(maxGradient)
	return mass * math.sin(theta) * g
end 

 
local WANTED_VEHICLE_TYPES = { bus = true, tram = true }

local function discoverVehicles()
	collectgarbage("collect")
	local env = {
		getAllModels = api.res.modelRep.getAll,
		findModel = api.res.modelRep.find,
		getModel = api.res.modelRep.get,
		getModelName = api.res.modelRep.getName,
		getAllCargoTypes = api.res.cargoTypeRep.getAll,
		findCargoType = api.res.cargoTypeRep.find,
		getCargoType = api.res.cargoTypeRep.get,
		log = print,
		clock = os.clock,
		availability = function(name, vehicleType, model)
			local availability = { all = true }
			if filterClimate(name, vehicleType, model) then
				availability.auto = true
			end
			for _, region in pairs({ "europe", "usa", "asia" }) do
				if filterClimateOverride(name, vehicleType, model, region) then
					availability[region] = true
				end
			end
			return availability
		end,
	}
	local result = discovery.run(env, WANTED_VEHICLE_TYPES)
	vehicleUtil.modelAvailablility = result.modelAvailability
	vehicleUtil.cargoIdxLookup = result.cargoIdxLookup
	vehicleUtil.inverseCargoIdxLookup = result.inverseCargoIdxLookup
	vehicleUtil.cargoWeightLookup = result.cargoWeightLookup
	vehicleUtil.cargoCapacityLookup = result.cargoCapacityLookup
	vehicleUtil.locomotiveReplacments = {}
	vehicleUtil.discoveredVehiclesByType = result.byType
	vehicleUtil.modelRepLookup = result.modelRepLookup
	vehicleUtil.modelNameLookup = result.modelNameLookup
	vehicleUtil.lastDiscovery = result
end

local function getAllVehiclesByType(vehicleType)
	if not vehicleUtil.discoveredVehiclesByType then
		discoverVehicles()
	end
	local vehicles = vehicleUtil.discoveredVehiclesByType[vehicleType]
	if not vehicles then
		print("bus_line_tool: WARNING no vehicles of type " .. tostring(vehicleType) .. " were discovered")
		return {}
	end
	return vehicles
end
 
local function findVehiclesOfType(vehicleType, params) 
	local result = {}
	if not params then params = {} end
	if not params.vehicleRestriction then 
		params.vehicleRestriction = "auto" 
	end
	if not params.vehicleFavourites then 
		params.vehicleFavourites = {} 
	end
	for i, model in pairs(getAllVehiclesByType(vehicleType) ) do
		if model.metadata and vehicleUtil.modelAvailablility[i][params.vehicleRestriction] then 
			local availability = model.metadata.availability
			--trace("inspecting vehicle", model.metadata, " index ", i," availability=",availability)
			if util.filterYearFromAndTo(availability) then 
				if not params.vehicleFavourites[vehicleType] or params.vehicleFavourites[vehicleType][i] then 
					table.insert(result, {modelId = i, model=model}) 
				end 
			end 
		end
	end
	return result
end

local function getVehicleDescription(vehicle)
	local baseDescription = _(vehicle.model.metadata.description.name)
	local waggons = vehicleUtil.discoveredVehiclesByType["waggon"]
	if waggons and waggons[vehicle.modelId] then -- it is a waggon - needs some disambiguation
		local name = vehicleUtil.modelNameLookup[vehicle.modelId]
		local region
		if string.find(name, "asia") then 
			region = "asia"
		elseif string.find(name, "usa") then 
			region = "usa"
		end
		if region then 
			baseDescription = baseDescription.." (".._(region)..")"
		end 
		local topSpeed = vehicle.model.metadata.railVehicle.topSpeed
		baseDescription = baseDescription.." "..api.util.formatSpeed(topSpeed)
	end
	return baseDescription
end
vehicleUtil.findVehiclesOfType = findVehiclesOfType 
vehicleUtil.getVehicleDescription = getVehicleDescription
function vehicleUtil.describeVehicle(vehicleDetail)
	local model = vehicleDetail.model
	local capacity = vehicleUtil.cargoCapacityLookup[vehicleDetail.modelId]
	local pax = capacity and capacity["PASSENGERS"] or 0
	local config = getVehicleConfig(model)
	local speed = config and config.topSpeed and api.util.formatSpeed(config.topSpeed) or "?"
	return _(model.metadata.description.name) .. " · " .. tostring(pax) .. " pax · " .. speed
end
paramHelper.findVehiclesOfType = findVehiclesOfType
paramHelper.getVehicleDescription = getVehicleDescription

function vehicleUtil.findBestMatchVehicleOfType(vehicleType, params, scoreWeights , optionalFilterFn)	
	local cargoType = params.cargoType 
	
	local vehicles =  findVehiclesOfType(vehicleType,  params) 
	trace("finding best match vehicle of type",vehicleType," the base number of vehicles was",#vehicles)
	local options = {}
	local filterByCargoType = vehicleUtil.filterByCargoTypeId(cargoType)
	for i, vehicleDetail in pairs(vehicles) do	
		local vehicle = vehicleDetail.model
		local vehicleId = vehicleDetail.modelId
		if optionalFilterFn and not optionalFilterFn(vehicle) then 
			trace("Vehicle",vehicleId," did not meet the optional filter")
			goto continue
		end
		
		if not filterByCargoType(vehicleId) then
			trace("Vehicle",vehicleId," did not meet the cargo filter")
			goto continue 
		end		
		local engine = getVehicleEngine(vehicle)
		local config = getVehicleConfig(vehicle)
		local capacity = vehicleUtil.cargoCapacityLookup[vehicleDetail.modelId][cargoType]
		local meetsCapacity = 0
		if params.targetCapacity then 
			meetsCapacity = math.abs(params.targetCapacity-capacity)
		end 
		table.insert(options, { 
			vehicleDetail = vehicleDetail,
			scores = {
				config.weight/engine.power,
				config.weight/engine.tractiveEffort,
				1/capacity,
				1/config.topSpeed,
				vehicle.metadata.cost.price,
				vehicle.metadata.maintenance.runningCosts,
				vehicle.metadata.emission and vehicle.metadata.emission.idleEmission or 60,
				meetsCapacity
			}
		})
		::continue::
	end
	trace("number of vehicles found=",#options)
--[[	
	if (vehicleType == "tram" or vehicleType == "bus") and util.tracelog then 
		debugPrint({tramOptions=util.evaluateAndSortFromScores(options,scoreWeights),scoreWeights=scoreWeights})
	end
	if vehicleType == "truck" and util.tracelog then 
		debugPrint({truckOptions=util.evaluateAndSortFromScores(options,scoreWeights),scoreWeights=scoreWeights})
	end
	if vehicleType == "ship" and util.tracelog then 
		debugPrint({shipOptions=util.evaluateAndSortFromScores(options,scoreWeights),scoreWeights=scoreWeights})
	end]]--
	local best = util.evaluateWinnerFromScores(options, scoreWeights)
	return best and best.vehicleDetail
end

	
function vehicleUtil.getBestMatchForIntercityBus()
	return vehicleUtil.findBestMatchVehicleOfType("bus", {cargoType="PASSENGERS"},paramHelper.getParams().interCityBusScoreWeights )
end

function vehicleUtil.buildIntercityBus() 
	return vehicleUtil.createVehicleConfig(vehicleUtil.getBestMatchForIntercityBus().modelId)
end 

function vehicleUtil.getBestMatchForUrbanBus()
	return vehicleUtil.findBestMatchVehicleOfType("bus", {cargoType="PASSENGERS"}, paramHelper.getParams().urbanBusScoreWeights)
end

function vehicleUtil.buildUrbanBus() 
	return vehicleUtil.copyConfig(vehicleUtil.createVehicleConfig(vehicleUtil.getBestMatchForUrbanBus().modelId))
end 
local function isCargo(cargoType) 
	if type("cargoType") == "string" then 
		return cargoType ~= "PASSENGERS"
	else 
		return cargoType > 0
	end
end

function vehicleUtil.getWaggonsByCargoType(cargoType, params) 
	local result = {}
	for i, vehicleDetail in pairs(findVehiclesOfType("waggon", params)) do	
		local vehicle = vehicleDetail.modelId
		if vehicleUtil.filterByCargoTypeId(cargoType)(vehicle) then 
			table.insert(result, vehicleDetail)
		end
	end
	return result
end

function vehicleUtil.findBestMatchWaggon( params )
	local options = {}
	local cargoType = params.cargoType
	local targetSpeed = params.isHighSpeedTrack and getHighSpeedTrackSpeed()  or getStandardTrackSpeed()
	for i, vehicleDetail in pairs(vehicleUtil.getWaggonsByCargoType(cargoType, params)) do	
		local vehicle = vehicleDetail.model
	
		 
		local config = getVehicleConfig(vehicle)
		local mass = config.weight
	 
		--local capacity = vehicleUtil.getCargoCapacity(vehicle, cargoType)
		local capacity = vehicleUtil.cargoCapacityLookup[vehicleDetail.modelId][cargoType]
		local length = getModelLengthx(vehicle)
		local differenceFromTargetSpeed = math.abs(targetSpeed - config.topSpeed)
		local underTargetSpeed = math.max(targetSpeed - config.topSpeed ,0)
		local loadSpeed = vehicle.metadata.transportVehicle.loadSpeed
		table.insert(options, { 
			vehicleDetail=vehicleDetail, 
			scores = {
				differenceFromTargetSpeed, 
				underTargetSpeed,
				mass / capacity ,
				length/capacity,
				capacity / loadSpeed
				}			
			}
		)
	end
	trace("number of options found = ",util.size(options))
	return util.evaluateWinnerFromScores(options, paramHelper.getParams().waggonScoreWeights).vehicleDetail
end

local function emptyCompartment(vehicle)
	local transportVehicle = vehicle.metadata.transportVehicle
	for i, compartment in pairs(transportVehicle.compartments) do
		for j, loadConfig in pairs(compartment.loadConfigs) do
			return #loadConfig.cargoEntries == 0
		end
	end
	return true
end

local function getAllAvailableLocomotives(params) 
	local vehicles =  findVehiclesOfType("train", params) 
	local results = {} 
	for i, vehicleDetail in pairs(vehicles) do 
		local vehicle = vehicleDetail.model
		local engine = getVehicleEngine(vehicle)
		if engine and engine.type ~= params.locomotiveRestriction and (not params.isCargo or emptyCompartment(vehicle)) then 
			table.insert(results, vehicleDetail)
		else 
			--trace("No engine found for ",vehicleDetail.modelId)
			--debugPrint(vehicleDetail)
		end
	end
	return results
end

function vehicleUtil.findBestMatchLocomotive(targetSpeed, targetTractiveEffort, filterFn, params )
	 
	local options = {} 
	for i, vehicleDetail in pairs( getAllAvailableLocomotives(params) ) do 	
		local vehicle = vehicleDetail.model
		if filterFn and not filterFn(vehicle) then goto continue end		
		local engine =getVehicleEngine(vehicle)
		local config = getVehicleConfig(vehicle)
		local engineMass = config.weight
		-- need to account for the fact the locomotive has to haul itself (which may be signficant)
		local tractiveEffortForLoco  = calculateTractiveEffortForMass(engineMass)
		local actualTargetTractiveEffort = tractiveEffortForLoco + targetTractiveEffort
		--trace("Calulated the actualTargetTractiveEffort=",actualTargetTractiveEffort," based on targetTractiveEffort=",targetTractiveEffort," and tractiveEffortForLoco=",tractiveEffortForLoco)
		local length = getModelLengthx(vehicle)
		local differenceFromTargetSpeed = math.abs(targetSpeed - config.topSpeed)
		local underTargetSpeed = math.max(targetSpeed - config.topSpeed ,0) -- double penalty for being below the target speed
		table.insert(options, { 
			vehicleDetail=vehicleDetail, 
			scores = {
				differenceFromTargetSpeed,
				underTargetSpeed,
				math.abs(actualTargetTractiveEffort -engine.tractiveEffort),
				engineMass/engine.tractiveEffort,
				length/engine.tractiveEffort,
				vehicle.metadata.cost.price,
				engineMass/engine.power,
				vehicle.metadata.emission and vehicle.metadata.emission.idleEmission or 60
				}			
			}
		)
	
		::continue::
	end
	local weights = paramHelper.getLocomotiveScoreWeights(isCargo)
	return util.evaluateWinnerFromScores(options, weights).vehicleDetail
end



function vehicleUtil.filterByCargoType(cargoType)
	if type(cargoType) == "number" then
		cargoType = api.res.cargoTypeRep.get(cargoType).id
	end
	--trace("Filtering vehicles for cargoType=",cargoType)
	return function(vehicle)
		--trace("inspecting vehicle ", vehicle.metadata.description.name)
		local transportVehicle = vehicle.metadata.transportVehicle
		for i, compartment in pairs(transportVehicle.compartments) do
			for j, loadConfig in pairs(compartment.loadConfigs) do
				for k, cargoEntry in pairs(loadConfig.cargoEntries) do
					if cargoEntry.type==cargoType then
						--trace("vehicle was successful")
						return true
					end
				end
			end
		end
		--trace("vehicle failed")
		return false
	end
end
function vehicleUtil.filterByCargoTypeId(cargoType) 
	return function(vehicleId)
		return vehicleUtil.cargoCapacityLookup[vehicleId][cargoType] > 0
	end
end
function vehicleUtil.getCargoCapacityFromId(vehicleId, cargoType) 
	if not vehicleUtil.cargoCapacityLookup then 
		discoverVehicles()
	end 
	return vehicleUtil.cargoCapacityLookup[vehicleId][cargoType]
end 

function vehicleUtil.getCargoCapacity(vehicle, cargoType)
	if type(cargoType) == "number" then
		cargoType = api.res.cargoTypeRep.get(cargoType).id
	end
	local transportVehicle = vehicle.metadata.transportVehicle
	for i, compartment in pairs(transportVehicle.compartments) do
		for j, loadConfig in pairs(compartment.loadConfigs) do
			for k, cargoEntry in pairs(loadConfig.cargoEntries) do
				if cargoEntry.type==cargoType then
					
					return cargoEntry.capacity
				end
			end
		end
	end

	return 0
	
end

function vehicleUtil.createVehicleConfig(modelId)
	local config = api.type.TransportVehicleConfig.new()
	local vehiclePart = initVehiclePart()
	vehiclePart.part.modelId = modelId
	config.vehicles[1]=vehiclePart
	config.vehicleGroups[1]=1
	return config
end

function vehicleUtil.filterToNonElectricLocomotive(vehicle)
	local engines = vehicle.metadata.railVehicle.engines
	for i, engine in pairs(engines) do
		if engine.type == api.type.enum.VehicleEngineType.ELECTRIC then  
			return false
		end
	end
	return true
end


local function calculateMaxConsistPerLoco(locoInfo, waggonInfo, cargoType)
	local locoMass = getVehicleMass(locoInfo.model)
	--local waggonCapacity = vehicleUtil.getCargoCapacity(waggonInfo.model, cargoType)
	local waggonCapacity = vehicleUtil.cargoCapacityLookup[waggonInfo.modelId][cargoType]
	local waggonMass = getVehicleMass(waggonInfo.model)
	 
	local cargoMass = waggonCapacity * vehicleUtil.cargoWeightLookup[cargoType] / 1000
	local totalwaggonMass = waggonMass + cargoMass
	
	local maxMass =calculateMaxMassForLocomotive(locoInfo.model)
	
	local maxCarriages  = math.floor( (maxMass-locoMass) / totalwaggonMass)
	--trace("maxCarriages calculated as ",maxCarriages,"maxMass=",maxMass,"locoMass=",locoMass,"totalwaggonMass=",totalwaggonMass)
	return math.max(1, maxCarriages) -- prevent downstream errors with zero carriages
end

vehicleUtil.cachedVehicleParts = {}

local function vehiclePartForId(modelId, loadConfigIdx)
	if vehicleUtil.cachedVehicleParts[modelId] then 
		if vehicleUtil.cachedVehicleParts[modelId][loadConfigIdx] then 
			return vehicleUtil.cachedVehicleParts[modelId][loadConfigIdx]
		end 
	else 
		vehicleUtil.cachedVehicleParts[modelId] = {}
	end 
	local vehiclePart = {}
	vehiclePart.part = {}
	vehiclePart.part.loadConfig={loadConfigIdx < 0 and 0 or loadConfigIdx}
	vehiclePart.autoLoadConfig={loadConfigIdx< 0 and 1 or 0} 
	vehiclePart.part.modelId = modelId
	vehiclePart.part.reversed = false
	vehicleUtil.cachedVehicleParts[modelId][loadConfigIdx]=vehiclePart
	return vehiclePart
end

local function assembleConsistForWaggon(targetCapacity, params, waggonInfo, locoInfo, extraLocomotives)
	local config = {}
	config.vehicles = {} 
	config.vehicleGroups = {}
	local cargoType = params.cargoType
	--local waggonCapacity = vehicleUtil.getCargoCapacity(waggonInfo.model, cargoType)
	local waggonCapacity = vehicleUtil.cargoCapacityLookup[waggonInfo.modelId][cargoType]
	local waggonLength = getModelLengthx(waggonInfo.model)
	local waggonMass = getVehicleMass(waggonInfo.model)
 
	local cargoWeight = waggonCapacity * vehicleUtil.cargoWeightLookup[cargoType]
	cargoWeight = cargoWeight / 1000 -- seems to be in kg, everything else is in tons
	local desiredNumberOfWaggons = math.ceil(targetCapacity/waggonCapacity)
	local maxLength = params.stationLength-4 -- have to subtract 4 for the length of the buffer stop
	
	desiredNumberOfWaggons = math.min(math.floor(maxLength/waggonLength), desiredNumberOfWaggons)
	local waggonTopSpeed = waggonInfo.model.metadata.railVehicle.topSpeed
	local targetSpeed = waggonTopSpeed
	local targetTractiveEffort = calculateTractiveEffortForMass((waggonMass+cargoWeight)*desiredNumberOfWaggons)
	--trace("Calculated targetspeed=",targetSpeed," and targetTractiveEffort=",targetTractiveEffort, " for targetCapacity=",targetCapacity, " allowElectricTrains=",allowElectricTrains)
	local filterFn
	if not params.isElectricTrack then 
		filterFn = vehicleUtil.filterToNonElectricLocomotive
	end
	if not locoInfo then 
		locoInfo = vehicleUtil.findBestMatchLocomotive(targetSpeed, targetTractiveEffort, filterFn, params )
	end
	local locoLength = getModelLengthx(locoInfo.model)
	local totalMass = 0
	local emptyMass = totalMass
	--trace("Found loco to use, locoLength=",locoLength)
	
	local maxWaggonsPerLoco  = calculateMaxConsistPerLoco(locoInfo, waggonInfo, cargoType)
	local function calculateLocomotivesRequired() 
		return math.ceil(desiredNumberOfWaggons/maxWaggonsPerLoco)
	end
	
	local numberOfLocomotivesRequired = calculateLocomotivesRequired()
	local function getLength() 
		return desiredNumberOfWaggons*waggonLength +numberOfLocomotivesRequired * locoLength
	end
	local proposedLength = getLength() 
	
	if proposedLength >  maxLength then
		--trace("The proposed length is exceeds station length. proposedLength=",proposedLength," stationlength=",maxLength, " cutting back. targetCapacity was ",targetCapacity)
		numberOfLocomotivesRequired = maxLength / (waggonLength*maxWaggonsPerLoco + locoLength)
		desiredNumberOfWaggons = maxWaggonsPerLoco * numberOfLocomotivesRequired
		--trace("After calculation, the optimal locomotives is ",numberOfLocomotivesRequired, " with ",desiredNumberOfWaggons, " waggons. New length is", getLength(), " theoretical locomotives required is", calculateLocomotivesRequired())
		desiredNumberOfWaggons =  math.max(math.floor(desiredNumberOfWaggons),1)
		numberOfLocomotivesRequired = calculateLocomotivesRequired()
		if getLength() > maxLength then 
			desiredNumberOfWaggons = desiredNumberOfWaggons -1
			numberOfLocomotivesRequired = calculateLocomotivesRequired()
		end
		if maxLength-getLength() > waggonLength then 
			desiredNumberOfWaggons = desiredNumberOfWaggons +1 
		end
		--trace("After rounding, the number of locomotives is ",numberOfLocomotivesRequired, " with ",desiredNumberOfWaggons, " waggons. New length is", getLength(), " theoretical locomotives required is", calculateLocomotivesRequired())
	end
	desiredNumberOfWaggons = math.max(desiredNumberOfWaggons, 1)
	if extraLocomotives then 
		numberOfLocomotivesRequired = math.max(1, numberOfLocomotivesRequired + extraLocomotives)
		while getLength() > maxLength do
			desiredNumberOfWaggons = desiredNumberOfWaggons -1
		end
	end
	
	
	for i = 1, numberOfLocomotivesRequired do  
		if i > 1 and vehicleUtil.locomotiveReplacments[locoInfo.modelId] then 
			config.vehicles[i]=vehiclePartForId(vehicleUtil.locomotiveReplacments[locoInfo.modelId], -1) 
		else 
			config.vehicles[i]=vehiclePartForId(locoInfo.modelId, -1)
		end 
		config.vehicleGroups[i]=1
	end 

	
	--trace("the waggonCapacity=",waggonCapacity," waggonMass=",waggonMass," cargoWeight=",cargoWeight, " numberOfLocomotivesRequired=",numberOfLocomotivesRequired, " desiredNumberOfWaggons=",desiredNumberOfWaggons)
	local loadConfigIdx = vehicleUtil.cargoIdxLookup[waggonInfo.modelId][params.cargoType]-1
	for i = 1,desiredNumberOfWaggons do  
		config.vehicles[i+numberOfLocomotivesRequired]=vehiclePartForId(waggonInfo.modelId, loadConfigIdx)
		config.vehicleGroups[i+numberOfLocomotivesRequired]=1
	end

	return { config = config, waggons = desiredNumberOfWaggons, locomotives = numberOfLocomotivesRequired}
end

local function assembleConsist(targetCapacity, params)
	
	
	local waggonInfo = vehicleUtil.findBestMatchWaggon(params)
	return assembleConsistForWaggon(targetCapacity, params, waggonInfo).config
end

function vehicleUtil.getConsistInfo(transportVehicleConfig, cargoType, params)
	local totalMass =0 
	local emptyMass =0
	local power = 0
	local tractiveEffort = 0
	local capacity = 0
	local cost = 0
	local runningCost = 0
	local emission = 0
	local lifespan = 2^16
	local engineType
	local topSpeed = 2^16 
	local length = 0
	local numCars = 0
	local loadSpeed = 0
	local leadName 
	local trailName
	-- need to discover topSpeed first
	if not vehicleUtil.modelRepLookup then 
		discoverVehicles()
	end
	
	for i, vehiclePart in pairs(transportVehicleConfig.vehicles) do 
		if not vehicleUtil.modelRepLookup[vehiclePart.part.modelId] then 
			vehicleUtil.modelRepLookup[vehiclePart.part.modelId] = api.res.modelRep.get(vehiclePart.part.modelId)
		end
		topSpeed = math.min(topSpeed,vehicleUtil.modelRepLookup[vehiclePart.part.modelId].metadata.railVehicle.topSpeed)
	end
	for i, vehiclePart in pairs(transportVehicleConfig.vehicles) do 
		numCars= numCars+1
		local model = vehicleUtil.modelRepLookup[vehiclePart.part.modelId]
		if i == 1 then 
			leadName = vehicleUtil.modelNameLookup[vehiclePart.part.modelId]
		end
		trailName =  vehicleUtil.modelNameLookup[vehiclePart.part.modelId]
		--local cargoCapacity = vehicleUtil.getCargoCapacity(model, cargoType)
		local cargoCapacity = vehicleUtil.cargoCapacityLookup[vehiclePart.part.modelId] and vehicleUtil.cargoCapacityLookup[vehiclePart.part.modelId][cargoType]  or vehicleUtil.getCargoCapacity(vehicle, cargoType)
		local cargoMass = cargoCapacity * vehicleUtil.cargoWeightLookup[cargoType] / 1000
		capacity = capacity + cargoCapacity
		for j , engine in pairs(model.metadata.railVehicle.engines) do 
			power = power + engine.power
			tractiveEffort = tractiveEffort + engine.tractiveEffort
			engineType = engine.type
		end
		if cargoCapacity > 0 then
			loadSpeed= loadSpeed + model.metadata.transportVehicle.loadSpeed
		end
		if model.metadata.emission then 
			emission = emission + model.metadata.emission.idleEmission
		end
		emptyMass = emptyMass + model.metadata.railVehicle.weight
		totalMass = totalMass + model.metadata.railVehicle.weight+ cargoMass
		lifespan = math.min(lifespan, model.metadata.maintenance.lifespan)
		cost = cost + model.metadata.cost.price
		local thisTopSpeed = model.metadata.railVehicle.topSpeed
		local adjustment = 1-(1-(topSpeed/thisTopSpeed))*(2/3) -- derived from experimentation
		runningCost = runningCost + model.metadata.maintenance.runningCosts*adjustment
		length = length + getModelLengthx(model)
	end
	local emptyAccel = calculateVehicleAcceleration2(power, tractiveEffort, topSpeed, emptyMass)
	local loadedAccel = calculateVehicleAcceleration2(power, tractiveEffort, topSpeed, totalMass)
	local maxLength = params and params.stationLength-4 or paramHelper.getStationLength()-4
	return {
		emptyMass = emptyMass,
		totalMass = totalMass,
		power = power,
		tractiveEffort = tractiveEffort,
		emission = emission,
		emptyAccel=emptyAccel,
		loadedAccel=loadedAccel,
		capacity=capacity,
		length = length,
		topSpeed = topSpeed,
		cost=cost,
		runningCost = runningCost,
		isElectric = engineType == api.type.enum.VehicleEngineType.ELECTRIC, 
		lifespan=lifespan,
		isMaxLength=maxLength-length < length/numCars,
		isHighSpeed = topSpeed > getStandardTrackSpeed() ,
		loadSpeed = loadSpeed,
		leadName = leadName,
		trailName = trailName,
		isVeryHighSpeedTrain = topSpeed > 200 / 3.6, -- 200 km/h in m/s
		numCars = numCars
	}
end
local function buildFromMultipleUnit(multipleUnitInfo, cargoType, targetCapacity, params)
	local numRepeats =1 
	local count = 0
	local result = {}
	local function buildMuConfig(numRepeats)
		local config = api.type.TransportVehicleConfig.new()
		for i = 1, numRepeats do
			for j, vehicleInfo in pairs(multipleUnitInfo) do 
				local car = initVehiclePart(params)
				car.part.modelId = vehicleInfo.modelId
				car.part.reversed = vehicleInfo.reversed and vehicleInfo.reversed or false -- explicit nil to false conversion
				config.vehicles[1+#config.vehicles]=car
				config.vehicleGroups[1+#config.vehicleGroups]=1
			end
		end
		return config
	end
	
	local config = buildMuConfig(1)
	 
	local info = vehicleUtil.getConsistInfo(config, cargoType, params)
	local numRepeats = math.ceil(targetCapacity/info.capacity)
	local maxRepeats = math.floor((params.stationLength-4)/info.length)
	if params.targetThroughput then 
		for i =1 , maxRepeats do 
			numRepeats = i
			if vehicleUtil.estimateThroughputBasedOnConsist(buildMuConfig(i), params).throughput >= params.targetThroughput then 
				break 
			end
		end
	end
	numRepeats = math.min(numRepeats, maxRepeats)
	local results ={} 
	if numRepeats <= maxRepeats then 
		table.insert(results, vehicleUtil.copyConfig(buildMuConfig(numRepeats)))
	end
	-- to give more options to select also build one more and one less than optimal 
	if numRepeats > 1 then 
		table.insert(results, vehicleUtil.copyConfig(buildMuConfig(numRepeats-1)))
	end
	
	if numRepeats < maxRepeats then 
		table.insert(results, vehicleUtil.copyConfig(buildMuConfig(numRepeats+1)))
	end
	
	return results
end

local function evaluateBestPassengerTrainOption(vehicleConfigs,cargoType, targetCapacity, params)
	local choices = {}
	local begin = os.clock()
	for i , vehicleConfig in pairs(vehicleConfigs) do
		--debugPrint({vehicleConfig=vehicleConfig})
		local info = vehicleUtil.getConsistInfo(vehicleConfig, cargoType, params)
		if (not info.isElectric or params.isElectricTrack or paramHelper.getParams().allowPassengerElectricTrains) and info.capacity > 0 and info.length < params.stationLength-4 then
			local accelerationScore = 0
			if params.distance then 
				local targetDist = 	paramHelper.getParams().targetTrainAccelerationDistance*params.distance
				accelerationScore = math.abs(targetDist-info.loadedAccel.d)
				if info.loadedAccel.d ~= info.loadedAccel.d then
					trace("WARNING invalid acceleration for ",info.leadName)
					goto continue 
				end
			end
			local p = vehicleUtil.calculateProjectedProfit(vehicleConfig, info, params)
			table.insert(choices, {
				config = vehicleConfig,
				p =p,
				
				leadName = info.leadName,
				scores = {
					math.abs(info.capacity-targetCapacity), 
					1/info.topSpeed, 
					info.emission,
					accelerationScore,
					2^24-p.projectedProfit
				}
			})
			
		else
			trace("rejected config as not allowElectricTrains for ",info.leadName, " capacity was ",info.capacity ," length was ", info.length)
		end
		::continue::
	end
	trace("time taken to prepare ",#choices," was ",(os.clock()-begin))
	if params.isForVehicleReport then 
		return util.evaluateAndSortFromScores(choices, paramHelper.getParams().passengerTrainConsistScoreWeights)
	end
	local bestOption =  util.evaluateWinnerFromScores(choices, paramHelper.getParams().passengerTrainConsistScoreWeights)
	local p = bestOption.p
	trace("The best passenger option was ",bestOption.leadName,"  projected ticket price=",p.projectedTicketPrice, " projectedPayment=",p.projectedPayment," projectedRevenue=",p.projectedRevenue, " projectedProfit=",p.projectedProfit, " runningCost=",p.runningCost, " throughput=",p.throughput, " projectedPaymentPerLoad=",p.projectedPaymentPerLoad, " distance=",params.distance, " totalTime=",p.totalTime, " totalTimeOriginal=",p.totalTimeOriginal, " total choices=",#choices, " time taken ",(os.clock()-begin))
	return bestOption.config
	
end
local function getSelfPropelledVehicles(cargoType, params)
	local result = {}
	for i, vehicleDetails in pairs(findVehiclesOfType("train", params)) do
		if #vehicleDetails.model.metadata.railVehicle.engines > 0 and vehicleUtil.cargoCapacityLookup[vehicleDetails.modelId][cargoType] > 0 then 
			table.insert(result, vehicleDetails)
		end
	end
	return result
end
function vehicleUtil.assembleConsistForTargetThroughput(waggonInfo, locoInfo, targetThroughput, params, extraLocomotives)
	local waggonCapacity = vehicleUtil.cargoCapacityLookup[waggonInfo.modelId][params.cargoType]
	local length = getModelLengthx(waggonInfo.model)
	local maxWaggons = math.ceil((params.stationLength-4)/length) 
	local consist 
	local consistMeetingTargetThroughput
	local consistMeetingTotalThroughput
	for i = waggonCapacity, maxWaggons*waggonCapacity, waggonCapacity do 
		consist = assembleConsistForWaggon(i, params, waggonInfo, locoInfo, extraLocomotives)
		local throughput = vehicleUtil.estimateThroughputBasedOnConsist(consist.config, params).throughput
		if not consistMeetingTargetThroughput and throughput >= targetThroughput then 
			consistMeetingTargetThroughput=  consist
		end
		if not consistMeetingTotalThroughput and throughput >= params.totalTargetThroughput then 
			consistMeetingTotalThroughput=  consist
		end
	end
	return consistMeetingTotalThroughput or consistMeetingTargetThroughput or consist
end

function vehicleUtil.calculateProjectedProfit(config, info, params)
	local throughputInfo =  vehicleUtil.estimateThroughputBasedOnConsist(config, params) 
	local throughput = throughputInfo.throughput
	if params.targetThroughput then 
		-- need to clamp the expected throughput to the actual demand, any extra capacity will not produce revenue
		if throughput >= params.totalTargetThroughput then 
			throughput = math.min(throughput, params.totalTargetThroughput)
		else 
			throughput = math.min(throughput, params.targetThroughput)
		end
	end
	-- thank you to this source for ticket price calculation:
	-- https://www.reddit.com/r/TransportFever/comments/rj8b9l/so_i_heard_yall_were_wondering_how_payment_is/
	--local cargoFactor = 1.75
	local cargoFactor = 1
	local projectedTicketPrice = (10 + (info.topSpeed*3.6) ^ 0.86)
	
	local projectedPayment = 0.1*(math.max(300 , params.distance))*projectedTicketPrice*cargoFactor
	local sections = 1 
	if params.line then 
		sections = #params.line.stops
	end 
	local projectedPaymentPerLoad = projectedPayment*info.capacity
	local projectedRevenue =  sections*projectedPayment * throughput
	local projectedProfit = projectedRevenue - info.runningCost 
	return {
		projectedPayment = projectedPayment,
		projectedTicketPrice = projectedTicketPrice,
		projectedRevenue = projectedRevenue,
		projectedProfit = projectedProfit,
		runningCost = info.runningCost ,
		throughput= throughput,
		leadName = info.leadName,
		projectedPaymentPerLoad=projectedPaymentPerLoad,
		projectedProfit = projectedProfit,
		totalTime = throughputInfo.totalTime,
		totalTimeOriginal = throughputInfo.totalTimeOriginal,
		maxThroughput = throughputInfo.throughput,
		averageSpeed = throughputInfo.averageSpeed,
		routeLength = throughputInfo.routeLength,
		projectedTimings = throughputInfo.projectedTimings,
		projectedTimingsRaw = throughputInfo.projectedTimingsRaw,
		projectedLoadTime = throughputInfo.projectedLoadTime,
		topSpeed = info.topSpeed
	}
end

local function assembleConsistUsingWaggonAndLocomotive(targetCapacity, params, waggonInfo, locoInfo, extraLocomotives)
	if params.targetThroughput then 
		return vehicleUtil.assembleConsistForTargetThroughput(waggonInfo, locoInfo, params.targetThroughput, params, extraLocomotives)
	else 
		return assembleConsistForWaggon(targetCapacity, params, waggonInfo, locoInfo, extraLocomotives)
	end
end

function vehicleUtil.buildAllConsistPermutations(targetCapacity, params) 
	local results ={}
	local locos = getAllAvailableLocomotives(params) 
	for i, waggonInfo in pairs(vehicleUtil.getWaggonsByCargoType(params.cargoType, params)) do
		for j, locoInfo in pairs(locos) do 
			local consist = assembleConsistUsingWaggonAndLocomotive(targetCapacity, params, waggonInfo, locoInfo, 0)
			if consist.waggons > 0 then 
				table.insert(results, consist.config)
			end 
			local startFrom =  consist.locomotives > 1 and -1 or 1
			local endAt = consist.locomotives * 2
			
			for extraLocomotives = startFrom , endAt do 
				if extraLocomotives ~= 0 then 
					local consist = assembleConsistUsingWaggonAndLocomotive(targetCapacity, params, waggonInfo, locoInfo, extraLocomotives)
					if consist.waggons > 0 then
						table.insert(results, consist.config)
					end
				end
			end
		end
	end
	return results
end


function vehicleUtil.solveAndBuildOptimalCargoTrain(targetCapacity, params)
	local options = {}
	local begin = os.clock()
	for i, config in pairs(vehicleUtil.buildAllConsistPermutations(targetCapacity, params) ) do
		 
		local info = vehicleUtil.getConsistInfo(config, params.cargoType, params)
		local p = vehicleUtil.calculateProjectedProfit(config, info, params)
		if p.projectedProfit ~= p.projectedProfit then 
				trace("NAN profit detected:",info.leadName,"  projected ticket price=",p.projectedTicketPrice, " projectedPayment=",p.projectedPayment," projectedRevenue=",p.projectedRevenue, " projectedProfit=",p.projectedProfit, " runningCost=",p.runningCost, " throughput=",p.throughput, " projectedPaymentPerLoad=",p.projectedPaymentPerLoad, " distance=",params.distance, " totalTime=",p.totalTime," totalTimeOriginal=",p.totalTimeOriginal)
		else 
			local vehicleCount = params.totalTargetThroughput and math.ceil(params.totalTargetThroughput / p.throughput) or 1
			table.insert(options, {
				config = config,
				p = p,
				projectedPayment = p.projectedPayment,
				projectedTicketPrice = p.projectedTicketPrice,
				projectedRevenue = p.projectedRevenue,
				projectedProfit = p.projectedProfit,
				runningCost = info.runningCost ,
				throughput= p.throughput,
				leadName = info.leadName,
				totalTime = p.totalTime,
				projectedPaymentPerLoad=p.projectedPaymentPerLoad,
				vehicleCount = vehicleCount,
				scores = { 
					2^28-p.projectedProfit -- smaller is better
				}
			})
		end
  
	end
	trace("Time taken to build ",#options, " was ",(os.clock()-begin))
	if params.isForVehicleReport then 
		return util.evaluateAndSortFromScores(options)
	end

	local bestOption = util.evaluateWinnerFromScores(options)
	trace("The best option was ",bestOption.leadName,"  projected ticket price=",bestOption.projectedTicketPrice, " projectedPayment=",bestOption.projectedPayment," projectedRevenue=",bestOption.projectedRevenue, " projectedProfit=",bestOption.projectedProfit, " runningCost=",bestOption.runningCost, " throughput=",bestOption.throughput, " projectedPaymentPerLoad=",bestOption.projectedPaymentPerLoad, " distance=",params.distance," time taken:",(os.clock()-begin))
	
	return bestOption.config
end

function vehicleUtil.getTopSpeed(vehicleConfig) 
	if not vehicleUtil.modelRepLookup then 
		discoverVehicles() 
	end 
	local vehicle = vehicleUtil.modelRepLookup[vehicleConfig.vehicles[1].part.modelId]
	return getVehicleConfig(vehicle).topSpeed
end 

function vehicleUtil.buildTrain(targetCapacity, params)
	if params.locomotiveRestriction == -1 and climate=="usa" and util.year() < 2000 and params.isCargo and climateRestrictionsInForce then 
		params.locomotiveRestriction =  api.type.enum.VehicleEngineType.ELECTRIC 
	end
	local cargoType = params.cargoType
	if isCargo(cargoType) then 
		return vehicleUtil.solveAndBuildOptimalCargoTrain(targetCapacity, params)
	end
	local begin = os.clock()
	local results = vehicleUtil.buildAllConsistPermutations(targetCapacity, params) 
	local buildTrains = os.clock()
	trace("checking consists against prebuilt options, time taken for train build ",(buildTrains-begin))
	
	local muTypes = getMultipleUnitTypes(params)
	for i, multipleUnitInfo in pairs(muTypes) do 
		--trace("Adding multiple unit info, i=",i, " of ",#muTypes)
		if params.vehicleFavourites and params.vehicleFavourites["train"] then 
			if not params.vehicleFavourites[multipleUnitInfo[1].modelId] then 	
				goto continue 
			end
		end
		for i, result in pairs(buildFromMultipleUnit(multipleUnitInfo, cargoType, targetCapacity, params)) do 
			table.insert(results,result )
		end
		::continue::
	end
	local selfPropelledTime = os.clock()
	trace("about to get self propelled cars, time taken to getMu",(selfPropelledTime-buildTrains))
	local selfPropelled = getSelfPropelledVehicles(cargoType, params)
	trace("got ",#selfPropelled, " selfPropelled cars")
	for i, modelInfo in pairs(selfPropelled) do 
		--trace("Adding self propelled unit info, i=",i)
		for i, result in pairs(buildFromMultipleUnit({modelInfo}, cargoType, targetCapacity, params)) do 
			table.insert(results,result )
		end
	end
	trace("Time taken to build ",#results," was ",(os.clock()-begin), " self propelled time ",(os.clock()-selfPropelledTime))
	--debugPrint(results)
	return evaluateBestPassengerTrainOption(results,cargoType, targetCapacity, params)
end
	
function vehicleUtil.getLoadTime(vehicleConfig, cargoType) 
	local capacity =  vehicleUtil.calculateCapacity(vehicleConfig, cargoType) 
	
	local loadSpeed = 0 
	for i = 1, #vehicleConfig.vehicles do 
		local modelId = vehicleConfig.vehicles[i].part.modelId
		loadSpeed = loadSpeed + vehicleUtil.getModel(modelId).metadata.transportVehicle.loadSpeed
	end
	return capacity / loadSpeed 
end 

function vehicleUtil.estimateThroughputBasedOnConsist(config, params)
	local distance = params.distance
	local info = vehicleUtil.getConsistInfo(config, params.cargoType, params)
	local projectedTimings = {} 
	local projectedTimingsRaw = {}
	local routeLength = 0
	local totalTime 
	local totalTimeOriginal 
	local loadTime
	local loadStationFactor = 0.5
	if params.loadStationFactor then 
		loadStationFactor = ( params.currentCapacity/info.capacity ) * params.loadStationFactor
	end
	if params.line or params.routeInfos then 
		local line = params.line
		totalTime = 0 
		loadTime = 0
		totalTimeOriginal = 0
		local endAt = line and #line.stops or #params.routeInfos
		for i = 1, endAt do 
		
			
			if not params.routeInfos then 
				params.routeInfos = {}
			end
			if not params.routeInfos[i] then
				if not line then 
					trace("WARNING! Missing routeInfo at i=",i," skipping")
					goto continue 
				end
				local priorStop = i == 1 and line.stops[#line.stops] or line.stops[i-1]
				local station1 = api.engine.getComponent(priorStop.stationGroup, api.type.ComponentType.STATION_GROUP).stations[1]
				local station2 = api.engine.getComponent(line.stops[i].stationGroup, api.type.ComponentType.STATION_GROUP).stations[1]
				params.routeInfos[i] = pathFindingUtil.getRouteInfo(station1, station2)
			end
			params.routeInfo = params.routeInfos[i]
			params.distance = params.routeInfo.straightDistance
			local tripTime = calculateTripTime(info.loadedAccel, params, info.topSpeed, true,info)
			table.insert(projectedTimings, tripTime.totalTime)
			table.insert(projectedTimingsRaw, tripTime.originalTotalTime)
			totalTime = totalTime + tripTime.totalTime
			totalTimeOriginal = totalTimeOriginal + tripTime.originalTotalTime
			loadTime = loadTime + loadStationFactor*(info.capacity/info.loadSpeed) 
			routeLength = routeLength + params.routeInfos[i].routeLength
			::continue::
		end 
	else 
		local outboundTripTime = calculateTripTime(info.loadedAccel, params, info.topSpeed, true,info)
		local returnTripTime = calculateTripTime(info.emptyAccel, params, info.topSpeed, false,info)
		projectedTimings = {
			outboundTripTime.totalTime,
			returnTripTime.totalTime 
		}
		projectedTimingsRaw = {
			outboundTripTime.originalTotalTime,
			returnTripTime.originalTotalTime 
		}
		
		
		totalTime	=outboundTripTime.totalTime+returnTripTime.totalTime 
		totalTimeOriginal = outboundTripTime.originalTotalTime+returnTripTime.originalTotalTime 
		loadTime =  2*(info.capacity/info.loadSpeed)
		if params.routeInfo then 
			routeLength = params.routeInfo.routeLength*2
		else 
			routeLength = params.distance*2
		end
	end
	if loadTime ~= loadTime then 
		--debugPrint({vehicleInfo=info})
	--	trace("NAN loadTime detected")
	end
	if params.sectionTimeCorrection then 
		local correctedTime = totalTime * params.sectionTimeCorrection
		--trace("Correcting the section time by ", params.sectionTimeCorrection, " originally:",util.formatTime(totalTime)," corrected:",util.formatTime(correctedTime))
		totalTime = correctedTime
		for i = 1 , #projectedTimings do 
			projectedTimings[i]=projectedTimings[i]*params.sectionTimeCorrection
		end 
	end 
	local totalSectionTime = totalTime
	totalTime = totalTime + loadTime
	local throughput = info.capacity /  totalTime
	local throughputPer12min = throughput * 12 * 60
	local averageSpeed = routeLength/totalTime 
	--trace("Calculated averageSpeed as ",api.util.formatSpeed(averageSpeed), " based on routeLength=",routeLength," and totalTime=",totalTime, " sectionTImeCorrection was ",params.sectionTimeCorrection )
	--trace("for ",info.numCars," waggons outboundTripTime= ", outboundTripTime," returnTripTime= ",returnTripTime,   " totalTime=",totalTime, " totalCapacity=",totalCapacity, " distance=",distance,  " throughput=",throughput, " throughputPer12min=",throughputPer12min, " loadTime=",loadTime, "topSpeed=",info.topSpeed," isHighSpeed?",info.isHighSpeed)
	--end 
	return {throughput = throughputPer12min, totalCapacity=info.capacity, totalTime=totalTime, isMaxLength=info.isMaxLength, totalTimeOriginal=totalTimeOriginal, averageSpeed = averageSpeed, routeLength= routeLength, projectedTimings=projectedTimings, projectedTimingsRaw=projectedTimingsRaw, projectedLoadTime=loadTime, totalSectionTime=totalSectionTime}
end

function vehicleUtil.estimateThroughputBasedOnCapacity( distance, targetCapacity, params)
	
	params.distance = distance
	local targetThroughput = params.targetThroughput
	params.targetThroughput = nil
	
	local config = vehicleUtil.buildTrain(targetCapacity, params)
	params.targetThroughput = targetThroughput
	return vehicleUtil.estimateThroughputBasedOnConsist(config, params)
end
function vehicleUtil.estimateMaxThroughputPerConsist(distance, params)
	return vehicleUtil.estimateThroughputBasedOnCapacity( distance, 2^16, params)
end

function vehicleUtil.copyConfig(newVehicleConfig) -- seems like we need to store this data in lua objects to avoid strange effects (disspearing)
	local copy = {}
	copy.vehicles ={}
	copy.vehicleGroups = {} 
	for i, vehicle in pairs(newVehicleConfig.vehicles) do 
		local vehicleCopy = {}
		vehicleCopy.part = {}
		vehicleCopy.part.loadConfig= util.deepClone(vehicle.part.loadConfig)
		vehicleCopy.autoLoadConfig= util.deepClone(vehicle.autoLoadConfig)
		vehicleCopy.part.modelId = vehicle.part.modelId
		vehicleCopy.part.reversed = vehicle.part.reversed
		vehicleCopy.purchaseTime = vehicle.purchaseTime
		vehicleCopy.targetMaintenanceState = vehicle.targetMaintenanceState
		copy.vehicles[i] = vehicleCopy
	end
	for k, v in pairs(newVehicleConfig.vehicleGroups) do 
		copy.vehicleGroups[k]=v
	end
	return copy
end


function vehicleUtil.copyConfigToApi(newVehicleConfig, params) -- reverses the process above
	local copy  = api.type.TransportVehicleConfig.new() 
	for i, vehicle in pairs(newVehicleConfig.vehicles) do 
		local vehicleCopy = initVehiclePart( params) 
		vehicleCopy.part.modelId = vehicle.part.modelId
		vehicleCopy.part.reversed = vehicle.part.reversed
		vehicleCopy.part.loadConfig= util.deepClone(vehicle.part.loadConfig)
		vehicleCopy.autoLoadConfig= util.deepClone(vehicle.autoLoadConfig)
		if vehicle.targetMaintenanceState then 
			vehicleCopy.targetMaintenanceState = vehicle.targetMaintenanceState
		end
		copy.vehicles[i] = vehicleCopy
	end
	for k, v in pairs(newVehicleConfig.vehicleGroups) do 
		copy.vehicleGroups[k]=v
	end
	return copy
end

function vehicleUtil.estimateThroughputPerConsist(distance, targetLineRate, params)
	local cargoType =params.cargoType
	trace("Estimating capacity for consist, based on cargoType=",cargoType)
	if params.locomotiveRestriction == -1 and climate=="usa" and util.year() < 2000 and params.isCargo and climateRestrictionsInForce then 
		params.locomotiveRestriction =  api.type.enum.VehicleEngineType.ELECTRIC 
	end 
	params.distance = distance
	--params.targetThroughput = targetLineRate
	local converged = false 
	local minCapacity = 2^16
	local minLength = 2^16
	for i , waggon in pairs(vehicleUtil.getWaggonsByCargoType(cargoType, params)) do 
		minCapacity = math.min(minCapacity, vehicleUtil.cargoCapacityLookup[waggon.modelId][cargoType])
		minLength = math.min(minLength, getModelLengthx(waggon.model))
	end
	local maxWaggons = math.ceil((params.stationLength-4)/minLength)
	
	local targetCapacity  = math.ceil(targetLineRate / 10)
	for testCapacity = minCapacity, maxWaggons*minCapacity, minCapacity do 
		local throughput = vehicleUtil.estimateThroughputBasedOnCapacity( distance, testCapacity, params)
		if throughput.throughput>targetLineRate then 
			trace("determined that the line rate can be achieved with capacity at ",testCapacity)
			return throughput
		end
		if throughput.isMaxLength then 
			trace("determined that the line rate cannot be achieved with capacity at ",testCapacity)
			return throughput
		end
	end
	trace("unable to determine appropriate solution for target, falling back to maximum")	
	return vehicleUtil.estimateMaxThroughputPerConsist( distance, params)
end 

function vehicleUtil.getModel(modelId) 
	if not vehicleUtil.modelRepLookup then 
		discoverVehicles()
	end
	return  vehicleUtil.modelRepLookup[modelId]
end

function vehicleUtil.getThroughputInfoForRoadVehicle(config, stations, params)
	local modelId = config.vehicles[1].part.modelId
	local model = vehicleUtil.getModel(modelId) 
	local configData = getVehicleConfig(model)
	local engine = getVehicleEngine(model)
	local topSpeed = configData.topSpeed
	local tractiveEffort = engine.tractiveEffort
	local power = engine.power
	local mass = configData.weight
	local capacity = vehicleUtil.cargoCapacityLookup[modelId][params.cargoType]
	local cargoWeight = capacity * vehicleUtil.cargoWeightLookup[params.cargoType] / 1000
	
	
	local function createRouteSectionsFromRouteInfo(routeInfo) 
		local routeSections = {} 
		local previousSpeedLimit
		for i = 1, #routeInfo.edges do
			local edgeId  =routeInfo.edges[i].id
			local edge = routeInfo.edges[i].edge
			local speedLimit =  math.min(util.getRoadSpeedLimit(edgeId), topSpeed)
			trace("The speed limit was ", api.util.formatSpeed(speedLimit))
			local resetSpeed = false
			if i > 2 then 
				local angle = util.calculateAngleConnectingEdges(edge, routeInfo.edges[i-1].edge)
				if angle > math.rad(60) then 
					trace("Junction angle detected ",math.deg(angle)," at ",edgeId," resetting speed")
					resetSpeed=true
					routeSections[#routeSections].resetEndSpeed =true
				end 
			end
			
			if speedLimit ~= previousSpeedLimit or resetSpeed then 
				table.insert(routeSections, {
					length = util.calculateSegmentLengthFromEdge(edge),
					resetStartSpeed = resetSpeed,
					speedLimit = speedLimit
				})
			else 
				local routeSection = routeSections[#routeSections]
				routeSection.length = routeSection.length +  util.calculateSegmentLengthFromEdge(edge)
			end
			previousSpeedLimit = speedLimit
		end
		trace("Constructed ",#routeSections," between ",stations[1]," and ",stations[2])
		return routeSections
	end 
		
	
	
	local totalTime = 0
	local totalDistance = 0
	local function estimateTripTime(priorStation, station)
		local routeInfo = pathFindingUtil.getRoadRouteInfoBetweenStations(priorStation, station)
		if not routeInfo then 
			
			local assumedDist = 1.2*util.distBetweenStations(priorStation, station)
			totalDistance = totalDistance + assumedDist 
			local speedFactor = assumedDist > 1000 and (2/3) or (1/2)
			local assumedTime = assumedDist/(speedFactor*topSpeed)
			trace("WARNING! Could not find a path between",priorStation," and ",station,"! Using assumedDist=",assumedDist," assumedTime=",assumedTime)
			return
		end 
		
		local routeSections =  createRouteSectionsFromRouteInfo(routeInfo) 
		local speed = 0
		for i = 1, #routeSections do 
			local routeSection = routeSections[i]
			local topSpeed = routeSection.speedLimit
			speed = math.min(speed, topSpeed)
			if routeSection.resetStartSpeed then 
				speed =0 
			end
			local gradient= 0 -- may do gradient correction later
			local info = calculateTripTimeOnRouteSection(power, tractiveEffort, topSpeed, mass+cargoWeight, gradient, routeSection.length, speed)
			speed = info.speed
			totalDistance = totalDistance + routeSection.length
			totalTime = totalTime + info.time 
		end
	end
	
	for i = 1, #stations do 
		local priorStation = i==1 and stations[#stations] or stations[i-1]
		local station = stations[i]
		estimateTripTime(priorStation, station)
		trace("Estimated total oubound time between ",priorStation, " and ", station," as ",totalTime)
	end 
	
 
	 
	local avgSpeed = totalDistance/totalTime
	trace("Estimated total trip time between ", stations[1], " and ", stations[2]," as ",totalTime, " total dist was ",totalDistance," averageSpeed =",api.util.formatSpeed(avgSpeed))
	local throughput = capacity /  totalTime
	local throughputPer12min = throughput * 12 * 60
	return { 
		estimatedTripTime = totalTime,
		capacity = capacity,
		routeLength = totalDistance,
		throughput = throughputPer12min
	} 

end

function vehicleUtil.buildVehicle(params, vehicleType, optionalFilterFn, scoreWeights)
	local config = api.type.TransportVehicleConfig.new()
	if not scoreWeights then 
		if vehicleType == "truck" then 
			if params.hasTruckStop and params.routeLength and params.routeLength < 1500 then
				scoreWeights = paramHelper.getParams().urbanTruckScoreWeights
			else 
				scoreWeights = paramHelper.getParams().truckScoreWeights
			end
		end
		if vehicleType == "bus" then 
			if params.isUrbanLine or params.routeLength and params.routeLength < 1500 then
				scoreWeights = paramHelper.getParams().urbanBusScoreWeights
			else 
				scoreWeights = paramHelper.getParams().interCityBusScoreWeights
			end
		end
		if vehicleType == "plane" then 
			scoreWeights =  paramHelper.getParams().airCraftScoreWeights
		end
		if vehicleType == "tram" then 
			scoreWeights = paramHelper.getParams().urbanBusScoreWeights
		end
		if vehicleType == "ship" then 
			if params.isCargo then 
				scoreWeights = paramHelper.getParams().cargoShipScoreWeights
			else 
				scoreWeights = paramHelper.getParams().passengerShipScoreWeights
			end 
		 
		end 
	end
	
	local modelDetail = vehicleUtil.findBestMatchVehicleOfType(vehicleType, params, scoreWeights, optionalFilterFn)
	local vehiclePart = initVehiclePart(params)
	vehiclePart.part.modelId = modelDetail.modelId
	config.vehicles[1]=vehiclePart
	config.vehicleGroups[1]=1
	if vehicleType=="ship" and not modelDetail.model.metadata.waterVehicle then
		trace("could not find waterVehicle for model")
		debugPrint(modelDetail)
	end
	local numConfigs = 1
	if modelDetail.model.metadata.waterVehicle or  modelDetail.model.metadata.airVehicle then 
		numConfigs = #firstNonNil(modelDetail.model.metadata.waterVehicle,modelDetail.model.metadata.airVehicle).configs
	end
	numConfigs = #modelDetail.model.metadata.transportVehicle.compartments
	local loadConfig = vehicleUtil.cargoIdxLookup[vehiclePart.part.modelId][params.cargoType]-1
	trace("setting up ", vehicleType," vechicle, numConfigs was ", numConfigs)
	if numConfigs > 1 then 
		local loadConfigs ={}
		local autoLoadConfig ={}
		for i = 1, numConfigs do
			table.insert(loadConfigs, loadConfig)
			table.insert(autoLoadConfig, 0)
		end
		vehiclePart.part.loadConfig=loadConfigs
		vehiclePart.autoLoadConfig=autoLoadConfig
		config.vehicles[1]=vehiclePart -- copy on assignment ? 
	else 
		--if util.tracelog then debugPrint({vehiclePartBefore=vehiclePart})end
	
		trace("Setting up vehicle for ",params.cargoType," the loadConfig was ",loadConfig)
		local loadConfigs = {loadConfig} 
		local autoLoadConfig ={0} --params.cargoType=="UNSORTED_MAIL" and {1} or {0}
		vehiclePart.part.loadConfig=loadConfigs
		vehiclePart.autoLoadConfig=autoLoadConfig
		--if util.tracelog then debugPrint({vehiclePart=vehiclePart, autoLoadConfig=autoLoadConfig,loadConfig=loadConfig})end
		config.vehicles[1]=vehiclePart
	end 
	
	return vehicleUtil.copyConfig(config)
end

function vehicleUtil.getCurrentCargoConfig(vehiclePart)
	local loadConfig = vehiclePart.part.loadConfig[1]
	local modelId = vehiclePart.part.modelId
	if not vehicleUtil.inverseCargoIdxLookup then 
		discoverVehicles()
	end 
	local cargoLookup = vehicleUtil.inverseCargoIdxLookup[ modelId]
	if not cargoLookup then 
		trace("WARNING! Unable to find config for ",modelId)
		return 
	end
	return cargoLookup[loadConfig+1]
end 

function vehicleUtil.buildTruck(params )
	return vehicleUtil.buildVehicle(params, "truck")
end

function vehicleUtil.buildTram()
	return vehicleUtil.copyConfig(vehicleUtil.buildVehicle({cargoType="PASSENGERS"}, "tram"))
end

function vehicleUtil.isLargeShip(vehicleConfig) 
	if not vehicleUtil.modelRepLookup then 
		discoverVehicles() 
	end 
	return vehicleUtil.modelRepLookup[vehicleConfig.vehicles[1].part.modelId].metadata.waterVehicle.type == 1
end 

function vehicleUtil.buildShip(params, allowLargeShips)
	local filterFn
	if not allowLargeShips then
		filterFn = function(vehicle) 
			return vehicle.metadata.waterVehicle.type == 0
		end
	end
	return vehicleUtil.buildVehicle(params, "ship", filterFn)
end

function vehicleUtil.buildPlane(params, smallOnly)
	local filterFn
	if smallOnly then 
		filterFn = function(vehicle)
			return vehicle.metadata.airVehicle.type == 0
		end
	end
	return vehicleUtil.buildVehicle(params, "plane", filterFn)
end

function vehicleUtil.buildVehicleFromLineType(transportModes, params)
	local vehicleType = getTypeFromMode(transportModes)
	
	
	return vehicleUtil.buildVehicle(params,vehicleType)
end


function vehicleUtil.buildMaximumCapacityTrain(params)
	return vehicleUtil.buildTrain(2^16, params)
end

function vehicleUtil.isElectricTram(transportVehicleConfig)
	if not  vehicleUtil.modelRepLookup then 
		discoverVehicles()
	end
	 
	local model = vehicleUtil.modelRepLookup[transportVehicleConfig.vehicles[1].part.modelId]
	return model.metadata.railVehicle
	and model.metadata.railVehicle.engines[1]
	and model.metadata.railVehicle.engines[1].type == api.type.enum.VehicleEngineType.ELECTRIC
end

function vehicleUtil.calculateCapacity(transportVehicleConfig, cargoType)
	local capacity = 0 
	if not  vehicleUtil.modelRepLookup then 
		discoverVehicles()
	end
	for i = 1, #transportVehicleConfig.vehicles do 
		local modelId = transportVehicleConfig.vehicles[i].part.modelId
		capacity = capacity + vehicleUtil.cargoCapacityLookup[modelId][cargoType]
	end
	return capacity
end
function vehicleUtil.findVehicleFromLineType(transportModes, params)
	return vehicleUtil.findBestMatchVehicleOfType(getTypeFromMode(transportModes), params)
end 
function vehicleUtil.checkIfVechicleCanBeUpgradeOrExtended(vehicle, transportModes, params) 
	local vehicleType = getTypeFromMode(transportModes)
	local vehicleDetail =  api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
	local transportVehicleConfig = vehicleDetail.transportVehicleConfig
	local testConfig
	if vehicleType=="train" then
		testConfig = vehicleUtil.buildMaximumCapacityTrain(params)
	 
	else 
		testConfig = vehicleUtil.buildVehicle(params, vehicleType )
	end
	return not vehicleUtil.checkIfVehicleConfigMatches(testConfig, transportVehicleConfig)
end

function vehicleUtil.checkIfVehicleConfigMatches(testConfig, transportVehicleConfig)
	if #testConfig.vehicles ~= #transportVehicleConfig.vehicles then
		return false
	end
	for i=1, #testConfig.vehicles do
		if testConfig.vehicles[i].part.modelId ~= transportVehicleConfig.vehicles[i].part.modelId then
			return false
		end
	end
	return true
end 

-- ************************
-- UI
-- ************************

function vehicleUtil.displayVehicleConfig(newVehicleConfig, maxSize) 
	--trace("About to display newVehicleConfig")
	--debugPrint(newVehicleConfig)
	if not newVehicleConfig then 
		return api.gui.comp.TextView.new(" ")
	end
	
	
	local boxlayout = api.gui.layout.BoxLayout.new("HORIZONTAL");
	for i, vehicle in pairs(newVehicleConfig.vehicles) do
		local modelId = vehicle.part.modelId
		local model = api.res.modelRep.get(modelId)
		local name = model.metadata.description.name
		--[[
		icon = "ui/models/vehicle/train/usa/hhp_8.tga",
  smallIcon = "ui/models_small/vehicle/train/usa/hhp_8.tga",
  smallIconCblend = "ui/models_small/vehicle/train/usa/hhp_8_cblend.tga",
  icon20 = "ui/models_20/vehicle/train/usa/hhp_8.tga",
  icon20cblend = "ui/models_20/vehicle/train/usa/hhp_8_cblend.tga",]]--
		local icon = model.metadata.description.icon20
		--trace("Getting icon for ",name," modelId was ",modelId)
		local imageView = api.gui.comp.ImageView.new(icon)
		imageView:setTooltip(_(name))
		boxlayout:addItem(imageView)
	end
	local comp= api.gui.comp.Component.new(" ")
	if maxSize then 
		comp:setMaximumSize(api.gui.util.Size.new(maxSize,30))
	end 
	--comp:setMaximumSize(api.gui.util.Size.new(300,30))
	comp:setLayout(boxlayout)
	return comp 	
end
 



return vehicleUtil