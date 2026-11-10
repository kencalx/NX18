#!/usr/bin/env python3
"""The NX 18 logo: a monoline NX (cyan N, an X whose coral stroke passes under the cyan one) with a small 18 in a coral pill as an exponent.
Colours from the Switch 2 Joy-Con: charcoal body, cyan left rail, coral right rail. Every letter is drawn, no fonts.
python3 docs/images/nx18/make_logo.py writes the SVGs beside it. nx18-icon-square-1024.png (the app icon the NSP script gives an app whose game
has no icon) is nx18-icon-square.svg rendered at 1024 px and flattened, as Xcode wants an icon without alpha:
  qlmanage -t -s 1024 -o /tmp nx18-icon-square.svg; sips -s format jpeg -s formatOptions 100 /tmp/nx18-icon-square.svg.png --out /tmp/i.jpg; sips -s format png /tmp/i.jpg --out nx18-icon-square-1024.png"""
import math, os
OUT = os.path.dirname(os.path.abspath(__file__))
CHAR, CYAN, CORAL, WHITE = "#2A2A2D", "#00C8F5", "#FF6B5A", "#FFFFFF"
W, H, T, B, GAP = 18, 104, 9, 95, 6
cx, cy, dx, dy = 41, 52, 64, -86
L = math.hypot(dx, dy); ux, uy = dx / L, dy / L
t = (W + GAP) / abs((64 * 86 * 2) / (L * L))
p1, p2 = (cx - ux * t, cy - uy * t), (cx + ux * t, cy + uy * t)
def f(v): return f"{v:.2f}".rstrip("0").rstrip(".")
def N(c): return f'<path d="M9 {B} V{T} L73 {B} V{T}" stroke="{c}"/>'
def X(co, cu): return f'<path d="M9 {T} L73 {B}" stroke="{co}"/><path d="M9 {B} L{f(p1[0])} {f(p1[1])} M{f(p2[0])} {f(p2[1])} L73 {T}" stroke="{cu}"/>'
def one(c): return f'<path d="M9 30 L27 {T} V{B}" stroke="{c}"/>'
def eight(c): return f'<circle cx="33" cy="28" r="19" stroke="{c}"/><circle cx="33" cy="71" r="24" stroke="{c}"/>'
def g(x, y, s, body, w=W): return f'<g transform="translate({f(x)} {f(y)}) scale({f(s)})" fill="none" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round">{body}</g>'
# the 18 pill in NX units (NX cap height 104): digits at scale S2, pill around them
NXW, PGAP, RISE = 186, 20, 26          # pill sits RISE above the cap line, PGAP right of the X
KN = 0
def mark(cN, cXo, cXu, pill, digits, filled, S2=0.38, PADX=20, PADY=13):
    """the whole mark in NX units; origin = top-left of the NX caps; returns (svg, bbox)"""
    DW, DH = (36 + 18 + 66) * S2, H * S2
    PW, PH = DW + 2 * PADX, DH + 2 * PADY
    px, py = NXW + PGAP, -RISE
    sw = W * S2
    if filled == 'knock':   # one-colour: the digits are cut out of the pill, so any background shows through
        global KN; KN += 1; mid = f"knock{KN}"
        dm = g(px + PADX, py + PADY, S2, one('#000') + f'<g transform="translate(54 0)">{eight('#000')}</g>')
        p = (f'<mask id="{mid}" maskUnits="userSpaceOnUse" x="{f(px-5)}" y="{f(py-5)}" width="{f(PW+10)}" height="{f(PH+10)}"><rect x="{f(px)}" y="{f(py)}" width="{f(PW)}" height="{f(PH)}" rx="{f(PH/2)}" fill="#fff"/>{dm}</mask>'
             f'<rect x="{f(px)}" y="{f(py)}" width="{f(PW)}" height="{f(PH)}" rx="{f(PH/2)}" fill="{pill}" mask="url(#{mid})"/>')
        body = g(0, 0, 1, N(cN)) + g(104, 0, 1, X(cXo, cXu)) + p
        return body, (0, -RISE, NXW + PGAP + PW, H + RISE)
    if filled: p = f'<rect x="{f(px)}" y="{f(py)}" width="{f(PW)}" height="{f(PH)}" rx="{f(PH/2)}" fill="{pill}"/>'
    else: p = f'<rect x="{f(px+sw/2)}" y="{f(py+sw/2)}" width="{f(PW-sw)}" height="{f(PH-sw)}" rx="{f((PH-sw)/2)}" fill="none" stroke="{pill}" stroke-width="{f(sw)}"/>'
    d = g(px + PADX, py + PADY, S2, one(digits) + f'<g transform="translate(54 0)">{eight(digits)}</g>')
    body = g(0, 0, 1, N(cN)) + g(104, 0, 1, X(cXo, cXu)) + p + d
    return body, (0, -RISE, NXW + PGAP + PW, H + RISE)
def place(body, bbox, cw, ch, scale):
    x0, y0, w, h = bbox
    return f'<g transform="translate({f((cw - w*scale)/2 - x0*scale)} {f((ch - h*scale)/2 - y0*scale)}) scale({f(scale)})">{body}</g>'

V = {  # name: (background, N, X over, X under, pill, digits, mode)
    'dark':           (CHAR,  CYAN, CYAN, CORAL, CORAL, CHAR,  True),
    'light':          (WHITE, CHAR, CHAR, CHAR,  CORAL, WHITE, True),
    'mono-black':     (None,  CHAR, CHAR, CHAR,  CHAR,  None,  'knock'),
    'mono-white':     (None,  WHITE, WHITE, WHITE, WHITE, None, 'knock'),
    'color-transparent': (None, CYAN, CYAN, CORAL, CORAL, CHAR, True),
}
def lockup(v):
    bg, *c = V[v]; body, bb = mark(*c)
    r = f'<rect width="433" height="200" rx="36" fill="{bg}"/>' if bg else ''
    return r + place(body, bb, 433, 200, 1.05)
def icon():
    body, bb = mark(CYAN, CYAN, CORAL, CORAL, CHAR, True, S2=0.5, PADX=18, PADY=12)
    return f'<rect width="1024" height="1024" rx="230" fill="{CHAR}"/>' + place(body, bb, 1024, 1024, 2.6)
def icon_square():   # full-bleed square for App Store / Xcode asset catalogues (iOS rounds the corners itself)
    body, bb = mark(CYAN, CYAN, CORAL, CORAL, CHAR, True, S2=0.5, PADX=18, PADY=12)
    return f'<rect width="1024" height="1024" fill="{CHAR}"/>' + place(body, bb, 1024, 1024, 2.6)
def svg(w, h, body, title): return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><title>{title}</title>{body}</svg>\n'
def write(n, s): open(os.path.join(OUT, n), 'w').write(s)
for v in V: write(f'nx18-lockup-{v}.svg', svg(433, 200, lockup(v), f'NX18 ({v})'))
write('nx18-icon.svg', svg(1024, 1024, icon(), 'NX18 app icon'))
write('nx18-icon-square.svg', svg(1024, 1024, icon_square(), 'NX18 app icon, full bleed'))
