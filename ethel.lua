local locations = {"loc1", "loc2", "loc3", "loc4", "loc5", "crasshouse", "wood_drop", "trash_area"}
local A = locations[math.random(#locations)]
local B = nil
while B == nil or B == A do
    B = locations[math.random(#locations)]
end

local is_init = false
function init()
    is_init = true

    gotoLandmark("food")
    interactChest("food_chest", {"deposit all category food", "withdraw 1 category food"})
end

function loop()
    sleepms(1000)
    if not is_init then init() end

    gotoLandmark(A)
    sleepms(1000)
    gotoLandmark(B)

    while getHunger() < 20 do
        if not eatFood() then break end
    end

end
