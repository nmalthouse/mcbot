# Bot

## TODO 
Write a function which determines what block a player is currently looking at.
When a player sends a chat that the bot interprets as a command, use the info from the chat packet to query the entity table to get players pos and head rotation

What if we just named properties?

## Hosting multiple bots:
bot_list
connection_list

Deal with having multiple instances of the same packet
Can be time based, if the packet is to a different id and is within 1/10 of a second from the last, discard

What do we want from this project?
Cool problems to solve.
A bot that fells and replants trees in an area
A bot that manages a set of chests, sorting items, retrieving requested items.
A bot that goes strip mining
A bot that goes hunting
A bot that manages the breeding and slaughtering of animals
A bot that farms a section of land

Bot pathfinding.
Having a fast pathfinding algorithm that finds the fastest route is important.
Things we need to consider. What blocks we can walk through, what blocks we can't jump on


Block lookup using multiple tables

Table of idRange.
These indices map to a blockinfo table containing:
block_name


What are properties
Non unique names,
a max number of states
some integer number associated with a state

waterlogged: true false, 0 1
dir: north south east west 0 1 2 3
dir: south east north west 0 1 2 3 //can be named the same but have different enumuration values

The process.py script can assign a unique id to each unique property
Each block_info then holds a list of property ids

process.py outputs a table mapping property ids
id | prop_name | []values


Is this block a stair?

if id in tag_reg["block"]["stair"]
