import json


with open("full_blocks.json") as jfile:
    jobj = json.load(jfile)

    properties = {}

    pro = {}

    pro2 = {}

    array = []

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

        array.append({"name": block, "lower": starting_id,"upper": starting_id + num_states - 1 })



        if "properties" in jobj[block]:
            num_with_props += 1
            for prop in jobj[block]["properties"]:
                properties[block]["count"] *= len(jobj[block]["properties"][prop])
                if not (prop in pro):
                    pro[prop] = []
                    pro2[prop] = []

                if jobj[block]["properties"][prop] not in pro2[prop]:
                    pro2[prop].append(jobj[block]["properties"][prop])

                for item in jobj[block]["properties"][prop]:
                    if item not in pro[prop]:
                        pro[prop].append(item)



    for key in properties:
        print(key, properties[key])

    total = 0
    for key in properties:
        total += properties[key]["count_state"]

    print("numblocks: ", num_blocks, "block_ids: ", total, "avg id per block: ", total / num_blocks)

    with open("output.json", "w") as outj:
        outj.write(json.dumps(properties))

    with open("props.json", "w") as outj:
        outj.write(json.dumps(pro))

    with open("props2.json", "w") as outj:
        outj.write(json.dumps(pro2))

    with open("array.json", "w") as outj:
        outj.write(json.dumps(sorted(array, key=lambda item: item["lower"])))
    
    print("num with props", num_with_props)
