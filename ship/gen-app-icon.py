"""Build every app icon Scroll Anytime ships from ONE source photograph.

    <x64 python> ship/gen-app-icon.py ship/icon-source.png [--fill 0.86] [--no-widen]

Needs the x64 interpreter (cv2 + numpy), not the ARM64 one:
    C:\\Users\\abiea\\AppData\\Local\\Programs\\Python\\Python312-x64\\python.exe

Why each step exists — every one of these was learned by rendering the result at 60px and looking:

  WIDEN     The photograph's scroll is much taller than it is wide (the finials add ~45% to the
            height). Fitted into a square it fills the height and only ~58% of the width, which is
            why it read small and quiet beside real home-screen icons. The sheet between the two
            rollers is a flat, uniform parchment texture, so mirrored columns from its centre are
            inserted until the scroll is near-square — an open Sefer Torah, which is exactly what a
            wider sheet reads as. Every seam is a mirror axis, so the join is continuous.
  CROP      to the artwork's own bounding box (finials included, never clipped), then scale to fill
            FILL of the tile. iOS applies the corner mask itself; nothing is rounded here.
  GRADE     gamma lift on L (not a linear multiply, which clipped the parchment to paper-white and
            erased its texture); a little CLAHE so the rollers keep their cylinder shading instead of
            flattening into the sheet; a saturation boost restricted to gold hues; a per-channel warm
            because a greyscale-then-tint (what sharp's .tint does) turned the gold SILVER.
  KEY       the scroll is luma-keyed off its own near-black background and normal-blended onto the
            ground. Screening it lightened the parchment wherever the glow was strongest; pasting it
            left a rectangle, because the photo's "black" is a dark grey and ours is #0B0B0F.
  GLOW      a generated radial amber bloom — a blurred copy of the artwork is still a rectangle.
  OUTPUT    1024x1024, 3-channel (no alpha — ITMS-90717), sRGB. Each smaller size is area-resampled
            and then unsharp-masked in proportion to how small it is, which is what keeps the
            rollers' edges crisp at 60px and 40px.
"""
import argparse
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024
GROUND_BGR = np.array([15, 11, 11], np.float32) / 255  # #0B0B0F


