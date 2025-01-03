function loop()
    command("tp Annie -373 77 209")
    sleepms(1000)

    freemovetest(Vec3:New(0,1.5,0))
    sleepms(1000)
    local pos = getPosition()
    say("x ".. pos.x .. ", " .. pos.y .. " " .. pos.z)
    freemovetest(Vec3:New(0,-1.5,0))
    sleepms(10000)
    --freemovetest(Vec3:New(0,-1,0))

end
