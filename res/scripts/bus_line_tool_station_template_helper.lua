local vec2 = require "vec2"
local vec3 = require "vec3"
local transf = require "transf"
local constructionutil = require "constructionutil"
local paramsutil = require "paramsutil"
local colliderutil = require "colliderutil"
local modulesutil = require "modulesutil"
local trainstationutil = require "modules/trainstationutil"
	
local tracelog = true 	
local function trace(...)
	if tracelog then 
		print(...)
	end
end 

local mainBuildingSlotId = 3400000
local platformSlotId = 4400000
local cargoPlatformSlotId =  6400000
local passengerPlatformSlotId = 7400000
local trackSlotId = 8400000
local stairsSlotId = 9400000
local passengerPlatformRoofSlotId = 10400000
local passengerPlatformAddonSlotId = 10800000

local platformLength = 40
local platformWidth = 5

local mainBuildingPosition = vec3.new(-10, 0, 0)

local jMin = trainstationutil.stationYMin
local jMax = trainstationutil.stationYMax

local mainBuildingTag = 0
local trackTag = 1
local platformTag = 2
local addonTag = 3

local headLeftTag = 0
local headRightTag = 1
local throughFrontTag = 2
local throughBackTag = 3

local cargoTag = 0
local passengerTag = 1

local genericAddonTag = 0
local roofTag = 1

local function GetId(type, subtype, i, j, k, o)
	if o == nil then o = 0 end
	if type == mainBuildingTag then
		local offset = 0
		if subtype == headLeftTag then 
			offset = 300000
			return mainBuildingSlotId + offset + 1000 * i + 20 * j + o
		elseif subtype == headRightTag then 
			offset = 400000
			return mainBuildingSlotId + offset + 1000 * i + 20 * j + o
		elseif subtype == throughFrontTag then 
			offset = 200000 
			return mainBuildingSlotId + offset + 3000 * i + 40 * j + 10 * k + o
		elseif subtype == throughBackTag then 
			offset = 0
			return mainBuildingSlotId + offset + 3000 * i + 40 * j + 10 * k + o
		end
	elseif type == trackTag then
		return trackSlotId + 1000 * i + 10 * j
	elseif type == platformTag then
		return (subtype == cargoTag and cargoPlatformSlotId or passengerPlatformSlotId) + 1000 * i + 10 * j
	elseif type == addonTag then
		return ((subtype == genericAddonTag) and passengerPlatformAddonSlotId or passengerPlatformRoofSlotId) + 1000 * i + 10 * j
	end
end
local eraAStart = 1850
local eraBStart = 1920
local eraCStart = 1980

local function getEra(year) 
	return year >= eraCStart and "c" or year >= eraBStart and "b" or "a"
