"""Canonical parametric generator for the Tatlin app icon.

Tatlin's *Monument to the Third International* rendered as a leaning double-helix
truss cone. This module supersedes the gen*.py sketches (kept only for history).

Emits per-slot variants the asset catalog needs:
  - shape="square"   full-bleed (iOS masks its own corners)
  - shape="squircle" baked Apple superellipse + margin (macOS is not masked)
  - palettes: light (approved icon5), dark, tinted (grayscale on transparent)
And a separate simplified monochrome glyph for the menu bar (template image).

Usage:  python3 tower.py            # writes all SVG variants next to this file
        python3 tower.py <out_dir>  # writes them into <out_dir>
"""
import math, sys, os

S = 1024

# ---- palettes -------------------------------------------------------------
LIGHT  = dict(bg="#ece2cf", bg2=None,       rail="#cf2e22", ink="#1a1410", strut="#1a1410", strut_op=0.55, bg_alpha=1)
DARK   = dict(bg="#1d2c4d", bg2="#0b1224",  rail="#e0392b", ink="#ece2cf", strut="#ece2cf", strut_op=0.40, bg_alpha=1)
# tinted: iOS renders a grayscale source and applies a system tint; transparent ground.
TINTED = dict(bg=None,      bg2=None,       rail="#ffffff", ink="#bdbdbd", strut="#bdbdbd", strut_op=0.55, bg_alpha=0)


def _lerp(a, b, t): return a + (b - a) * t


def _superellipse(cx, cy, rx, ry, n=5.0, steps=180):
    """Apple-style continuous-corner squircle as a closed path."""
    pts = []
    for i in range(steps + 1):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + rx * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = cy + ry * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((x, y))
    return "M %.2f %.2f " % pts[0] + " ".join("L %.2f %.2f" % p for p in pts[1:]) + " Z"


def tower_svg(palette, shape="square"):
    # geometry — identical to the approved icon5 master
    bx, by = S * 0.34, S * 0.80
    tx, ty = S * 0.62, S * 0.21
    turns, r0, taper = 1.5, S * 0.195, 0.74
    dx, dy = tx - bx, ty - by
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    px, py = -uy, ux

    def axis(t): return _lerp(bx, tx, t), _lerp(by, ty, t)
    def rad(t):  return r0 * (1 - taper * t)

    def hp(t, ph):
        cx, cy = axis(t); r = rad(t); a = 2 * math.pi * turns * t + ph
        return (cx + px * math.cos(a) * r,
                cy + py * math.cos(a) * r - math.sin(a) * r * 0.30)

    def smooth(ph, n=160):
        P = [hp(i / n, ph) for i in range(n + 1)]
        return "M %.2f %.2f " % P[0] + " ".join("L %.2f %.2f" % q for q in P[1:])

    Nt = 11
    A = [hp(i / Nt, 0) for i in range(Nt + 1)]
    B = [hp(i / Nt, math.pi) for i in range(Nt + 1)]
    ink, strut, op = palette["ink"], palette["strut"], palette["strut_op"]

    seg = []
    def line(p, q, w, o):
        seg.append(f'<line x1="{p[0]:.1f}" y1="{p[1]:.1f}" x2="{q[0]:.1f}" y2="{q[1]:.1f}" '
                   f'stroke="{strut}" stroke-width="{w}" stroke-opacity="{o}"/>')
    for i in range(Nt):
        line(A[i], B[i], 5, op); line(B[i], A[i + 1], 4, op * 0.7)
    line(A[Nt], B[Nt], 5, op)

    gx0, gy0 = axis(0); gx1, gy1 = axis(1)
    cxp, cyp = _lerp(bx, tx, 0.5) + px * r0 * 1.7, _lerp(by, ty, 0.5) + py * r0 * 1.7
    gantry = (f'<path d="M {gx0:.1f} {gy0:.1f} Q {cxp:.1f} {cyp:.1f} {gx1:.1f} {gy1:.1f}" '
              f'stroke="{ink}" stroke-width="13"/>')
    base = (f'<line x1="{bx - r0:.1f}" y1="{by + 12:.1f}" x2="{bx + r0 * 1.25:.1f}" y2="{by + 12:.1f}" '
            f'stroke="{ink}" stroke-width="15"/>')
    rails = (f'<path d="{smooth(0)}" stroke="{palette["rail"]}" stroke-width="19"/>'
             f'<path d="{smooth(math.pi)}" stroke="{palette["rail"]}" stroke-width="19"/>')
    tower = "".join(seg) + base + gantry + rails

    # ---- background + clipping per shape --------------------------------
    defs, bg, clip_open, clip_close = "", "", "", ""
    if palette["bg2"]:
        defs = (f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0.3" y2="1">'
                f'<stop offset="0" stop-color="{palette["bg"]}"/>'
                f'<stop offset="1" stop-color="{palette["bg2"]}"/></linearGradient></defs>')
        fill = "url(#bg)"
    else:
        fill = palette["bg"] or "none"

    if shape == "square":
        if palette["bg_alpha"]:
            bg = f'<rect width="{S}" height="{S}" fill="{fill}"/>'
    elif shape == "squircle":
        # Apple macOS grid: content box ~824 on 1024, continuous corners.
        m = S * 0.0977
        box = S - 2 * m
        path = _superellipse(S / 2, S / 2, box / 2, box / 2)
        defs += f'<clipPath id="sq"><path d="{path}"/></clipPath>'
        if palette["bg_alpha"]:
            bg = f'<path d="{path}" fill="{fill}"/>'
        clip_open = '<g clip-path="url(#sq)">'
        clip_close = '</g>'

    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
            f'viewBox="0 0 {S} {S}">{defs}{bg}'
            f'<g fill="none" stroke-linecap="round" stroke-linejoin="round">'
            f'{clip_open}{tower}{clip_close}</g></svg>')


