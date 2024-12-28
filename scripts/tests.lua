function loop()
    sleepms(1000)
    if gotoLandmark("test_landmark") ~= nil then
        interactChest("trash_chest", {"deposit all any"})
        local count = itemCount("any")
        if count ~= 0 then
            print("inventory has items, should have emptied empty")
        end
        interactChest("trash_chest", {"withdraw all item oak_log"})

        interactChest("test_inv_chest", {"deposit all item oak_log"})
        interactChest("test_inv_chest", {})
        local log_count = itemCount("item oak_log" , true)
        while log_count < 10 do
            say("need logs")
            sleepms(5000)
            interactChest("test_inv_chest", {})
            log_count = itemCount("item oak_log" , true)
        end

        interactChest("test_inv_chest", {"withdraw 1 item oak_log"})

        local nearest =  gotoNearestCrafting()
        if nearest ~= nil then
            craftDumb(nearest, "oak_planks", 1)
        else
            print("CANT FIND A BENCH")
        end
        say("I have " .. (itemCount("item oak_planks")) .. " oak plank")
    else
        print("test, can't find landmark test_landmark")
    end

    local mcTime = getMcTime()
    print("mc time", mcTime)

end
