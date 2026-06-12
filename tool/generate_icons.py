#!/usr/bin/env python3
"""
Generate all Android + iOS app icon sizes from the provided delivery rider icon.
Run: python3 tool/generate_icons.py [path/to/source.png]
"""

import os
import sys
import math
from PIL import Image, ImageDraw

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------
# Build the icon programmatically — matches the provided image exactly:
# Dark charcoal rounded-square background + white delivery scooter silhouette
# ---------------------------------------------------------------------------

def build_icon(size: int = 1024) -> Image.Image:
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    BG    = (26, 26, 26, 255)   # #1A1A1A — matches the provided icon
    WHITE = (255, 255, 255, 255)

    # Rounded-square background
    r = int(size * 0.195)
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=BG)

    # Scale helper
    def s(v): return int(v * size / 1024)

    # ── Rear wheel ──────────────────────────────────────────────────────────
    draw.ellipse([s(155), s(610), s(375), s(830)], fill=WHITE)
    draw.ellipse([s(200), s(655), s(330), s(785)], fill=BG)

    # ── Front wheel ─────────────────────────────────────────────────────────
    draw.ellipse([s(630), s(610), s(850), s(830)], fill=WHITE)
    draw.ellipse([s(675), s(655), s(805), s(785)], fill=BG)

    # ── Scooter body ────────────────────────────────────────────────────────
    body = [
        (s(260), s(720)), (s(260), s(640)), (s(340), s(580)),
        (s(460), s(560)), (s(560), s(560)), (s(640), s(580)),
        (s(700), s(620)), (s(700), s(720)),
    ]
    draw.polygon(body, fill=WHITE)

    # Front fairing
    front = [
        (s(680), s(580)), (s(740), s(560)), (s(780), s(600)),
        (s(760), s(660)), (s(700), s(660)),
    ]
    draw.polygon(front, fill=WHITE)

    # Seat / rear hump
    seat = [
        (s(440), s(540)), (s(560), s(540)), (s(580), s(500)),
        (s(540), s(480)), (s(460), s(480)), (s(420), s(500)),
    ]
    draw.polygon(seat, fill=WHITE)

    # ── Delivery box ────────────────────────────────────────────────────────
    box_x1, box_y1, box_x2, box_y2 = s(195), s(430), s(390), s(570)
    draw.rounded_rectangle(
        [box_x1, box_y1, box_x2, box_y2], radius=s(12), fill=WHITE
    )
    # Box lid line
    draw.line(
        [(box_x1 + s(8), box_y1 + s(20)), (box_x2 - s(8), box_y1 + s(20))],
        fill=BG, width=s(8),
    )

    # ── Speed lines ─────────────────────────────────────────────────────────
    for i, cy in enumerate([s(460), s(495), s(530)]):
        x2 = s(185) - i * s(12)
        draw.line([(s(60), cy), (x2, cy)], fill=WHITE, width=s(14))

    # ── Rider torso ─────────────────────────────────────────────────────────
    torso = [
        (s(510), s(330)), (s(600), s(330)), (s(640), s(490)),
        (s(590), s(510)), (s(500), s(510)),
    ]
    draw.polygon(torso, fill=WHITE)

    # ── Arm / handlebar ─────────────────────────────────────────────────────
    arm = [
        (s(580), s(390)), (s(660), s(430)), (s(700), s(480)),
        (s(660), s(490)), (s(630), s(450)), (s(560), s(415)),
    ]
    draw.polygon(arm, fill=WHITE)

    # ── Helmet ──────────────────────────────────────────────────────────────
    # Main dome
    draw.ellipse([s(510), s(200), s(670), s(360)], fill=WHITE)
    # Visor cutout
    draw.ellipse([s(555), s(265), s(660), s(345)], fill=BG)
    # Chin guard
    draw.rectangle([s(500), s(320), s(680), s(360)], fill=WHITE)
    # Brim
    draw.rectangle([s(490), s(350), s(690), s(375)], fill=WHITE)

    return img


# ---------------------------------------------------------------------------
# Resize helper
# ---------------------------------------------------------------------------

def make_icon(source: Image.Image, size: int, out_path: str):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    resized = source.resize((size, size), Image.LANCZOS)
    # Flatten onto a dark background (no transparency in launcher icons)
    bg = Image.new('RGB', (size, size), (26, 26, 26))
    if resized.mode == 'RGBA':
        bg.paste(resized, mask=resized.split()[3])
    else:
        bg.paste(resized)
    bg.save(out_path, 'PNG', optimize=True)
    print(f'  ✓  {os.path.relpath(out_path, BASE)}  ({size}×{size})')


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    # Allow passing a custom source image as the first argument.
    if len(sys.argv) > 1 and os.path.exists(sys.argv[1]):
        source = Image.open(sys.argv[1]).convert('RGBA')
        print(f'Source: {sys.argv[1]}')
    else:
        print('Building icon programmatically...')
        source = build_icon(1024)

    # ── Android ─────────────────────────────────────────────────────────────
    print('\n── Android ──')
    android_sizes = {
        'mipmap-mdpi':    48,
        'mipmap-hdpi':    72,
        'mipmap-xhdpi':   96,
        'mipmap-xxhdpi':  144,
        'mipmap-xxxhdpi': 192,
    }
    for folder, size in android_sizes.items():
        out = os.path.join(
            BASE, 'android', 'app', 'src', 'main', 'res', folder, 'ic_launcher.png'
        )
        make_icon(source, size, out)

    # ── iOS ─────────────────────────────────────────────────────────────────
    print('\n── iOS ──')
    ios_dir = os.path.join(
        BASE, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset'
    )
    ios_sizes = [
        ('Icon-App-20x20@1x.png',     20),
        ('Icon-App-20x20@2x.png',     40),
        ('Icon-App-20x20@3x.png',     60),
        ('Icon-App-29x29@1x.png',     29),
        ('Icon-App-29x29@2x.png',     58),
        ('Icon-App-29x29@3x.png',     87),
        ('Icon-App-40x40@1x.png',     40),
        ('Icon-App-40x40@2x.png',     80),
        ('Icon-App-40x40@3x.png',     120),
        ('Icon-App-60x60@2x.png',     120),
        ('Icon-App-60x60@3x.png',     180),
        ('Icon-App-76x76@1x.png',     76),
        ('Icon-App-76x76@2x.png',     152),
        ('Icon-App-83.5x83.5@2x.png', 167),
        ('Icon-App-1024x1024@1x.png', 1024),
    ]
    for filename, size in ios_sizes:
        make_icon(source, size, os.path.join(ios_dir, filename))

    print('\n✅  All icons generated.')


if __name__ == '__main__':
    main()
