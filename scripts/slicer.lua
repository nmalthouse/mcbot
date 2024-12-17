local needed_items = {--36 slots total
    --take stack, return , name
    {2,1, "diamond_axe"},
    {2,1, "diamond_shovel"},
    {2,1, "diamond_pickaxe"},
    {1,1, "stone"},
    {6,32, "stone_bricks"},
    {3,1, "oak_planks"},
    {3,1, "dirt"},
    {1,1, "torch"},
}

function checkInventory(doit)
    local missing = false
    for _, v in ipairs(needed_items) do
        local count = itemCount("item " .. v[3])
        if count <= v[2] then 
            missing = true 
            print("low on: " .. v[3])
        end
    end
    if countFreeSlots() < 5 then missing = true end
    if missing == true then
        local old_pos = getPosition()
        gotoLandmark("supply")
        for _,v in ipairs(needed_items) do
            interactChest("supply_chest", {"deposit all item " .. v[3]})
        end
        gotoLandmark("discard")
        interactChest("discard_chest", {"deposit all any"})

        gotoLandmark("supply")
        for _,v in ipairs(needed_items) do
            interactChest("supply_chest", {"withdraw " .. v[1] .. " item " .. v[3]})
        end

        gotoCoord(old_pos)
    end
end


local finished_marker = "oak_planks"
function loop()
    local o = "air"
    local a = "stone";
    local b = "dirt"
    local s = "stone_bricks"
    local w = "oak_planks"
    --applySlice({bitmap = { 1,0,1, 0,1,0, 1,0,1}, origin_index = 4})
    --applySlice({bitmap = { "air",b,a, b,a,b, a,b,a}, origin_index = 4, offset = Vec3:New(-1,2,-1), direction="north"})
    --applySlice({bitmap = { "air",b,a, b,a,b, a,b,a}, origin_index = 4, offset = Vec3:New(-1,2,-1), direction="south"})
    --applySlice({bitmap = { "air",b,a, b,a,b, a,b,a}, origin_index = 4, offset = Vec3:New(-1,2,-1), direction="east"})
    --applySlice({bitmap = { b,o,o, b,a,o, o,o,a}, origin_index = 4, offset = Vec3:New(-1,2,-1), direction="north"})
    
    if gotoLandmark("dookie") ~= nil then
        local i = 0
        while i < 50 do
            checkInventory()
            local t = o
            if i % 5 == 0 then t = "torch" end
            applySlice({bitmap = { 
                                   s,s,s,s,s, 
                                   s,o,o,o,s, 
                                   s,t,o,o,s, 
                                   s,o,o,o,s, 
                                   w,w,b,w,w
        }, offset=Vec3:New(-2,1,-3), direction="west",w=5})
            --applySlice({bitmap = { o,o,o,o,o, o,o,o,o,o, w,w,b,w,w}, offset=Vec3:New(-2,2,-1), direction="west",w=5,h=3})
            --applySlice({bitmap = { o,o,o,o,o, o,o,o,o,o, w,w,b,w,w}, offset=Vec3:New(-2,3,-1), direction="west",w=5,h=3})
            local pos = getPosition()
            pos = pos:add(directionToVec("west"):smul(1))
            gotoCoord(pos)
            i = i + 1
        end
    end
    sleepms(10000);


    --local pos = getPosition()
    --while pos.y > 11 do
    --    pos  = getPosition()
    --    applySlice({bitmap = { a,a,a, a,"ladder",a, a,a,a}, offset = Vec3:New(-1,-1,-1)})
    --    freemovetest({x = 0, y = -1, z = 0})

    --end

    --local s = makeSlice([[
    --xxx
    --s0x
    --xxx]], {"x=minecraft:air", "s=minecraft:stone"})
end
