function old()
    sleepms(500);
    gotoLandmark("tools")
    sleepms(100);
    chopNearestTree()
end


local is_init = true
function wheatLoop()
    sleepms(1000);
    gotoLandmark("seeds")
    interactChest("seeds_chest",{"deposit all item wheat_seeds", "withdraw 1 item wheat_seeds"})

    if is_init == true then
        is_init = false
        gotoLandmark("tools")
        interactChest("tools_chest", {"deposit all any", "withdraw 1 item diamond_axe"})
    end


    sleepms(1000);
    local t = getFieldFlood("wheat_farm", "wheat")
    for i,f in pairs(t) do
        local b = blockInfo(f)
        if b.name == "wheat" and b.state.age == 7 then
            gotoCoord(f)
            breakBlock(f)
            sleepms(300);
            placeBlock(f, "wheat_seeds")
            sleepms(300);
        end
    end



    sleepms(100);

    gotoLandmark("wheat_drop")
    interactChest("wheat_drop_chest", {"deposit all item wheat"})
end

function loop()
    sleepms(1000)
    doTheFood()
    sleepms(1000)
    gotoLandmark("food")
    interactChest("food_chest", {"deposit all category food"})

    wheatLoop()
end
