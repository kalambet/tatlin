import math
S=1024
def lerp(a,b,t): return a+(b-a)*t

# Leaning cone axis (Tatlin leans ~23deg). Base lower-left, apex upper-right.
bx,by=S*0.30,S*0.84
tx,ty=S*0.66,S*0.18
turns=3.0; r0=S*0.215; taper=0.82; N=300
dx,dy=tx-bx,ty-by; L=math.hypot(dx,dy)
ux,uy=dx/L,dy/L; px,py=-uy,ux
def axis(t): return lerp(bx,tx,t),lerp(by,ty,t)
def rad(t): return r0*(1-taper*t)
def hp(t,ph):
    cx,cy=axis(t); r=rad(t); a=2*math.pi*turns*t+ph
    return cx+px*math.cos(a)*r, cy+py*math.cos(a)*r - math.sin(a)*r*0.34
def path(ph,n=N):
    p=[hp(i/n,ph) for i in range(n+1)]
    return "M %.2f %.2f "%p[0]+" ".join("L %.2f %.2f"%q for q in p[1:])

# external leaning gantry arc: a great diagonal sweep on the lean side
gx0,gy0=axis(0); gx1,gy1=axis(1)
# control point flung out perpendicular for a bowed girder
cxp,cyp=lerp(bx,tx,0.5)+px*r0*1.7, lerp(by,ty,0.5)+py*r0*1.7
arc=f"M {gx0:.1f} {gy0:.1f} Q {cxp:.1f} {cyp:.1f} {gx1:.1f} {gy1:.1f}"

svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
<defs><linearGradient id="bg" x1="0" y1="0" x2="0.3" y2="1">
<stop offset="0" stop-color="#1d2c4d"/><stop offset="1" stop-color="#0b1224"/></linearGradient></defs>
<rect width="{S}" height="{S}" rx="{S*0.22}" fill="url(#bg)"/>
<g fill="none" stroke-linecap="round" stroke-linejoin="round">
  <path d="{arc}" stroke="#5a6c92" stroke-width="14"/>
  <line x1="{gx0:.1f}" y1="{gy0:.1f}" x2="{gx1:.1f}" y2="{gy1:.1f}" stroke="#3a4a6b" stroke-width="12"/>
  <path d="{path(0)}" stroke="#e8b84b" stroke-width="26"/>
  <path d="{path(math.pi)}" stroke="#f4f1e8" stroke-width="18"/>
</g></svg>'''
open("icon2.svg","w").write(svg); print("ok")
