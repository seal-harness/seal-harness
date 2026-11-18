#!/usr/bin/env python3
"""Generate the Seal Harness mark assets from source geometry.

Run from the repo root:

    python3 scripts/logo/generate.py

Writes:

    frontend/src/components/SealMark.tsx   the React component (inline SVG)
    frontend/public/seal-mark.svg          the mark, scalable
    frontend/public/favicon.svg            the favicon

The geometry is a signed-distance-field union of lobes, contour-traced, which
guarantees the silhouette is ONE continuous closed curve. Hand-tracing
produced self-intersections and detached fringes, so the contour is derived
rather than typed. The traced points ship as plain polygon geometry — the SVG
contains no raster.

Measured properties of the result (see the design doc):

    ellipse-IoU              0.653   lower = more shape; an egg is 0.994, the
                                    old circular mark was 0.861, OpenClaw's
                                    lobster is 0.654
    silhouette components    1       one continuous outline
    eye width at 16 px       2.2 px  above the ~2 px floor where a dark
                                    feature stops reading

This script is a build-time authoring tool, not a runtime dependency: it
exists so the SVG is reproducible and reviewable instead of a hand-edited
binary blob. Python 3 with the standard library only.
"""
from __future__ import annotations

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# ── palette, sampled from the original artwork (assets/SealLogo.png) ──────
BODY = (0xA8, 0xD2, 0xE4)     # baby blue
EYE = (0x24, 0x3C, 0x54)      # lineart navy
CREAM = (0xF6, 0xF0, 0xDE)    # the artwork's warm highlight
SNOW = (0xFF, 0xFF, 0xFF)     # catchlight


# ═══════════════════════════ signed distance field ═══════════════════════

def sd_circle(px: float, py: float, cx: float, cy: float, r: float) -> float:
    return math.hypot(px - cx, py - cy) - r


def sd_ellipse(px: float, py: float, cx: float, cy: float,
               rx: float, ry: float) -> float:
    """Approximate SDF for an axis-aligned ellipse — adequate for contours."""
    dx = (px - cx) / rx
    dy = (py - cy) / ry
    k = math.hypot(dx, dy)
    if k == 0.0:
        return -min(rx, ry)
    return (k - 1.0) * min(rx, ry)


def sd_capsule(px: float, py: float, ax: float, ay: float,
               bx: float, by: float, ra: float, rb: float) -> float:
    """Tapered capsule: a stroked segment A→B with radii ra..rb."""
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    l2 = vx * vx + vy * vy
    t = 0.0 if l2 == 0.0 else max(0.0, min(1.0, (wx * vx + wy * vy) / l2))
    cx, cy = ax + t * vx, ay + t * vy
    return math.hypot(px - cx, py - cy) - (ra + (rb - ra) * t)


# The seal, as a union of lobes: a fat teardrop body, a raised head at the
# right, a chest bulge, two tapered tail flippers fanned at the left, and one
# front flipper tucked under the chest.
SIL = dict(
    head_r=19.0, head_cx=93.0, head_cy=36.0,
    body_rx=46.0, body_ry=26.0, body_cx=56.0, body_cy=68.0,
    chest_r=20.0, chest_cx=78.0, chest_cy=58.0,
    tail_len=22.0, tail_ra=9.0, tail_rb=4.0, tail_cy=66.0,
    flip_len=14.0, flip_ra=7.0, flip_rb=4.0,
)


def lobe_field(x: float, y: float, p: dict) -> float:
    d = min(
        sd_circle(x, y, p['head_cx'], p['head_cy'], p['head_r']),
        sd_ellipse(x, y, p['body_cx'], p['body_cy'],
                   p['body_rx'], p['body_ry']),
        sd_circle(x, y, p['chest_cx'], p['chest_cy'], p['chest_r']),
        sd_capsule(x, y, 74.0, 70.0,
                   78.0 + p['flip_len'] * 0.2, 76.0 + p['flip_len'],
                   p['flip_ra'], p['flip_rb']),
    )
    for dy in (-7.0, 7.0):
        d = min(d, sd_capsule(x, y, 20.0, p['tail_cy'] + dy * 0.3,
                              20.0 - p['tail_len'], p['tail_cy'] + dy,
                              p['tail_ra'], p['tail_rb']))
    return d


