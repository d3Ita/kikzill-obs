"""Convertit les PNG sources de kikzill_roulette en WebP legers pour l'overlay.

Usage : python tools/convert_images.py <dossier_source_png> <dossier_destination_webp>

Les PNG d'origine font ~190 Ko piece : 355 vignettes = 72 Mo, trop lourd pour un
depot qu'on retelecharge a chaque mise a jour. En WebP 320 px on tombe ~10x plus bas
sans difference visible a la taille ou les vignettes sont affichees.
"""
import sys
from pathlib import Path
from PIL import Image

MAX_SIDE = 320
QUALITY = 82

def main(src_dir, dst_dir):
    src, dst = Path(src_dir), Path(dst_dir)
    dst.mkdir(parents=True, exist_ok=True)
    before = after = 0
    count = 0

    for png in sorted(src.glob("*.png")):
        img = Image.open(png).convert("RGBA")
        img.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
        out = dst / (png.stem + ".webp")
        img.save(out, "WEBP", quality=QUALITY, method=6)
        before += png.stat().st_size
        after += out.stat().st_size
        count += 1

    mb = lambda n: n / 1024 / 1024
    print(f"{src.name:12} {count:4} images   {mb(before):7.1f} Mo -> {mb(after):6.1f} Mo")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
