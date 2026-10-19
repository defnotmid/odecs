# The odecs logo: a 32x32 pixel-art turntable seen from above, a record on
# the platter, the tonearm resting in the groove. Writes an SVG whose parts
# are groups a script can show or hide by id, to spin the record:
#
#   body     plinth, platter, record, label, tonearm, pitch slider (always on)
#   shine_a  the light on the grooves (on)     shine_b, shine_c  the record turned
#                                              a third and two thirds
#   led      the power light lit (on)
#   silhouette  every pixel visible by default as one outline (off): the shape
#               to morph, extrude or collide
#
# Each group is one path per colour, its pixels traced into merged outlines.
#
#   python3 tools/logo/logo.py assets/logo.svg   (also prints the body)
import math, sys

W = H = 32
PAL = {
  'O': '#1b1a2e', 'P': '#4a4670', 'p': '#35324f', 'L': '#6c68a0', 'R': '#14131d', 'g': '#302e47',
  'G': '#57547a', 'C': '#2ee6f0', 'c': '#17a9c4', 'h': '#0b0b12', 'A': '#d8deeb', 'a': '#8a90aa',
  'r': '#ff5a4e', 'Y': '#ffe14d', 'y': '#8a6a3c', 'W': '#ffffff',
}

def grid():
    return [['.'] * W for _ in range(H)]

def put(g, x, y, c):
    if 0 <= x < W and 0 <= y < H:
        g[y][x] = c

# ---- the plinth: a rounded box, lit along the top, shaded along the bottom ------
body = grid()
X0, Y0, X1, Y1 = 1, 3, 30, 28
for y in range(Y0, Y1 + 1):
    for x in range(X0, X1 + 1):
        if x in (X0, X1) and y in (Y0, Y1):
            continue
        put(body, x, y, 'O' if x in (X0, X1) or y in (Y0, Y1) else 'P')
for x in range(X0 + 1, X1):
    put(body, x, Y0 + 1, 'L')
    put(body, x, Y1 - 1, 'p')
for x in (X0 + 2, X0 + 3, X1 - 3, X1 - 2):
    put(body, x, Y1 + 1, 'O')   # little feet

# ---- the record: grooves, a cyan label, the spindle --------------------------------
cx, cy, R = 12.0, 16.0, 8.4
def rad(x, y):
    return math.hypot(x + 0.5 - cx, y + 0.5 - cy)
for y in range(H):
    for x in range(W):
        d = rad(x, y)
        if R + 0.9 < d <= R + 1.8:
            put(body, x, y, 'O')
        elif R < d <= R + 0.9:
            put(body, x, y, 'a' if (x + 0.5 - cx) + (y + 0.5 - cy) > -2 else 'A')   # the platter's rim
        elif d <= R:
            put(body, x, y, 'C' if d <= 3.3 else 'R')
            if d > 3.3 and any(lo < d <= hi for lo, hi in ((4.5, 5.2), (6.2, 6.9))):
                put(body, x, y, 'g')   # grooves
            if 2.0 < d <= 3.3 and (x + 0.5 - cx) + (y + 0.5 - cy) > 1.0:
                put(body, x, y, 'c')   # the label's shade
for (x, y) in [(11, 15), (12, 15), (11, 16), (12, 16)]:
    put(body, x, y, 'h')

# ---- the tonearm: a counterweight, the pivot, the arm down to the headshell ----------
def blob(cells, fill, light=()):
    for (x, y) in cells:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            if (x + dx, y + dy) not in cells and body[y + dy][x + dx] in '.PLp':
                put(body, x + dx, y + dy, 'O')
    for (x, y) in cells:
        put(body, x, y, 'A' if (x, y) in light else fill)
blob({(25, 5), (26, 5)}, 'a', {(25, 5)})
blob({(24, 7), (25, 7), (26, 7), (24, 8), (25, 8), (26, 8), (24, 9), (25, 9), (26, 9)}, 'a', {(24, 7), (25, 7)})
blob({(25, y) for y in range(10, 18)} | {(24, 18), (23, 19)}, 'A')
blob({(19, 20), (20, 20), (21, 20), (22, 20), (19, 21), (20, 21), (21, 21)}, 'a', {(20, 20), (21, 20), (22, 20)})

