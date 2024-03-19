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

function Vec3:__tostring()
    return string.format("[%f, %f, %f]", self.x, self.y ,self.z)
end

function Vec3:crass()
    print ("CRASS FUNC")
end


function Vec3:add(b, y , z)
    local j = b
    if type(b) ~= 'table' then j = {x = b, y = y or 0, z = z or 0} end

    return Vec3:new({ x = self.x + j.x, y = self.y + j.y, z = self.z + j.z })
end
Vec3:new() --For some reason I have to call this otherwise zig -> lua can't see Vec3 methods

function handleHunger()
    local food_amount = itemCount("category food")
    if food_amount < 10 then
        local pos = getPosition()
        gotoLandmark("food")
        while food_amount < 10 do
            interactChest("food_chest", {"withdraw 1 category food"})
            food_amount = itemCount("category food")
        end
        gotoCoord(pos)
    end

    while getHunger() < 20 do
        if not eatFood() then break end
    end
end