def luminance(img_f):
    return 0.2126 * img_f[:, :, 2] + 0.7152 * img_f[:, :, 1] + 0.0722 * img_f[:, :, 0]


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def mark_box(img, thresh=72):
    """Bounding box of the artwork: pixels clearly brighter than the photo's dark ground."""
    lum = luminance(img.astype(np.float32))
    ys, xs = np.where(lum > thresh)
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def widen(img, box, target_aspect=1.0):
    """Insert mirrored parchment columns at the sheet's centre until the scroll is near-square."""
    x0, y0, x1, y1 = box
    H, W = y1 - y0, x1 - x0
    need = int(round(H * target_aspect - W))
    if need <= 16:
        return img, 0
    # the sheet: the bright, flat plateau across the middle rows, containing the image centre
    mid = img[y0 + int(H * 0.38): y0 + int(H * 0.62)]
    prof = luminance(mid.astype(np.float32)).mean(axis=0)
    bright = prof > prof.max() * 0.82
    cx = img.shape[1] // 2
    l = cx
    while l > 0 and bright[l - 1]:
        l -= 1
    r = cx
    while r < len(bright) - 1 and bright[r + 1]:
        r += 1
    inset = int((r - l) * 0.20)          # stay clear of the roller shadows at the plateau's ends
    l, r = l + inset, r - inset
    c = (l + r) // 2
    # NOT mirrored. A mirror pair is perfectly continuous, but it prints the parchment's texture
    # as a Rorschach butterfly around the seam, and that symmetry is visible at 1024 and still
    # faintly at 512. Instead, unmirrored plateau slices are joined with linear crossfades; the
    # texture is low-contrast noise, so a crossfade is invisible, and nothing is symmetric.
    # The plateau columns [l, r) are replaced by a band (r - l) + need wide, built two ways and
    # blended by row:
    #   STRETCH  the plateau resized horizontally. Perfect for the rows above and below the sheet
    #            (a smooth glow gradient stretches invisibly) and for the sheet's ragged edges (a
    #            wave that gets a little wider still reads as parchment). Continuous at both ends
    #            by construction. Useless for the sheet's interior, where stretched grain smears.
    #   TILE     unmirrored copies of the plateau joined by 48px crossfades — invisible on the
    #            low-contrast grain, no symmetry, and its last columns fade into the plateau's own
    #            last columns so it is continuous at the right seam too.
    # Every earlier variant failed on exactly one of these: a mirror printed a butterfly, a plain
    # crossfade ghosted the edges, a hard cut stepped the gradient.
    Wm = (r - l) + need
    P = img[:, l:r].astype(np.float32)
    bg = cv2.resize(P, (Wm, img.shape[0]), interpolation=cv2.INTER_LINEAR)
    # Frequency separation. The sheet is lit from one side, so every tiled copy of the plateau
    # carried its own left-to-right brightness ramp and the band came out as faint vertical
    # stripes. Split the plateau: the LOW frequencies (the lighting) are stretched once across the
    # whole band, and only the HIGH frequencies (the grain) are tiled — grain has no direction.
    lp = cv2.GaussianBlur(P, (0, 0), 30)
    hp = P - lp
    lp_band = cv2.resize(lp, (Wm, img.shape[0]), interpolation=cv2.INTER_LINEAR)
    f = 48
    ramp = np.linspace(0, 1, f, dtype=np.float32)[None, :, None]
    xf = lambda A, B: A * (1 - ramp) + B * ramp
    Q = hp
    while Q.shape[1] < Wm + f:
        Q = np.concatenate([Q[:, :-f], xf(Q[:, -f:], hp[:, :f]), hp[:, f:]], axis=1)
    grain = np.concatenate([Q[:, :Wm - f], xf(Q[:, Wm - f:Wm], hp[:, -f:])], axis=1)
    tex = lp_band + grain
    rows = np.where(luminance(P).mean(axis=1) > 100)[0]
    top_edge, bot_edge = int(rows.min()), int(rows.max())
    m = int((bot_edge - top_edge) * 0.06)
    y = np.arange(img.shape[0], dtype=np.float32)
    row_w = smoothstep(top_edge + m, top_edge + 3 * m, y) * (1 - smoothstep(bot_edge - 3 * m, bot_edge - m, y))
    mid = bg * (1 - row_w[:, None, None]) + tex * row_w[:, None, None]
    out = np.concatenate([img[:, :l].astype(np.float32), mid, img[:, r:].astype(np.float32)], axis=1)
    return np.clip(out, 0, 255).astype(np.uint8), need


def grade(img):
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    L = lab[:, :, 0].astype(np.float32) / 255
    Lg = np.power(L, 1 / 1.32)                                   # open the midtones, keep the highlights
    clahe = cv2.createCLAHE(clipLimit=1.5, tileGridSize=(8, 8))
    Lc = clahe.apply((Lg * 255).astype(np.uint8)).astype(np.float32) / 255
    lab[:, :, 0] = np.clip((0.68 * Lg + 0.32 * Lc) * 255, 0, 255).astype(np.uint8)
    out = cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)

    hsv = cv2.cvtColor(out, cv2.COLOR_BGR2HSV).astype(np.float32)
    h, s = hsv[:, :, 0], hsv[:, :, 1]
    gold = smoothstep(6, 12, h) * (1 - smoothstep(30, 38, h))     # OpenCV hue 0-180: ~12°-70°
    hsv[:, :, 1] = np.clip(s * (1 + 0.32 * gold), 0, 255)
    out = cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2BGR).astype(np.float32)

    out[:, :, 2] = out[:, :, 2] * 1.05 + 3      # R up
    out[:, :, 1] = out[:, :, 1] * 1.00 + 1
    out[:, :, 0] = out[:, :, 0] * 0.90          # B down: warmth
    return np.clip(out, 0, 255).astype(np.uint8)


