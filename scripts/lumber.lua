local chopped_list = {}
local tree_types = {
    "birch",
    "spruce",
    "oak",
}
function chop_loop()
    if itemCount("tag minecraft:axes") < 2 then
        if gotoLandmark("tools") then

            while itemCount("tag minecraft:axes") < 2 do
                interactChest("tools_chest", {"withdraw 1 tag minecraft:axes"})
            end
        else 
            say("cant find tools chest")
        end
    end

    for _,v in ipairs(tree_types) do
        if itemCount("item " .. v .. "_sapling") < 10 then
            if gotoLandmark("junk") then
                interactChest("junk_chest", {"withdraw 1 item " .. v .. "_sapling"})
            else
                say("can't find junk chest")
            end
        end
    end

    local tree_name = chopNearestTree()
    if tree_name  then
        local pos = getPosition()
        placeBlock(pos, tree_name .. "_sapling")
        table.insert(chopped_list, {time = timestamp(), pos = pos})
        sleepms(1000)
    else 
        sleepms(2000)
    end

    if itemCount("tag minecraft:logs") > 64  then
        gotoLandmark("wood_drop")
        interactChest("wood_drop_chest", {"deposit all tag minecraft:logs"})
    end

    if countFreeSlots() < 19 then
        gotoLandmark("junk")
        interactChest("junk_chest", {"deposit all any", "withdraw 2 tag minecraft:axes", "withdraw all category food"})
        for _v in ipairs(tree_types) do
            interactChest("junk_chest", {"withdraw 1 item " .. v .. "_sapling"})
        end

        --interactChest("junk_chest", {"deposit all any", "withdraw all item birch_sapling", "withdraw all item diamond_axe", "withdraw all category food"})
    end


    local time = timestamp()
    for i, ch in ipairs(chopped_list) do
        local DECAY_TIME_S = 60 * 3
        if time - ch.time > DECAY_TIME_S then
            gotoCoord(ch.pos)
            local nearby = findNearbyItems(10)
            for _, near in ipairs(nearby) do gotoCoord(near) end

            table.remove(chopped_list,i)
            sleepms(100)
            break
        end
    end
end

function onYield()
    --handleSleep()
    handleHunger("$food")
end

function handleSleep()
    local sleep_time = 12542
    local time = getMcTime() % 24000

    if time > sleep_time then
        local old_pos = getPosition()
        local bl = gotoLandmark("bed")
        local bed_block = bl.pos:sub(directionToVec(bl.facing))
        placeBlock(bed_block, "use")

        while getMcTime() % 24000  > sleep_time do
            sleepms(1000)
        end
        gotoCoord(old_pos)
    end
end

function loop()
    chop_loop()
end
