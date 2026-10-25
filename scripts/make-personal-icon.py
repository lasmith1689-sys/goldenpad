"""GoldenPad LS icon: a gun-barrel view with a tuxedoed agent and a gold 007.

Original artwork drawn with PIL (no actor likeness, no copy of the official
007 logo). Rendered at 4x and downsampled for clean edges.
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 4096
OUT = sys.argv[1]
cx, cy = S / 2, S * 0.43


def radial_barrel(img):
    """Dark steel barrel: radial gradient plus spiral rifling grooves."""
    px = img.load()
    R = S * 0.47
    for y in range(0, S, 2):
        for x in range(0, S, 2):
            dx, dy = x - cx, y - cy
            r = math.hypot(dx, dy)
            if r > R:
                v = 0
            else:
                t = r / R
                ang = math.atan2(dy, dx)
                # 8 spiral grooves that twist as they move outward
                groove = 0.5 + 0.5 * math.cos(8 * (ang + t * 2.2))
                base = 18 + 70 * (t ** 1.6)
                v = int(base * (0.55 + 0.45 * groove))
                # bright rim highlight near the muzzle edge
                v += int(40 * max(0.0, 1 - abs(t - 0.96) / 0.04))
            col = (v, v, min(255, v + 4))
            px[x, y] = col
            px[x + 1, y] = col
            px[x, y + 1] = col
            px[x + 1, y + 1] = col


def agent(draw, ox, oy, k):
    """Black silhouette of a man in a tuxedo, side-on, aiming a pistol."""
    blk = (8, 8, 10)
    P = lambda pts: [(ox + x * k, oy + y * k) for x, y in pts]
    # legs: wide braced stance, trousers taper to the shoes
    draw.polygon(P([(-60, 110), (5, 110), (-40, 330), (-70, 372), (-150, 372), (-108, 330)]), fill=blk)
    draw.polygon(P([(-5, 110), (62, 110), (110, 330), (165, 372), (85, 372), (50, 330)]), fill=blk)
    # tuxedo jacket: broad shoulders, nipped waist, flared hem
    draw.polygon(P([(-98, -160), (92, -160), (70, 20), (98, 140), (-100, 140), (-72, 20)]), fill=blk)
    draw.ellipse(P([(-118, -196), (112, -120)]), fill=blk)
    # neck, head, and a hint of slicked-back hair at the crown
    draw.rectangle(P([(-24, -222), (24, -170)]), fill=blk)
    draw.ellipse(P([(-58, -335), (54, -205)]), fill=blk)
    draw.ellipse(P([(-44, -350), (64, -282)]), fill=blk)
    # white shirt front between the lapels, and a bow tie
    wht = (235, 235, 238)
    draw.polygon(P([(-34, -158), (34, -158), (0, 30)]), fill=wht)
    draw.polygon(P([(-34, -150), (0, -132), (-34, -114)]), fill=blk)
    draw.polygon(P([(34, -150), (0, -132), (34, -114)]), fill=blk)
    draw.ellipse(P([(-9, -141), (9, -123)]), fill=blk)
    # aiming arm: shoulder to hand, a solid sleeve with a slight downward taper
    draw.polygon(P([(-60, -175), (-80, -102), (-262, -118), (-262, -170)]), fill=blk)
    draw.ellipse(P([(-290, -178), (-244, -112)]), fill=blk)                     # fist
    # pistol: slide, trigger guard, grip
    draw.polygon(P([(-405, -188), (-262, -188), (-262, -146), (-405, -146)]), fill=blk)
    draw.rectangle(P([(-420, -182), (-400, -160)]), fill=blk)                   # muzzle
    draw.polygon(P([(-300, -150), (-256, -150), (-262, -78), (-300, -82)]), fill=blk)
    # free arm bent back at the hip
    draw.polygon(P([(80, -150), (118, -138), (128, -40), (88, 40), (62, 20), (90, -40)]), fill=blk)


img = Image.new("RGB", (S, S), (0, 0, 0))
radial_barrel(img)
draw = ImageDraw.Draw(img)

# The lit muzzle opening the agent stands in.
hole = S * 0.215
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse([cx - hole * 1.25, cy - hole * 1.25, cx + hole * 1.25, cy + hole * 1.25], fill=150)
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.03))
img.paste(Image.new("RGB", (S, S), (255, 255, 255)), (0, 0), glow)
draw.ellipse([cx - hole, cy - hole, cx + hole, cy + hole], fill=(245, 245, 248))

# Agent, clipped to the opening.
fig = Image.new("RGB", (S, S), (245, 245, 248))
agent(ImageDraw.Draw(fig), cx + hole * 0.20, cy + hole * 0.02, hole / 410)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).ellipse([cx - hole, cy - hole, cx + hole, cy + hole], fill=255)
img.paste(fig, (0, 0), mask)

# Gold 007 across the bottom.
font = None
for name in ("C:/Windows/Fonts/impact.ttf", "C:/Windows/Fonts/arialbd.ttf"):
    try:
        font = ImageFont.truetype(name, int(S * 0.20))
        break
    except OSError:
        pass
text = "007"
bbox = draw.textbbox((0, 0), text, font=font)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
tx, ty = (S - tw) / 2 - bbox[0], S * 0.80 - th / 2 - bbox[1]
shadow = Image.new("L", (S, S), 0)
ImageDraw.Draw(shadow).text((tx + S * 0.008, ty + S * 0.012), text, font=font, fill=255)
img.paste(Image.new("RGB", (S, S), (0, 0, 0)), (0, 0), shadow.filter(ImageFilter.GaussianBlur(S * 0.006)))
gold = Image.new("RGB", (S, S))
gpx = ImageDraw.Draw(gold)
for y in range(S):
    t = (y - ty) / max(th, 1)
    t = min(max(t, 0.0), 1.0)
    # bright highlight band in the upper third, deeper gold below
    hi = max(0.0, 1 - abs(t - 0.28) / 0.28)
    r = int(196 + 59 * hi)
    g = int(146 + 84 * hi)
    b = int(40 + 90 * hi)
    gpx.line([(0, y), (S, y)], fill=(r, g, b))
tmask = Image.new("L", (S, S), 0)
ImageDraw.Draw(tmask).text((tx, ty), text, font=font, fill=255)
img.paste(gold, (0, 0), tmask)

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", OUT)