def compose(mark, fill):
    mh, mw = mark.shape[:2]
    scale = (S * fill) / max(mh, mw)
    interp = cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC
    mark = cv2.resize(mark, (int(round(mw * scale)), int(round(mh * scale))), interpolation=interp)
    mh, mw = mark.shape[:2]
    markf = mark.astype(np.float32) / 255

    # luma key: the scroll is opaque, the photo's dark ground is not
    lum = luminance(markf)
    lum = cv2.GaussianBlur(lum, (0, 0), 1.2)
    alpha = smoothstep(0.045, 0.20, lum)
    # elliptical falloff so nothing survives at the artwork's rectangle edge
    yy, xx = np.mgrid[0:mh, 0:mw]
    nx, ny = (xx - mw / 2) / (mw / 2), (yy - mh / 2) / (mh / 2)
    alpha = alpha * smoothstep(0, 1, (1.32 - np.sqrt(nx * nx + ny * ny)) / 0.40)

    canvas = np.empty((S, S, 3), np.float32)
    canvas[:] = GROUND_BGR
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.hypot(xx - S / 2, yy - S / 2)
    g = smoothstep(0, 1, (S * 0.52 - d) / (S * 0.32))           # radial amber bloom
    glow = np.stack([34 / 255 * g, 104 / 255 * g, 150 / 255 * g], axis=2)
    canvas = 1 - (1 - canvas) * (1 - glow)

    x, y = (S - mw) // 2, (S - mh) // 2
    a = alpha[:, :, None]
    region = canvas[y:y + mh, x:x + mw]
    canvas[y:y + mh, x:x + mw] = region * (1 - a) + markf * a
    return (np.clip(canvas, 0, 1) * 255).round().astype(np.uint8)


def at_size(master, s):
    if s == S:
        return master
    im = cv2.resize(master, (s, s), interpolation=cv2.INTER_AREA)
    amount = 0.60 if s <= 60 else 0.48 if s <= 90 else 0.36 if s <= 180 else 0.16
    blur = cv2.GaussianBlur(im, (0, 0), 0.7 if s <= 90 else 1.0)
    return cv2.addWeighted(im, 1 + amount, blur, -amount, 0)


def maskable(master, s, pad=0.10):
    inner = int(round(s * (1 - 2 * pad)))
    im = at_size(master, inner)
    out = np.empty((s, s, 3), np.uint8)
    out[:] = (GROUND_BGR * 255).round().astype(np.uint8)
    o = (s - inner) // 2
    out[o:o + inner, o:o + inner] = im
    return out


def write(path, img):
    assert img.ndim == 3 and img.shape[2] == 3, 'every icon must be 3-channel — no alpha'
    cv2.imwrite(path, img, [cv2.IMWRITE_PNG_COMPRESSION, 9])
    return os.path.getsize(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('source')
    ap.add_argument('--fill', type=float, default=0.86)
    ap.add_argument('--no-widen', action='store_true')
    a = ap.parse_args()

    src = cv2.imread(a.source, cv2.IMREAD_COLOR)
    if src is None:
        sys.exit(f'cannot read {a.source}')
    box = mark_box(src)
    print(f'  source {src.shape[1]}x{src.shape[0]}  mark box {box}  aspect h/w {(box[3]-box[1])/(box[2]-box[0]):.2f}')
    if not a.no_widen:
        src, added = widen(src, box, 1.0)
        box = mark_box(src)
        print(f'  widened by {added}px -> mark box {box}  aspect h/w {(box[3]-box[1])/(box[2]-box[0]):.2f}')
    x0, y0, x1, y1 = box
    pad = int(0.012 * max(x1 - x0, y1 - y0))
    crop = src[max(0, y0 - pad): y1 + pad, max(0, x0 - pad): x1 + pad]
    master = compose(grade(crop), a.fill)

    ios_dir = os.path.join(ROOT, 'ship/ios/pwa-shell/Assets.xcassets/AppIcon.appiconset')
    web_dir = os.path.join(ROOT, 'app/public/icons')
    ui_dir = os.path.join(ROOT, 'ui-screens/icon')
    for d in (web_dir, ui_dir):
        os.makedirs(d, exist_ok=True)

    print('  iOS asset catalog:')
    for name, s in [('1024.png', 1024), ('20@2x.png', 40), ('20@3x.png', 60), ('29@2x.png', 58), ('29@3x.png', 87),
                    ('40@2x.png', 80), ('40@3x.png', 120), ('60@2x.png', 120), ('60@3x.png', 180)]:
        print(f'    {name:<12} {s:>4}px  {write(os.path.join(ios_dir, name), at_size(master, s))} bytes')
    print('  PWA + web:')
    for name, s in [('icon-192.png', 192), ('icon-512.png', 512), ('apple-touch-icon.png', 180)]:
        print(f'    {name:<24} {s:>4}px  {write(os.path.join(web_dir, name), at_size(master, s))} bytes')
    print(f'    {"icon-maskable-512.png":<24}  512px  {write(os.path.join(web_dir, "icon-maskable-512.png"), maskable(master, 512))} bytes')
    write(os.path.join(ui_dir, 'after-1024.png'), master)
    print('  master -> ui-screens/icon/after-1024.png')


if __name__ == '__main__':
    main()
