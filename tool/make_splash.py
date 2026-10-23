#!/usr/bin/env python3
"""Genera el logo de arranque (marca + "HandiMan ¡Ya!") para Android e iOS.

El mismo dibujo se usa en la pantalla nativa (Android 12+ como ícono de la
pantalla de inicio, Android anterior e iOS como imagen centrada) y en la
pantalla de Flutter, al mismo tamaño y en el mismo lugar, para que el paso de
una a otra no se note. Copia las medidas de BrandLogo (lib/core/widgets/
brand_logo.dart). Uso: python3 tool/make_splash.py (requiere Pillow).
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
NAVY = (0x02, 0x17, 0x3A, 255)
ORANGE = (0xF2, 0x55, 0x00, 255)

# Alto del logo en dp. Con este alto el logo entero entra en el círculo de
# 192 dp que Android 12+ deja ver del ícono de arranque.
LOGO_H = 34
ICON_CANVAS = 288  # dp, tamaño del ícono de arranque sin fondo (Android 12+)


def draw_logo(scale: float) -> Image.Image:
    h = LOGO_H * scale
    font = ImageFont.truetype(str(ROOT / 'assets/fonts/Nunito-900.ttf'), round(h * 0.6))
    spacing = -0.5 * (h / 56)
    mark = Image.open(ROOT / 'assets/brand/logo_mark.png').convert('RGBA').resize((round(h), round(h)), Image.LANCZOS)

    def text_width(t: str) -> float:
        return sum(font.getlength(c) + spacing for c in t)

    w1, gap, w2 = text_width('HandiMan'), h * 0.6 * 0.12, text_width('¡Ya!')
    width = round(h + h * 0.18 + w1 + gap + w2) + 2
    img = Image.new('RGBA', (width, round(h)), (0, 0, 0, 0))
    img.alpha_composite(mark, (0, 0))
    d = ImageDraw.Draw(img)
    ascent, descent = font.getmetrics()
    size = h * 0.6
    baseline = (h - size) / 2 + size * ascent / (ascent + descent)
    x = h + h * 0.18
    for text, color in (('HandiMan', NAVY), ('¡Ya!', ORANGE)):
        for c in text:
            d.text((x, baseline), c, font=font, fill=color, anchor='ls')
            x += font.getlength(c) + spacing
        x += gap
    return img


def logo_at(scale: float) -> Image.Image:
    """Dibuja a 8x y reduce, para que todas las densidades midan lo mismo en dp."""
    big = draw_logo(8)
    width_dp = round(big.width / 8)
    return big.resize((round(width_dp * scale), round(LOGO_H * scale)), Image.LANCZOS)


def save(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)
    print(path.relative_to(ROOT), img.size)


def main() -> None:
    res = ROOT / 'android/app/src/main/res'
    for bucket, scale in (('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)):
        logo = logo_at(scale)
        # Android anterior a 12: imagen centrada sobre el color de fondo.
        save(logo, res / f'drawable-{bucket}/splash_logo.png')
        # Android 12+: el mismo logo centrado en el lienzo de 288 dp del ícono.
        side = round(ICON_CANVAS * scale)
        icon = Image.new('RGBA', (side, side), (0, 0, 0, 0))
        icon.alpha_composite(logo, ((side - logo.width) // 2, (side - logo.height) // 2))
        save(icon, res / f'drawable-{bucket}/splash_icon.png')
    # Flutter: el mismo dibujo, a 1x, 2x, 3x y 4x.
    save(logo_at(1), ROOT / 'assets/brand/splash_logo.png')
    for n in (2, 3, 4):
        save(logo_at(n), ROOT / f'assets/brand/{n}.0x/splash_logo.png')
    # iOS: LaunchImage a 1x, 2x y 3x.
    ios = ROOT / 'ios/Runner/Assets.xcassets/LaunchImage.imageset'
    for n, name in ((1, 'LaunchImage.png'), (2, 'LaunchImage@2x.png'), (3, 'LaunchImage@3x.png')):
        save(logo_at(n), ios / name)
    print('logo en dp:', logo_at(1).size)


if __name__ == '__main__':
    main()
