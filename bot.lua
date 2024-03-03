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


function loop()
    sleepms(1000);
    local t = getFieldFlood("wheat_farm", "wheat")
    for i,f in pairs(t) do
        local b = blockInfo(f)
        if b.name == "wheat" and b.state.age == 7 then
            gotoCoord(f)
            breakBlock(f)
            placeBlock(f, "wheat_seeds")
        end
    end


    sleepms(1000)
    gotoLandmark("other")
    interactChest("other_dropper", {{deposit= {name="stone"}}, {deposit = {name="birch_log"}} })
    sleepms(100);

    gotoLandmark("wheat_drop")
    local table = {{deposit={name="wheat"}}}
    interactChest("wheat_drop_chest", table)

    gotoLandmark("seeds")
    interactChest("seeds_chest",{{withdraw={name="wheat_seeds"}}, {deposit={name="wheat_seeds"}}})
end