end
	local helper = {}

	helper.createTemplateFn = function(params, fileName)
		if fileName and string.find(fileName, "elevated") then 
			params.isElevated = true 
			-- print("Setting isElevated to true")
		end
		if fileName and string.find(fileName, "underground") then 
			params.isUnderground = true 
		end

		local result = {}

		if not params.trackType then params.trackType = 0 end
		if not params.catenary then params.catenary = 0 end

		--local cargo = params.type == 1
		--local head = params.head == 1
		local cargo = params.templateIndex >= 6
		local head = params.templateIndex % 2 == 1
		local year = params.year
		local era = getEra(year)
		local variant = cargo and "cargo" or "era_" .. era
		
		trace("Original params.length=",params.length," useLengthDirectly?",params.useLengthDirectly)
		if not params.useLengthDirectly then 
			local lmap = { 0, 1, 2, 3, 5, 7, 9 }
			params.length = lmap[params.length + 2]
			params.useLengthDirectly = true
		end
		trace("Remapped params.length was",params.length)
		local s = params.length and -math.floor(params.length / 2) or 0
		local e = params.length and math.ceil(params.length / 2) or 0
		local even = (e - s) % 2 == 0
		
		--local offset = 1
		--local mbModule = "station/rail/modular_station/main_building_3_" .. variant .. ".module"
		--local level = 3
		local offset = 0
		local mbModule = "station/rail/modular_station/main_building_2_" .. variant .. ".module" -- locking down the module to the medium building always
		local level = 1
		
		--[[if params.tracks < 3 then
			offset = 0
			mbModule = "station/rail/modular_station/main_building_1_" .. variant .. ".module"
			level = 1
		elseif params.tracks < 6 then
			offset = 0
			mbModule = "station/rail/modular_station/main_building_2_" .. variant .. ".module"
			level = 2
		end]]--
		local prefix = params.isElevated and "elevated_" or params.isUnderground and "underground_" or ""
		local function AddTrack(i, s, e)
			for j = s,e do
				local id = GetId(trackTag, nil, i, j)
				if params.catenary == 0 and params.trackType == 0 then result[id] = "station/rail/modular_station/"..prefix.."platform_track.module"
				elseif params.catenary == 0 and params.trackType == 1 then result[id] = "station/rail/modular_station/"..prefix.."platform_high_speed_track.module"
				elseif params.catenary == 1 and params.trackType == 0 then result[id] = "station/rail/modular_station/"..prefix.."platform_track_catenary.module"
				elseif params.catenary == 1 and params.trackType == 1 then result[id] = "station/rail/modular_station/"..prefix.."platform_high_speed_track_catenary.module"
				end
			end
		end
		local function AddCargo(i, s, e)
			local stationPlatformModule = "station/rail/modular_station/"..prefix.."platform_cargo_era_" .. era .. ".module" 
			-- print("Adding cargo platform, stationPlatformModule was",stationPlatformModule," prefix was",prefix," isUnderground?",params.isUnderground)
			for j = s,e do result[GetId(platformTag, cargoTag, i, j)] = stationPlatformModule end
		end
		local function AddPassenger(i, s, e )
			local center = math.floor((e - s) / 2) + s
			local dist = e - s
			local roofModule = "station/rail/modular_station/platform_passenger_roof_era_" .. era .. ".module"
			local curvedRoofModule = (level >= 2 and era == "c") 
				and "station/rail/modular_station/platform_passenger_roof_curved_era_" .. era .. ".module" 
				or roofModule
			local underpassModule = "station/rail/modular_station/"..prefix.."addon_platform_passenger_stairs_era_" .. era .. ".module" 
			local platformModule = "station/rail/modular_station/"..prefix.."platform_passenger_era_" .. era .. ".module" 
			if params.isUnderground then 
				underpassModule = nil 
				roofModule = nil 
				curvedRoofModule = nil
			end
			for j = s, e do  
				if not head then
					local id = GetId(platformTag, passengerTag, i, j)
					result[id] = platformModule
					if (j == center or (dist > 3 and j == s + 1) or (dist > 3 and j == e - 1) ) then
						result[GetId(addonTag, genericAddonTag, i, j)] =  underpassModule
					end
					if (j ~= s and j ~= e) or e - s <= 3 then
						result[GetId(addonTag, roofTag, i, j)] = (not even and (j == center or j == center + 1) or j == center)
							and curvedRoofModule or roofModule 
					end
				else
					local id = GetId(platformTag, passengerTag, i, j)
					result[id] = platformModule
					if (j == center or j == s or (dist > 3 and j == e - 1) ) then
						result[GetId(addonTag, genericAddonTag, i, j)] = underpassModule
					end
					if j ~= e or j == s or j == s + 1 then
						result[GetId(addonTag, roofTag, i, j)] = j == s and curvedRoofModule or roofModule 
					end
				end
				if params.isElevated then 
					local railingModule = "station/rail/modular_station/railing.module"
					local railingPlatformAddonSlotId = 12800000 -- from evelvated_modular_station.con
					result[railingPlatformAddonSlotId + 1000 * i + 10 * j]=railingModule
				end 
				
			end
		end
		
		local function GetSideModuleAndOffset(variant, level)
			local offset = 7 - 3 + level
			if level == 3 and variant ~= "era_c" then offset = 6 end
			if params.isElevated or params.isUnderground then 
				return nil 
			end
			return "station/rail/modular_station/side_building_" .. level .. "_" .. variant .. ".module", offset
		end
		
		if head then
			local mul = cargo and 2 or 1
			local c = params.tracks and (math.floor((params.tracks+1) / 2) + 1) * mul + 1 + params.tracks or 1
			c = math.floor(c / 2) - 1
			local l = -math.floor(params.length / 2)
			result[GetId(mainBuildingTag, headLeftTag, c, l, nil, offset)] = mbModule
		else
			local k = 0
			if not even then k = 2 end
			result[mainBuildingSlotId          + 10 * k + offset] = mbModule
			if params.includeOffsideBuildings then 
				 -- above is 3400020
				 -- then have 3618020 on 4 track 
				 -- i.e. 218,000 
				--local id = GetId(mainBuildingTag, throughFrontTag, 0, 2, k, 0) --The id was	3600100
				--local i = params.tracks + 3
				local i = math.floor((params.tracks+1)*1.5) 
				if params.buildThroughTracks then 
					i = i + 2
				end
				local id = GetId(mainBuildingTag, throughFrontTag, i, 0, k, offset) -- The id was	3618020	 i=	6
		 		-- print("The id was",id, " i=",i)
				result[id] = mbModule
			end 
			
			if level >= 3 then
				local i = variant == "era_c" and 2 or 0
				if params.length > 5 then
					local m, o = GetSideModuleAndOffset(variant, level - 2)
					result[GetId(mainBuildingTag, throughBackTag, 0, 2, k+0+i, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -2, k-1-i, o)] = m
					local m, o = GetSideModuleAndOffset(variant, level - 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 2, k-1+i, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -2, k+1-i, o)] = m
					local m, o = GetSideModuleAndOffset(variant, level - 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 1, k+1+i, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k-1-i, o)] = m
					local m, o = GetSideModuleAndOffset(variant, level)
					result[GetId(mainBuildingTag, throughBackTag, 0, 1, k-1+i/2, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k+1-i/2, o)] = m
				elseif params.length > 4 then
					local m, o = GetSideModuleAndOffset(variant, level - 2)
					result[GetId(mainBuildingTag, throughBackTag, 0, 2, k-2+i, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -2, k+1-i, o)] = m
					local m, o = GetSideModuleAndOffset(variant, level - 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 1, k+1+i, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k-1-i, o)] = m
					local m, o = GetSideModuleAndOffset(variant, level)
					result[GetId(mainBuildingTag, throughBackTag, 0, 1, k-1+i/2, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k+1-i/2, o)] = m
				elseif params.length > 3 then
					local m, o = GetSideModuleAndOffset(variant, level - 2)
					result[GetId(mainBuildingTag, throughBackTag, 0, 1, k, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k-1, o)] = m
					local m, o = GetSideModuleAndOffset(variant, level - 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 1, k-1, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k+1, o)] = m
				elseif params.length > 1 then
					local m, o = GetSideModuleAndOffset(variant, level - 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 1, k-1, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k+1, o)] = m
				end
			elseif level >= 2 then
				if params.length > 4 and not params.isElevated then
					local m, o = GetSideModuleAndOffset(variant, 2)
					result[GetId(mainBuildingTag, throughBackTag, 0, 0, k+2, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k+2, o)] = m
					if params.includeOffsideBuildings then 
						local i = math.floor((params.tracks+1)*1.5) 
						if params.buildThroughTracks then 
							i = i + 2
						end
						-- expected ids 
						-- 3618035
						-- 3618045
						
						--3617995
						--3618005
						-- print("id1 = ",GetId(mainBuildingTag, throughFrontTag, i, 0, k+2, o)," o=",o)
						-- print("id2 = ",GetId(mainBuildingTag, throughFrontTag, i, -1, k+2, o)," o=",o)
						result[GetId(mainBuildingTag, throughFrontTag, i, 0, k+2, o)] = m
						result[GetId(mainBuildingTag, throughFrontTag, i, -1, k+2, o)] = m
					end 
					local m, o = GetSideModuleAndOffset(variant, 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 1, k-1, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k+0, o)] = m
					if params.includeOffsideBuildings then 
						local i = math.floor((params.tracks+1)*1.5) 
						if params.buildThroughTracks then 
							i = i + 2
						end
						-- print("id3 = ",GetId(mainBuildingTag, throughFrontTag, i, 1, k-1, o)," o=",o)
						-- print("id4 = ",GetId(mainBuildingTag, throughFrontTag, i, -1, k+0, o)," o=",o)
						result[GetId(mainBuildingTag, throughFrontTag, i, 1, k-1, o)] = m
						result[GetId(mainBuildingTag, throughFrontTag, i, -1, k+0, o)] = m
					end 
				elseif params.length > 2 then
					local m, o = GetSideModuleAndOffset(variant, 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 0, k+1, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, 0, k-2, o)] = m
					if params.includeOffsideBuildings then 
						local i = math.floor((params.tracks+1)*1.5) 
						if params.buildThroughTracks then 
							i = i + 2
						end
						result[GetId(mainBuildingTag, throughFrontTag, i, 0, k+1, o)] = m
						result[GetId(mainBuildingTag, throughFrontTag, i, 0, k-2, o)] = m
					end 
				end
			else
				if params.length > 2 then
				local m, o = GetSideModuleAndOffset(variant, 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 0, k+1, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, 0, k-2, o)] = m
					if params.includeOffsideBuildings then 
						local i = math.floor((params.tracks+1)*1.5) 
						if params.buildThroughTracks then 
							i = i + 2
						end
						-- print("id1 = ",GetId(mainBuildingTag, throughFrontTag, i, 0, k+1, o)," o=",o)
						-- print("id2 = ",GetId(mainBuildingTag, throughFrontTag, i, 0, k-2, o)," o=",o)
						result[GetId(mainBuildingTag, throughFrontTag, i, 0, k+1, o)] = m
						result[GetId(mainBuildingTag, throughFrontTag, i, 0, k-2, o)] = m
					end
					
				end
				if params.length > 4 then
				local m, o = GetSideModuleAndOffset(variant, 1)
					result[GetId(mainBuildingTag, throughBackTag, 0, 0, k+2, o)] = m
					result[GetId(mainBuildingTag, throughBackTag, 0, -1, k+1, o)] = m
					if params.includeOffsideBuildings then 
						local i = math.floor((params.tracks+1)*1.5) 
						if params.buildThroughTracks then 
							i = i + 2
						end
						-- print("id3 = ",GetId(mainBuildingTag, throughFrontTag, i, 0, k+2, o)," o=",o)
						-- print("id4 = ",GetId(mainBuildingTag, throughFrontTag, i, -1, k+1, o)," o=",o)
						result[GetId(mainBuildingTag, throughFrontTag, i, 0, k+2, o)] = m
						result[GetId(mainBuildingTag, throughFrontTag, i, -1, k+1, o)] = m
					end 
				end
			end
		end
		if params.isElevated then 
			result[11600012] = "station/rail/modular_station/platform_lifts.module"
			result[11600028] = "station/rail/modular_station/platform_lifts.module"
		end 
	
		if not cargo then
			AddPassenger(0, s, e )
			AddTrack(1, s, e)
			local o = 0
			if params.buildThroughTracks then 
				AddTrack(2, s, e)
				AddTrack(3, s, e)
				o = 2
			end 
			if params.tracks >= 1 then 
				AddTrack(2+o, s, e)
				AddPassenger(3+o, s, e)
			end
			if params.tracks >= 2 then 
				AddTrack(4+o, s, e)
			end
			if params.tracks >= 3 then 
				AddTrack(5+o, s, e)
				AddPassenger(6+o, s, e)
			end
			if params.tracks >= 4 then 
				AddTrack(7+o, s, e)
			end
			if params.tracks >= 5 then 
				AddTrack(8+o, s, e)
				AddPassenger(9+o, s, e)
			end
			if params.tracks >= 6 then 
				AddTrack(10+o, s, e)
			end
			if params.tracks >= 7 then 
				AddTrack(11+o, s, e)
				AddPassenger(12+o, s, e)
			end
			if params.tracks >= 8 then 
				AddTrack(13+o, s, e)
			end
			if params.tracks >= 9 then 
				AddTrack(14+o, s, e)
				AddPassenger(15+o, s, e)
			end
			if params.tracks >= 10 then 
				AddTrack(16+o, s, e)
			end
			if params.tracks >= 11 then 
				AddTrack(17+o, s, e)
				AddPassenger(18+o, s, e)
			end
		end
		if cargo then
			AddCargo(0, s, e)
			AddTrack(2, s, e)
			if params.tracks >= 1 then 
				AddTrack(3, s, e)
				AddCargo(4, s, e)
			end
			if params.tracks >= 2 then 
				AddTrack(6, s, e)
			end
			if params.tracks >= 3 then 
				AddTrack(7, s, e)
				AddCargo(8, s, e)
			end
			if params.tracks >= 4 then 
				AddTrack(10, s, e)
			end
			if params.tracks >= 5 then 
				AddTrack(11, s, e)
				AddCargo(12, s, e)
			end
			if params.tracks >= 6 then 
				AddTrack(14, s, e)
			end
			if params.tracks >= 7 then 
				AddTrack(15, s, e)
				AddCargo(16, s, e)
			end
			if params.tracks >= 8 then 
				AddTrack(18, s, e)
			end
		end
		return result
	end
	
	
	helper.createRoadTemplateFn = function(params)
		local moduleVariants = {
			["passengerTerminal"] = 0,
			["cargoTerminal"] = 1,
			["hor_entrance_exit"] = 3,
			["hor_entrance"] = 4,
			["hor_exit"] = 5,
			["ver_entrance_exit"] = 6,
			["ver_entrance"] = 7,
			["ver_exit"] = 8,
			["small_building"] = 2,
			["large_building"] = 9,
		}			
		local result = {}
		-- local cargo = params.type == 1
		local cargo = params.templateIndex >= 3
	
		local length = params.year < 1950 and params.length or params.length2
	
		local MangleId = function(coords)
			return 200000 * (coords[2] + 100) + 100 * (coords[1] + 100) + coords[3]
		end
		local module = cargo and "station/street/cargo_platform.module" or "station/street/passenger_platform.module"
		
		for i = -1, 0 - params.platL, -1 do
			for j = 0, length do
				result[MangleId({i, j - math.floor(length / 2), cargo and 1 or 0})] = module
			end
			if params.includeEntryExit and params.includeEntryExit[i] then 
				--20209804
				
				--20010204 for 6
				local id = MangleId({i, length - math.floor(length / 2),moduleVariants.hor_entrance})
				-- print("The proposed mangleId was",id," i=",i) -- The proposed mangleId was	19810304
				result[id] = "station/street/entrance.module"
				--20015503
				
				--20210205 for 6 
				local id = MangleId({i, length  , moduleVariants.hor_exit})
				-- print("The proposed mangleId2 was",id)
				result[id] = "station/street/exit.module"
			end 
		end
		for i = 0, params.platR - 1 do
			for j = 0, length do
				result[MangleId({i, j - math.floor(length / 2), cargo and 1 or 0})] = module
			end
			if params.includeEntryExit and params.includeEntryExit[i] then 
				--20209804
				
				--20010104 should be
				--local id = MangleId({i, length - math.floor(length / 2),moduleVariants.hor_entrance})
				local id = MangleId({i, length- math.floor(length / 2) ,moduleVariants.hor_exit})
				-- print("The proposed mangleId was",id," i=",i) -- The proposed mangleId was	19810304
			
				result[id] = "station/street/exit.module"
				--20009805
				
				--20210105 should be
				local id = MangleId({i,  0 , moduleVariants.hor_entrance})
				-- print("The proposed mangleId2 was",id)
				result[id] = "station/street/entrance.module"
			end 
		end
		result[MangleId({55, 0, 3})] = "station/street/entrance_exit.module"
		if params.entrance_exit_b == 1 then
            result[MangleId({55, 1, 3})] = "station/street/entrance_exit.module"
		end
		
		--[[
		adding topSMallbuilding coordi	55	1
		adding topSMallbuilding coordi	-1	1
		adding topSMallbuilding coordi	0	1
		adding topSMallbuilding slot coordi	1	-2
		adding topSMallbuilding slot coordi	1	-1
		adding topSMallbuilding slot coordi	1	0
		adding topSMallbuilding slot coordi	1	1
		adding topSMallbuilding slot coordi	1	2
		adding topSMallbuilding slot coordi	1	3
		adding topSMallbuilding slot coordi	1	4
		adding topSMallbuilding slot coordi	1	5
		adding topSMallbuilding slot coordi	-2	-2
		adding topSMallbuilding slot coordi	-2	-1
		adding topSMallbuilding slot coordi	-2	0
		adding topSMallbuilding slot coordi	-2	1
		adding topSMallbuilding slot coordi	-2	2
		adding topSMallbuilding slot coordi	-2	3
		adding topSMallbuilding slot coordi	-2	4
		adding topSMallbuilding slot coordi	-2	5
		adding bottomgtopSMallbuilding coordi	55	0
adding topSMallbuilding coordi	55	1
adding bottomgtopSMallbuilding coordi	-1	0
adding topSMallbuilding coordi	-1	1
adding bottomgtopSMallbuilding coordi	0	0
		]]--
		
		if params.includeSmallBuilding then 
