import math
S=1024
def lerp(a,b,t): return a+(b-a)*t
bx,by=S*0.33,S*0.82
tx,ty=S*0.63,S*0.20
turns=1.5; r0=S*0.20; taper=0.74; N=14   # few bays -> reads as truss
dx,dy=tx-bx,ty-by; L=math.hypot(dx,dy)
ux,uy=dx/L,dy/L; px,py=-uy,ux
def axis(t): return lerp(bx,tx,t),lerp(by,ty,t)
def rad(t): return r0*(1-taper*t)
def hp(t,ph):
    cx,cy=axis(t); r=rad(t); a=2*math.pi*turns*t+ph
    return (cx+px*math.cos(a)*r, cy+py*math.cos(a)*r - math.sin(a)*r*0.30)
A=[hp(i/N,0) for i in range(N+1)]
B=[hp(i/N,math.pi) for i in range(N+1)]
RED="#cf2e22"; INK="#1a1410"
def poly(P,w,col):
    d="M %.2f %.2f "%P[0]+" ".join("L %.2f %.2f"%q for q in P[1:])
    return f'<path d="{d}" stroke="{col}" stroke-width="{w}"/>'
seg=[]
def line(p,q,w,col,op=1): seg.append(f'<line x1="{p[0]:.1f}" y1="{p[1]:.1f}" x2="{q[0]:.1f}" y2="{q[1]:.1f}" stroke="{col}" stroke-width="{w}" stroke-opacity="{op}"/>')
# triangulated bays: rung + one diagonal per bay
for i in range(N):
    line(A[i],B[i],6,INK,0.7)             # rung
    line(B[i],A[i+1],5,INK,0.5)           # diagonal brace
line(A[N],B[N],6,INK,0.7)
gx0,gy0=axis(0); gx1,gy1=axis(1)
cxp,cyp=lerp(bx,tx,0.5)+px*r0*1.7, lerp(by,ty,0.5)+py*r0*1.7
gantry=f'<path d="M {gx0:.1f} {gy0:.1f} Q {cxp:.1f} {cyp:.1f} {gx1:.1f} {gy1:.1f}" stroke="{INK}" stroke-width="13"/>'
base=f'<line x1="{bx-r0*1.1:.1f}" y1="{by+10:.1f}" x2="{bx+r0*1.3:.1f}" y2="{by+10:.1f}" stroke="{INK}" stroke-width="15"/>'
rails=poly(A,18,RED)+poly(B,18,RED)
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
<rect width="{S}" height="{S}" rx="{S*0.22}" fill="#ece2cf"/>
<g fill="none" stroke-linecap="round" stroke-linejoin="round">
{gantry}{"".join(seg)}{base}{rails}
</g></svg>'''
open("icon4.svg","w").write(svg); print("ok")
