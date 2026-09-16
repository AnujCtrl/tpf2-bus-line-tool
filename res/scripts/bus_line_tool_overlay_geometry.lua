-- Pure 2D geometry for the in-world overlay. Polygons are lists of {x, y}; y points north.
local geometry = {}

function geometry.circle(cx, cy, radius, n)
	local poly = {}
	for i = 0, n - 1 do
		local a = 2 * math.pi * i / n
		poly[#poly + 1] = { cx + radius * math.cos(a), cy + radius * math.sin(a) }
	end
	return poly
end

function geometry.rect(x, y, w, h)
	return { { x, y }, { x + w, y }, { x + w, y + h }, { x, y + h } }
end

-- Seven-segment layout. Segment letters: a top, b top-right, c bottom-right, d bottom, e bottom-left, f top-left, g middle.
local DIGIT_SEGMENTS = {
	[0] = "abcdef", [1] = "bc", [2] = "abged", [3] = "abgcd", [4] = "fgbc",
	[5] = "afgcd", [6] = "afgedc", [7] = "abc", [8] = "abcdefg", [9] = "abcdfg",
}

local DEFAULTS = { height = 8, width = 4.5, thickness = 1.2, gap = 1.5 }

local function segmentRect(letter, ox, oy, o)
	local t, w, h = o.thickness, o.width, o.height
	local half = h / 2
	if letter == "a" then return geometry.rect(ox, oy + h - t, w, t) end
	if letter == "d" then return geometry.rect(ox, oy, w, t) end
	if letter == "g" then return geometry.rect(ox, oy + half - t / 2, w, t) end
	if letter == "f" then return geometry.rect(ox, oy + half, t, half) end
	if letter == "e" then return geometry.rect(ox, oy, t, half) end
	if letter == "b" then return geometry.rect(ox + w - t, oy + half, t, half) end
	if letter == "c" then return geometry.rect(ox + w - t, oy, t, half) end
	error("unknown segment " .. tostring(letter))
end

function geometry.digitPolygons(number, originX, originY, opts)
	local o = {}
	for k, v in pairs(DEFAULTS) do o[k] = opts and opts[k] or v end
	local text = tostring(math.floor(number))
	local polys = {}
	for i = 1, #text do
		local digit = tonumber(text:sub(i, i))
		local ox = originX + (i - 1) * (o.width + o.gap)
		for letter in DIGIT_SEGMENTS[digit]:gmatch(".") do
			polys[#polys + 1] = segmentRect(letter, ox, originY, o)
		end
	end
	return polys
end

return geometry