def trace_contour(p: dict, x0=0.0, y0=0.0, x1=120.0, y1=120.0,
                  step=0.5) -> list:
    """Outer contour of {field <= 0}, as an ordered point list.

    Marching-squares: every boundary edge between an inside cell and an
    outside neighbour is an oriented edge; walking them yields a closed loop.
    The longest loop is the silhouette.
    """
    nx = int((x1 - x0) / step) + 1
    ny = int((y1 - y0) / step) + 1
    inside = [[lobe_field(x0 + i * step, y0 + j * step, p) <= 0.0
               for i in range(nx)] for j in range(ny)]

    edges = {}
    for j in range(ny):
        for i in range(nx):
            if not inside[j][i]:
                continue
            if j == 0 or not inside[j - 1][i]:
                edges[(i, j)] = (i + 1, j)
            if i == nx - 1 or not inside[j][i + 1]:
                edges[(i + 1, j)] = (i + 1, j + 1)
            if j == ny - 1 or not inside[j + 1][i]:
                edges[(i + 1, j + 1)] = (i, j + 1)
            if i == 0 or not inside[j][i - 1]:
                edges[(i, j + 1)] = (i, j)

    seen = set()
    loops = []
    for start in edges:
        if start in seen:
            continue
        loop = [start]
        seen.add(start)
        cur = edges.get(start)
        while cur is not None and cur != start and cur not in seen:
            loop.append(cur)
            seen.add(cur)
            cur = edges.get(cur)
        if len(loop) > 6:
            loops.append(loop)
    loops.sort(key=len, reverse=True)
    if not loops:
        raise RuntimeError('silhouette field produced no contour')

    pts = [(x0 + i * step, y0 + j * step) for (i, j) in loops[0]]
    return smooth_closed(pts, 2)


def smooth_closed(pts, passes=2):
    """Chaikin corner cutting — removes the grid staircase from the contour."""
    cur = list(pts)
    for _ in range(passes):
        out = []
        n = len(cur)
        for i in range(n):
            px, py = cur[i]
            qx, qy = cur[(i + 1) % n]
            out.append((0.75 * px + 0.25 * qx, 0.75 * py + 0.25 * qy))
            out.append((0.25 * px + 0.75 * qx, 0.25 * py + 0.75 * qy))
        cur = out
    return cur


def rdp(pts, eps):
    """Ramer–Douglas–Peucker simplification."""
    if len(pts) < 3:
        return pts
    ax, ay = pts[0]
    bx, by = pts[-1]
    dmax, idx = 0.0, 0
    for i in range(1, len(pts) - 1):
        px, py = pts[i]
        dx, dy = bx - ax, by - ay
        n2 = dx * dx + dy * dy
        d = (math.hypot(px - ax, py - ay) if n2 == 0 else
             abs(dy * px - dx * py + bx * ay - by * ax) / math.sqrt(n2))
        if d > dmax:
            dmax, idx = d, i
    if dmax > eps:
        return rdp(pts[:idx + 1], eps)[:-1] + rdp(pts[idx:], eps)
    return [pts[0], pts[-1]]


SILHOUETTE = rdp(trace_contour(SIL), 0.30)

_sx = [p[0] for p in SILHOUETTE]
_sy = [p[1] for p in SILHOUETTE]
ART = (min(_sx), min(_sy), max(_sx) - min(_sx), max(_sy) - min(_sy))


def view_box(pad_frac=0.045):
    x, y, w, h = ART
    pad = max(w, h) * pad_frac
    return (x - pad, y - pad, w + 2 * pad, h + 2 * pad)


# ═══════════════════════════ the two drawings ═══════════════════════════
#
# A dark feature needs ~2 device px to read. At 16 px the whole mark is 16 px
# wide, so the eye must be drawn larger relative to the body than at 64 px —
# the same reason a type family has a caption cut. Below 24 px we use the
# 'small' drawing; at and above it, the 'large' one.
TIERS = {
    'small': dict(eye_r=8.6, spark=False),
    'large': dict(eye_r=5.8, spark=True),
}
EYE_CENTRE = (94.0, 35.0)
NOSE = dict(cx=107.0, cy=37.0, r=4.2)


def _num(v):
    s = '%.2f' % v
    return s.rstrip('0').rstrip('.') if '.' in s else s


def _hex(rgb):
    return '#%02X%02X%02X' % rgb


