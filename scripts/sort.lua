local cats = getSortCategories()

function loop()
    gotoLandmark("junk")
    interactChest("junk_chest", {"withdraw all any"})

    local lms = gotoLandmark("sort_start")
    local lme = getLandmark("sort_end")
    local diff = lme.pos:sub(lms.pos)
    if diff.x * diff.z ~= 0 then print("sorting area is not flat") end
    local y = diff.y
    diff.y = 0
    local dnorm = diff:unit()
    local norm = directionToVec(lme.facing)

    local final = diff:dot(Vec3:New(1,0,1))
    local inc = dnorm:dot(Vec3:New(1,1,1))
    local ci = 1
    for i=0, final, inc do
        local po = lms.pos:add(dnorm:smul(i))
        gotoCoord(po)
        for yi = 0, y do
            interactInv(po:sub(norm):add(Vec3:New(0,yi,0)), {"deposit all category " .. cats[ci], "withdraw 1 category food"})
            ci = ci + 1
        end
    end


    sleepms(1000)

end

function onYield()
    handleHunger()
end
