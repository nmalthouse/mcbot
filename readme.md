# A Minecraft Bot written in zig
Linux only because epoll() is used.

[Lua API documentation](lua_doc.md)

## Running:
        # Install zig version 0.13.0
        # make sure you have the following libraries installed system-wide:
        # libepoxy
        # sdl2
        # freetype
        # 
        # Setup a 1.21.3 Minecraft server and ensure the following is set in server.properties:
        # online-mode=false

        git clone https://github.com/nmalthouse/mcbot.git
        cd mcbot
        git submodule update --init --recursive
        zig build run

The file bot_config.lua sets port, ip, and bots that will be added.

## Current features:
- Code generation for the Minecraft protocol.
- Dimensions
- Pathfinding, (includes: ladders, gaps)
- Debug rendering
- Block breaking
- Basic inventory interaction
- Crafting
- Multiple bots
- Lua scripting

A picture of the debug renderer. 

![astar pathfinding](img/astar.jpg)

# Depends on
* [zig-nbt](https://github.com/SuperAuguste/zig-nbt)
* Everything listed under ratgraph's dependencies

## Architecture overview:

        fn main
            reads bot_config.lua
            Establishes connections with Minecraft server for all bots specified.
            Spawn a thread per bot, see function luaBotScript
            Sets up epoll() to monitor all the tcp file descriptors.
            Respond to epoll events, parsing Minecraft packets and updating our version of the Minecraft state.
            This thread sends some packets back to the server, (keepalive, respawn, confirm teleport request).
            Optionally spawn the draw() thread.
        
        fn draw()
            Renders a basic view of the Minecraft world. Can show entities, inventory, pathfinding nodes.
            launch with zig build run -- draw


