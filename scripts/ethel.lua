local locations = {"loc1", "loc2", "loc3", "loc4", "loc5", "crasshouse", "wood_drop", "trash_area"}
local A = locations[math.random(#locations)]
local B = nil
while B == nil or B == A do
    B = locations[math.random(#locations)]
end

function loop()
    sleepms(1000)

    gotoLandmark(A)
    sleepms(1000)
    gotoLandmark(B)

end

function onYield()
    handleHunger()
end
