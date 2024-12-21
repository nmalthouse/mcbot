bots = {}
ip = "192.168.1.120"
port = 25565

local bots_list = {
        { name = "James",       script_name = "scripts/lumber.lua" },
        { name = "Charles",     script_name = "scripts/path.lua" },
        { name = "John1",        script_name = "scripts/slicer.lua" },
        { name = "Walter",      script_name = "scripts/inv.lua" },
        { name = "Mary",        script_name = "scripts/testwalk.lua" },
        { name = "Henry",       script_name = "scripts/craft.lua" },
        { name = "George",      script_name = "scripts/do_nothing.lua" },
        { name = "Robert",      script_name = "scripts/do_nothing.lua" },
        { name = "Harry",       script_name = "scripts/ethel.lua" },
        { name = "Fred",        script_name = "scripts/ethel.lua" },
        { name = "Albert",      script_name = "scripts/ethel.lua" },

        { name = "Anna",        script_name = "scripts/ethel.lua" },
        { name = "Emma",        script_name = "scripts/ethel.lua" },
        { name = "Minnie",      script_name = "scripts/ethel.lua" },
        { name = "Margaret",    script_name = "scripts/ethel.lua" },
        { name = "Ada",         script_name = "scripts/ethel.lua" },
        { name = "Annie",       script_name = "scripts/ethel.lua" },
        { name = "Laura",       script_name = "scripts/ethel.lua" },
        { name = "Ethel",       script_name = "scripts/ethel.lua" },
}

local num_to_add = 1

for i = 1, num_to_add do
    bots[i] = bots_list[i]
end

