# Global TODO
* verbose logging of the different systems to a file.
* wrapper around epoll() to allow for a other platforms or a single tcpConnectToHost
* Notify Lua scripts when errors occur

## Other
* Fix the size of font rendering in debug render.
* Fix the cube rendering code
* Make it look pretty
* Store entities in a spatial lookup structure. Simulate collisions using ratgraphs 3d AABB collisions. 

## Pathfinder/positioning
* Breaking or placing blocks to complete a path, low hanging leaves prevent trees from being felled.
* Being left floating by changing world, bot should fall or jump to safety. Currently a floating bot can't pathfind anywhere

## Resource assignment
* How to coordinate access to a shared resource?
* Beds, tasks (mining, lumber, crafting, sorting)
* McWorld stores a list of bed positions similar to the crafting table lookup table. Bot is given the resource with local myBed = getBed(). Bot can call freeBed(myBed)?
* Bot always looks for nearest bed so the bed resource is only owned for one sleep cycle.

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

Design Idea
A mine is specified using a sign landmark, "mine:1"
A mine has distinct stages of construction
Sinking a shaft
main trunk construction
n branches off trunk
branch completion
trunk completion
mine completion - shaft sealed

Easiest solution to leaf problem:
Pass a list of blocks to pathfinder,  these blocks are considerd enterable and will be broken.
Should the pathfinder check for nonEnterable blocks before moving and break?


### Farming bot plan
#### Overview
Bot watches a plot of farmland and harvests and replants crops.

#### Problems
How to determine which blocks to watch?
Farm is specified using a landmark, any adjacent blocks of farmland are added and a floodfill for farmland is performed.
The flood fill should have a parameter that controls how many non farmland blocks can be traversed before abandoning a node
The list of farmland is returned.
Bot scans through checking the block above for a crop, empty farmland is left empty
