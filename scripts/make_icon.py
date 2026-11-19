#!/usr/bin/env python3
"""Generate docs/CydiaIcon.png. Requires Pillow; run only when the icon changes."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "docs" / "CydiaIcon.png"


def lerp(a, b, t):
    return int(a + (b - a) * t)


def make_icon():
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    gradient = Image.new("RGBA", (SIZE, SIZE))
    pixels = gradient.load()
    start = (255, 107, 138)
    end = (153, 0, 64)
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x + y) / (2 * (SIZE - 1))
            pixels[x, y] = (
                lerp(start[0], end[0], t),
                lerp(start[1], end[1], t),
                lerp(start[2], end[2], t),
                255,
            )

    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=224, fill=255)
    image.paste(gradient, (0, 0), mask)

    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((120, 90, 900, 870), fill=(255, 255, 255, 34))
    glow = glow.filter(ImageFilter.GaussianBlur(70))
    image.alpha_composite(glow)

    draw = ImageDraw.Draw(image)
    white = (255, 255, 255, 255)
    soft = (255, 255, 255, 235)

    # Beamed eighth notes.
    draw.ellipse((190, 625, 440, 800), fill=white)
    draw.ellipse((520, 560, 770, 735), fill=white)
    draw.rounded_rectangle((398, 250, 440, 700), radius=21, fill=white)
    draw.rounded_rectangle((728, 185, 770, 635), radius=21, fill=white)
    draw.polygon([(398, 250), (770, 185), (770, 290), (398, 355)], fill=white)

    # Download arrow.
    draw.rounded_rectangle((812, 585, 858, 760), radius=23, fill=soft)
    draw.polygon([(752, 752), (918, 752), (835, 882)], fill=soft)

    image = image.resize((512, 512), Image.LANCZOS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    image.save(OUT, "PNG", optimize=True)
    print(OUT)


if __name__ == "__main__":
    make_icon()
