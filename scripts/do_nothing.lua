function loop()
    while getHunger() < 20 do
        if not eatFood() then break end
    end
    sleepms(1000)
end

