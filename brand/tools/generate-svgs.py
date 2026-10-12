"""Writes the vector brand assets in brand/ (logo, mark, wordmark, icon, menu bar glyphs, mascots,
social card). The SVGs are committed; run this only when changing the geometry or colours:

    python3 brand/tools/generate-svgs.py && scripts/make-icon.sh

The robin is one hand-drawn path (BODY). The wordmark is built from 24-unit round-capped strokes on a
100-unit x-height. The icon tile is Apple's continuous-corner rounded rectangle (824 pt at 100, 100,
radius 185.4), exported from SwiftUI's RoundedRectangle(style: .continuous).
"""
import math, os
OUT=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
INK="#1A1512"; PAPER="#FFF4E8"; CORAL="#FF5A36"
SQ="M924 512L924 640.59C924 722.19 924 763 910.11 806.92C892.66 854.88 854.88 892.66 806.92 910.11C763 924 722.19 924 640.59 924L383.41 924C301.81 924 261 924 217.08 910.11C169.12 892.66 131.34 854.88 113.89 806.92C100 763 100 722.19 100 640.59L100 383.41C100 301.81 100 261 113.89 217.08C131.34 169.12 169.12 131.34 217.08 113.89C261 100 301.81 100 383.41 100L640.59 100C722.19 100 763 100 806.92 113.89C854.88 131.34 892.66 169.12 910.11 217.08C924 261 924 301.81 924 383.41Z"
BODY="M204 70C196 54 182 45 164 45C144 45 130 55 120 67C96 88 50 128 22 166Q15 177 28 181L72 177C86 201 108 213 132 213C176 213 206 182 210 140C212 120 210 106 205 98L230.5 88.6Q236 86.4 230.6 84.2Z"
BODY_NOBEAK="M204 70C196 54 182 45 164 45C144 45 130 55 120 67C96 88 50 128 22 166Q15 177 28 181L72 177C86 201 108 213 132 213C176 213 206 182 210 140C212 120 210 106 205 98Z"
DOT=(146,149,40); EYE=(177,80,8)
def circ(cx,cy,r): return f"M{cx-r} {cy}a{r} {r} 0 1 0 {2*r} 0a{r} {r} 0 1 0 {-2*r} 0Z"
def w(name, s): open(os.path.join(OUT,name),"w").write(s.strip()+"\n")
HDR='<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}"{extra}>'

# ---- wordmark (geometric monoline, built from 24-unit strokes; baseline y=0, x-height 100)
Wst=24; R=38; h=12
def P(x,y): return f"{x:g} {y:g}".replace(".0 "," ")
def fmt(v): return f"{v:.1f}".rstrip("0").rstrip(".")
def pt(x,y): return f"{fmt(x)} {fmt(y)}"
def arcpt(cx,cy,r,deg): a=math.radians(deg); return (cx+r*math.cos(a), cy+r*math.sin(a))
dots=[]
def r_(x0):
    sx=x0+h; cx=sx+R; e=arcpt(cx,-50,R,-60)
    return f"M{pt(sx,-88)}V-12M{pt(sx,-50)}A{R} {R} 0 0 1 {pt(*e)}", e[0]+h
def e_(x0):
    cx=x0+h+R; e=arcpt(cx,-50,R,42)
    return f"M{pt(cx-R,-50)}H{fmt(cx+R)}A{R} {R} 0 1 0 {pt(*e)}", cx+R+h
def l_(x0):
    sx=x0+h; return f"M{pt(sx,-136)}V-12", sx+h
def b_(x0):
    sx=x0+h
    return f"M{pt(sx,-136)}V-12M{pt(sx,-50)}A{R} {R} 0 1 1 {pt(sx+2*R,-50)}A{R} {R} 0 1 1 {pt(sx,-50)}", sx+2*R+h
def i_(x0):
    sx=x0+h; dots.append((sx,-124)); return f"M{pt(sx,-88)}V-12", sx+h
def d_(x0):
    cx=x0+h+R; sx=cx+R
    return f"M{pt(sx,-136)}V-12M{pt(sx,-50)}A{R} {R} 0 1 0 {pt(sx-2*R,-50)}A{R} {R} 0 1 0 {pt(sx,-50)}", sx+h