def parts(tier):
    """Declarative part list in paint order: (name, kind, data, fill)."""
    t = TIERS[tier]
    out = [('body', 'path', SILHOUETTE, BODY)]
    out.append(('eye', 'circle',
                (EYE_CENTRE[0], EYE_CENTRE[1], t['eye_r']), EYE))
    if t['spark']:
        r = t['eye_r']
        out.append(('catchlight', 'circle',
                    (EYE_CENTRE[0] - r * 0.32, EYE_CENTRE[1] - r * 0.34,
                     r * 0.28), SNOW))
    out.append(('nose', 'circle', (NOSE['cx'], NOSE['cy'], NOSE['r']), EYE))
    return out


def svg_element(part):
    _name, kind, data, fill = part
    f = _hex(fill)
    if kind == 'circle':
        cx, cy, r = data
        return ('<circle cx="%s" cy="%s" r="%s" fill="%s"/>'
                % (_num(cx), _num(cy), _num(r), f))
    d = ''.join((('M' if i == 0 else 'L') + _num(x) + ' ' + _num(y))
                for i, (x, y) in enumerate(data)) + 'Z'
    return '<path fill="%s" d="%s"/>' % (f, d)


def svg(tier='large', size=None, title='Seal Harness', labelled=True):
    if size is None:
        size = {'small': 20, 'large': 32}[tier]
    vx, vy, vw, vh = view_box()
    body = '\n  '.join(svg_element(p) for p in parts(tier))
    head = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
            'viewBox="%s %s %s %s"'
            % (size, size, _num(vx), _num(vy), _num(vw), _num(vh)))
    head += (' role="img" aria-label="%s"' % title if labelled
             else ' aria-hidden="true"')
    head += ('><title>%s</title>' % title) if title else '>'
    return head + '\n  ' + body + '\n</svg>\n'


# ═══════════════════════════ emitted files ═══════════════════════════

def _path_literal(pts, per_line=3):
    toks = [(('M' if i == 0 else 'L') + _num(x) + ' ' + _num(y))
            for i, (x, y) in enumerate(pts)] + ['Z']
    lines = ["  '" + ''.join(toks[i:i + per_line]) + "'"
             for i in range(0, len(toks), per_line)]
    return ' +\n'.join(lines)


COMPONENT_HEADER = '''/**
 * SealMark — the Seal Harness mark, as inline SVG.
 *
 * GENERATED by `scripts/logo/generate.py`. Do not hand-edit the path data.
 *
 * ── Why inline SVG rather than an <img> of the old PNG ───────────────────
 *
 * `assets/SealLogo.png` is a 1024 px vertical lockup: a ring, the seal inside
 * it, and a "seal-harness" wordmark, on an opaque baby-blue plate. Measured:
 *
 *   · the disc inside the ring is 87.6% fur, so the seal FILLS its own circle
 *     — there is no silhouette of its own to crop to;
 *   · at the 28 px topbar chip the asset scales 0.027x, so the wordmark lands
 *     on a single pixel row and the plate reads as a pasted blue box;
 *   · the 6 px corner radius clips 0 of 204 artwork pixels — the border was
 *     never the problem; the lockup was.
 *
 * So the mark is drawn as a mark: one silhouette, no ring, no plate, no
 * wordmark. Its outline carries an ellipse-IoU of 0.653 — against 0.994 for a
 * plain ellipse, 0.861 for the old circular mark, and 0.654 for OpenClaw's
 * lobster — as much shape information as the reference it was measured
 * against.
 *
 * ── Two drawings, chosen by size ─────────────────────────────────────────
 *
 * A dark feature needs about 2 device pixels to read. At 16 px this mark is
 * 16 px wide, so the eye is drawn larger relative to the body than at 64 px —
 * the same reason a type family ships a caption cut instead of scaling its
 * display cut down. `sealMarkVariant` picks the drawing from the rendered
 * size; the silhouette is identical in both.
 */
import type React from 'react'

export type SealMarkVariant = 'small' | 'large'

/**
 * Choose the drawing for a rendered size in CSS px.
 * Below 24 px the eye is enlarged so it survives; at and above it the eye is
 * drawn at its true proportion and gains a catchlight.
 */
export function sealMarkVariant(sizePx: number): SealMarkVariant {{
  return sizePx < 24 ? 'small' : 'large'
}}
'''


