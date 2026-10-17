"""Draws the Formwerk app icon (design: "the rounded edge").
A white cube on Werk Blue whose front edge is rounded in Signal Orange.
Writes iOS light/dark/tinted (full-bleed squares, the system rounds them) and the Mac tiles."""
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1]
S = 1024
SS = 4  # supersampling for smooth edges


def quad(p0, c, p1, n=24):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t * t * p1[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t * t * p1[1]) for t in [i / n for i in range(n + 1)]]


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def cube(colors, scale=1.0, offset=(0, 0)):
    """The cube in 1024 space, drawn at SS× on a transparent layer."""
    top, left, right, edge = colors
    img = Image.new("RGBA", (S * SS, S * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def P(pts):
        return [((x - 512) * scale * SS + 512 * SS + offset[0] * SS, (y - 517) * scale * SS + 517 * SS + offset[1] * SS) for x, y in pts]

    # The orange edge goes first; the top face overlaps its upper end so no background shows between them.
    band = [(484, 505), (540, 505)] + quad((540, 820), (512, 850), (484, 820))
    d.polygon(P(band), fill=edge)
    d.polygon(P([(234, 374), (486, 519), (486, 820), (234, 676)]), fill=left)
    d.polygon(P([(790, 374), (538, 519), (538, 820), (790, 676)]), fill=right)
    d.polygon(P([(484, 518), (540, 518)] + quad((540, 518), (512, 548), (484, 518))), fill=edge)
    d.polygon(P([(512, 214), (790, 374), (512, 534), (234, 374)]), fill=top)
    return img


def tile(bg_top, bg_bottom, colors, mac=False):
    base = gradient(S * SS, bg_top, bg_bottom).convert("RGBA")
    if mac:
        canvas = Image.new("RGBA", (S * SS, S * SS), (0, 0, 0, 0))
        m, inner = 100 * SS, 824 * SS
        mask = Image.new("L", (S * SS, S * SS), 0)
        ImageDraw.Draw(mask).rounded_rectangle([m, m, m + inner, m + inner], radius=185 * SS, fill=255)
        shadow = Image.new("RGBA", (S * SS, S * SS), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle([m, m + 12 * SS, m + inner, m + inner + 12 * SS], radius=185 * SS, fill=(0, 0, 0, 80))
        shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SS))
        canvas.alpha_composite(shadow)
        canvas.paste(base, (0, 0), mask)
        canvas.alpha_composite(cube(colors, scale=0.82))
        return canvas.resize((S, S), Image.LANCZOS)
    base.alpha_composite(cube(colors))
    return base.convert("RGB").resize((S, S), Image.LANCZOS)


LIGHT = ((255, 255, 255, 255), (212, 225, 250, 255), (147, 180, 242, 255), (255, 138, 42, 255))
DARK = ((233, 238, 248, 255), (110, 140, 200, 255), (61, 99, 179, 255), (255, 138, 42, 255))
TINT = ((242, 242, 242, 255), (154, 154, 154, 255), (106, 106, 106, 255), (255, 255, 255, 255))

os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith(".png"):
        os.remove(os.path.join(OUT, f))
tile((46, 116, 240), (23, 63, 158), LIGHT).save(os.path.join(OUT, "icon-ios.png"))
tile((26, 28, 33), (14, 15, 18), DARK).save(os.path.join(OUT, "icon-ios-dark.png"))
tile((30, 30, 32), (20, 20, 22), TINT).convert("L").save(os.path.join(OUT, "icon-ios-tinted.png"))
mac = tile((46, 116, 240), (23, 63, 158), LIGHT, mac=True)
images = [
    {"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-ios.png"},
    {"appearances": [{"appearance": "luminosity", "value": "dark"}], "idiom": "universal", "platform": "ios",
     "size": "1024x1024", "filename": "icon-ios-dark.png"},
    {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "idiom": "universal", "platform": "ios",
     "size": "1024x1024", "filename": "icon-ios-tinted.png"},
]
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        name = f"mac-{pt}@{scale}x.png"
        mac.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
        images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}", "filename": name})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(OUT, "Contents.json"), "w"), indent=2)
# A copy for the launch screen / welcome (transparent cube only)
cube(LIGHT).resize((S, S), Image.LANCZOS).save(os.path.join(os.path.dirname(OUT), "LogoCube.imageset", "logo-cube.png")) if os.path.isdir(os.path.join(os.path.dirname(OUT), "LogoCube.imageset")) else None
print("icon written")