--			local coordI = 55 
			local coordI = -1
			local coordI = 0
			local moduleType = cargo and "station/street/era_a_cargo_building_10_10.module" or "station/street/era_"..getEra(params.year).."_passenger_building_10_10.module"
			result[MangleId({0, 0, moduleVariants.small_building})]=moduleType
			result[MangleId({-1, 0, moduleVariants.small_building})]=moduleType
		end
		if params.includeLargeBuilding then 
			-- 20609806
			-- first order 21800000
			-- leaves 9806 --> 9797
			-- print("Setting up large building, id was",MangleId({-2, 3, moduleVariants.large_building}))
			-- 19809806
			local moduleType = cargo and "station/street/era_a_cargo_building_20_20.module" or "station/street/era_"..getEra(params.year).."_passenger_building_20_20.module"
			result[MangleId({-2, 3, moduleVariants.large_building})]=moduleType
			result[MangleId({-2, -1, moduleVariants.large_building})]=moduleType
		end 
		if params.modules then 
			for k, v in pairs(params.modules) do 
				local name = v.name 
				if name and string.find(name, "building") then 
					-- print("adding back original building at ",v," for ",name)
					result[v]=name
				end
			end 	
		end 
		
		return result
	end
function helper.determineActualRoadStationParams(params) 
	local MangleId = function(coords)
		return 200000 * (coords[2] + 100) + 100 * (coords[1] + 100) + coords[3]
	end
	for key, module in pairs(params.modules) do 
		local removeLength = key - 20000000
		local platCount = math.floor((key%10000)/100)
		local i = platCount > 50 and 100-platCount or platCount
		if module.name == "station/street/cargo_platform.module" or  module.name == "station/street/passenger_platform.module" then 
			
			
			if platCount >50 then --left
				params.platL = math.max(params.platL, 100-platCount)
			else 
				params.platR = math.max(params.platR, platCount)
			end
			---- print("The plat count was",platCount," platL=",params.platL,"platR=",params.platR)			
		end
		if module.name == "station/street/exit.module" or module.name == "station/street/entrance.module" then 
			if not params.includeEntryExit then 
				params.includeEntryExit = {}
			end 
			params.includeEntryExit[i]=true
		end
		if module.name ==  "station/street/entrance_exit.module" and key == MangleId({55, 1, 3}) then 
			params.entrance_exit_b  = 1
		end 
	
	end 

