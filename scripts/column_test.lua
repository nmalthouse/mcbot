local landmarks = {
    depot = "lumber_depot", -- Place this sign within reach of all chests
    sapling = "sapling",
    wood = "wood",
    axe = "axes",
    food = "$food",
}
local log_map = {
    dark_oak_log = "dark_oak_sapling",
    cherry_log = "cherry_sapling",
    spruce_log = "spruce_sapling",
    oak_log = "oak_sapling",
    birch_log =  "birch_sapling",
    acacia_log = "acacia_sapling",
}
local supplies = {--Map item names to minimum quantities bot has
    stone_axe = 2,
}

for _,v in pairs(log_map) do
    supplies[v] = 10
end

function findTreeAndChop()
    --local binf = blockInfo(Vec3:New(-372, 77, 210))
    --print(binf.name)
    --sleepms(100000)

    --pathfindColumnMatch({ground_offset = -1, predicates = {
    --    {count = 1, tags = {"minecraft:dirt"}},
    --    {count = 1 ,names = {"redstone_torch"}},
    --}})
    local tree =  pathfindColumnMatch({ground_offset = -1, predicates = {
        {max = 1, tags = {"minecraft:dirt"}},
        {min = 3, max = 1024 ,tags = {"minecraft:logs"}},
        {min = 0, max = 4 ,names = {"air"}},
        {max = 1 ,tags = {"minecraft:leaves"}},
    }})
    if tree ~= nil then
        allowYield(false) -- We won't be able to pathfind to bed etc while chopping tree so disable yield
        local fir  = tree
        local sec  = tree:add(Vec3:New(0,1,0))

        local firr  = tree:add(Vec3:New(0.5,0,0.5))
        local pos = getPosition()

        local below = tree
        local sapling_list = {}
        local below_list = getBreakableSlice(below)
        --Determine where to place saplings and what type.
        for _,v in ipairs(below_list) do
            if blockHasTag(v, "minecraft:logs") then
                local info = blockInfo(v)
                breakBlock(v)
                if log_map[info.name] ~= nil then
                    table.insert(sapling_list, {name = log_map[info.name], pos = v})
                end
            end
        end

        local above = tree:add(Vec3:New(0,1,0))

        --Break second layer
        local list = getBreakableSlice(above)
        for _,v in ipairs(list) do 
            local bi = blockInfo(v)
            if hasBlockTag(bi.name, "minecraft:logs") then
                breakBlock(v)
            end
        end

        --Move into tree
        freemovetest(tree:sub(getPosition():add(Vec3:New(-0.5, 0,-0.5))))
        --gotoCoord(tree, 0.7)--Walk under the tree
        local leaf_count = 0

        local pillar_count = 0
        above = above:add(Vec3:New(0,1,0))
        while blockHasTag(above, "minecraft:logs") or leaf_count <= 4 do
        --while hasBlockTag(blockInfo(above).name, "minecraft:logs") or leaf_count <= 4 do
            if not blockHasTag(above, "minecraft:logs") then leaf_count = leaf_count + 1 end

            local list = getBreakableSlice(above)
            local old_pos = getPosition()
            for _,v in ipairs(list) do 
                local bi = blockInfo(v)
                local pos = getPosition()
                if hasBlockTag(bi.name, "minecraft:logs") then
                    if v:sub(pos):magnitude() > 5 then
                        pillar_count = pillar_count + 1
                        breakBlock(pos:add(Vec3:New(0,2,0))) -- break Block above in case of leaf block
                        freemovetest(Vec3:New(0,1,0))
                        print(pos.x, pos.y, pos.z)
                        placeBlock(tree:add(Vec3:New(0,pillar_count - 1,0)), bi.name)
                        sleepms(1000)
                    end
                    --if dist greater than 4, build a pillar

                    breakBlock(v)
                end
            end
            above = above:add(Vec3:New(0,1,0))
        end

        --Break the pillar and move down
        while pillar_count > 0 do
            breakBlock(tree:add(Vec3:New(0,pillar_count - 1, 0)))
            freemovetest(Vec3:New(0,-1,0))
            pillar_count = pillar_count - 1
        end

        --Place down saplings
        for _,v in ipairs(sapling_list) do
            placeBlock(v.pos, v.name)
            sleepms(200)
        end
        local nearby_items = findNearbyItems(8)
        for _, near in ipairs(nearby_items) do
            _ = pcall(gotoCoord, near, 0.6)
            sleepms(500)
        end
        allowYield(true) --Reenable yielding
    end



    --[[
    --Tree digging, 
    --We have found a tree
    --break the two logs and walk into created void
    --scan at head in breakable radius and break any
    --store break_layer_index
    --repeat break
    --if dist to breakable block > break_dist
    --  add block below and inc pillar_count
    --end
    --scan 4 above leaf block for 
    --remove pillar
    --place sapling
    --]]
end
--[[
--Script TODO
--
--support any axe kinds
--write a manangeInventory function that goes in onYield and ensures proper.
--put landmarks in config table
--have flags to disable sleep, hunger, etc
--store chopped trees in list to revist
--Write the geofencing thing to prevent bot from pathing too far
--]]

function leafQuell()
    local bl = pathfindColumnMatch({ground_offset = -1, predicates = {
        {max = 1, tags = {"minecraft:dirt"}},
        {min = 0, max = 1 ,names = {"air"}},
        {max = 1 ,tags = {"minecraft:leaves"}},
    }})


    if bl ~= nil then
        allowYield(false)
        local fir  = bl
        local sec  = bl:add(Vec3:New(0,1,0))

                breakBlock(fir)
                breakBlock(sec)
        allowYield(true)
    end
end

function manageInventory()
    --First check if all requirments are satisfied, if not path to depot
    local needs_manage = false
    local msg = ""
    for k,v in pairs(supplies) do
        if itemCount("item " .. k) < v then
            needs_manage = true 
            msg = msg .. k .. ", "
        end
    end
    if itemCount("tag minecraft:logs") > 64 then needs_manage = true end
    if countFreeSlots() < 5 then needs_manage = true end
    if needs_manage then
        sleepms(1000)
        say("Low on " .. msg)
        local status,err = pcall(gotoLandmark, landmarks.depot)
        if status then
            interactChest(landmarks.wood .. "_chest", {"deposit all tag minecraft:logs"})
            for _,v in pairs(log_map) do
                interactChest(landmarks.sapling .. "_chest", {"deposit all item " .. v, "withdraw 2 item " .. v})
                if itemCount("item " .. v) < 10 then
                    say("Chest doesn't have enough " .. v)
                end
            end
            interactChest(landmarks.axe .. "_chest", {"deposit all item stone_axe", "withdraw 2 item stone_axe" })
        else
            say("Can't find depot " .. landmarks.depot)
        end
    end

end

function onYield()
    --TODO restore position
    manageInventory()
end

function loop()
    sleepms(1000)
    findTreeAndChop()
    leafQuell()
end
