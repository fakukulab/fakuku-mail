"""(예전 아이콘: 봉투+클립. 지금 아이콘은 tools/icon_fakuku.py.) Draws the old FAKUKU Mail icon layers as filled SVG shapes.
Needs: pip install shapely
Usage (the values in the current icon):
  python3 tools/icon_layers.py Icon/AppIcon.icon/Assets \
    '{"wire":66,"gap":46,"scale":0.6,"angle":-30,"cx":640,"cy":430,"ex":220,"ey":420,"ew":470,"eh":340,"flap":60,"lift":10}'
Then run tools/make_icon.sh and tools/icon_review.sh on a Mac.
"""
import math, sys, json
from shapely.geometry import LineString, Polygon, box
from shapely import affinity
from shapely.ops import unary_union

OUT = sys.argv[1]
P = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
wire = P.get("wire", 46)
gap = P.get("gap", 40)
scale = P.get("scale", 0.92)
angle = P.get("angle", -32)
cx, cy = P.get("cx", 690), P.get("cy", 400)

def arc(c, r, a0, a1, n=48):
    return [(c[0] + r*math.cos(math.radians(a0 + (a1-a0)*i/n)), c[1] + r*math.sin(math.radians(a0 + (a1-a0)*i/n))) for i in range(n+1)]

# Gem paperclip centerline, columns A<B<C<D, y grows downward
s = wire + gap
A, B, C, D = -1.5*s, -0.5*s, 0.5*s, 1.5*s
pts = [(B, -110), (B, 170)]
pts += arc((0, 170), s/2, 180, 0)[1:]           # small bottom turn B -> C (through bottom)
pts += [(C, -200)]
pts += arc(((A+C)/2, -200), (C-A)/2, 0, -180)[1:]  # top turn C -> A (through top)
pts += [(A, 240)]
pts += arc((0, 240), D, 180, 0)[1:]              # big bottom turn A -> D
pts += [(D, -90)]
clip = LineString(pts).buffer(wire/2, cap_style="round", join_style="round", quad_segs=24)
clip = affinity.rotate(clip, angle, origin=(0, 0))
clip = affinity.scale(clip, scale, scale, origin=(0, 0))
clip = affinity.translate(clip, cx, cy)

def path_d(geom):
    polys = geom.geoms if hasattr(geom, "geoms") else [geom]
    out = []
    for p in polys:
        for ring in [p.exterior, *p.interiors]:
            c = list(ring.coords)
            out.append("M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in c) + " Z")
    return " ".join(out)

def svg(d):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n  <path fill="#FFFFFF" fill-rule="evenodd" d="{d}"/>\n</svg>\n'

ex, ey, ew, eh, er = P.get("ex", 212), P.get("ey", 372), P.get("ew", 560), P.get("eh", 392), 64
env_body = f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n  <rect x="{ex}" y="{ey}" width="{ew}" height="{eh}" rx="{er}" fill="#FFFFFF"/>\n</svg>\n'
# flap: a filled chevron band from the top corners down to the middle
t = P.get("flap", 56)
l, r, top = ex + 40, ex + ew - 40, ey + 34
mid = ey + eh * 0.56
flap = Polygon([(l, top), (ex + ew/2, mid), (r, top), (r, top + t), (ex + ew/2, mid + t*1.15), (l, top + t)])
flap = flap.buffer(10, join_style="round").buffer(-10, join_style="round")
open(f"{OUT}/front.svg", "w").write(svg(path_d(clip)))
open(f"{OUT}/middle.svg", "w").write(svg(path_d(flap)))
open(f"{OUT}/back.svg", "w").write(env_body)
b = unary_union([clip, box(ex, ey, ex+ew, ey+eh)]).bounds
dx, dy = 512 - (b[0]+b[2])/2, 512 - (b[1]+b[3])/2 + P.get("lift", 0)
clip = affinity.translate(clip, dx, dy); flap = affinity.translate(flap, dx, dy); ex += dx; ey += dy
open(f"{OUT}/front.svg", "w").write(svg(path_d(clip)))
open(f"{OUT}/middle.svg", "w").write(svg(path_d(flap)))
open(f"{OUT}/back.svg", "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n  <rect x="{ex:.1f}" y="{ey:.1f}" width="{ew}" height="{eh}" rx="{er}" fill="#FFFFFF"/>\n</svg>\n')
b = unary_union([clip, box(ex, ey, ex+ew, ey+eh)]).bounds
print("glyph bounds", [round(v) for v in b], "width %", round((b[2]-b[0])/10.24), "height %", round((b[3]-b[1])/10.24))
