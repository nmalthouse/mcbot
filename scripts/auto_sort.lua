function loop()
    local chests = {}
    local item_map = {}
    sleepms(1000)
    if gotoLandmark("sort_depot") then
        local deposit_pos = getLandmark("deposit_chest")
        local t = getFieldFlood("sort_depot", "chest", 3)
        for i,f in ipairs(t) do
            local binfo = blockInfo(f)
            if deposit_pos.pos:eql(f) then
                table.remove(t, i)
                print("removing deposit chest from list")
            end
        end
        for i,v in ipairs(t) do 
            interactInv(v, {})
            local info = getInv(true)
            chests[v] = {}
            for _, val in ipairs(info) do
                if chests[v][val['name']] == nil then
                    chests[v][val['name']]  = 0
                end
                item_map[val['name']] = v
                chests[v][val['name']] = chests[v][val['name']] + val['count']
            end
            sleepms(100)

        end

        --local selfsort = getInv()
        --for _,v in ipairs(selfsort) do
        --    if item_map[v['name']] ~= nil then
        --        --take the item and move it to the right chest
        --        interactChest("deposit_chest", {"withdraw all item " .. v['name']})
        --        interactInv(item_map[v['name']], {"deposit all item ".. v['name']})
        --    end

        --end
    


        interactChest("deposit_chest", {})
        local to_sort = getInv(true)
        for _,v in ipairs(to_sort) do
            if item_map[v['name']] ~= nil then
                --take the item and move it to the right chest
                interactChest("deposit_chest", {"withdraw all item " .. v['name']})
                interactInv(item_map[v['name']], {"deposit all item ".. v['name']})
            end
        end
        --for k,v in pairs(chests)do
        --    print(k)
        --    for ke, val in pairs(v) do
        --        print("\t", ke, val)
        --    end
        --end
        --print(itemCount("item comparator", true))
        --[[
        --go through all the chests and make note of what items they hold
        --go to dropoff chest and look for items that have a slot in sorted chests, grab and deposit in relevant chest
        --]]
    else say("can't find sort") end
    sleepms(5000)

end

function onYield()
    handleSleep()
end
