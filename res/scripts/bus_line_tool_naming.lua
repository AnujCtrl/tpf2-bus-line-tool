-- Suggests a name for a new line. Pure; see spec §7.
local naming = {}

local function escape(s) return (s:gsub("%p", "%%%1")) end

local function countWithPrefix(existingNames, prefix)
	local count = 0
	local pattern = "^" .. escape(prefix) .. " %d+$"
	for _, name in ipairs(existingNames) do
		if name == prefix or name:match(pattern) then count = count + 1 end
	end
	return count
end

local function exists(existingNames, name)
	for _, n in ipairs(existingNames) do if n == name then return true end end
	return false
end

function naming.suggest(input)
	local towns = {}
	for i = 1, #input.towns do if input.towns[i] then towns[#towns + 1] = input.towns[i] end end
	local first, last = towns[1], towns[#towns]
	local existing = input.existingNames or {}

	if first and last and first ~= last then
		local base = first .. " – " .. last .. " " .. input.carrier
		if not exists(existing, base) then return base end
		local n = 2
		while exists(existing, base .. " " .. n) do n = n + 1 end
		return base .. " " .. n
	end

	local prefix = input.carrier
	if first then prefix = first .. " " .. input.carrier end
	if input.isCircle then prefix = prefix .. " Ring" end
	return prefix .. " " .. (countWithPrefix(existing, prefix) + 1)
end

return naming