def menubar_svg(state="idle"):
    """Simplified monochrome glyph for the menu bar (template image, ~18pt).

    The detailed lattice mushes below ~32pt, so the menu bar gets a reduced
    single-spiral silhouette. Pure black on transparent -> macOS tints it.
    `recording` adds a filled record dot.
    """
    V = 36
    bx, by = V * 0.36, V * 0.84
    tx, ty = V * 0.60, V * 0.16
    turns, r0, taper = 1.5, V * 0.20, 0.72
    dx, dy = tx - bx, ty - by
    L = math.hypot(dx, dy); ux, uy = dx / L, dy / L; px, py = -uy, ux

    def axis(t): return _lerp(bx, tx, t), _lerp(by, ty, t)
    def rad(t):  return r0 * (1 - taper * t)
    def hp(t, ph):
        cx, cy = axis(t); r = rad(t); a = 2 * math.pi * turns * t + ph
        return (cx + px * math.cos(a) * r,
                cy + py * math.cos(a) * r - math.sin(a) * r * 0.30)
    def smooth(ph, n=120):
        P = [hp(i / n, ph) for i in range(n + 1)]
        return "M %.2f %.2f " % P[0] + " ".join("L %.2f %.2f" % q for q in P[1:])

    gx0, gy0 = axis(0); gx1, gy1 = axis(1)
    cxp, cyp = _lerp(bx, tx, 0.5) + px * r0 * 1.7, _lerp(by, ty, 0.5) + py * r0 * 1.7
    body = (f'<path d="M {gx0:.1f} {gy0:.1f} Q {cxp:.1f} {cyp:.1f} {gx1:.1f} {gy1:.1f}" '
            f'stroke="#000" stroke-width="2.2"/>'
            f'<line x1="{bx - r0:.2f}" y1="{by + 0.4:.2f}" x2="{bx + r0:.2f}" y2="{by + 0.4:.2f}" '
            f'stroke="#000" stroke-width="2.6"/>'
            f'<path d="{smooth(0)}" stroke="#000" stroke-width="3.1"/>')
    dot = ''
    if state == "recording":
        dot = f'<circle cx="{V*0.80:.1f}" cy="{V*0.80:.1f}" r="{V*0.13:.1f}" fill="#000"/>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{V}" height="{V}" '
            f'viewBox="0 0 {V} {V}"><g fill="none" stroke-linecap="round" '
            f'stroke-linejoin="round">{body}</g>{dot}</svg>')


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    os.makedirs(out, exist_ok=True)
    variants = {
        "tower-mac.svg":      tower_svg(LIGHT, "squircle"),
        "tower-ios.svg":      tower_svg(LIGHT, "square"),
        "tower-ios-dark.svg": tower_svg(DARK,  "square"),
        "tower-ios-tinted.svg": tower_svg(TINTED, "square"),
        "menubar-idle.svg":      menubar_svg("idle"),
        "menubar-recording.svg": menubar_svg("recording"),
    }
    for name, svg in variants.items():
        open(os.path.join(out, name), "w").write(svg)
    print("wrote:", ", ".join(variants))
