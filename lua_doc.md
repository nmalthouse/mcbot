## Lua API documentation
The api is currently unstable.

If in doubt, consult the `LuaApi.Api struct` inside main.zig
All the functions in this struct are exported to lua with their given name.
Within a function, look for calls to `getArg` for the arguments a function expects. The second argument to `getArg` is the type zig expects, and the third is the argument's index, starting at 1.

For the values a function returns look for a `pushV()` call.

How it works:

## Lua Environment
`scripts/common.lua` is always run before the user script so everything in that file is in the namespace.

There are two Lua functions the program calls.

Mandatory: 
`loop()`, called in a loop.

Optional:
TODO onYield should be removed
`onYield()`, this is called whenever a blocking call into the lua api is made. 
The main purpose is to allow for periodically checking food, inventory etc without cluttering your script. 
See the `handleHunger()` function in `scripts/common.lua`.
Notice how the function stores and then restores the bot's position if it gets modified.


## Landmarks
A few of the functions use "landmarks". A landmark is just a Minecraft sign placed in the world. The name of the landmark is the first line of text on the sign. If signs have the same name the one that gets selected is random.
If a sign is placed on a chest, a second landmark with "_chest" appended to the original name is created.
