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

function Vec3:eql(b)
    return self.x == b.x and self.y == b.y and self.z == b.z
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
    local food_amount = itemCount("category food", false)
    if food_amount < 10 then
        say("getting food only have ".. food_amount)
        local pos = getPosition()
        if not gotoLandmark(ch) then
            say("can't find food")
            return
        end
        local it_count = 0
        while food_amount < 10 do
            interactChest(ch .. "_chest", {"withdraw 1 category food"})
            food_amount = itemCount("category food", false)
            it_count = it_count + 1
            if it_count > 3 then
                say("no food in chest")
                break
            end
        end
        gotoCoord(pos)
    end

    while getHunger() < 20 do
        if not eatFood() then break end
    end
end

function inventoryEnsureAtLeast(chest, item, count) 
    if itemCount("item " .. item,false) > count then
        interactChest(chest .. "_chest", {"deposit all item " .. item})
        --Put everything in the chest

    end
    local it_count = 0
    while itemCount("item " .. item,false) < count do
        interactChest(chest .."_chest", {"withdraw 1 item " .. item})
        it_count = it_count + 1
        if it_count > 30 then--quick and dirty way until interactChest can notify failure
            break
        end

        --Take out enough
    end

end

function handleSleep()
    local sleep_time = 12542
    local time = getMcTime() % 24000

    if time > sleep_time then
        local old_pos = getPosition()
        local bl = gotoLandmark("bed")
        if bl then
    
            local bed_block = bl.pos:sub(directionToVec(bl.facing))
            placeBlock(bed_block, "use")
    
            while getMcTime() % 24000  > sleep_time do
                sleepms(1000)
            end
            gotoCoord(old_pos)
        else
            say("can't find a bed")
        end
    end
end
