function data()
 
return {
		info = {
			minorVersion = 2,
			severityAdd = 'NONE',
			severityRemove = 'NONE',
			name = _('Bus line tool! (fixed fork)'),
			description = _([[ 
Local fork of okeating's Bus line tool (Workshop 2998909889): no crash on save load with many mods, tabbed window, numbered stop markers, route preview, auto line names, truck stops preserved, edit existing lines.

Original description:
One area where I much prefer cities skylines is the relative ease of creating bus lines. TPF2 can be a little tedious, and this mod aims to solve this by letting you build bus (and tram) lines with just one click per stop!

Click to build the bus stop, click to add the stop to a line, build a depot, buy vehicles, assign them to the line - all now with one click!

Features:
- Select where you want your bus stops to go, either a circular or linear route using buses or trams and the tool will do the rest!
- Performs street upgrades for you (i.e. adding bus lanes or tram tracks if desired) 
- Defaults in a sensible vehicle choice using a weighted ranking (you are free to custom pick the vehicle)
- Defaults in a number of vehicles (formula is number of stops divided by 2, rounded down, but always at least 2 vehicles)
- Looks for an appropriate depot nearby with a path to the line, if not found will automatically construct one 
- Ignore validation option will allow the tool to force upgrade a street even if it would otherwise be prevented by a collision

Update version 1.1:
- Add a new feature that allows you to select existing bus stations to include in the line
]]),
			tags = { 'Script Mod', 'Tram', 'Bus' },
			authors = {
				{
					name = 'okeating',
					role = 'CREATOR',
				},
			},
			params = {}
		},




	

	runFn = function (settings, modParams)
	end,
	}
end
