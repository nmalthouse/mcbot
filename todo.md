# Global TODO
* verbose logging of the different systems to a file
* wrapper around epoll() to allow for a other platforms or a single tcpConnectToHost
* Cleanup the vector classes, move to using zalgebra? 
* Tune the pathfinder for large vertical movements
* Store a per-bot entity list rather than a single global list.
* Notify Lua scripts when errors occur


## Other
* Fix the size of font rendering in debug render.
* Fix the cube rendering code


### Mining bot plan
Mining is hard because a number of factors. Caves, lava, water, monsters.
Easy way around is to only strip mine, perfect sealed tunnels can be created.
Resources that must be monitored:
* Tool durability 
* Food
* Blocks for sealing voids in tunnel
* Torches

Other things that must be taken into account
* travel time to mining face.
* y level of mineshaft
* retaining state of mineshaft between reloads
* specifying shape of mineshaft using manual vector math and check/breakBlock calls is tedious and error prone

Design Idea
A mine is specified using a sign landmark, "mine:1"
A mine has distinct stages of construction
Sinking a shaft
main trunk construction
n branches off trunk
branch completion
trunk completion
mine completion - shaft sealed

A special marker block can be used to store memory in the mc world.


# crafting
Api looks like this: craft(oak_fence, 1)
Wow do we do it?
