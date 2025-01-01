function loop()
    sleepms(1000)
    giveError()
    gotoLandmark("asswiper")
    local bl = Vec3:New(-190, 71, 201)
    local binfo = blockInfo(bl)

    placeBlock(bl, "use")
    for k,v in pairs(binfo.state) do
        --print(k, v)
    end
    --gotoLandmark("doorroom")
end