x=0; parts=[]
for fn,gap in [(r_,0),(e_,6),(e_,14),(l_,16),(b_,20),(i_,18),(r_,18),(d_,5)]:
    x+=gap; s,x=fn(x); parts.append(s)
WW=x; WPATH="".join(parts)
def wordmark_group(ink, accent, tx, ty, k):
    d="".join(f'<circle cx="{fmt(dx)}" cy="{dy}" r="15" fill="{accent}"/>' for dx,dy in dots)
    return (f'<g transform="translate({fmt(tx)} {fmt(ty)}) scale({k})"><path d="{WPATH}" fill="none" stroke="{ink}" stroke-width="{Wst}" stroke-linecap="round" stroke-linejoin="round"/>{d}</g>')

def bird(body, eye, accent=CORAL, beak=True):
    return (f'<path d="{BODY if beak else BODY_NOBEAK}" fill="{body}"/>'
            f'<circle cx="{DOT[0]}" cy="{DOT[1]}" r="{DOT[2]}" fill="{accent}"/>'
            f'<circle cx="{EYE[0]}" cy="{EYE[1]}" r="{EYE[2]}" fill="{eye}"/>')

for suffix, body, eye in [("", INK, PAPER), ("-dark", PAPER, INK)]:
    title = "Reelbird"
    # mark: bird only, square box
    w(f"mark{suffix}.svg", HDR.format(vb="8 13 236 236", extra=' role="img" aria-label="Reelbird"') + f"<title>{title}</title>" + bird(body, eye) + "</svg>")
    # wordmark alone
    w(f"wordmark{suffix}.svg", HDR.format(vb=f"-14 -152 {fmt(WW+28)} 166", extra=' role="img" aria-label="Reelbird"') + f"<title>{title}</title>" + wordmark_group(body, CORAL, 0, 0, 1) + "</svg>")
    # logo lockup: mark + wordmark, wordmark x-height centred on the bird
    k=0.64; tx=270; base=129+0.5*136*k
    vbw = tx + WW*k + 14
    w(f"logo{suffix}.svg", HDR.format(vb=f"8 33 {fmt(vbw-8)} 192", extra=' role="img" aria-label="Reelbird"') + f"<title>{title}</title>" + bird(body, eye) + wordmark_group(body, CORAL, tx, base, k) + "</svg>")

