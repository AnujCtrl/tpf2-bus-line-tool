# Bus line tool! (fixed fork)

Fork of okeating's Transport Fever 2 mod "Bus line tool!" (Steam Workshop 2998909889).
Personal use only: the upstream mod carries no licence.

## Install

    ./install.sh

Copies the mod to the game's local mods folder as `bus_line_tool_fixed_1`.
Unsubscribe from or disable the Workshop copy: both use the same module names.

## Tests

    lua5.4 test/run.lua

Pure logic is tested on the host with a fake `api` (`test/fake_api.lua`).
Game-facing changes are verified in-game; the tool logs lines prefixed `bus_line_tool:` to
`~/.local/share/Steam/userdata/204184616/1066780/local/crash_dump/stdout.txt`.

## Design

See `docs/superpowers/specs/2026-09-16-bus-line-tool-fork-design.md`.

## In-game checklist

1. Load "gtnh kab" with the fork enabled and the Workshop copy disabled: no freeze, no crash, and no `bus_line_tool: discovered` line in stdout.txt until the window is opened.
2. Open the tool: one `bus_line_tool: discovered N bus, M tram models in X ms` line; the chooser lists buses with capacity and speed.
3. Place three stops on streets: numbered markers, route along the streets, green/blue hover, orange segments with Bus lanes on.
4. Build: the line gets the suggested (or edited) name and the chosen colour; vehicles are bought.
5. Reuse a combined bus/truck station: truck stop intact.
6. Edit line tab: add a stop after row 2, remove one, rename, Apply; line updated, vehicles still assigned.

## Known limitations

- No keyboard shortcut (the scripting API has no key listener).
- Colour cannot be changed on an existing line (no command for it).
- A street stop added in edit mode is inserted once, on the side facing the next stop; add the opposite side by clicking the new station in a second edit.
- Stop numbers are drawn as seven-segment digits on the terrain because scripts cannot draw text in the world.
- Street widening that a build would perform is not shown in the preview; only bus lanes and tram tracks are highlighted.
- Toggling "Circle line" after picking stops does not refresh the suggested name until the next stop change.
