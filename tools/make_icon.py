#!/usr/bin/env python3
"""
make_icon.py — 生成 Blade 的图标（1024 母版 + iOS 全套尺寸）

设计：深色背景 + 一柄 45° 的刃，刃口带青色能量线，背后一道极淡的"划痕"光带。
要求（iOS）：满幅正方形、**不透明**（不能有 alpha，否则透出来是黑的）、
不自己画圆角（系统会裁）。

用法：
    python3 tools/make_icon.py            # 生成到 src/icons/
"""

import os
import math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "icons")
S = 1024          # 母版边长
SS = 3            # 形状超采样倍数（先画大再缩小，边缘才干净）


# ─────────────────────────────────────────────────────────── 渐变工具
def linear_gradient(size, stops, angle_deg):
    """stops: [(pos0..1, (r,g,b)), ...]；angle_deg: 0=从左到右，90=从上到下"""
    n = 512
    strip = Image.new("RGB", (n, 1))
    px = strip.load()
    for x in range(n):
        t = x / (n - 1)
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                k = 0 if p1 == p0 else (t - p0) / (p1 - p0)
                px[x, 0] = tuple(int(c0[j] + (c1[j] - c0[j]) * k) for j in range(3))
                break
        else:
            px[x, 0] = stops[-1][1]
    strip = strip.resize((size, size), Image.BICUBIC)
    return strip.rotate(-angle_deg, resample=Image.BICUBIC, expand=False)


def radial_glow(size, center, radius, color, peak_alpha):
    """一张柔和的圆形光晕（RGBA）"""
    layer = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(layer)
    cx, cy = center
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=peak_alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(radius * 0.55))
    out = Image.new("RGBA", (size, size), color + (0,))
    out.putalpha(layer)
    return out


def radial_falloff(size, power=2.2, invert=False):
    """径向衰减遮罩：中心 255 → 边缘 0（invert=True 则相反）。小图算完放大，天然平滑。"""
    n = 96
    img = Image.new("L", (n, n), 0)
    px = img.load()
    c = (n - 1) / 2.0
    for y in range(n):
        for x in range(n):
            d = math.hypot(x - c, y - c) / (c * 1.4142)
            v = max(0.0, 1.0 - min(1.0, d / 0.92))
            v = v ** power
            px[x, y] = int(255 * (v if not invert else (1.0 - v)))
    return img.resize((size, size), Image.BICUBIC)


def add(base, layer):
    return Image.alpha_composite(base, layer)


