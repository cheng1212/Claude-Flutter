# -*- coding: utf-8 -*-
"""生成 zCode 应用图标(科技风:深墨蓝底 + 焦糖橙 `>_` 终端提示符 + 青色电路)。

用法:
    D:/anaconda3/python.exe tool/make_icon.py

输出(全部覆盖写):
    android/app/src/main/res/mipmap-{mdpi..xxxhdpi}/ic_launcher.png          兜底(旧系统)
    android/app/src/main/res/mipmap-{mdpi..xxxhdpi}/ic_launcher_foreground.png  adaptive 前景
    web/icons/Icon-192.png / Icon-512.png / favicon.png                      (存在才写)

设计约定:
    - 画布 1024 逻辑像素,S=4 超采样(4096)再 LANCZOS 缩小,Pillow 无抗锯齿全靠它。
    - adaptive 安全区 = 中心直径 66/108 圆(r≈313 逻辑),前景元素全部在内,
      四角氛围(网格/电路)留在背景层,被圆形遮罩裁掉也自然。
"""
from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

APP = Path(__file__).resolve().parent.parent
RES = APP / "android" / "app" / "src" / "main" / "res"
WEB = APP / "web" / "icons"

S = 4                       # 超采样倍率
C = 1024                    # 逻辑画布
N = C * S                   # 实际画布

# 调色(和 lib/theme.dart 同源;暗底上做了提亮)
INK_TOP = (17, 27, 46)      # 背景渐变顶 #111B2E
INK_BOT = (9, 14, 24)       # 背景渐变底 #090E18
ORANGE = (255, 123, 46)     # 主符号 #FF7B2E(焦糖橙提亮)
AQUA = (89, 194, 176)       # 电路 #59C2B0(哑光青提亮)
AMBER = (233, 161, 59)      # 点缀 #E9A13B


def lpx(v: tuple[float, float]) -> tuple[float, float]:
    """逻辑坐标 → 超采样坐标。"""
    return (v[0] * S, v[1] * S)


def lnum(v: float) -> float:
    return v * S


