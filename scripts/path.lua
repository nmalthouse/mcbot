local direc = "north"
function loop()
    local d = "dirt"
    local ic = "ice"
    local n = "noop"
    local o = "air"
    --say("/give @a stone 10")
    sleepms(100)

    local i =  0
    if gotoLandmark("farms") ~= nil then
        while i < 9 * 4 do
            local ice = d
            local sup = n
            if i % 9 == 0 then
                ice = ic
                sup = "stone"
            end
            applySlice({bitmap = {o,o,o,o,o  ,o,o,o,o,
                                  d,d,d,d,ice,d,d,d,d,
                                  n,n,n,n,sup,n,n,n,n,
        }, offset = Vec3:New(-4,1,0), w=9, direction=direc })
                local pos = getPosition()
                pos = pos:add(directionToVec(direc):smul(1))
                gotoCoord(pos)
                i = i + 1

        end
    end
end