# ---- the pitch slider, the start button ------------------------------------------------
for y in range(13, 23):
    put(body, 28, y, 'O')
blob({(27, 17), (28, 17), (29, 17)}, 'A')
blob({(3, 25), (4, 25)}, 'a', {(3, 25)})

# ---- the light on the record: three turns of a glint across the grooves -------------
def shine(angle):
    g = grid()
    for y in range(H):
        for x in range(W):
            d = rad(x, y)
            if 3.9 < d <= R - 0.5 and body[y][x] in 'Rg':
                a = math.atan2(y + 0.5 - cy, x + 0.5 - cx)
                da = (a - angle + math.pi) % (2 * math.pi) - math.pi
                if abs(da) < 0.22:
                    put(g, x, y, 'G')
    return g
shine_a, shine_b, shine_c = shine(-2.4), shine(-2.4 + 2 * math.pi / 3), shine(-2.4 + 4 * math.pi / 3)

led = grid()
put(led, 27, 25, 'r'); put(led, 28, 25, 'r')

LAYERS = [('body', body, True), ('shine_a', shine_a, True), ('shine_b', shine_b, False),
          ('shine_c', shine_c, False), ('led', led, True)]

# Writes the outline of the mask's pixels as path data: one closed loop per
# boundary, the pixels on its right (clockwise on screen), so holes wind the
# other way and fill as holes under either fill rule. Straight runs are single
# segments; pixels touching only at a corner stay apart. (ovg tools/mascot trace)
def trace(mask):
    def at(x, y):
        return 0 <= x < W and 0 <= y < H and (x, y) in mask
    out = {}   # boundary edges by start vertex (two where pixels touch at a corner)
    for y in range(H):
        for x in range(W):
            if not at(x, y):
                continue
            if not at(x, y - 1): out.setdefault((x, y), []).append((x + 1, y))
            if not at(x + 1, y): out.setdefault((x + 1, y), []).append((x + 1, y + 1))
            if not at(x, y + 1): out.setdefault((x + 1, y + 1), []).append((x, y + 1))
            if not at(x - 1, y): out.setdefault((x, y + 1), []).append((x, y))
    d = ''
    for start in [(x, y) for y in range(H + 1) for x in range(W + 1)]:
        while out.get(start):
            # Walk the loop, writing a point where the direction changes.
            pts, v, dir = [], start, (0, 0)
            while True:
                k = 0
                if len(out[v]) == 2 and pts:
                    # At a corner touch, turn right: keep to the pixels on the right.
                    right = (-dir[1], dir[0])
                    k = next((j for j in range(2) if (out[v][j][0] - v[0], out[v][j][1] - v[1]) == right), 0)
                nxt = out[v].pop(k)
                step = (nxt[0] - v[0], nxt[1] - v[1])
                if not pts or step != dir:
                    pts.append(v)
                dir, v = step, nxt
                if v == start:
                    break
            d += f'M{pts[0][0]} {pts[0][1]}'
            for prev, p in zip(pts, pts[1:]):
                d += f'H{p[0]}' if p[1] == prev[1] else f'V{p[1]}'
            d += 'Z'
    return d

# Each layer is one path per colour, its pixels traced into merged outlines;
# `silhouette` (off) is every pixel visible by default as one outline, the
# shape to morph, extrude or collide (onimite outline{svg, id = "silhouette"}).
out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W * 8}" height="{H * 8}" shape-rendering="crispEdges">']
for name, g, on in LAYERS:
    colours = list(dict.fromkeys(g[y][x] for y in range(H) for x in range(W) if g[y][x] != '.'))
    paths = ''.join(f'<path fill="{PAL[c]}" d="{trace({(x, y) for y in range(H) for x in range(W) if g[y][x] == c})}"/>'
                    for c in colours)
    out.append(f'<g id="{name}"{"" if on else " display=\"none\""}>{paths}</g>')
seen = {(x, y) for _, g, on in LAYERS if on for y in range(H) for x in range(W) if g[y][x] != '.'}
out.append(f'<g id="silhouette" display="none"><path fill="{PAL["O"]}" d="{trace(seen)}"/></g>')
out.append('</svg>\n')
open(sys.argv[1], 'w').write('\n'.join(out))
print('\n'.join(''.join(r) for r in body))
