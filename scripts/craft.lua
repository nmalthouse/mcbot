function loop()

    --gotoLandmark("stuff")
    --interactChest("stuff_chest", {"deposit all any", "withdraw 1 item oak_log"})
    --interactChest("stuff_chest", {"withdraw 1 item stick", "withdraw 1 item diamond"})

    gotoLandmark("hay")
    interactChest("hay_chest", {"deposit all item hay_block"})

    --if itemCount("item wheat") < 9 * 64 then

        gotoLandmark("wheat_drop")
        interactChest("wheat_drop_chest", {"deposit all item wheat", "withdraw 10 item wheat"})
    --end

    gotoLandmark("craft")
    print(craftDumb("hay_block", 64))
    --craftDumb("oak_planks" ,16)
    --craftDumb("diamond_axe" ,1)
    
end