# ---- app icon (1024 canvas, 824 tile, Apple continuous-corner squircle, nothing outside the tile)
ICON=f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<title>Reelbird app icon</title>
<defs>
<linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#221D1A"/><stop offset="1" stop-color="#0E0B0A"/></linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.28" r="0.7"><stop offset="0" stop-color="#FF8A5C" stop-opacity="0.08"/><stop offset="1" stop-color="#FF8A5C" stop-opacity="0"/></radialGradient>
<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="0.3" stop-color="#FFFFFF" stop-opacity="0.03"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.07"/></linearGradient>
<linearGradient id="cream" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFF9F0"/><stop offset="1" stop-color="#F3E0C8"/></linearGradient>
<radialGradient id="coral" cx="0.36" cy="0.3" r="0.8"><stop offset="0" stop-color="#FF8256"/><stop offset="0.6" stop-color="#FF5A36"/><stop offset="1" stop-color="#E5432B"/></radialGradient>
<filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="10"/></filter>
<filter id="tight" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="2.5"/></filter>
<clipPath id="shape"><path d="{SQ}"/></clipPath>
</defs>
<path d="{SQ}" fill="url(#tile)"/>
<path d="{SQ}" fill="url(#glow)"/>
<g clip-path="url(#shape)">
<g transform="translate(136 130) scale(2.95)">
<path d="{BODY}" fill="#000" opacity="0.42" transform="translate(0 7)" filter="url(#soft)"/>
<path d="{BODY}" fill="url(#cream)"/>
<circle cx="146" cy="151" r="40" fill="#7A2A14" opacity="0.3" filter="url(#tight)"/>
<circle cx="146" cy="149" r="40" fill="url(#coral)"/>
<circle cx="177" cy="80" r="8" fill="{INK}"/>
<circle cx="179.6" cy="77.4" r="2.4" fill="{PAPER}"/>
</g>
</g>
<path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="3" clip-path="url(#shape)"/>
</svg>'''
w("icon.svg", ICON)

# ---- menu bar template glyphs (black + alpha; the app sets isTemplate = true)
w("menubar.svg", f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="10 13 232 232"><path fill-rule="evenodd" fill="#000" d="{BODY}{circ(146,149,40)}{circ(177,80,9)}"/></svg>')
w("menubar-recording.svg", f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="10 13 232 232"><path fill-rule="evenodd" fill="#000" d="{BODY}{circ(146,149,48)}{circ(177,80,9)}"/><circle cx="146" cy="149" r="32" fill="#000"/></svg>')

# ---- mascots (256 box). Light = ink bird for light UI; -dark = paper bird for dark UI.
LEGS='<path d="M118 211L112 238M146 211L150 238" fill="none" stroke="{c}" stroke-width="7" stroke-linecap="round"/>'
def mascot_idle(body, eye):
    return bird(body, eye) + LEGS.format(c=body)
def mascot_recording(body, eye):
    ring=f'<circle cx="146" cy="149" r="51" fill="none" stroke="{CORAL}" stroke-width="5"/>'
    return bird(body, eye) + ring + LEGS.format(c=body)
def mascot_celebrating(body, eye):
    wing=f'<path d="M124 94C108 66 88 42 62 26C55 22 49 27 51 34C53 41 56 47 60 52C55 53 53 57 56 61C62 70 69 78 76 85C71 87 70 92 74 96C82 104 91 112 100 118Z" fill="{body}"/>'
    beaks=(f'<path d="M203 70L233 70.5Q238 71.5 233.5 75L205 86Z" fill="{body}"/>'
           f'<path d="M205 91L228 102Q231.5 104.5 227 105L205 99Z" fill="{body}"/>')
    eye_=f'<path d="M169 84Q177 74 185 84" fill="none" stroke="{eye}" stroke-width="5" stroke-linecap="round"/>'
    legs=f'<path d="M116 210L104 228M144 211L136 230" fill="none" stroke="{body}" stroke-width="7" stroke-linecap="round"/>'
    sparks=(f'<path d="M222 34L230 20M240 52L254 46M206 26L206 12" fill="none" stroke="{CORAL}" stroke-width="6" stroke-linecap="round"/>')
    g=(f'<g transform="rotate(-8 128 140) translate(0 -10)">{wing}<path d="{BODY_NOBEAK}" fill="{body}"/>{beaks}'
       f'<circle cx="146" cy="149" r="40" fill="{CORAL}"/>{eye_}{legs}</g>')
    return g + sparks
def mascot_sleeping(body, eye):
    eye_=f'<path d="M169 80Q177 88 185 80" fill="none" stroke="{eye}" stroke-width="5" stroke-linecap="round"/>'
    dot=f'<circle cx="146" cy="149" r="37" fill="none" stroke="{CORAL}" stroke-width="6"/>'
    return f'<g transform="translate(0 18)"><path d="{BODY}" fill="{body}"/>{dot}{eye_}</g>'
for name, fn in [("idle",mascot_idle),("recording",mascot_recording),("celebrating",mascot_celebrating),("sleeping",mascot_sleeping)]:
    for suffix, body, eye in [("", INK, PAPER), ("-dark", PAPER, INK)]:
        w(f"mascot-{name}{suffix}.svg", HDR.format(vb="0 0 256 256", extra='') + fn(body, eye) + "</svg>")

# ---- social preview 1280x640: dark lockup centred on ink
k=0.64; tx=270; base=129+0.5*136*k
lw = tx + WW*k + 14 - 8; lh = 192
S = 820/lw
ox = (1280 - lw*S)/2 - 8*S; oy = (640 - lh*S)/2 - 33*S
w("social-preview.svg", f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640">
<defs><radialGradient id="g" cx="0.5" cy="0.4" r="0.75"><stop offset="0" stop-color="#26201C"/><stop offset="1" stop-color="{INK}"/></radialGradient></defs>
<rect width="1280" height="640" fill="url(#g)"/>
<g transform="translate({fmt(ox)} {fmt(oy)}) scale({S:.4f})">{bird(PAPER, INK)}{wordmark_group(PAPER, CORAL, tx, base, k)}</g>
</svg>''')
