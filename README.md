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