def gradient_bg() -> Image.Image:
    """对角渐变底:逐行插值,列向再做轻微偏移制造斜向感。"""
    img = Image.new("RGB", (N, N))
    dr = ImageDraw.Draw(img)
    for y in range(N):
        t = y / (N - 1)
        row = tuple(round(a + (b - a) * t) for a, b in zip(INK_TOP, INK_BOT))
        dr.line([(0, y), (N, y)], fill=row)
    # 斜向明暗:右上再压一层半透明深色三角,过渡生硬就大半径糊掉
    shade = Image.new("L", (N, N), 0)
    sd = ImageDraw.Draw(shade)
    sd.polygon([(N, 0), (N, N), (0, N)], fill=46)
    shade = shade.filter(ImageFilter.GaussianBlur(160 * S // 4))
    black = Image.new("RGB", (N, N), (4, 7, 12))
    img = Image.composite(black, img, shade)
    return img


def draw_grid(dr: ImageDraw.ImageDraw) -> None:
    """背景网格:细线 64 逻辑一格,主线 256 一格。"""
    fine = (255, 255, 255, 11)
    major = (255, 255, 255, 20)
    for x in range(0, C + 1, 64):
        w = 3 if x % 256 == 0 else 2
        dr.line([lpx((x, 0)), lpx((x, C))], fill=major if w == 3 else fine, width=lnum(w))
    for y in range(0, C + 1, 64):
        w = 3 if y % 256 == 0 else 2
        dr.line([lpx((0, y)), lpx((C, y))], fill=major if w == 3 else fine, width=lnum(w))


def trace(dr: ImageDraw.ImageDraw, pts: list[tuple[float, float]], *,
          color, width: float, node_r: float, node_filled: bool) -> None:
    """电路走线:直角折线 + 端点节点(空心焊盘/实心点)。"""
    for a, b in zip(pts, pts[1:]):
        dr.line([lpx(a), lpx(b)], fill=color, width=lnum(width))
    for i, (x, y) in enumerate(pts):
        r = lnum(node_r)
        if node_filled or i in (0, len(pts) - 1):
            if node_filled:
                dr.ellipse([x * S - r, y * S - r, x * S + r, y * S + r], fill=color)
            else:  # 空心焊盘:底色芯 + 描边
                dr.ellipse([x * S - r, y * S - r, x * S + r, y * S + r], fill=INK_TOP)
                dr.ellipse([x * S - r, y * S - r, x * S + r, y * S + r],
                           outline=color, width=lnum(width))


def bg_layer() -> Image.Image:
    img = gradient_bg()
    dr = ImageDraw.Draw(img, "RGBA")
    draw_grid(dr)

    # 中心橙色辉光(符号后面垫一圈暖光)
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy, r = 512 * S, 500 * S, 330 * S
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ORANGE + (72,))
    glow = glow.filter(ImageFilter.GaussianBlur(150 * S // 4))
    img = Image.alpha_composite(img.convert("RGBA"), glow)

    # 四角电路(会部分被圆遮罩裁掉,残段正好当纹理)
    dr = ImageDraw.Draw(img, "RGBA")
    corner = (255, 255, 255, 26)
    trace(dr, [(88, 168), (236, 168), (296, 228)], color=corner, width=6, node_r=16, node_filled=False)
    trace(dr, [(236, 168), (236, 96)], color=corner, width=6, node_r=14, node_filled=False)
    trace(dr, [(936, 856), (788, 856), (728, 796)], color=corner, width=6, node_r=16, node_filled=False)
    trace(dr, [(788, 856), (788, 928)], color=corner, width=6, node_r=14, node_filled=False)
    return img


def draw_prompt(dr: ImageDraw.ImageDraw, color) -> None:
    """主符号 `>_`:粗折线 V 形(圆帽)+ 圆角下划线。"""
    w = lnum(78)
    a, b, c = lpx((368, 336)), lpx((512, 512)), lpx((368, 688))
    dr.line([a, b], fill=color, width=w)
    dr.line([b, c], fill=color, width=w)
    for p in (a, b, c):  # 圆帽
        r = w / 2
        dr.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=color)
    dr.rounded_rectangle([lnum(576), lnum(636), lnum(740), lnum(716)], radius=lnum(40), fill=color)


def fg_layer() -> Image.Image:
    """adaptive 前景:透明底,主符号 + 外发光 + 青色电路点缀(全部在安全区内)。"""
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # 外发光:先画一遍符号,大半径糊开垫底
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    draw_prompt(ImageDraw.Draw(glow), ORANGE + (200,))
    glow = glow.filter(ImageFilter.GaussianBlur(46 * S // 4))
    img = Image.alpha_composite(img, glow)

    dr = ImageDraw.Draw(img, "RGBA")
    draw_prompt(dr, ORANGE + (255,))

    # 青色电路:右上/左下各一条,对角呼应;末端空心焊盘
    trace(dr, [(612, 318), (742, 318)], color=AQUA + (235,), width=10, node_r=22, node_filled=False)
    trace(dr, [(412, 706), (282, 706)], color=AQUA + (235,), width=10, node_r=22, node_filled=False)
    # 细碎点缀:琥珀点 + 小青点
    for (x, y, r, col) in [(268, 360, 14, AMBER), (756, 660, 10, AQUA)]:
        rr = lnum(r)
        dr.ellipse([x * S - rr, y * S - rr, x * S + rr, y * S + rr], fill=col + (255,))
    return img


def down(src: Image.Image, px: int) -> Image.Image:
    return src.resize((px, px), Image.LANCZOS)


def save(img: Image.Image, path: Path, px: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    down(img, px).save(path, "PNG", optimize=True)
    print(f"  {path.relative_to(APP)}  ({px}x{px})")


def main() -> None:
    bg, fg = bg_layer(), fg_layer()
    square = Image.alpha_composite(bg.convert("RGBA"), fg)  # 兜底/网页用整图

    densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    print("legacy ic_launcher:")
    for d, px in densities.items():
        save(square, RES / f"mipmap-{d}" / "ic_launcher.png", px)
    print("adaptive ic_launcher_foreground:")
    for d, base in densities.items():
        save(fg, RES / f"mipmap-{d}" / "ic_launcher_foreground.png", base * 108 // 48)

    if WEB.parent.is_dir():
        print("web icons:")
        save(square, WEB / "Icon-192.png", 192)
        save(square, WEB / "Icon-512.png", 512)
        save(square, WEB / "favicon.png", 16)
    print("done.")


if __name__ == "__main__":
    main()
