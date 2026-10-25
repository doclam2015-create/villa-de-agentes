#!/usr/bin/env python3
"""Ícono de Villa de Agentes: cúpula dorada de la sede de gobierno sobre una isla, con tres personajes de colores."""
import os, sys, subprocess, shutil
from PIL import Image, ImageDraw

def png(lado):
    esc = 4; L = lado * esc
    pad = round(L * 0.07); caja = L - 2 * pad; u = caja / 100
    arte = Image.new("RGB", (caja, caja)); d = ImageDraw.Draw(arte)
    for y in range(caja):
        t = y / max(1, caja - 1)
        d.line([(0, y), (caja, y)], fill=(int(14 + 30 * t), int(28 + 60 * t), int(70 + 90 * t)))
    d.ellipse([8 * u, 62 * u, 92 * u, 92 * u], fill=(70, 118, 72))            # isla
    d.rectangle([30 * u, 44 * u, 70 * u, 72 * u], fill=(236, 226, 204))        # palacio
    for i in range(5):
        x = 33 * u + i * 8.4 * u
        d.rectangle([x, 50 * u, x + 3 * u, 72 * u], fill=(250, 244, 230))
    d.pieslice([33 * u, 22 * u, 67 * u, 62 * u], 180, 360, fill=(214, 170, 68)) # cúpula
    d.rectangle([49 * u, 14 * u, 51 * u, 24 * u], fill=(214, 170, 68))
    for cx, col in ((18, (46, 160, 220)), (82, (230, 120, 60)), (50, (120, 200, 110))):
        cy = 80 if cx != 50 else 84
        d.ellipse([(cx - 4) * u, (cy - 13) * u, (cx + 4) * u, (cy - 5) * u], fill=(240, 200, 165))
        d.rounded_rectangle([(cx - 5) * u, (cy - 5) * u, (cx + 5) * u, (cy + 7) * u], radius=3 * u, fill=col)
    m = Image.new("L", (caja, caja), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, caja - 1, caja - 1], radius=caja * 0.225, fill=255)
    im = Image.new("RGBA", (L, L), (0, 0, 0, 0)); im.paste(arte, (pad, pad), m)
    return im.resize((lado, lado), Image.LANCZOS)

def icns(destino):
    base = destino[:-5] + ".iconset"; os.makedirs(base, exist_ok=True)
    for lado in (16, 32, 128, 256, 512):
        png(lado).save(os.path.join(base, f"icon_{lado}x{lado}.png"))
        png(lado * 2).save(os.path.join(base, f"icon_{lado}x{lado}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", base, "-o", destino], check=True)
    shutil.rmtree(base)
    png(512).save(os.path.join(os.path.dirname(os.path.abspath(__file__)), "AppIcon.png"))

if __name__ == "__main__":
    icns(sys.argv[1])
