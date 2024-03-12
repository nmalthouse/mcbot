local com = dofile("scripts/common.lua")

function loop()
    sleepms(1000)
    interactChest("tools_chest", {"withdraw all item oak_log"})
    --com.doTheFood()
    --gotoLandmark("tools")

    --gotoLandmark("craft")
    --craftingTest("craft_craft")
end
