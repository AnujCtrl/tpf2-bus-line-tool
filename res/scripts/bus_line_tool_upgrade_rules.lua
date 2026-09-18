-- Which street attributes a route upgrade sets. Used by the builder (route_builder.initEntity)
-- and by the overlay preview so that the orange "will be upgraded" edges match what gets built.
local rules = {}

function rules.targets(street, params)
	local hasBus = street.hasBus
	if params.addBusLanes and not params.tramOnlyUpgrade then hasBus = true end
	local tramTrackType = math.max(street.tramTrackType or 0, params.tramTrackType or 0)
	return { hasBus = hasBus, tramTrackType = tramTrackType }
end

function rules.needsUpgrade(street, params)
	local target = rules.targets(street, params)
	return target.hasBus ~= street.hasBus or target.tramTrackType ~= (street.tramTrackType or 0)
end

return rules
