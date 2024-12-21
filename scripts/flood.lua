local chests = { -- all the landmarks this bot will use
    food = "food",
    depot = "farm_depot", -- All the chests are within reach of depot landmark
    yield = "farmed",
}

--Map crop's block names to their stats
local crops = {
    beetroots = { age = 3, item = "beetroot_seeds", crop = "beetroot"},
    carrots = {age = 7, item = "carrot", crop = "carrot"},
    potatoes = {age = 7, item = "potato", crop = "potato"},
    wheat = {age = 7, item = "wheat_seeds", crop = "wheat"},
}

function contains(table, item)
    for i,v in ipairs(table) do
        if v == item then
            return true
        end
    end
    return nil
end
--[[
--TODO the bot checks the flood blocks in order, this is very inefficent
--looks like a tsp, just do a nearest neighbor
--]]


function loop()
    sleepms(1000)
    depositHarvest()
    --if gotoLandmark(chests.seed) then
    --else
    --    say("can't find ".. chests.seed)
    --end
    if gotoLandmark("floodtest") then
        local t = getFieldFlood("floodtest", "farmland",3 )
        local nearest_index = nil
        local nearest_dist = 100000000
        for i,f in ipairs(t) do
            local b = blockInfo(f)
            if b.name == "farmland" then
                local above_pos = f:add(Vec3:New(0,1,0))
                local above = blockInfo(above_pos)
                if crops[above.name] ~= nil and crops[above.name].age == above.state.age then
                    print("found fully grown")
                if gotoCoord(above_pos, 1) ~= nil then
                    print("breaking")
    
                    breakBlock(above_pos)
                    sleepms(300);
                    placeBlock(above_pos, crops[above.name].item)
                    sleepms(300);
                    local nearby_items = findNearbyItems(4)
                    for _, near in ipairs(nearby_items) do 
                        gotoCoord(near,2) 
                        sleepms(500)
                    end

                end
                end
            end

        end
    else
        say("cant find floodtest")
    end
    --sleepms(1000)
end


function depositHarvest()
    if gotoLandmark(chests.depot) then 
        --interactChest(chests.yield .. "_chest", {"withdraw 1 category food"})
        for k,v in pairs(crops) do
            if itemCount("item ".. v.crop ) > 64 then
                interactChest(chests.yield .. "_chest", {"deposit all item " .. v.crop})
            end
            if itemCount("item ".. v.item) < 10 then
                interactChest(chests.yield .. "_chest", {"withdraw 1 item " .. v.item})
            end
            --inventoryEnsureAtLeast(chests.yield, v.item, 10)
        end

    else
        say("Can't find depot!")
    end
end

function onYield()
    handleSleep()
    handleHunger(chests.food)
    if countFreeSlots() < 3 then
        local pos = getPosition()
        depositHarvest()
        gotoCoord(pos, 0)
    end
end
