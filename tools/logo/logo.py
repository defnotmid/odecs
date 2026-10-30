# The oicut logo: a 32x32 pixel-art punk hedgehog seen from the side, facing
# right: brown quills with a red, cyan-tipped mohawk cut along the ridge, a
# scowl, a safety pin through the ear and a studded collar. Writes an SVG whose
# parts are groups a script can show or hide by id, to blink:
#
#   body     quills, mohawk, face, ear, collar, feet (always on)
#   eye      the eye open (on)                  blink  the eye shut (off)
#   silhouette  every pixel visible by default as one outline (off): the shape
#               to morph, extrude or collide
#
# Each group is one path per colour, its pixels traced into merged outlines.
#
#   python3 tools/logo/logo.py assets/logo.svg   (also prints the body)
import math, sys

W = H = 32
PAL = {
  'O': '#1b1a2e', 'Q': '#5a4334', 'q': '#8c6a4c', 'u': '#3e2e25', 'r': '#ff5a4e', 's': '#c43a35',
  'C': '#2ee6f0', 'F': '#efd2a6', 'f': '#c99d70', 'k': '#ff8fa3', 'h': '#0b0b12', 'W': '#ffffff',
  'A': '#d8deeb', 'a': '#8a90aa', 'R': '#14131d',
}

def grid():
    return [['.'] * W for _ in range(H)]

def put(g, x, y, c):
    if 0 <= x < W and 0 <= y < H:
        g[y][x] = c

def tri(t):
    # A triangle wave, 0 at whole t and 1 halfway between: one spike per period.
    f = t - math.floor(t)
    return 1 - abs(2 * f - 1)

def ell(x, y, cx, cy, rx, ry):
    return math.hypot((x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry)

# ---- the body: an oval of quills, spikes off the back, the mohawk on the ridge -------
body = grid()
cx, cy, RX, RY = 14.0, 20.0, 11.0, 8.0

# A spike from the oval's edge at angle a, leaning back by lean, length long:
# pixels within its tapering triangle, the last tip_len of it in colour tip,
# outlined over the spikes drawn before it so each stands apart.
def spike(a, lean, long, half, fill, tip, tip_len):
    bx, by = cx + RX * 0.9 * math.cos(a), cy + RY * 0.9 * math.sin(a)
    da = a - lean
    dx, dy = math.cos(da), math.sin(da)
    cells = {}
    for y in range(H):
        for x in range(W):
            px, py = x + 0.5 - bx, y + 0.5 - by
            t, s = px * dx + py * dy, -px * dy + py * dx
            if 0 <= t <= long and abs(s) <= half * (1 - t / long) + 0.45:
                cells[(x, y)] = tip if t > long - tip_len else fill
    for (x, y) in cells:
        for ddx, ddy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            if (x + ddx, y + ddy) not in cells:
                put(body, x + ddx, y + ddy, 'O')
    for (x, y), c in cells.items():
        put(body, x, y, c)
for i in range(6):
    spike(-2.95 + 0.42 * i, 0.25, 3.2, 1.3, 'Q', 'q', 1.2)   # the rump and back, low quills
for a in (2.85, 2.45):
    spike(a, -0.2, 2.6, 1.2, 'Q', 'q', 1.0)
for i, long in enumerate((5.5, 7.5, 8.5, 8.0, 6.0)):
    spike(-2.2 + 0.33 * i, 0.45, long, 1.0, 'r', 'C', 2.0)  # the mohawk

for y in range(H):
    for x in range(W):
        d = ell(x, y, cx, cy, RX, RY)
        if d <= 1:
            a = math.atan2(y + 0.5 - cy, x + 0.5 - cx)
            streak = tri(a / 0.21) > 0.72 and d > 0.5
            put(body, x, y, 'q' if streak else ('u' if d > 0.8 and y > cy + 3 else 'Q'))

# ---- the face: a round cheek and a pointed snout, a scowl, the nose ------------------
fx, fy = 22.5, 21.5
def face(x, y):
    return ell(x, y, fx, fy, 5.6, 5.0) <= 1 or ell(x, y, 26.6, 23.2, 3.4, 2.0) <= 1
for y in range(H):
    for x in range(W):
        if face(x, y):
            put(body, x, y, 'f' if y >= 24 and ell(x, y, fx, fy, 5.6, 5.0) > 0.55 else 'F')
# the studded collar where the face meets the quills
for y in range(H):
    for x in range(W):
        e = ell(x, y, fx, fy, 5.6, 5.0)
        if 1.0 < e <= 1.3 and y >= 16 and body[y][x] in 'Qqu' and x < 21:
            put(body, x, y, 'A' if (y - 16) % 3 == 1 else 'R')
for (x, y) in [(29, 23), (30, 23), (29, 24)]:
    put(body, x, y, 'h')   # the nose
for (x, y) in [(21, 18), (22, 18), (23, 19), (24, 19)]:
    put(body, x, y, 'h')   # the brow, low and angry
for (x, y) in [(26, 25), (27, 25)]:
    put(body, x, y, 'f')   # the mouth's crease

# ---- the ear, with a safety pin through it -------------------------------------------
for (x, y) in [(19, 15), (20, 15), (19, 16), (20, 16), (21, 16)]:
    put(body, x, y, 'F')
put(body, 20, 16, 'k')
for (x, y) in [(18, 14), (18, 15), (18, 16)]:
    put(body, x, y, 'a')
put(body, 18, 13, 'A')

# ---- the feet ----------------------------------------------------------------------------
for (x, y) in [(9, 28), (10, 28), (18, 28), (19, 28), (20, 28)]:
    put(body, x, y, 'f')

# ---- the outline: every empty pixel beside a filled one --------------------------------
edge = [(x, y) for y in range(H) for x in range(W) if body[y][x] == '.' and any(
    0 <= x + dx < W and 0 <= y + dy < H and body[y + dy][x + dx] != '.' for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))]
for (x, y) in edge:
    put(body, x, y, 'O')

eye = grid()
for (x, y) in [(22, 19), (23, 20), (22, 20)]:
    put(eye, x, y, 'h')
put(eye, 22, 19, 'W')
put(eye, 23, 19, 'h')

blink = grid()
for (x, y) in [(22, 20), (23, 20)]:
    put(blink, x, y, 'h')

LAYERS = [('body', body, True), ('eye', eye, True), ('blink', blink, False)]

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
