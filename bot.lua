function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

function old()
    sleepms(500);
    gotoLandmark("tools")
    sleepms(100);
    chopNearestTree()
end


local is_init = true
function wheatLoop()
    sleepms(1000);
    if is_init == true then
        is_init = false
        gotoLandmark("tools")
        interactChest("tools_chest", {"deposit all any", "withdraw 1 item diamond_axe"})
    end

    gotoLandmark("seeds")
    interactChest("seeds_chest",{"deposit all item wheat_seeds", "withdraw 1 item wheat_seeds"})


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



    sleepms(1000)
    gotoLandmark("other")
    interactChest("other_dropper", {"deposit all item birch_log", "deposit all item stone"})
    sleepms(100);

    gotoLandmark("wheat_drop")
    interactChest("wheat_drop_chest", {"deposit all item wheat"})

end

function loop()
    sleepms(1000)
    gotoLandmark("wheat_drop")
    sleepms(100)
    gotoLandmark("food")
    interactChest("food_chest", {"deposit all category food"})
    interactChest("food_chest", {"withdraw 1 category food"})
    --wheatLoop()

    while getHunger() < 20 do
        if not eatFood() then break end
    end
end
