-- Merges the modules of an existing modular road station with the modules a template generates
-- for its new size, keeping every existing module (truck platforms stay truck platforms).
local stationModules = {}

function stationModules.merge(existing, generated)
	local merged = {}
	for slot, module in pairs(existing or {}) do merged[slot] = module end
	for slot, module in pairs(generated or {}) do
		if merged[slot] == nil then merged[slot] = module end
	end
	return merged
end

return stationModules
