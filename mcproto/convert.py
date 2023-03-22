import json

def writeJson(filename, table):
    with open(filename, "w") as mat_out:
        mat_out.write(json.dumps(table))

blocks = sorted(json.load(open("blocks.json", "r")), key = lambda block: block['id'])
items = sorted(json.load(open("items.json", "r")), key = lambda item: item['id'])
materials = json.load(open("materials.json", "r"))

def findMaterialIndex(material, mats):
    i = 0
    for item in mats:
        if item["name"] == material:
            return i
        i += 1

# create the material table first, the indicies are needed for the block table

mat_table = []
block_table = []
item_table = []

for key in materials:
    tools = []
    for tool in materials[key]:
        tools.append({"item_id": int(tool), "multiplier": materials[key][tool]})

    mat_table.append({
        "name": key,
        "tools":tools,
        })

i = 0
for item in items:
    if int(item["id"]) != i :
        print("Item id's not continous")
        exit(-1) 
    item_table.append({
        "id": item["id"],
        "name": item["name"],
        "stack_size": item["stackSize"],
        })
    i += 1

i = 0
for block in blocks:
    if int(block["id"]) != i :
        print("block id's not continous")
        exit(-1) 

    mat_index = findMaterialIndex(block["material"], mat_table)
    block_table.append({
        "name": block["name"],
        "id": block["id"],
        "hardness": block["hardness"],
        "resistance": block["resistance"],
        "stack_size": block["stackSize"],
        "diggable": block["diggable"],
        "transparent": block["transparent"],
        "default_state": block["defaultState"],
        "min_state": block["minStateId"],
        "max_state": block["maxStateId"],
        "drops": block["drops"],

        # the two problamatic fields are states and material
        "material_i": mat_index,

        })
    i += 1




writeJson("converted/all.json", {
    "blocks":block_table,
    "materials":mat_table,
    "items":item_table,
    })
# writeJson("converted/mat_table.json", mat_table)
# writeJson("converted/block_table.json", block_table)
# writeJson("converted/item_table.json", item_table)


