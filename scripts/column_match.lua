function loop()
    local lm = gotoLandmark("mine_down")
    local vec = directionToVec(lm.facing)
    local opposite_dir = reverseDirection(lm.facing)
    local ovec = directionToVec(opposite_dir)

    local pos  = getPosition()
    while pos.y > 11 do
        pos  = getPosition()

        breakBlock(pos:add(vec):add(0,-1,0))
        breakBlock(pos:add(0,-1,0))

        local below = pos:add(0,-1,0)
        placeBlock(below:add(1,0,0), "cobblestone")
        placeBlock(below:add(0,0,-1), "cobblestone")
        placeBlock(below:add(0,0,1), "cobblestone")

        placeBlock(pos:add(0,-1,0), "ladder", opposite_dir)
        freemovetest({x = 0, y = -1, z = 0})

    end
    placeBlock(pos:add(0,-1,0), "cobblestone")

   -- local crass = vec:add(Vec3:new({x = 0,y = 20,z = 0}))
   -- print(crass.x, crass.y, crass.z)
    sleepms(1000000)
end

function onYield()
end
