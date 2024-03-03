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

function loop2()
    sleepms(100)
end


function loop1()
    sleepms(1000)
    blockinfo(-207, 67, 186)
    blockinfo(-207, 67, 185)
    blockinfo(-207, 67, 187)

    blockinfo(-216, 72,218)
    blockinfo(-215, 72,218)
    blockinfo(-214, 72,218)

    print("STAIRS")
        for i = 0, 7 do
            blockinfo(-212 + i, 72, 214)
        end
    sleepms(1000);
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
    interactChest("other_chest", {{deposit= {name="stone"}} })
    sleepms(100);

    gotoLandmark("wheat_drop")
    local table = {{deposit={name="wheat"}}}
    interactChest("wheat_drop_chest", table)
end
