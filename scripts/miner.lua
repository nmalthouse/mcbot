local com = require("common")

local mine = ""
function loop()
    sleepms(1000)
    init()
end

did_init = false
function init()
    if did_init then 

        return
    end
    mine = assignMine()
    print("assigned")
    print(mine)
    did_init = true

    gotoLandmark("tools")
    interactChest("tools_chest", {"deposit all any", "withdraw 1 item diamond_pickaxe", "withdraw 1 item diamond_shovel", "withdraw 1 item cobblestone"})
    interactChest("tools_chest", {"withdraw 1 item torch"})
    gotoLandmark(mine)
    --in the positive z
    local c = getLandmark(mine)
    local zc = 1
    for x = 1, 50 do
        for i = 1, 50 do
            c.z = c.z + zc

            c.y = c.y + 2
            local above = blockInfo(c)
            c.y = c.y - 1

            if above.name == 'sand' or above.name == 'gravel' then
                while above.name ~= 'air' do
                    breakBlock(c)
                    sleepms(1000)
                    c.y = c.y + 1
                    above = blockInfo(c)
                    c.y = c.y - 1
                end
                c.y = c.y + 1
                placeBlock(c, 'cobblestone')
                c.y = c.y - 1
            end
            breakBlock(c)


            c.y = c.y - 1
            breakBlock(c)
            c.y = c.y - 1

            local bi = blockInfo(c)
            if bi.name == 'air' then
                placeBlock(c, 'cobblestone')
            end
            c.y = c.y + 1

            if i % 3 == 0 then
                sleepms(100);
                gotoCoord(c)
            end

            if i % 6 == 0 and x % 6 == 1 then
                local info = blockInfo(c)
                if info.name == 'air' then 
                    placeBlock(c, 'torch')
                end
            end
        end
        c.x = c.x - 1
        c.z = c.z + zc
        zc = zc * -1

    end
    local c = getLandmark(mine)
end

