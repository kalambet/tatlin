import math

S = 1024  # canvas
def lerp(a,b,t): return a+(b-a)*t

# --- Tatlin's Tower: leaning double-helix on a tilted axis, tapering upward ---
# Axis: base bottom-left-ish, top leaning up-right.
bx, by = S*0.34, S*0.86      # base center
tx, ty = S*0.58, S*0.16      # apex center
turns  = 2.6
r0     = S*0.20              # base radius
taper  = 0.78               # how much radius shrinks at top
N      = 240

def axis(t): return lerp(bx,tx,t), lerp(by,ty,t)
def radius(t): return r0*(1-taper*t)

# axis direction & perpendicular (for offsetting the helix horizontally)
dx, dy = tx-bx, ty-by
L = math.hypot(dx,dy)
ux, uy = dx/L, dy/L          # along axis
px, py = -uy, ux             # perpendicular

def helix_point(t, phase):
    cx, cy = axis(t)
    r = radius(t)
    ang = 2*math.pi*turns*t + phase
    # horizontal swing along perpendicular; vertical "depth" squashed for 3D feel
    off = math.cos(ang)*r
    depth = math.sin(ang)*r*0.35
    return cx + px*off, cy + py*off - depth

def path(phase):
    pts=[helix_point(i/N, phase) for i in range(N+1)]
    d="M %.2f %.2f "%pts[0]+ " ".join("L %.2f %.2f"%p for p in pts[1:])
    return d

helixA = path(0)
helixB = path(math.pi)
# central leaning mast
mx0,my0 = axis(0); mx1,my1 = axis(1)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1b2a4a"/>
      <stop offset="1" stop-color="#0c1326"/>
    </linearGradient>
  </defs>
  <rect width="{S}" height="{S}" rx="{S*0.22}" fill="url(#bg)"/>
  <g fill="none" stroke-linecap="round" stroke-linejoin="round">
    <line x1="{mx0:.1f}" y1="{my0:.1f}" x2="{mx1:.1f}" y2="{my1:.1f}" stroke="#3a4a6b" stroke-width="10"/>
    <path d="{helixA}" stroke="#e8b84b" stroke-width="22"/>
    <path d="{helixB}" stroke="#f4f1e8" stroke-width="22"/>
  </g>
</svg>'''
open("icon.svg","w").write(svg)
print("wrote icon.svg")
