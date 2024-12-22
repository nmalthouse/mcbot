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
        local crop_list = {}
        for _,f in ipairs(t) do
            local b = blockInfo(f)
            local keep = false
            local above_pos = f:add(Vec3:New(0,1,0))
            local above = blockInfo(above_pos)
            if b.name == "farmland" then
                if crops[above.name] ~= nil and crops[above.name].age == above.state.age then keep = true end
            end
            if keep then
                table.insert(crop_list, above_pos)
            end
        end

        print("left to check: " .. #crop_list)
        while #crop_list > 0 do
            local tstart = timestamp_ms()
            local nearest_index = 1
            local nearest_dist  = 1000000
            local bpos = getPosition()
            for i,v in ipairs(crop_list) do
                local mag = bpos:sub(v):magnitude()
                if mag < nearest_dist then 
                    nearest_dist = mag
                    nearest_index = i
                end
            end
            local tend = timestamp_ms()
            print("took " .. tend - tstart)

            local n = crop_list[nearest_index]
                local above = blockInfo(n)
            if gotoCoord(n, 1) ~= nil then
                breakBlock(n)
                placeBlock(n, crops[above.name].item)
                sleepms(100);
                local nearby_items = findNearbyItems(5)
                for _, near in ipairs(nearby_items) do 
                    gotoCoord(near,1) 
                    sleepms(1000)
                end

            end
            table.remove(crop_list, nearest_index)
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
