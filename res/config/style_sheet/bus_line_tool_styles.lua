local ssu = require "stylesheetutil"
function data()
    local result = {}
    local a = ssu.makeAdder(result)

	a("!BusLineToolButton", {
		backgroundColor = ssu.makeColor(83, 151, 198, 200),
		borderColor = ssu.makeColor(0, 0, 0, 150)
	})
	a("!BusLineToolButton:hover", {
		backgroundColor =  ssu.makeColor(106, 192, 251, 200),
	})
	a("!BusLineToolButton:active", {
		backgroundColor = ssu.makeColor(161, 217, 255, 200),
	})
	a("!BusLineToolButton:disabled", {
		backgroundColor = ssu.makeColor(160, 180, 190, 50),
	})
	a("!BusLineToolHeader", {
		fontSize = 15,
		color = ssu.makeColor(255, 255, 255, 255),
		padding = { 6, 0, 2, 0 },
	})
	a("!BusLineToolStatus", {
		fontSize = 12,
		color = ssu.makeColor(200, 220, 240, 255),
		padding = { 2, 0, 2, 0 },
	})
	return result
end
