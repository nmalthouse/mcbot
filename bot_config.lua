bots = {}

local bots_list = {
        { name = "John",        script_name = "bot.lua" },
        { name = "James",       script_name = "ethel.lua" },
        { name = "Charles",     script_name = "ethel.lua" },
        { name = "George",      script_name = "ethel.lua" },
        { name = "Henry",       script_name = "ethel.lua" },
        { name = "Robert",      script_name = "ethel.lua" },
        { name = "Harry",       script_name = "ethel.lua" },
        { name = "Walter",      script_name = "ethel.lua" },
        { name = "Fred",        script_name = "ethel.lua" },
        { name = "Albert",      script_name = "ethel.lua" },

        { name = "Mary",        script_name = "ethel.lua" },
        { name = "Anna",        script_name = "ethel.lua" },
        { name = "Emma",        script_name = "ethel.lua" },
        { name = "Minnie",      script_name = "ethel.lua" },
        { name = "Margaret",    script_name = "ethel.lua" },
        { name = "Ada",         script_name = "ethel.lua" },
        { name = "Annie",       script_name = "ethel.lua" },
        { name = "Laura",       script_name = "ethel.lua" },
        { name = "Ethel",       script_name = "ethel.lua" },
}

local num_to_add = 1;

for i = 1, num_to_add do
    bots[i] = bots_list[i]
end
