#! /usr/bin/env python
import json
import sys

with open("registries.json") as infile:
    json_file = json.load(infile)
    query = int(sys.argv[1])

    items = json_file["minecraft:item"]

    for key in items["entries"]:
        if int(items["entries"][key]["protocol_id"]) == query:
            print(key)
            exit(0)


print("Id not found")
exit(1)
