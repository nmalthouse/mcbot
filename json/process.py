import json



with open("full_blocks.json") as jfile:
    # Dictionary of unique properties with list of blocks that use them
    uprops = []

    jobj = json.load(jfile)

    properties = {}

    pro = {}

    pro2 = {}

    array = []
    block_info = []

    num_blocks = 0

    num_with_props = 0
    for block in jobj:
        num_blocks += 1
        properties[block] = {}
        properties[block]["count"] = 1
        properties[block]["count_state"] = len(jobj[block]["states"])
        num_states = len(jobj[block]["states"])
        starting_id = jobj[block]["states"][0]["id"]
        for i in range(0, num_states):
            assert(jobj[block]["states"][i]["id"] == starting_id + i)

        properties[block]["lower"] = starting_id
        properties[block]["upper"] = starting_id + num_states - 1

        array.append({"lower": starting_id,"upper": starting_id + num_states - 1 })
        info = {}
        info["id"] = starting_id
        info["name"] = block


        if "properties" in jobj[block]:
            for prop in jobj[block]["properties"]:
                index_of_prop = -1
                index = 0
                for item in uprops:
                    if jobj[block]["properties"][prop] == item["prop"]:
                        index_of_prop = index
                        break
                    index += 1
                if index_of_prop == -1:
                    uprops.append({"prop_name": prop, "prop": jobj[block]["properties"][prop]})
                    index_of_prop = len(uprops) - 1
                    uprops[index_of_prop]["blocks"] = []

                uprops[index_of_prop]["blocks"].append(block)







            num_with_props += 1
            # info["properties"] = jobj[block]["properties"]
            for prop in jobj[block]["properties"]:
                properties[block]["count"] *= len(jobj[block]["properties"][prop])
                if not (prop in pro):
                    pro[prop] = []
                    pro2[prop] = {}
                    pro2[prop]["prop"] = []

                if jobj[block]["properties"][prop] not in pro2[prop]["prop"]:
                    pro2[prop]["prop"].append(jobj[block]["properties"][prop])
                    pro2[prop]["blocks"] = []

                pro2[prop]["blocks"].append(block)

                for item in jobj[block]["properties"][prop]:
                    if item not in pro[prop]:
                        pro[prop].append(item)

        block_info.append(info)


    for key in properties:
        print(key, properties[key])

    total = 0
    for key in properties:
        total += properties[key]["count_state"]

    print("numblocks: ", num_blocks, "block_ids: ", total, "avg id per block: ", total / num_blocks)

    #with open("output.json", "w") as outj:
    #    outj.write(json.dumps(properties))

    #with open("props.json", "w") as outj:
    #    outj.write(json.dumps(pro))

    with open("uprops.json", "w") as outj:
        outj.write(json.dumps(sorted(uprops, key =lambda item: str.lower(item["prop_name"]))))

    with open("id_array.json", "w") as outj:
        outj.write(json.dumps(sorted(array, key=lambda item: item["lower"])))

    with open("block_info_array.json", "w") as outj:
        outj.write(json.dumps(sorted(block_info, key=lambda item: item["id"])))
    
    print("num with props", num_with_props)
