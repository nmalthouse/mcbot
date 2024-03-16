function loop()
    floodFindColumn({
        {one = { y = -1, tag = "minecraft:dirt"}},
        {n =   { y = 0, max = 7, tag = "minecraft:logs"}},
        {one = {tag = "minecraft:leaves"}},
    })
end

function onYield()
end
