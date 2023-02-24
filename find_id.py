#! /usr/bin/env python
import json
import sys

with open("blocks.json") as infile:
    json_file = json.load(infile)
    query = int(sys.argv[1])

    for item in json_file:
        for id__ in item["ids"]:
            if(id__ == query):
                print(item["name"])
                exit(0)

print("Id not found")
exit(1)
