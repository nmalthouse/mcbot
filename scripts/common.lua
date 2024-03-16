function doTheFood ()
    gotoLandmark("food")
    interactChest("food_chest", {"deposit all category food", "withdraw 1 category food"})

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

Vec3 = {x = 0, y = 0, z  = 0}
function Vec3:new(o)
    o = o or { }
    setmetatable(o,self)
    self.__index = self
    return o
end

function Vec3:add(b, y , z)
    local j = b
    if type(b) ~= 'table' then j = {x = b, y = y or 0, z = z or 0} end

    self.x = self.x + j.x
    self.y = self.y + j.y
    self.z = self.z + j.z
end
