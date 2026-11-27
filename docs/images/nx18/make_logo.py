#!/usr/bin/env python3
"""The NX 18 logo: a monoline NX (cyan N, an X whose coral stroke passes under the cyan one) with a small 18 in a coral pill as an exponent.
Colours from the Switch 2 Joy-Con: charcoal body, cyan left rail, coral right rail. Every letter is drawn, no fonts.
python3 docs/images/nx18/make_logo.py writes the SVGs beside it, Beam's too (beam-icon*.svg, beam-title-*.svg). nx18-icon-square-1024.png (the app icon the NSP script gives an app whose game
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
# Beam (the Mac app, beam/): the NX 18 mark over a B whose lower bowl is a coral stroke passing under the stem, as the X's does, with three coral dashes either side (the beam).
# BEAM in the title: capitals drawn in the NX's grammar (cap height T..B, stroke W, round ends), 96 apart
def B_(c, c2=None, split=False):
    lo = f'M{9 + W + GAP} 52 H44 A21.5 21.5 0 0 1 44 95 H{9 + W + GAP}' if split else 'M9 52 H44 A21.5 21.5 0 0 1 44 95 H9'
    return f'<path d="M9 95 V9 H40 A21.5 21.5 0 0 1 40 52 H9" stroke="{c}"/><path d="{lo}" stroke="{c2 or c}"/>'
def E_(c): return f'<path d="M70 9 H9 V95 H70 M9 52 H58" stroke="{c}"/>'
def A_(c): return f'<path d="M9 95 L41 9 L73 95 M23 62 H59" stroke="{c}"/>'
def M_(c): return f'<path d="M9 95 V9 L41 58 L73 9 V95" stroke="{c}"/>'
def dashes(x0, side):   # three strokes on one side of the B, the middle one longest; side -1 ends at x0, +1 starts there
    d = ''.join(f'<path d="M{f(x0 - L if side < 0 else x0)} {y} H{f(x0 if side < 0 else x0 + L)}" stroke="{CORAL}"/>' for y, L in ((18, 34), (52, 58), (86, 34)))
    return f'<g fill="none" stroke-width="{W}" stroke-linecap="round">{d}</g>'
def beam_icon(rounded):
    body, bb = mark(CYAN, CYAN, CORAL, CORAL, CHAR, True, S2=0.5, PADX=18, PADY=12)
    dl, gap, bw, s = 58, 40, 66, 0.9                       # dash length, dash-to-B gap, the B's drawn width, the row's scale
    roww = 2 * (dl + gap) + bw
    row = dashes(dl, -1) + g(dl + gap - 9, 0, 1, B_(CYAN, CORAL, True)) + dashes(dl + gap + bw + gap, 1)
    rx, ry = bb[2] / 2 - roww * s / 2, 104 + 70
    body += f'<g transform="translate({f(rx)} {f(ry)}) scale({f(s)})">{row}</g>'
    bg = f'<rect width="1024" height="1024"{" rx=\"230\"" if rounded else ""} fill="{CHAR}"/>'
    return bg + place(body, (0, -26, bb[2], ry + 104 * s), 1024, 1024, 2.3)
BEAM_V = {'dark': (CYAN, CYAN, CORAL, CHAR, WHITE), 'light': (CHAR, CHAR, CHAR, WHITE, CHAR)}   # N, X over, X under, the 18's digits, BEAM; on no background
def beam_title(v):
    cN, cXo, cXu, dg, cw = BEAM_V[v]
    body, bb = mark(cN, cXo, cXu, CORAL, dg, True)
    dl, gap = 58, 40                                       # the icon's dashes either side of BEAM
    x0 = bb[2] + 64 + dl + gap
    body += dashes(bb[2] + 64 + dl, -1) + ''.join(g(x0 + i * 96, 0, 1, fn(cw)) for i, fn in enumerate((B_, E_, A_, M_)))
    x1 = x0 + 3 * 96 + 82 + gap
    body += dashes(x1, 1)
    w = x1 + dl + W / 2                                    # W / 2: the last dash's round end
    return place(body, (-W / 2, -26, w + W / 2, 130), round((w + W) * 1.3 + 40), 200, 1.3), round((w + W) * 1.3 + 40)
def svg(w, h, body, title): return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><title>{title}</title>{body}</svg>\n'
def write(n, s): open(os.path.join(OUT, n), 'w').write(s)
if __name__ == '__main__':
    for v in V: write(f'nx18-lockup-{v}.svg', svg(433, 200, lockup(v), f'NX18 ({v})'))
    write('nx18-icon.svg', svg(1024, 1024, icon(), 'NX18 app icon'))
    write('nx18-icon-square.svg', svg(1024, 1024, icon_square(), 'NX18 app icon, full bleed'))
    write('beam-icon.svg', svg(1024, 1024, beam_icon(True), 'NX 18 Beam app icon'))
    write('beam-icon-square.svg', svg(1024, 1024, beam_icon(False), 'NX 18 Beam app icon, full bleed (beam/scripts/make_icons.swift renders the app icon set from it)'))
    for v in BEAM_V: body, tw = beam_title(v); write(f'beam-title-{v}.svg', svg(tw, 200, body, f'NX 18 Beam ({v})'))
