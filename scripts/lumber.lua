local chopped_list = {}
function chop_loop()
    local axe_count = itemCount("item diamond_axe")
    if axe_count < 2 then
        gotoLandmark("tools")
        while axe_count < 2 do
            interactChest("tools_chest", {"withdraw 1 item diamond_axe"})
            axe_count = itemCount("item diamond_axe")
        end
    end

    if chopNearestTree() then
        local pos = getPosition()
        placeBlock(pos, "birch_sapling")
        table.insert(chopped_list, {time = timestamp(), pos = pos})
        sleepms(1000)
    else 
        sleepms(2000)
    end

    if itemCount("item birch_log") > 64  then
        gotoLandmark("wood_drop")
        interactChest("wood_drop_chest", {"deposit all item birch_log"})
    end

    if countFreeSlots() < 19 then
        gotoLandmark("junk")
        interactChest("junk_chest", {"deposit all any", "withdraw all item birch_sapling", "withdraw all item diamond_axe", "withdraw all category food"})
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
    handleHunger()
end

function loop()
    chop_loop()
end