end 
	
	helper.createHarbourTemplateFn = function(params)
		local result = {}
	
		local MangleId = function(coordAndFace) 
			return 1000000 * (coordAndFace[1] + 100) + 100 * (coordAndFace[2] + 100) + coordAndFace[3]
		end
			
		-- ["50_12"] { 0, 1, 2, 3 }
		-- ["50_12_flip"] { 4, 5, 6, 7 }
		-- ["100_25"] { 8, 9, 10, 11 }
		-- ["100_25_flip"] { 12, 13, 14, 15 }
		-- ["100_50"] { 16, 17, 18, 19 }
		-- ["100_50_flip"] { 20, 21, 22, 23 }
		-- ["50_50"] { 24, 25, 26, 27 }
		-- ["50_50_flip"] { 28, 29, 30, 31 }
		-- ["50_12_pier"] { 36, 37, 38, 39 }
		-- ["100_12_pier"] { 44, 45, 46, 47 }
		-- ["12_12"] { 48, 49, 50, 51 }
		
		-- local cargo = params.type == 1
		local cargo = params.templateIndex == 1
		-- print("IsCargo? ",cargo)
		local big = params.size == 1
		local terminals = math.pow(2, params.terminals)
		
		local platform = "station/water/passenger_dock_50_12.module"
		local pier = "station/water/small_pier.module"
		if big then
			if cargo then
				platform = "station/water/cargo_dock_100_25.module"
			else
				platform = "station/water/passenger_dock_100_25.module"
			end
			pier = "station/water/medium_pier.module"
		else 
			if cargo then
				platform = "station/water/cargo_dock_50_12.module"
			end
		end
		
		--result[MangleId({0, 0, 0})] = "station/water/passenger_dock_50_12.module"
		result[MangleId({1,1,50})] = "station/water/pedestrian_entrance.module" -- 98010150
		result[MangleId({0,1,50})] = "station/water/pedestrian_entrance.module"
		result[MangleId({-1,1,50})] = "station/water/pedestrian_entrance.module"
		result[MangleId({-2,1,50})] = "station/water/pedestrian_entrance.module"
		
		if params.includeSecondPassengerEntrance then 
			-- 100010150
			result[MangleId({1,2,50})] = "station/water/pedestrian_entrance.module"
			result[MangleId({0,2,50})] = "station/water/pedestrian_entrance.module"
			result[MangleId({-1,2,50})] = "station/water/pedestrian_entrance.module"
			result[MangleId({-2,2,50})] = "station/water/pedestrian_entrance.module"
		end 
		
		
		if cargo then
			result[MangleId({0, 0, 28})] = "station/water/cargo_dock_50_50.module"
		else
			result[MangleId({0, 0, 28})] = "station/water/passenger_dock_50_50.module"
		end
		
		if big then
			if terminals == 1 then
				result[MangleId({0, -4, 4})] = platform
				result[MangleId({0, -6, 44})] = pier
			end
			if terminals == 2 then
				result[MangleId({0,-4,8})] = platform
								
				result[MangleId({-2,-7,47})] = pier
				result[MangleId({1,-7,45})] =  pier
			end
			if terminals == 4 then
				result[MangleId({2,-6,8})] = platform
				result[MangleId({3,-4,11})] = platform
				result[MangleId({-2,-6,8})] = platform

				result[MangleId({0,-9,47})] = pier
				result[MangleId({-4,-9,47})] = pier
				result[MangleId({3,-9,45})] = pier
				result[MangleId({-1,-9,45})] = pier
			end
			if terminals >= 8 then
				result[MangleId({2,-6,8})] = platform
				result[MangleId({3,-4,11})] = platform
				result[MangleId({-2,-6,8})] = platform
				
				-- commented out because they appear to be innaccessible 
				--result[MangleId({0,-9,47})] = pier
				result[MangleId({-4,-9,47})] = pier
				result[MangleId({3,-9,45})] = pier
				--result[MangleId({-1,-9,45})] = pier
				
				result[MangleId({-2,-14,8})] = platform
				result[MangleId({2,-14,8})] = platform
				 

				result[MangleId({0,-17,47})] = pier
				result[MangleId({-4,-17,47})] = pier
				
				result[MangleId({3,-17,45})] = pier
				
				result[MangleId({-1,-17,45})] = pier
			end
		else 
			if terminals == 1 then
				result[MangleId({0, -4, 4})] = platform
				result[MangleId({0, -5, 36})] = pier
			end
			if terminals >= 2 then
				result[MangleId({-2,-4,0})] = platform
				result[MangleId({1,-4,0})] = platform
				
				result[MangleId({-1,-5,37})] = pier
				result[MangleId({0,-5,39})] = pier
				
				if terminals >= 4 then
					result[MangleId({-3,-5,39})] = pier
					result[MangleId({2,-5,37})] = pier
				end
			end
		end
		
		
		return result
	end
