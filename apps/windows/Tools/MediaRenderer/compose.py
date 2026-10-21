"""compose.py - frame the rendered pages (rounded corners, soft shadow, hairline edge)
and turn the recording bar's frames into a looping GIF.
Usage: python3 compose.py <rendered folder> <output folder>"""
import glob
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)


def frame(name, width=1200):
    win = Image.open(os.path.join(src, name + ".png")).convert("RGBA")
    r, pad = 24, 90
    mask = Image.new("L", win.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, win.width - 1, win.height - 1), r, fill=255)
    win.putalpha(mask)
    canvas = Image.new("RGBA", (win.width + pad * 2, win.height + pad * 2), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad + 18, pad + win.width, pad + win.height + 18), r, fill=(0, 0, 0, 60))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(34)))
    canvas.alpha_composite(win, (pad, pad))
    ImageDraw.Draw(canvas).rounded_rectangle((pad, pad, pad + win.width - 1, pad + win.height - 1), r, outline=(0, 0, 0, 28), width=2)
    canvas.resize((width, round(canvas.height * width / canvas.width)), Image.LANCZOS).save(os.path.join(dst, name + ".png"), optimize=True)


for page in ("home-light", "home-dark", "history-light", "settings-light"):
    frame(page)

frames = [Image.open(f).convert("RGB").quantize(colors=48, method=Image.Quantize.MEDIANCUT) for f in sorted(glob.glob(os.path.join(src, "bar-*.png")))]
frames[0].save(os.path.join(dst, "recording-bar.gif"), save_all=True, append_images=frames[1:],
               duration=[40] * (len(frames) - 1) + [1200], loop=0, optimize=True, disposal=1)
