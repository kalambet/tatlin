import math
S=1024
def lerp(a,b,t): return a+(b-a)*t

# Leaning truss cone — Monument to the Third International
bx,by=S*0.32,S*0.83
tx,ty=S*0.64,S*0.19
turns=2.0; r0=S*0.215; taper=0.80; N=64
dx,dy=tx-bx,ty-by; L=math.hypot(dx,dy)
ux,uy=dx/L,dy/L; px,py=-uy,ux
def axis(t): return lerp(bx,tx,t),lerp(by,ty,t)
def rad(t): return r0*(1-taper*t)
def hp(t,ph):
    cx,cy=axis(t); r=rad(t); a=2*math.pi*turns*t+ph
    return (cx+px*math.cos(a)*r, cy+py*math.cos(a)*r - math.sin(a)*r*0.36)

A=[hp(i/N,0) for i in range(N+1)]
B=[hp(i/N,math.pi) for i in range(N+1)]

def poly(P,w,col,op=1):
    d="M %.2f %.2f "%P[0]+" ".join("L %.2f %.2f"%q for q in P[1:])
    return f'<path d="{d}" stroke="{col}" stroke-width="{w}" stroke-opacity="{op}"/>'

L_=[]
RED="#d2342a"; INK="#1a1410"
# truss cross-members (X bracing) — thin ink
for i in range(N):
    L_.append(f'<line x1="{A[i][0]:.1f}" y1="{A[i][1]:.1f}" x2="{B[i+1][0]:.1f}" y2="{B[i+1][1]:.1f}" stroke="{INK}" stroke-width="3" stroke-opacity="0.55"/>')
    L_.append(f'<line x1="{B[i][0]:.1f}" y1="{B[i][1]:.1f}" x2="{A[i+1][0]:.1f}" y2="{A[i+1][1]:.1f}" stroke="{INK}" stroke-width="3" stroke-opacity="0.55"/>')
# rungs every few
for i in range(0,N+1,2):
    L_.append(f'<line x1="{A[i][0]:.1f}" y1="{A[i][1]:.1f}" x2="{B[i][0]:.1f}" y2="{B[i][1]:.1f}" stroke="{INK}" stroke-width="3" stroke-opacity="0.45"/>')
# external gantry arc
gx0,gy0=axis(0); gx1,gy1=axis(1)
cxp,cyp=lerp(bx,tx,0.5)+px*r0*1.75, lerp(by,ty,0.5)+py*r0*1.75
gantry=f'<path d="M {gx0:.1f} {gy0:.1f} Q {cxp:.1f} {cyp:.1f} {gx1:.1f} {gy1:.1f}" stroke="{INK}" stroke-width="12"/>'
# main rails red
rails=poly(A,16,RED)+poly(B,16,RED)
# base bar
base=f'<line x1="{bx-r0:.1f}" y1="{by+8:.1f}" x2="{bx+r0*1.2:.1f}" y2="{by+8:.1f}" stroke="{INK}" stroke-width="14"/>'

svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
<rect width="{S}" height="{S}" rx="{S*0.22}" fill="#ece2cf"/>
<g fill="none" stroke-linecap="round" stroke-linejoin="round">
{gantry}
{"".join(L_)}
{base}
{rails}
</g></svg>'''
open("icon3.svg","w").write(svg); print("ok")
