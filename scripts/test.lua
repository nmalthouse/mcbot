function loop()
    sleepms(1000)
    local bl = Vec3:New(5119, 69, 6201)
    local binfo = blockInfo(bl)

    placeBlock(bl, "use")
    for k,v in pairs(binfo.state) do
        print(k, v)
    end
    --gotoLandmark("doorroom")
end
