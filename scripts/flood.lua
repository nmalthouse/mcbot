local chests = { -- all the landmarks this bot will use
    food = "food",
    depot = "farm_depot", -- All the chests are within reach of depot landmark
    yield = "farmed",
    farm = "floodtest",
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

function depositHarvest()
    if gotoLandmark(chests.depot) then 
        --interactChest(chests.yield .. "_chest", {"withdraw 1 category food"})
        interactChest(chests.yield .. "_chest", {"deposit all any", "withdraw 1 category food"})
        for k,v in pairs(crops) do
            if itemCount("item ".. v.item,false) < 10 then
                interactChest(chests.yield .. "_chest", {"withdraw 1 item " .. v.item})
            end

            --inventoryEnsureAtLeast(chests.yield, v.item, 10)
        end

    else
        say("Can't find depot!")
    end
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
    if gotoLandmark(chests.farm) then
        local t = getFieldFlood(chests.farm, "farmland",3 )
        print("before " .. #t)
        local crop_list = {}
        for _,f in ipairs(t) do
            local b = blockInfo(f)
            local keep = false
            local above_pos = f:add(Vec3:New(0,1,0))
            local above = blockInfo(above_pos)
            if b.name == "farmland" then
                print(above.name, above.state.age)
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
        local nearby_items = findNearbyItemsId(3)
        for _, near_id in ipairs(nearby_items) do
            if doesEntityExist(near_id) then
                _ = pcall(gotoCoord, getEntityPos(near_id), 1.2)
            end
            sleepms(500)
        end


            end
            table.remove(crop_list, nearest_index)
        end

    else
        say("cant find floodtest")
    end
    --sleepms(1000)
end



function onYield()
    handleSleep()
    handleHunger(chests.yield)
    local should_depo = false
    for _,v in pairs(crops) do
        if itemCount("item ".. v.crop ,false) > 256 then
            should_depo  = true
            break
        end
    end
    if countFreeSlots() < 4 or should_depo then 
        local pos = getPosition()
        depositHarvest()
        gotoCoord(pos, 0)
    end
end
