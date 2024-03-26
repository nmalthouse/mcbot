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

function Vec3:New(x_,y_,z_)
    return Vec3:new({x = x_, y = y_, z = z_ })
end

function Vec3:one()
    return Vec3:New(1,1,1)
end

function Vec3:__tostring()
    return string.format("[%f, %f, %f]", self.x, self.y ,self.z)
end

function Vec3:crass()
    print ("CRASS FUNC")
end

function Vec3:smul(s)
    return Vec3:new({x = self.x *s, y = self.y * s, z = self.z *s})
end

function Vec3:magnitude()
    return math.sqrt(self.x^2 + self.y^2 + self.z^2)
end

function Vec3:unit()
    local mag = self:magnitude()
    if mag == 0 then return Vec3:new() end
    return Vec3:new({x = self.x / mag, y = self.y / mag, z = self.z / mag})
end

function Vec3:dot(b)
    return self.x * b.x + self.y * b.y + self.z * b.z
end

function Vec3:add(b, y , z)
    local j = b
    if type(b) ~= 'table' then j = {x = b, y = y or 0, z = z or 0} end

    return Vec3:new({ x = self.x + j.x, y = self.y + j.y, z = self.z + j.z })
end

function Vec3:sub(b)
    return self:add(b:smul(-1))
end
Vec3:new() --For some reason I have to call this otherwise zig -> lua can't see Vec3 methods

function handleHunger(chest_name)
    local ch = chest_name or "food"
    local food_amount = itemCount("category food")
    if food_amount < 10 then
        local pos = getPosition()
        gotoLandmark(ch)
        while food_amount < 10 do
            interactChest(ch .. "_chest", {"withdraw 1 category food"})
            food_amount = itemCount("category food")
        end
        gotoCoord(pos)
    end

    while getHunger() < 20 do
        if not eatFood() then break end
    end
end
