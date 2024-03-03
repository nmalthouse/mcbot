
w = 9
h = 3
sw = 16
pad = 2

xi = 8
yi = 84

print("{\"default\": [")
print("""
[154, 28],
[98, 18],
[116,18],
[98, 36],
[116, 36],
[8,8],
[8,26],
[8,44],
[8,62]
      """)

for y in range(0,h):
    for x in range(0,w):
        print(",[" , str(xi + x * (pad + sw)) , "," , str(yi + y * (pad + sw)) ,"]")

xi = 8
yi = 142
for i in range(0,9):
    print(",[" , str(xi + i * (pad + sw)), ",", str(yi), "]")


print(",[0,0]")#shield slot
print("]}")
