local direc = "north"
function loop()
    local d = "dirt"
    local ic = "ice"
    local n = "noop"
    local o = "air"
    --say("/give @a stone 10")
    sleepms(100)
    local supplies = {
        "redstone_block",
        "stone",
        "stone_bricks",
        "rail",
        "powered_rail",
    }

    local i =  0
    if gotoLandmark("beginbridge") then
        local s = "stone"
        local t = "stone_bricks"
        local r = "rail"
        local pr  ="powered_rail"

        while i < 128 do
            if countFreeSlots() < 4 then
                local old_pos = getPosition()
                if gotoLandmark("junk") then

                    interactChest("junk_chest", {"deposit all any"})
                    for _,v in ipairs(supplies) do
                        interactChest("junk_chest", {"withdraw all item " .. v})
                    end
                end
                gotoCoord(old_pos)
            end
            for _,v in ipairs(supplies) do
                while itemCount("item " .. v) < 5 do
                    say("I am low on " .. v)
                    sleepms(3000)
                end
            end
            local tt = r
            local b = s
            if i % 6 == 0 then
                tt = pr
                b = "redstone_block"
            end
            applySlice({bitmap = {
                o,o,o,
                o,o,o,
                o,n, o,
                t,b,t,
            }, offset = Vec3:New(-1,1,-2), w = 3, direction = "south"})
            applySlice({bitmap = {
                n,tt, n,
                n,n,n,
            }, offset = Vec3:New(-1,1,0), w = 3, direction = "south"})


                local pos = getPosition()
                pos = pos:add(directionToVec("south"):smul(1))
                while gotoCoord(pos) == nil do
                    say("I can't find my way!")
                    sleepms(10000)
                end
                i = i + 1
        end
    else 
        say("Cant find the train landmark")
        sleepms(1000)
    end
    --if gotoLandmark("farms") ~= nil then
    --    while i < 9 * 4 do
    --        local ice = d
    --        local sup = n
    --        if i % 9 == 0 then
    --            ice = ic
    --            sup = "stone"
    --        end
    --        applySlice({bitmap = {o,o,o,o,o  ,o,o,o,o,
    --                              d,d,d,d,ice,d,d,d,d,
    --                              n,n,n,n,sup,n,n,n,n,
    --    }, offset = Vec3:New(-4,1,0), w=9, direction=direc })
    --            local pos = getPosition()
    --            pos = pos:add(directionToVec(direc):smul(1))
    --            gotoCoord(pos)
    --            i = i + 1

    --    end
    --end
end
