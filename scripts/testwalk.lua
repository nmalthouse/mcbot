function loop()
    sleepms(1000)
    gotoLandmark("$food")
    interactChest("$food_chest", {"deposit all category food"})

    return nil

    --while itemCount("item oak_log") < 10 do
    --    say("I need wook")
    --    sleepms(2000)
    --end
    --local nearest = gotoNearestCrafting()
    --craftDumb(nearest, "oak_planks", 1)
    --say("I have " .. (itemCount("item oak_planks")) .. " oak plank")


    --sleepms(1000)
end
