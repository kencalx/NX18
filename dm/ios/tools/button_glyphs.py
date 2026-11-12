#!/usr/bin/env python3
"""The Switch button glyphs of the controller hints, from SVG to Swift.

Reads the vendored SVGs in dm/ios/Resources/ButtonIcons (Button Icons and Controls by Zacksly, CC BY 3.0; that folder's README.md and LICENSE.txt) and writes
dm/ios/Sources/NXButtonGlyphData.swift: each glyph's outline as absolute move / line / cubic / close steps in the SVG's units, and the box the outline fills, so the apps draw
it as a SwiftUI shape in any colour and at any size (NXButtonGlyph.swift) with no image files, asset catalog or SVG reader at run time. The SVG files are the source: change
one, run this, and commit both. --check (the test dm/ios/tests/test_button_icons.py) fails when the Swift file is not what this would write.

Only what these files use is read: <path> (arcs as cubics), <polygon> and <circle> filled with one colour (the recolouring is the apps' tint), no strokes or transforms. Anything else
stops with an error rather than drawing a different glyph.
"""
import argparse
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ICONS = REPO / 'dm/ios/Resources/ButtonIcons'
OUT = REPO / 'dm/ios/Sources/NXButtonGlyphData.swift'
# Swift case name: SVG file name (the pack's "Buttons Full Solid" glyphs)
GLYPHS = {'a': 'A', 'b': 'B', 'x': 'X', 'y': 'Y', 'plus': 'Plus'}
SVG_NS = '{http://www.w3.org/2000/svg}'
NUM = re.compile(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')
TOKEN = re.compile(r'[MmLlHhVvCcSsQqTtAaZz]|' + NUM.pattern)
ARGS = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'S': 4, 'Q': 4, 'T': 2, 'A': 7, 'Z': 0}


class GlyphError(Exception):
    pass


def path_steps(d):
    """An SVG path's data as absolute steps: ('M', x, y), ('L', x, y), ('C', x1, y1, x2, y2, x, y), ('Z',). H / V become lines, S / T their reflected curves, a quadratic a cubic"""
    tokens = TOKEN.findall(d)
    if re.sub(r'[\s,]', '', TOKEN.sub('', d)):
        raise GlyphError(f'unreadable path data: {d[:40]}')
    steps, i, cmd = [], 0, None
    x = y = sx = sy = 0.0
    last_c = last_q = None   # the previous cubic's second control point / the previous quadratic's control point, for S and T
    while i < len(tokens):
        t = tokens[i]
        if t.isalpha():
            cmd = t; i += 1
            if cmd in 'Zz':
                steps.append(('Z',)); x, y = sx, sy; last_c = last_q = None
                continue
        elif cmd is None:
            raise GlyphError('path data starts with a number')
        n = ARGS[cmd.upper()]
        raw = tokens[i:i + n]
        if len(raw) < n or any(v.isalpha() for v in raw):
            raise GlyphError(f'{cmd} needs {n} numbers')
        vals = [float(v) for v in raw]
        i += n
        rel = cmd.islower()
        c = cmd.upper()
        def pt(px, py): return (x + px, y + py) if rel else (px, py)
        if c == 'M':
            x, y = pt(*vals); sx, sy = x, y
            steps.append(('M', x, y)); last_c = last_q = None
            cmd = 'l' if rel else 'L'   # more pairs after a move are lines
        elif c == 'L':
            x, y = pt(*vals); steps.append(('L', x, y)); last_c = last_q = None
        elif c == 'H':
            x = x + vals[0] if rel else vals[0]; steps.append(('L', x, y)); last_c = last_q = None
        elif c == 'V':
            y = y + vals[0] if rel else vals[0]; steps.append(('L', x, y)); last_c = last_q = None
        elif c in 'CS':
            if c == 'C':
                c1 = pt(vals[0], vals[1]); c2 = pt(vals[2], vals[3]); end = pt(vals[4], vals[5])
            else:
                c1 = (2 * x - last_c[0], 2 * y - last_c[1]) if last_c else (x, y)
                c2 = pt(vals[0], vals[1]); end = pt(vals[2], vals[3])
            steps.append(('C', *c1, *c2, *end)); last_c = c2; last_q = None; x, y = end
        elif c in 'QT':
            if c == 'Q':
                q = pt(vals[0], vals[1]); end = pt(vals[2], vals[3])
            else:
                q = (2 * x - last_q[0], 2 * y - last_q[1]) if last_q else (x, y)
                end = pt(vals[0], vals[1])
            c1 = (x + 2 / 3 * (q[0] - x), y + 2 / 3 * (q[1] - y)); c2 = (end[0] + 2 / 3 * (q[0] - end[0]), end[1] + 2 / 3 * (q[1] - end[1]))
            steps.append(('C', *c1, *c2, *end)); last_q = q; last_c = None; x, y = end
        elif c == 'A':
            if vals[3] not in (0, 1) or vals[4] not in (0, 1):
                raise GlyphError('an arc whose flags are not 0 or 1 (flags written without separators are not read here)')
            end = pt(vals[5], vals[6])
            steps += arc_steps((x, y), vals[0], vals[1], vals[2], bool(vals[3]), bool(vals[4]), end)
            last_c = last_q = None; x, y = end
    return steps


