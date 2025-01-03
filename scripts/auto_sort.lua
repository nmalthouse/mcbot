function refresh_map()
    local chests = {}
    local item_map = {}
    local deposit_pos = getLandmark("deposit_chest")
    local tbefore = getFieldFlood("sort_depot", "chest", 3)
    local t = {}

    for i,f in ipairs(tbefore) do
        local binfo = blockInfo(f)
        local rem = false
        if deposit_pos.pos:eql(f) then
            rem = true
            print("removing deposit chest from list")
        end
        if binfo.state.type == 'right' then
            rem = true
            print("removing right side of double chest")
        end
        if rem == false then
            table.insert(t, f)
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
    return item_map
end

local item_map = {}
function loop()
    sleepms(1000)
    if gotoLandmark("sort_depot") then
        item_map = refresh_map()

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
            print("deposit has item " .. v['name'])
            if item_map[v['name']] ~= nil then
                --take the item and move it to the right chest
                interactChest("deposit_chest", {"withdraw all item " .. v['name']})
                interactInv(item_map[v['name']], {"deposit all item ".. v['name']})
            else
                print("item not found in map")
            end
            sleepms(1000)
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

    gotoLandmark("deep_storage")

end

function onYield()
    handleSleep()
end
