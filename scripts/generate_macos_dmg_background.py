#!/usr/bin/env python3
# 生成 macOS 打包脚本使用的自定义 DMG 背景图。
#
# 用法：
#   python3 scripts/generate_macos_dmg_background.py
#
# 参数说明：
#   可选参数：
#     --scale <N>
#       只输出指定缩放倍数的背景图，例如 `--scale 2`
#     --output <PATH>
#       配合 `--scale` 使用，覆盖默认输出路径
#
# 运行要求：
#   当前 Python 环境里需要安装 `Pillow`。
#
# 输出产物：
#   默认同时生成：
#   - packaging/macos/dmg-background.png
#   - packaging/macos/dmg-background@2x.png

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


BASE_WIDTH = 920
BASE_HEIGHT = 540
BASE_APP_ICON_X = 190
BASE_APP_ICON_Y = 300
BASE_APPS_ICON_X = 700
BASE_APPS_ICON_Y = 300
BASE_LOGO_X = 130
BASE_LOGO_Y = 112
DEFAULT_OUTPUTS = {
    1: "dmg-background.png",
    2: "dmg-background@2x.png",
}


def s(value: int, scale: int) -> int:
    return int(value * scale)


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFNSMono.ttf" if bold else "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Supplemental/Courier New.ttf",
    ]
    for candidate in candidates:
        path = Path(candidate)
        if path.exists():
            try:
                return ImageFont.truetype(str(path), size=size)
            except OSError:
                continue
    return ImageFont.load_default()


def draw_grid(draw: ImageDraw.ImageDraw, *, width: int, height: int, scale: int) -> None:
    line_color = (148, 163, 184, 18)
    for x in range(0, width, s(40, scale)):
        draw.line([(x, 0), (x, height)], fill=line_color, width=1)
    for y in range(0, height, s(40, scale)):
        draw.line([(0, y), (width, y)], fill=line_color, width=1)


def draw_glow(
    base: Image.Image,
    center: tuple[int, int],
    radius: int,
    color: tuple[int, int, int],
    opacity: int,
    *,
    scale: int,
) -> None:
    glow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    x, y = center
    glow_draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=(*color, opacity))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=s(22, scale)))
    base.alpha_composite(glow)


def add_arrow(base: Image.Image, *, app_icon_y: int, apps_icon_y: int, scale: int) -> None:
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    line = [(s(340, scale), app_icon_y), (s(550, scale), apps_icon_y)]
    draw.line(line, fill=(52, 211, 153, 138), width=s(5, scale))
    draw.polygon(
        [
            (s(550, scale), apps_icon_y),
            (s(522, scale), apps_icon_y - s(20, scale)),
            (s(522, scale), apps_icon_y + s(20, scale)),
        ],
        fill=(52, 211, 153, 172),
    )
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=s(1, scale)))
    base.alpha_composite(overlay)


def add_glass_panel(base: Image.Image, box: tuple[int, int, int, int], *, scale: int) -> None:
    panel = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(panel)
    draw.rounded_rectangle(box, radius=s(22, scale), fill=(255, 255, 255, 164), outline=(207, 218, 235, 120), width=s(1, scale))
    base.alpha_composite(panel)


def add_logo(base: Image.Image, logo_path: Path, *, scale: int) -> None:
    logo = Image.open(logo_path).convert("RGBA").resize((s(42, scale), s(42, scale)), Image.Resampling.LANCZOS)
    base.alpha_composite(logo, (s(BASE_LOGO_X, scale), s(BASE_LOGO_Y, scale)))


def add_text(base: Image.Image, *, scale: int) -> None:
    draw = ImageDraw.Draw(base)
    title_font = load_font(s(28, scale), bold=True)
    draw.text((s(186, scale), s(116, scale)), "Drag to install", font=title_font, fill=(15, 23, 42, 235))


def add_center_plate(base: Image.Image, *, scale: int) -> None:
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle(
        (s(120, scale), s(92, scale), s(800, scale), s(188, scale)),
        radius=s(24, scale),
        fill=(255, 255, 255, 128),
        outline=(207, 218, 235, 136),
        width=s(1, scale),
    )
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=s(1, scale)))
    base.alpha_composite(overlay)


def add_stage_glow(base: Image.Image, *, app_icon_x: int, apps_icon_x: int, scale: int) -> None:
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    for cx in (app_icon_x, apps_icon_x):
        draw.rounded_rectangle(
            (cx - s(78, scale), s(230, scale), cx + s(78, scale), s(390, scale)),
            radius=s(28, scale),
            fill=(255, 255, 255, 50),
            outline=(207, 218, 235, 68),
            width=s(1, scale),
        )
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=s(3, scale)))
    base.alpha_composite(overlay)


def render_background(logo_path: Path, output_path: Path, *, scale: int) -> None:
    width = s(BASE_WIDTH, scale)
    height = s(BASE_HEIGHT, scale)
    app_icon_x = s(BASE_APP_ICON_X, scale)
    app_icon_y = s(BASE_APP_ICON_Y, scale)
    apps_icon_x = s(BASE_APPS_ICON_X, scale)
    apps_icon_y = s(BASE_APPS_ICON_Y, scale)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    base = Image.new("RGBA", (width, height), (244, 247, 251, 255))
    gradient = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gradient)
    gd.rectangle((0, 0, width, height), fill=(244, 247, 251, 255))
    draw_grid(gd, width=width, height=height, scale=scale)
    base.alpha_composite(gradient)

    draw_glow(base, (app_icon_x, s(320, scale)), s(118, scale), (52, 211, 153), 20, scale=scale)
    draw_glow(base, (apps_icon_x, s(320, scale)), s(108, scale), (59, 130, 246), 16, scale=scale)
    add_center_plate(base, scale=scale)
    add_glass_panel(base, (s(120, scale), s(92, scale), s(800, scale), s(188, scale)), scale=scale)
    add_stage_glow(base, app_icon_x=app_icon_x, apps_icon_x=apps_icon_x, scale=scale)
    add_logo(base, logo_path, scale=scale)
    add_text(base, scale=scale)
    add_arrow(base, app_icon_y=app_icon_y, apps_icon_y=apps_icon_y, scale=scale)

    noise = Image.effect_noise((width, height), 6).convert("L")
    noise = ImageChops.multiply(noise, Image.new("L", (width, height), 18))
    grain = Image.merge("RGBA", (noise, noise, noise, Image.new("L", (width, height), 10)))
    base.alpha_composite(grain)

    base.save(output_path)
    print(output_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate the macOS DMG background image.")
    parser.add_argument(
        "--scale",
        type=int,
        choices=sorted(DEFAULT_OUTPUTS),
        help="Only generate a single scale variant.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Override the output path. Must be used together with --scale.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    root = Path(__file__).resolve().parents[1]
    logo_path = root / "assets" / "branding" / "dev_workbench_logo_1024.png"
    output_dir = root / "packaging" / "macos"

    if args.output is not None and args.scale is None:
        raise SystemExit("--output must be used together with --scale")

    if args.scale is not None:
        output_path = args.output or (output_dir / DEFAULT_OUTPUTS[args.scale])
        render_background(logo_path, output_path, scale=args.scale)
        return

    for scale, filename in DEFAULT_OUTPUTS.items():
        render_background(logo_path, output_dir / filename, scale=scale)


if __name__ == "__main__":
    main()
