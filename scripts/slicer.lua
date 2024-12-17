function loop()
    local o = "air"
    local a = "stone";
    local b = "dirt"
    --applySlice({bitmap = { 1,0,1, 0,1,0, 1,0,1}, origin_index = 4})
    --applySlice({bitmap = { "air",b,a, b,a,b, a,b,a}, origin_index = 4, offset = Vec3:New(-1,2,-1), direction="north"})
    --applySlice({bitmap = { "air",b,a, b,a,b, a,b,a}, origin_index = 4, offset = Vec3:New(-1,2,-1), direction="south"})
    --applySlice({bitmap = { "air",b,a, b,a,b, a,b,a}, origin_index = 4, offset = Vec3:New(-1,2,-1), direction="east"})
    --applySlice({bitmap = { b,o,o, b,a,o, o,o,a}, origin_index = 4, offset = Vec3:New(-1,2,-1), direction="north"})
    
    if gotoLandmark("crassmine") ~= nil then
        local i = 0
        while i < 10 do
            applySlice({bitmap = { o,o,o, o,o,o, o,b,o}, offset=Vec3:New(-1,1,-1), direction="west"})
            applySlice({bitmap = { o,o,o, o,o,o, o,b,o}, offset=Vec3:New(-1,2,-1), direction="west"})
            applySlice({bitmap = { o,o,o, o,o,o, o,b,o}, offset=Vec3:New(-1,3,-1), direction="west"})
            local pos = getPosition()
            pos = pos:add(directionToVec("west"):smul(3))
            sleepms(100)
            gotoCoord(pos)
            i = i + 1
        end
    end
    sleepms(10000);


    --local pos = getPosition()
    --while pos.y > 11 do
    --    pos  = getPosition()
    --    applySlice({bitmap = { a,a,a, a,"ladder",a, a,a,a}, offset = Vec3:New(-1,-1,-1)})
    --    freemovetest({x = 0, y = -1, z = 0})

    --end

    --local s = makeSlice([[
    --xxx
    --s0x
    --xxx]], {"x=minecraft:air", "s=minecraft:stone"})
end
