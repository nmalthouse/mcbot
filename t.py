def printRows(xi, yi, nx, ny, first =False):
    for y in range(0,ny):
        for x in range(0 , nx):
            print("{comma}[{xv},{yv}]".format(comma= ' ' if first else ',', xv = xi + x * 18, yv = yi + y * 18))
            first = False

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

printRows(8,84, 9,3)
printRows(8,142, 9,1)

print(",[0,0]")#shield slot
print("],")

print("\"generic_9x3\":[")
printRows(8,18, 9, 3, first = True)
printRows(8,84, 9,3)
printRows(8,142, 9,1)

print("]")
print("}")

