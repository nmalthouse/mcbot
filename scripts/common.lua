common = {}
common.doTheFood = function ()
    gotoLandmark("food")
    interactChest("food_chest", {"deposit all category food"})
    interactChest("food_chest", {"withdraw 1 category food"})
    --wheatLoop()

    while getHunger() < 20 do
        if not eatFood() then break end
    end
end

function dumpTable (o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dumpTable(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end
common.dumpTable = dumpTable

return common