helper.createAirfieldTemplateFn = function(params)
		local result = {}
		local cargo = params.templateIndex == 1
		local hangar = params.hangar == 0
		local terminals = params.terminals and params.terminals + 1 or 1
		local airportOffset = 10000000
		-- Starting slot id of each type of slot (can be non-consecutive)
		local mainBuildingSlotId = airportOffset + 1000
		local hangarSlotId = airportOffset + 2000
		local towerSlotId = airportOffset + 4000
		local cargo_stockSlotId = airportOffset + 5000
		local terminalSlotId = airportOffset + 70000
		result[mainBuildingSlotId + 0  ] = "station/air/airfield_main_building.module"
		if cargo then
			result[terminalSlotId     + 2  ] = "station/air/airfield_cargo_terminal.module"
		else
			result[terminalSlotId     + 2  ] = "station/air/airfield_passenger_terminal.module"
		end
		if terminals > 1 then
			if cargo then
				result[terminalSlotId     + 4  ] = "station/air/airfield_cargo_terminal.module"
			else
				result[terminalSlotId     + 4  ] = "station/air/airfield_passenger_terminal.module"
			end
		end
		if terminals > 2 then
			if cargo then
				result[terminalSlotId     + 6  ] = "station/air/airfield_cargo_terminal.module"
			else
				result[terminalSlotId     + 6  ] = "station/air/airfield_passenger_terminal.module"
			end
		end
		
		if hangar then result[hangarSlotId       + 2 + terminals * 2  ] = "station/air/airfield_hangar.module" end
		
		return result
	end
	local mainBuilding1SlotId = 1000
	local mainBuilding2SlotId = 1500
	local hangar1SlotId = 2000
	local hangar2SlotId = 2500
	local towerSlotId = 4000
	local cargo_stockSlotId = 5000
	local secondRunwaySlotId = 8000
	local terminalBSlotId = 8050
	local landingSlotId = 9000
	local terminal1SlotId = 70000
	local terminal2SlotId = 75000
	local terminalCargo1SlotId = 80000
	local terminalCargo2SlotId = 85000

	helper.secondRunwaySlotId = secondRunwaySlotId
	function helper.hasSecondTaxiway(construction) 
		return construction.params.modules[terminalBSlotId]
	end 
	
	helper.createAirportTemplateFn = function(params)
		
		local taxiModuleOverlap = 24
		local result = {}
		local cargo = params.templateIndex == 1
		local hangar = params.hangar == 0
		local terminals = params.terminals and params.terminals + 1 or 1
		local erac = params.year and params.year > 1980 or false
		
		result[mainBuilding1SlotId + 2] = "station/air/airport_main_building.module"
		
		if cargo then
			result[terminalCargo1SlotId     + 6] = "station/air/airport_cargo_terminal.module"
		else
			result[terminal1SlotId     + 6] = "station/air/airport_terminal.module"
		end
		if terminals > 1 then
			if cargo then
				result[terminalCargo1SlotId     + 9] = "station/air/airport_cargo_terminal.module"
			else
				result[terminal1SlotId     + 9] = "station/air/airport_terminal.module"
			end
		end
		if terminals > 2 then
			if cargo then
				result[terminalCargo1SlotId     + 12] = "station/air/airport_cargo_terminal.module"
			else
				result[terminal1SlotId     + 12] = "station/air/airport_terminal.module"
			end
		end
		if terminals > 3 then
			if cargo then
				result[terminalCargo1SlotId     + 18] = "station/air/airport_cargo_terminal.module"
			else
				result[terminal1SlotId     + 18] = "station/air/airport_terminal.module"
			end
		end
			
		if hangar then result[hangar1SlotId     + 7 + 3 * terminals] = "station/air/airport_hangar.module" end
			
		if erac then
			result[landingSlotId       + 1 - params.dir] = "station/air/airport_era_c_landing_direction.module"
		else
			result[landingSlotId       + 1 - params.dir] = "station/air/airport_era_b_landing_direction.module"
		end
		if params.secondRunway or params.buildOffsideCargoTerminal then
			result[secondRunwaySlotId] = "station/air/airport_2nd_runway.module"
		end
		if params.buildOffsideCargoTerminal then 
			result[terminalBSlotId]="station/air/airport_terminalB.module"
			result[mainBuilding2SlotId + 2] =  "station/air/airport_main_building.module"
			--result[mainBuilding2SlotId + 2] =  "station/air/airport_main_building.module"
			local terminals = params.cargoTerminals or 1
			result[terminalCargo2SlotId     + 6] = "station/air/airport_cargo_terminal.module"
			if terminals > 1 then
				result[terminalCargo2SlotId     + 9] = "station/air/airport_cargo_terminal.module"
			end 
			
			if terminals > 2 then 
				result[terminalCargo2SlotId     + 12] = "station/air/airport_cargo_terminal.module"
			end
		end 
		
		return result
	end
return helper