def arc_steps(start, rx, ry, rot, large, sweep, end):
    """An SVG elliptical arc as cubics (the SVG spec's endpoint-to-centre conversion, F.6.5, then at most 90 degrees per cubic)"""
    (x1, y1), (x2, y2) = start, end
    if (x1, y1) == (x2, y2): return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0: return [('L', x2, y2)]
    phi = math.radians(rot); cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    xp, yp = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = xp * xp / (rx * rx) + yp * yp / (ry * ry)
    if lam > 1: rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp
    den = rx * rx * yp * yp + ry * ry * xp * xp
    co = math.sqrt(max(0.0, num / den)) * (-1 if large == sweep else 1)
    cxp, cyp = co * rx * yp / ry, -co * ry * xp / rx
    cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2
    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    t1 = ang(1, 0, (xp - cxp) / rx, (yp - cyp) / ry)
    dt = ang((xp - cxp) / rx, (yp - cyp) / ry, (-xp - cxp) / rx, (-yp - cyp) / ry)
    if not sweep and dt > 0: dt -= 2 * math.pi
    elif sweep and dt < 0: dt += 2 * math.pi
    n = max(1, math.ceil(abs(dt) / (math.pi / 2) - 1e-9))
    d = dt / n; k = 4 / 3 * math.tan(d / 4)
    def at(t): return (cx + rx * math.cos(t) * cp - ry * math.sin(t) * sp, cy + rx * math.cos(t) * sp + ry * math.sin(t) * cp)
    def deriv(t): return (-rx * math.sin(t) * cp - ry * math.cos(t) * sp, -rx * math.sin(t) * sp + ry * math.cos(t) * cp)
    out, t = [], t1
    for i in range(n):
        p0, p3 = at(t), at(t + d)
        d0, d3 = deriv(t), deriv(t + d)
        if i == n - 1: p3 = (x2, y2)
        out.append(('C', p0[0] + k * d0[0], p0[1] + k * d0[1], p3[0] - k * d3[0], p3[1] - k * d3[1], *p3))
        t += d
    return out


def polygon_steps(points):
    v = [float(n) for n in NUM.findall(points)]
    if len(v) < 6 or len(v) % 2:
        raise GlyphError('a polygon needs three points or more')
    pts = list(zip(v[::2], v[1::2]))
    return [('M', *pts[0])] + [('L', *p) for p in pts[1:]] + [('Z',)]


def circle_steps(cx, cy, r):
    k = 0.5522847498 * r   # four cubics, the usual circle approximation, drawn clockwise as on screen (y down)
    return [('M', cx + r, cy), ('C', cx + r, cy + k, cx + k, cy + r, cx, cy + r), ('C', cx - k, cy + r, cx - r, cy + k, cx - r, cy),
            ('C', cx - r, cy - k, cx - k, cy - r, cx, cy - r), ('C', cx + k, cy - r, cx + r, cy - k, cx + r, cy), ('Z',)]


