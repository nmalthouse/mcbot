local start = "start_shit"
local final_x = 3092 / 8
local final_z = 7412 / 8

local supplies = {
    "netherrack",
}
local n = "netherrack"
local o = "air"
local j = "noop"

local done = false
function loop()
    sleepms(4000)
    local pos = getPosition()
    local first_dir = "north"

    if done then return end
    local i = 0
    local lm = gotoLandmark(start)
    if lm then
        while i < 700 do
        
            --if countFreeSlots() < 4 then
            --    local pos = getPosition()
            --    gotoLandmark(start)
            --    print("out of space")
            --    sleepms(60000)
            --    --OUT OF SPACE

            --end
                for _,v in ipairs(supplies) do
                    while itemCount("item " .. v) < 2 do
                        say("I am low on " .. v)
                        print("LOW ON")
                        sleepms(3000)
                    end
                end
                applySlice({bitmap = {
                    o,o,o,
                    o,o,o,
                    o,o,o,
                }, offset = Vec3:New(-1,2,-2), w = 3, direction = first_dir})
                --applySlice({bitmap = {
                --    n,n,n,
                --    n,n,n,
                --    n,n,n,
                --}, offset = Vec3:New(-1,2,-2), w = 3, direction = first_dir})
                --n = "netherrack"
                --local n_count = itemCount("item netherrack")
                --local b_count = itemCount("item basalt")
                --local s_count = itemCount("item stone_bricks")
                --local b = n
                --if b_count > 12 then b = "basalt" end
                --if s_count > 12 then b = "stone_bricks" end

                --applySlice({bitmap = {
                --    j,b,b,b,j,
                --    b,o,o,o,b,
                --    b,o,o,o,b,
                --    b,j,j,j,b,
                --    j,b,b,b,j,
                --}, offset = Vec3:New(-2,1,-3), w = 5, direction = first_dir})
                --applySlice({bitmap = {
                --    o,o,o,
                --}, offset = Vec3:New(-1,1,0), w = 3, direction = first_dir})
                    local pos = getPosition()
                    pos = pos:add(directionToVec(first_dir):smul(1))
                    while gotoCoord(pos) == nil do
                        say("I can't find my way!")
                        print("CRAP")
                        sleepms(10000)
                    end
                    i = i + 1
        end
        print("DONE")
        say("DONe")
        done = true
    else
        print("CANNOT FIND THE START")
    end
end

function onYield()
    while getHunger() < 20 do
        if not eatFood() then break end
    end
end