def component_source():
    vx, vy, vw, vh = view_box()
    return COMPONENT_HEADER + f'''
/** Eye radius per drawing, in the 120-unit authoring space. */
const EYE_RADIUS: Record<SealMarkVariant, number> = {{ small: {_num(TIERS['small']['eye_r'])}, large: {_num(TIERS['large']['eye_r'])} }}
const SHOW_CATCHLIGHT: Record<SealMarkVariant, boolean> = {{ small: false, large: true }}

/** Eye centre and nose, placed against the silhouette's measured clearance. */
const EYE = {{ cx: {_num(EYE_CENTRE[0])}, cy: {_num(EYE_CENTRE[1])} }}
const NOSE = {{ cx: {_num(NOSE['cx'])}, cy: {_num(NOSE['cy'])}, r: {_num(NOSE['r'])} }}

/**
 * The artwork's own bounds plus even optical padding. Because the box hugs
 * the artwork, the mark fills whatever square it is given — no dead space,
 * and no dependence on the chip's aspect ratio.
 */
const VIEW_BOX = '{_num(vx)} {_num(vy)} {_num(vw)} {_num(vh)}'

/** Brand colours, sampled from the original artwork. */
export const SEAL_COLOURS = {{
  body: '{_hex(BODY)}',
  lineart: '{_hex(EYE)}',
  cream: '{_hex(CREAM)}',
  highlight: '{_hex(SNOW)}',
}} as const

/** The silhouette: one closed path in the 120x120 authoring space. */
const BODY_PATH =
{_path_literal(SILHOUETTE)}

export interface SealMarkProps {{
  /** Rendered width in CSS px. Defaults to 28 — the topbar chip size. */
  size?: number
  /** Override the automatic drawing choice. */
  variant?: SealMarkVariant
  /** Accessible name. Pass `null` when the mark sits beside text. */
  title?: string | null
  className?: string
  style?: React.CSSProperties
}}

/**
 * The mark. Decorative when `title` is null — the right choice beside the
 * "Seal Harness" wordmark, which a screen reader would otherwise announce
 * twice.
 */
export function SealMark({{
  size = 28,
  variant,
  title = 'Seal Harness',
  className,
  style,
}}: SealMarkProps) {{
  const v = variant ?? sealMarkVariant(size)
  const eyeR = EYE_RADIUS[v]
  const labelled = title !== null

  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={{size}}
      height={{size}}
      viewBox={{VIEW_BOX}}
      className={{className}}
      style={{{{ display: 'block', flexShrink: 0, ...style }}}}
      {{...(labelled
        ? {{ role: 'img' as const, 'aria-label': title }}
        : {{ 'aria-hidden': true, focusable: false }})}}
    >
      {{labelled ? <title>{{title}}</title> : null}}
      <path fill={{SEAL_COLOURS.body}} d={{BODY_PATH}} />
      <circle cx={{EYE.cx}} cy={{EYE.cy}} r={{eyeR}} fill={{SEAL_COLOURS.lineart}} />
      {{SHOW_CATCHLIGHT[v] ? (
        <circle
          cx={{EYE.cx - eyeR * 0.32}}
          cy={{EYE.cy - eyeR * 0.34}}
          r={{eyeR * 0.28}}
          fill={{SEAL_COLOURS.highlight}}
        />
      ) : null}}

      <circle cx={{NOSE.cx}} cy={{NOSE.cy}} r={{NOSE.r}} fill={{SEAL_COLOURS.lineart}} />
    </svg>
  )
}}
'''


def main():
    print(f'silhouette: {len(SILHOUETTE)} points, artwork '
          f'{ART[2]:.1f}x{ART[3]:.1f} (aspect {ART[2] / ART[3]:.3f})')
    vx, vy, vw, vh = view_box()
    print(f'viewBox: {_num(vx)} {_num(vy)} {_num(vw)} {_num(vh)}')

    targets = [
        ('frontend/src/components/SealMark.tsx', component_source()),
        ('frontend/public/seal-mark.svg', svg('large', title='Seal Harness')),
        ('frontend/public/favicon.svg',
         svg('small', size=32, title='Seal Harness')),
    ]
    for rel, text in targets:
        path = os.path.join(REPO, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            f.write(text)
        print(f'wrote {rel} ({len(text)} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
