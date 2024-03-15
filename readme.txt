A Minecraft Bot written in zig
Linux only because of epoll() usage, can easily be changed

Running:
git submodule update --init --recursive
zig build run

The file bot_config.lua sets port, ip, and bots that will be added.

Current features:
- pathfinding
- basic inventory interaction
- multiple bots
- lua scripting
- offline mode only
- 1.19.3

Cool problems to solve:
A bot that fells and replants trees in an area
A bot that manages a set of chests, sorting items, retrieving requested items.
A bot that goes strip mining
A bot that goes hunting
A bot that manages the breeding and slaughtering of animals
A bot that farms a section of land


Todo:
Codegen for protocol.json. At the very least have zig enums generated for packet id's.