# ─────────────────────────────────────────────────────────── 主体
def build_master():
    W = S * SS
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 255))

    # ── 背景：斜向深蓝 + 中心冷光
    canvas = add(canvas, linear_gradient(W, [
        (0.00, (28, 42, 66)),
        (0.50, (15, 23, 38)),
        (1.00, (7, 10, 17)),
    ], 118).convert("RGBA"))
    canvas = add(canvas, radial_glow(W, (W * 0.52, W * 0.46), W * 0.64, (44, 86, 132), 165))

    # ── 刀身几何：两条二次贝塞尔曲线（刃背 / 刃口）在刀尖汇合
    #
    # 直线边做出来像凿子：刀的关键是**刃口的弧线**。所以刃背与刃口各用一条
    # 曲线，刃口外凸、刃背内收，两条在刀尖 T 处相交，切出真正有锋利感的轮廓。
    A = (W * 0.245, W * 0.790)          # 刃根·刃背端
    T = (W * 0.795, W * 0.195)          # 刀尖
    ax, ay = T[0] - A[0], T[1] - A[1]
    L = math.hypot(ax, ay)
    ux, uy = ax / L, ay / L
    nx, ny = -uy, ux                    # 指向刃口一侧
    HALF = W * 0.150                    # 刃根宽度（小尺寸要立得住，必须够厚）
    B = (A[0] + nx * HALF, A[1] + ny * HALF)          # 刃根·刃口端
    M = ((A[0] + T[0]) / 2, (A[1] + T[1]) / 2)
    C_spine = (M[0] - nx * W * 0.105, M[1] - ny * W * 0.105)   # 刃背内收
    C_edge = (M[0] + nx * W * 0.215, M[1] + ny * W * 0.215)    # 刃口外凸
    N = 180

    def _bez(p0, c, p1, t):
        mt = 1.0 - t
        return (mt * mt * p0[0] + 2 * mt * t * c[0] + t * t * p1[0],
                mt * mt * p0[1] + 2 * mt * t * c[1] + t * t * p1[1])

    def spine_at(t):
        return _bez(A, C_spine, T, min(1.0, max(0.0, t)))

    def edge_at(t):
        return _bez(B, C_edge, T, min(1.0, max(0.0, t)))

    def pt(t, u):
        """u=0 刃背 … u=1 刃口"""
        sp = spine_at(t)
        ed = edge_at(t)
        return (sp[0] + (ed[0] - sp[0]) * u, sp[1] + (ed[1] - sp[1]) * u)

    sil = [pt(i / N, 0.0) for i in range(N + 1)] + \
          [pt(i / N, 1.0) for i in range(N, -1, -1)]
    mask_blade = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask_blade).polygon(sil, fill=255)

    # ── 外发光（在刃之下，让刃有"背光"）
    halo = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    halo.paste(Image.new("RGBA", (W, W), (40, 180, 225, 120)), (0, 0),
               mask_blade.filter(ImageFilter.GaussianBlur(W * 0.055)))
    canvas = add(canvas, halo)

    # ── 深色轮廓（把刃从光里切出来）
    mask_outline = mask_blade.filter(ImageFilter.MaxFilter(max(1, int(W * 0.006)) | 1))
    outline = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    outline.paste(Image.new("RGBA", (W, W), (3, 5, 9, 255)), (0, 0), mask_outline)
    canvas = add(canvas, outline)

    # ── 刃体：横跨刃宽的金属色带
    RAMP = [
        (0.00, (26, 36, 48)),      # 刃背：暗钢（不再压到黑，小尺寸才有形）
        (0.10, (46, 64, 82)),
        (0.34, (104, 138, 168)),
        (0.58, (176, 206, 230)),
        (0.76, (236, 248, 255)),
        (0.89, (255, 255, 255)),
        (1.00, (188, 234, 255)),
    ]

    def ramp_color(u):
        for i in range(len(RAMP) - 1):
            a, ca = RAMP[i]
            b, cb = RAMP[i + 1]
            if a <= u <= b:
                k = (u - a) / (b - a) if b > a else 0
                return tuple(int(ca[j] + (cb[j] - ca[j]) * k) for j in range(3))
        return RAMP[-1][1]

    face = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    df = ImageDraw.Draw(face)
    BANDS = 220
    for k in range(BANDS):
        u0, u1 = k / BANDS, (k + 1) / BANDS
        poly = [pt(i / N, u0) for i in range(N + 1)] + \
               [pt(i / N, u1) for i in range(N, -1, -1)]
        df.polygon(poly, fill=ramp_color((u0 + u1) / 2) + (255,))
    face.putalpha(ImageChops.multiply(face.getchannel("A"), mask_blade))
    canvas = add(canvas, face)

    # ── 刃口能量线：这次画在刃体**之后**，并且故意溢出到轮廓外
    #    （上一版画在最下层，被刃体整个盖住了，所以看不到）
    edge_glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    dg = ImageDraw.Draw(edge_glow)
    for u0, u1, col, a in ((1.000, 1.030, (56, 214, 255), 255),
                           (0.962, 1.006, (226, 252, 255), 255),
                           (1.028, 1.060, (40, 170, 215), 200)):
        band = [pt(i / N, u0) for i in range(N + 1)] + \
               [pt(i / N, u1) for i in range(N, -1, -1)]
        dg.polygon(band, fill=col + (a,))
    edge_glow = edge_glow.filter(ImageFilter.GaussianBlur(W * 0.0045))
    canvas = add(canvas, edge_glow)

    # 刃口更外圈的柔光
    spill = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    dsp2 = ImageDraw.Draw(spill)
    band = [pt(i / N, 1.00) for i in range(N + 1)] + \
           [pt(i / N, 1.075) for i in range(N, -1, -1)]
    dsp2.polygon(band, fill=(70, 216, 255, 235))
    spill = spill.filter(ImageFilter.GaussianBlur(W * 0.026))
    canvas = add(canvas, spill)

    # ── 开刃面分界线（刃面上一条很淡的暗线，让人看出"开过锋"）
    bv = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    dbv = ImageDraw.Draw(bv)
    bb = [pt(i / N, 0.60) for i in range(N + 1)] + \
         [pt(i / N, 0.635) for i in range(N, -1, -1)]
    dbv.polygon(bb, fill=(58, 82, 104, 150))
    bv = bv.filter(ImageFilter.GaussianBlur(W * 0.0035))
    bv.putalpha(ImageChops.multiply(bv.getchannel("A"), mask_blade))
    canvas = add(canvas, bv)

    # ── 刃背细高光
    sp = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    dsp = ImageDraw.Draw(sp)
    sb = [pt(i / N, 0.015) for i in range(N + 1)] + \
         [pt(i / N, 0.070) for i in range(N, -1, -1)]
    dsp.polygon(sb, fill=(150, 182, 208, 140))
    sp = sp.filter(ImageFilter.GaussianBlur(W * 0.004))
    sp.putalpha(ImageChops.multiply(sp.getchannel("A"), mask_blade))
    canvas = add(canvas, sp)

    # ── 刃尖冷光
    canvas = add(canvas, radial_glow(W, (T[0], T[1]), W * 0.070, (200, 248, 255), 120))

    # ── 暗角：用径向衰减，不再是方块状
    vig = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    vig.putalpha(radial_falloff(W, power=2.6, invert=True).point(lambda v: int(v * 0.62)))
    canvas = add(canvas, vig)

    return canvas.resize((S, S), Image.LANCZOS).convert("RGB")


# ─────────────────────────────────────────────────────────── 输出各尺寸
# 文件名必须符合 iOS 的查找规则：CFBundleIconFiles 里写基名（不带 @2x/@3x），
# 系统自己拼后缀去找。AppIcon60x60 / AppIcon76x76 / AppIcon83.5x83.5 是主图标，
# Icon-20/29/40 是设置、Spotlight、通知用的旧式小图（留着更稳）。
SIZES = [
    ("AppIcon60x60@2x.png", 120),
    ("AppIcon60x60@3x.png", 180),
    ("AppIcon76x76@2x~ipad.png", 152),
    ("AppIcon83.5x83.5@2x~ipad.png", 167),
    ("Icon-20@2x.png", 40),
    ("Icon-20@3x.png", 60),
    ("Icon-29@2x.png", 58),
    ("Icon-29@3x.png", 87),
    ("Icon-40@2x.png", 80),
    ("Icon-40@3x.png", 120),
    ("AppIcon-1024.png", 1024),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    master = build_master()
    master.save(os.path.join(OUT, "AppIcon-1024.png"))
    for name, px in SIZES:
        if px == 1024:
            continue
        im = master.resize((px, px), Image.LANCZOS)
        im.save(os.path.join(OUT, name))
    print("生成到 %s" % os.path.normpath(OUT))
    for name, px in SIZES:
        p = os.path.join(OUT, name)
        print("  %-34s %4dpx  %6d bytes" % (name, px, os.path.getsize(p)))


if __name__ == "__main__":
    main()
