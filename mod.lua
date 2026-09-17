function data()
 
return {
		info = {
			minorVersion = 2,
			severityAdd = 'NONE',
			severityRemove = 'NONE',
			name = _('Bus Line Tool Plus'),
			description = _([[
Build bus and tram lines with a few clicks. Pick stops on streets or at existing stations, see a numbered route preview along the actual roads, choose the vehicle and the colour, and the tool builds the stops, upgrades the streets, creates the line and buys the vehicles. Existing bus and tram lines can be edited the same way.

Features:
- New line tab: click stops (streets or stations), linear or circular, bus or tram
- Route preview along the streets; orange where bus lanes or tram tracks would be added
- Line names suggested from the towns (editable) and a colour choice
- Existing stations keep their truck stops when a platform is added
- Edit line tab: insert, remove and rename stops on an existing line
- Safe on heavily modded saves: vehicle discovery only touches bus and tram models
]]),
			tags = { 'Script Mod', 'Tram', 'Bus' },
			authors = {
				{
					name = 'AnujCtrl',
					role = 'CREATOR',
				},
			},
			params = {}
		},




	

	runFn = function (settings, modParams)
	end,
	}
end
