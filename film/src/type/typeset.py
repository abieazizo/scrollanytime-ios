"""Type layers as premultiplied float RGBA (BGR order) numpy arrays, cached. Sizes are exact pixel
sizes of the em (PIL truetype size)."""
import functools, os
import numpy as np
import cv2
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONTS = {
    'display': os.path.join(ROOT, 'assets/fonts/FrankRuhlLibre-700.ttf'),
    'display500': os.path.join(ROOT, 'assets/fonts/FrankRuhlLibre-500.ttf'),
    'ui': os.path.join(ROOT, 'assets/fonts/Inter-600.ttf'),
    'ui500': os.path.join(ROOT, 'assets/fonts/Inter-500.ttf'),
}
CREAM = (234, 242, 245)      # BGR of #F5F2EA
GOLD = (75, 162, 201)        # BGR of #C9A24B
GLOW = (122, 200, 227)       # BGR of #E3C87A
WHITE = (255, 255, 255)


@functools.lru_cache(maxsize=64)
def font(face, px):
    return ImageFont.truetype(FONTS[face], px)


def measure(text, face, px, tracking=0):
    f = font(face, px)
    w = sum(f.getlength(ch) for ch in text) + tracking * (len(text) - 1) if tracking else f.getlength(text)
    asc, desc = f.getmetrics()
    return w, asc, desc


@functools.lru_cache(maxsize=256)
def text_layer(text, face, px, color=CREAM, alpha=1.0, tracking=0, pad=8):
    """Returns (rgba float32 HxWx4 premultiplied BGR+A, baseline_y, width). Origin = left, baseline."""
    f = font(face, px)
    w, asc, desc = measure(text, face, px, tracking)
    W, H = int(np.ceil(w)) + 2 * pad, asc + desc + 2 * pad
    im = Image.new('L', (W, H), 0)
    d = ImageDraw.Draw(im)
    if tracking:
        x = pad
        for ch in text:
            d.text((x, pad), ch, font=f, fill=255)
            x += f.getlength(ch) + tracking
    else:
        d.text((pad, pad), text, font=f, fill=255)
    a = np.asarray(im, np.float32) / 255.0 * alpha
    rgba = np.zeros((H, W, 4), np.float32)
    for c in range(3):
        rgba[..., c] = a * color[c] / 255.0
    rgba[..., 3] = a
    return rgba, pad + asc, w


def glow(rgba, sigma, color, strength):
    a = cv2.GaussianBlur(rgba[..., 3], (0, 0), sigma) * strength
    out = np.zeros_like(rgba)
    for c in range(3):
        out[..., c] = a * color[c] / 255.0
    out[..., 3] = a
    return out


def over(dst, src, x, y, opacity=1.0):
    """Composite premultiplied src RGBA onto dst (HxWx3 float BGR) with top-left at (x, y)."""
    H, W = dst.shape[:2]
    h, w = src.shape[:2]
    x, y = int(round(x)), int(round(y))
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0 or opacity <= 0:
        return dst
    s = src[y0 - y:y1 - y, x0 - x:x1 - x] * opacity
    dst[y0:y1, x0:x1] = dst[y0:y1, x0:x1] * (1 - s[..., 3:4]) + s[..., :3]
    return dst


def add(dst, src, x, y, opacity=1.0):
    """Additive (for glows)."""
    H, W = dst.shape[:2]
    h, w = src.shape[:2]
    x, y = int(round(x)), int(round(y))
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0 or opacity <= 0:
        return dst
    dst[y0:y1, x0:x1] += src[y0 - y:y1 - y, x0 - x:x1 - x, :3] * opacity
    return dst


def scaled(rgba, s):
    if abs(s - 1) < 1e-3:
        return rgba
    h, w = rgba.shape[:2]
    return cv2.resize(rgba, (max(1, int(w * s)), max(1, int(h * s))), interpolation=cv2.INTER_AREA if s < 1 else cv2.INTER_CUBIC)


def rule(width, height, color=GOLD, glow_sigma=6):
    pad = glow_sigma * 3
    a = np.zeros((height + 2 * pad, width + 2 * pad), np.float32)
    a[pad:pad + height, pad:pad + width] = 1.0
    rgba = np.zeros(a.shape + (4,), np.float32)
    for c in range(3):
        rgba[..., c] = a * color[c] / 255.0
    rgba[..., 3] = a
    g = glow(rgba, glow_sigma, GLOW, 0.8)
    return rgba, g, pad


def centered(dst, layer, cx, baseline, opacity=1.0, glow_layer=None, glow_opacity=0.0, scale=1.0):
    rgba, base, w = layer
    if scale != 1.0:
        rgba = scaled(rgba, scale)
        base *= scale
    h, W = rgba.shape[:2]
    x = cx - W / 2
    y = baseline - base
    if glow_layer is not None and glow_opacity > 0:
        add(dst, scaled(glow_layer, scale) if scale != 1 else glow_layer, x, y, glow_opacity * opacity)
    over(dst, rgba, x, y, opacity)
    return x, y, W, h
