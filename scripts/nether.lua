local start = "start_shit"
local final_x = 3092 / 8
local final_z = 7412 / 8

local supplies = {
    "diamond_pickaxe",
    --"netherrack",
}
local n = "netherrack"
local o = "air"
local j = "noop"

local done = false
function loop()
    sleepms(4000)
    local pos = getPosition()
    local first_dir = "west"

    if done then return end
    local i = 0
    local lm = gotoLandmark(start)
    if lm then
        while i < 225 do
        
            --if countFreeSlots() < 4 then
            --    local pos = getPosition()
            --    gotoLandmark(start)
            --    print("out of space")
            --    sleepms(60000)
            --    --OUT OF SPACE

            --end
                for _,v in ipairs(supplies) do
                    while itemCount("item " .. v) < 1 do
                        say("I am low on " .. v)
                        print("LOW ON")
                        sleepms(3000)
                    end
                end
                applySlice({bitmap = {
                    n,n,n,
                }, offset = Vec3:New(-1,1,0), w = 3, direction = first_dir})
                n = "netherrack"
                local c = n

                applySlice({bitmap = {
                    o,n,n,n,o,
                    c,o,o,o,c,
                    c,o,o,o,c,
                    c,j,j,j,c,
                    o,n,n,n,o,
                }, offset = Vec3:New(-2,1,-3), w = 5, direction = first_dir})
                applySlice({bitmap = {
                    o,o,o,
                }, offset = Vec3:New(-1,1,0), w = 3, direction = first_dir})
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