def read_svg(path):
    """(view box (x, y, w, h), steps) of one glyph file, its shapes in document order"""
    root = ET.parse(path).getroot()
    vb = [float(n) for n in NUM.findall(root.get('viewBox', ''))]
    if len(vb) != 4:
        raise GlyphError(f'{path.name}: no viewBox')
    style = ''.join(s.text or '' for s in root.iter(SVG_NS + 'style'))
    if re.search(r'stroke\s*:\s*(?!none)', style) or 'transform' in ET.tostring(root, encoding='unicode'):
        raise GlyphError(f'{path.name}: strokes or transforms are not read here')
    fills = set(re.findall(r'fill\s*:\s*([^;}]+)', style))
    if len(fills) > 1:
        raise GlyphError(f'{path.name}: more than one fill colour ({", ".join(sorted(fills))}); a glyph is one colour, tinted by the app')
    steps = []
    for el in root.iter():
        tag = el.tag.replace(SVG_NS, '')
        if el.get('stroke') not in (None, 'none') or el.get('fill-rule') == 'evenodd' or el.get('transform'):
            raise GlyphError(f'{path.name}: <{tag}> has a stroke, an even-odd fill or a transform')
        if tag == 'path': steps += path_steps(el.get('d', ''))
        elif tag == 'polygon': steps += polygon_steps(el.get('points', ''))
        elif tag == 'circle': steps += circle_steps(float(el.get('cx', 0)), float(el.get('cy', 0)), float(el.get('r', 0)))
        elif tag in ('rect', 'ellipse', 'line', 'polyline', 'image', 'text', 'use'):
            raise GlyphError(f'{path.name}: <{tag}> is not read here')
    if not steps:
        raise GlyphError(f'{path.name}: no shapes')
    return vb, steps


def fmt(v):
    s = f'{round(v, 3):.3f}'.rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def swift():
    lines = [
        '// Generated by dm/ios/tools/button_glyphs.py from dm/ios/Resources/ButtonIcons/*.svg: do not edit; change the SVG and run the script.',
        '// Button Icons and Controls by Zacksly (CC BY 3.0 Licensed | zacksly.itch.io), modified: recoloured (drawn in NX 18\'s colours, NXButtonGlyph.swift).',
        '// The licence is dm/ios/Resources/ButtonIcons/LICENSE.txt. Each outline: ops M (move), L (line), C (cubic), Z (close), one letter per step; pts the numbers they take',
        '// in order, in the SVG\'s units (y down); box the outline\'s extent (its points and control points), which the shape fills. Filled with the non-zero rule, as an SVG is.',
        'import CoreGraphics',
        '',
        'struct NXButtonGlyphOutline: Sendable {',
        '    let box: CGRect',
        '    let ops: String',
        '    let pts: [CGFloat]',
        '}',
        '',
        'enum NXButtonGlyphData {',
    ]
    for case, name in GLYPHS.items():
        _, steps = read_svg(ICONS / f'{name}.svg')
        xs = [s[k] for s in steps for k in range(1, len(s), 2)]
        ys = [s[k] for s in steps for k in range(2, len(s), 2)]
        x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
        ops = ''.join(s[0] for s in steps)
        pts = [fmt(v) for s in steps for v in s[1:]]
        lines.append(f'    // {name}.svg')
        lines.append(f'    static let {case} = NXButtonGlyphOutline(box: CGRect(x: {fmt(x0)}, y: {fmt(y0)}, width: {fmt(x1 - x0)}, height: {fmt(y1 - y0)}), ops: "{ops}",')
        body = []
        for i in range(0, len(pts), 16):
            body.append('        ' + ', '.join(pts[i:i + 16]))
        lines.append('        pts: [\n' + ',\n'.join(body) + '])')
    lines.append('}')
    return '\n'.join(lines) + '\n'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--check', action='store_true', help='fail when the Swift file is not what the SVGs give (changes nothing)')
    a = ap.parse_args(argv)
    try:
        text = swift()
    except (GlyphError, OSError, ET.ParseError) as e:
        print(f'button_glyphs: {e}', file=sys.stderr)
        return 2
    if a.check:
        if not OUT.is_file() or OUT.read_text() != text:
            print(f'button_glyphs: {OUT.relative_to(REPO)} is out of date: run python3 dm/ios/tools/button_glyphs.py', file=sys.stderr)
            return 1
        return 0
    OUT.write_text(text)
    print(f'button_glyphs: wrote {OUT.relative_to(REPO)} ({len(GLYPHS)} glyphs)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
