"""7.0-11.0: the rabbanim. Hero cards in thick bevelled gold frames (warm key, soft shadow, a light
sweep across the glass, a 6% push over the hold, slide off as the next arrives, name at 92 px
beneath), then the other portraits flying past at three depths with parallax and bokeh, faces only,
each exactly once, and "Scroll Anytime" rising at 10.3 at 120 px."""
import functools, json, os, sys
import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'src/type'))
sys.path.insert(0, os.path.join(ROOT, 'src'))
import typeset as T
import layout as LY

TL = json.load(open(os.path.join(ROOT, 'spec/timeline.json')))
PT = TL['portraits']
W, H = LY.W, LY.H
PORT = os.path.join(ROOT, 'assets/portraits')
META = {m['slug']: m for m in json.load(open(os.path.join(PORT, 'portraits.json')))}
HERO_SLUGS = ['ovadia', 'joey-haber', 'farhi']
HERO_NAMES = {'ovadia': ('Rabbi Ovadia Yosef', 'zt\u201dl'), 'joey-haber': ('Rabbi Joey Haber', ''), 'farhi': ('Rabbi Shlomo Farhi', '')}

CARD_W = int(round(1080 * PT['card_width_frac'] * LY.CARD_S))   # 778 on the master: 72% of the frame width
FRAME_T = int(round(40 * LY.CARD_S))
PW = CARD_W - 2 * FRAME_T                              # 702
PH = int(round(PW * 1.25))                             # 878
CARD_H = PH + 2 * FRAME_T
CARD_CY = LY.y(735)


def smooth(a, b, x):
    x = np.clip((x - a) / (b - a), 0, 1)
    return x * x * (3 - 2 * x)


def ease_out(x):
    x = min(max(x, 0.0), 1.0)
    return 1 - (1 - x) ** 3


def ease_in(x):
    x = min(max(x, 0.0), 1.0)
    return x ** 3


def ease_io(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * x * (x * (6 * x - 15) + 10)


def _rr_sdf(w, h, r, ss=2):
    """Signed distance (px, positive inside) to a rounded rect of size w x h, sampled at ss x."""
    ys, xs = np.mgrid[0:h * ss, 0:w * ss].astype(np.float32)
    xs = (xs + 0.5) / ss; ys = (ys + 0.5) / ss
    qx = np.abs(xs - w / 2) - (w / 2 - r)
    qy = np.abs(ys - h / 2) - (h / 2 - r)
    out = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2) + np.minimum(np.maximum(qx, qy), 0) - r
    return -out


@functools.lru_cache(maxsize=1)
def gold_frame():
    """Bevelled gold frame as premultiplied RGBA (CARD_H x CARD_W). Height-field shading."""
    ss = 2
    outer = _rr_sdf(CARD_W, CARD_H, 22, ss)
    inner_w, inner_h = PW, PH
    ys, xs = np.mgrid[0:CARD_H * ss, 0:CARD_W * ss].astype(np.float32)
    xs = (xs + 0.5) / ss - FRAME_T; ys = (ys + 0.5) / ss - FRAME_T
    qx = np.abs(xs - inner_w / 2) - (inner_w / 2 - 6)
    qy = np.abs(ys - inner_h / 2) - (inner_h / 2 - 6)
    inner = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2) + np.minimum(np.maximum(qx, qy), 0) - 6  # + outside inner
    ring = (outer > 0) & (inner > 0)
    u = np.clip(outer / (outer + np.maximum(inner, 1e-3)), 0, 1)
    # ogee profile: outer bead, cove, high ridge, step, inner lip
    h = (0.55 * smooth(0.0, 0.12, u) - 0.22 * np.exp(-((u - 0.30) / 0.07) ** 2) + 0.55 * np.exp(-((u - 0.58) / 0.13) ** 2)
         - 0.30 * smooth(0.78, 0.86, u) + 0.18 * np.exp(-((u - 0.93) / 0.03) ** 2))
    h = h * FRAME_T * ss * 0.55
    gx = cv2.Sobel(h, cv2.CV_32F, 1, 0, ksize=3) / 8
    gy = cv2.Sobel(h, cv2.CV_32F, 0, 1, ksize=3) / 8
    n = np.stack([-gx, -gy, np.ones_like(h)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    L = np.array([-0.45, -0.65, 0.62], np.float32); L /= np.linalg.norm(L)
    V = np.array([0, 0, 1], np.float32)
    Hh = (L + V); Hh /= np.linalg.norm(Hh)
    diff = np.clip(n @ L, 0, 1)
    spec = np.clip(n @ Hh, 0, 1) ** 46
    env = 0.5 + 0.5 * (-n[..., 1])                     # brighter facets face up (sky), darker face down
    shadow = np.array([22, 50, 84], np.float32) / 255     # deep warm brown-gold, BGR
    base = np.array([75, 162, 201], np.float32) / 255     # #C9A24B
    hi = np.array([122, 200, 227], np.float32) / 255      # #E3C87A
    k = np.clip(0.10 + 0.85 * diff + 0.25 * env - 0.15, 0, 1)[..., None]
    col = shadow[None, None] * (1 - k) + base[None, None] * k + hi[None, None] * spec[..., None] * 0.9
    # fine brushed grain
    rng = np.random.default_rng(9)
    col *= (1 + 0.035 * cv2.GaussianBlur(rng.normal(0, 1, h.shape).astype(np.float32), (0, 0), 0.7))[..., None]
    a = np.clip(np.minimum(outer, inner) * 1.0 + 0.5, 0, 1) * ring
    a = cv2.resize(a.astype(np.float32), (CARD_W, CARD_H), interpolation=cv2.INTER_AREA)
    col = cv2.resize(col.astype(np.float32), (CARD_W, CARD_H), interpolation=cv2.INTER_AREA)
    rgba = np.concatenate([np.clip(col, 0, 1.0) * a[..., None], a[..., None]], -1)
    return rgba.astype(np.float32)


@functools.lru_cache(maxsize=4)
def card(slug):
    """Full card: portrait (warm key, glass sheen, inner shadow) inside the gold frame. RGBA premul."""
    im = cv2.imread(os.path.join(PORT, f'{slug}_card.png')).astype(np.float32) / 255
    im = cv2.resize(im, (PW, PH), interpolation=cv2.INTER_AREA)
    ys, xs = np.mgrid[0:PH, 0:PW].astype(np.float32)
    key = 0.80 + 0.32 * np.exp(-(((xs - PW * 0.22) / (PW * 0.8)) ** 2 + ((ys - PH * 0.18) / (PH * 0.8)) ** 2))
    warm = np.array([0.90, 0.98, 1.06], np.float32)    # BGR: warm key
    im = im * key[..., None] * warm
    sheen = np.clip(1 - (xs / PW * 0.6 + ys / PH * 0.9), 0, 1) ** 3 * 0.04
    im = im + sheen[..., None]
    # exposure cap and a soft shoulder: a white beard must never clip (verification pass)
    lum = im @ np.array([0.0722, 0.7152, 0.2126], np.float32)
    p99 = float(np.percentile(lum, 99))
    if p99 > 0.86:
        im = im * (0.86 / p99)
    k0 = 0.68
    over = np.maximum(im - k0, 0)
    im = np.minimum(im, k0) + over / (1 + over / 0.26)
    # inner shadow from the frame lip
    d = np.minimum.reduce([xs, ys, PW - 1 - xs, PH - 1 - ys])
    im *= (0.55 + 0.45 * smooth(0, 26, d))[..., None]
    rgba = np.zeros((CARD_H, CARD_W, 4), np.float32)
    rgba[FRAME_T:FRAME_T + PH, FRAME_T:FRAME_T + PW, :3] = np.clip(im, 0, 1.2)
    rgba[FRAME_T:FRAME_T + PH, FRAME_T:FRAME_T + PW, 3] = 1
    fr = gold_frame()
    rgba = rgba * (1 - fr[..., 3:4]) + fr
    return rgba


@functools.lru_cache(maxsize=1)
def card_shadow():
    pad = int(140 * LY.CARD_S) + 4
    a = np.zeros((CARD_H + 2 * pad, CARD_W + 2 * pad), np.float32)
    a[pad + int(30 * LY.CARD_S):pad + CARD_H + int(40 * LY.CARD_S), pad + 10:pad + CARD_W - 10] = 1
    a = cv2.GaussianBlur(a, (0, 0), 42 * LY.CARD_S) * 0.78
    rgba = np.zeros(a.shape + (4,), np.float32)
    rgba[..., 3] = a
    return rgba, pad


def sweep_layer(u):
    """Diagonal light sweep across the glass, u in 0..1."""
    ys, xs = np.mgrid[0:PH, 0:PW].astype(np.float32)
    p = (xs / PW * 0.8 + ys / PH * 0.6) / 1.4
    c = -0.25 + 1.5 * u
    band = np.exp(-((p - c) / 0.07) ** 2) * 0.22 + np.exp(-((p - c + 0.11) / 0.025) ** 2) * 0.10
    return band


@functools.lru_cache(maxsize=8)
def name_layers(slug):
    name, suffix = HERO_NAMES[slug]
    main = T.text_layer(name, 'display', LY.px(92), T.CREAM)
    suf = T.text_layer(suffix, 'display', LY.px(54), T.CREAM) if suffix else None
    return main, suf


def draw_card(dst, slug, cx, cy, scale, opacity, sweep_u=None, name_op=1.0, layer='all'):
    rgba = card(slug).copy() if layer != 'type' else card(slug)
    if layer != 'type' and sweep_u is not None and 0 < sweep_u < 1:
        b = sweep_layer(sweep_u)
        rgba[FRAME_T:FRAME_T + PH, FRAME_T:FRAME_T + PW, :3] += b[..., None] * np.array([0.85, 0.95, 1.0], np.float32)
    s = scale
    if layer in ('all', 'image'):
        sh, pad = card_shadow()
        shs = T.scaled(sh, s)
        T.over(dst, shs, cx - shs.shape[1] / 2, cy - shs.shape[0] / 2 + 26 * s * LY.CARD_S, opacity)
        cs = T.scaled(rgba, s)
        T.over(dst, cs, cx - cs.shape[1] / 2, cy - cs.shape[0] / 2, opacity)
    if layer == 'image':
        return
    # the name beneath, with the honorific after it
    (main, suf) = name_layers(slug)
    rgba_m, base_m, wm = main
    base_y = cy + (CARD_H / 2) * s + LY.px(122)
    T.over(dst, rgba_m, cx - wm / 2 - 8, base_y - base_m, opacity * name_op)
    if suf:
        T.over(dst, suf[0], cx - suf[2] / 2 - 8, base_y + LY.px(70) - suf[1], opacity * name_op)


def hero_state(k, t):
    """(x offset in frame widths, scale, opacity, sweep u, name opacity) for hero k, or None.
    Card k is fully in place at its 'arrive' time. The change to the next card is a carousel move:
    both cards slide left together, one frame width apart, so no card ever covers another."""
    heroes = PT['heroes']
    tin = PT['hero_in']
    a = heroes[k]['arrive']
    leave = heroes[k + 1]['arrive'] - tin if k + 1 < len(heroes) else PT['flypast_t0'] - tin
    start = a if k == 0 else a - tin
    if t < start or t > leave + tin:
        return None
    if k == 0 and t < a + tin:                    # out of the white flare: settle into place
        u = (t - a) / tin
        x, s, op = 0.0, 1.10 - 0.10 * ease_out(u), min(1.0, 0.35 + u * 2.5)
    elif t < a:                                   # sliding in from the right
        u = (t - start) / tin
        x, s, op = 1.0 - ease_io(u), 1.0, 1.0
    else:
        x, s, op = 0.0, 1.0, 1.0
    s *= 1.0 + PT['push'] * ease_io(min(max((t - a) / max(0.3, leave - a), 0), 1.0))
    if t > leave:                                 # leaving to the left
        x = -ease_io((t - leave) / tin)
    sweep_u = (t - a - 0.10) / 0.62
    name_op = 1.0
    if t < a:
        name_op = 0.0
    elif t < a + 0.12:
        name_op = (t - a) / 0.12
    if t > leave:
        name_op = max(0.0, 1 - (t - leave) / 0.08)
    return x, s, op, sweep_u, name_op


# ----------------------------------------------------------------------------- fly-past
FLY = [  # slug, depth (0 near .. 2 far), x0, y, start, end, drift px/s (leftward)
    ('harari', 0, 760, 640, 9.70, 10.62, 200),
    ('zeytouneh', 2, 250, 1300, 9.76, 11.00, 90),
    ('galimidi', 1, 820, 1290, 9.84, 10.95, 150),
    ('mansour', 1, 230, 330, 10.00, 11.00, 120),
    ('moshe-haber', 2, 880, 290, 10.10, 11.00, 80),
]
DEPTH = {0: dict(d=int(400 * LY.CARD_S), blur=0.0, bright=1.0), 1: dict(d=int(300 * LY.CARD_S), blur=0.6 * LY.CARD_S, bright=0.9), 2: dict(d=int(220 * LY.CARD_S), blur=1.3 * LY.CARD_S, bright=0.75)}


@functools.lru_cache(maxsize=16)
def face_disc(slug, depth):
    D = DEPTH[depth]['d']
    im = cv2.imread(os.path.join(PORT, f'{slug}_face.png')).astype(np.float32) / 255
    h0, w0 = im.shape[:2]
    m0 = int(min(h0, w0) * 0.86)                     # inside any avatar edge: the photo fills the circle
    y0, x0 = (h0 - m0) // 2, (w0 - m0) // 2
    im = cv2.resize(im[y0:y0 + m0, x0:x0 + m0], (D, D), interpolation=cv2.INTER_AREA)
    ys, xs = np.mgrid[0:D, 0:D].astype(np.float32)
    r = np.sqrt((xs - D / 2 + 0.5) ** 2 + (ys - D / 2 + 0.5) ** 2) / (D / 2)
    a = np.clip((1 - r) * D * 0.06, 0, 1) * smooth(1.0, 0.82, r) ** 0.5
    ring = np.exp(-((r - 0.975) / 0.018) ** 2) * 0.9
    col = im * DEPTH[depth]['bright'] * (0.85 + 0.25 * np.exp(-(((xs - D * 0.3) / D) ** 2 + ((ys - D * 0.25) / D) ** 2)))[..., None]
    col = col * (1 - ring[..., None]) + ring[..., None] * np.array([0.38, 0.70, 0.86], np.float32)
    rgba = np.concatenate([col * a[..., None], a[..., None]], -1).astype(np.float32)
    if DEPTH[depth]['blur'] > 0:
        rgba = cv2.GaussianBlur(rgba, (0, 0), DEPTH[depth]['blur'])
    return rgba


def motion_blur_x(rgba, px):
    k = int(px) | 1
    if k < 3:
        return rgba
    return cv2.blur(rgba, (k, 1))


@functools.lru_cache(maxsize=1)
def bokeh_field():
    rng = np.random.default_rng(77)
    pts = []
    for depth, n in ((0, 8), (1, 12), (2, 22)):
        for _ in range(n):
            pts.append(dict(depth=depth, x=rng.uniform(-200, W + 600), y=rng.uniform(80, H - 80),
                            r=[46, 30, 18][depth] * LY.CARD_S * rng.uniform(0.7, 1.3), a=[0.10, 0.12, 0.16][depth] * rng.uniform(0.5, 1.2)))
    return pts


@functools.lru_cache(maxsize=64)
def bokeh_disc(r):
    D = int(r * 2 + 8)
    ys, xs = np.mgrid[0:D, 0:D].astype(np.float32)
    d = np.sqrt((xs - D / 2) ** 2 + (ys - D / 2) ** 2)
    a = np.clip(r - d + 0.5, 0, 1) * (0.7 + 0.3 * np.clip(d / r, 0, 1) ** 4)
    a = cv2.GaussianBlur(a, (0, 0), 1.2)
    return a


def draw_bokeh(dst, t, strength):
    gold = np.array([0.42, 0.76, 0.95], np.float32)
    speed = {k: v * W / 1080 for k, v in {0: 520, 1: 300, 2: 150}.items()}
    for p in bokeh_field():
        x = (p['x'] - speed[p['depth']] * (t - 7.0)) % (W + 800) - 300
        a = bokeh_disc(max(4.0, round(p['r'], 0)))
        D = a.shape[0]
        x0, y0 = int(x - D / 2), int(p['y'] - D / 2)
        xa, ya, xb, yb = max(0, x0), max(0, y0), min(W, x0 + D), min(H, y0 + D)
        if xb <= xa or yb <= ya:
            continue
        dst[ya:yb, xa:xb] += a[ya - y0:yb - y0, xa - x0:xb - x0, None] * gold * p['a'] * strength


def draw_flypast(dst, t, fps=30):
    """Each face drifts left at its depth's speed (parallax), grows 6% toward camera, fades in and
    out, and stays wholly inside the frame. No motion smear on a face."""
    for slug, depth, x0, y, t0, t1, v in sorted(FLY, key=lambda f: -f[1]):
        if not (t0 <= t <= t1):
            continue
        u = (t - t0) / (t1 - t0)
        op = min(1.0, (t - t0) / 0.18, 1.0 if t1 >= 11.0 else (t1 - t) / 0.2)
        sc = 0.94 + 0.12 * u
        rgba = T.scaled(face_disc(slug, depth), sc)
        x = LY.x(x0) if LY.ASPECT != '16x9' else W / 2 + (x0 - 540) * 1.6
        x -= v * (W / 1080) * (t - t0)
        D = rgba.shape[1]
        x = min(max(x, D / 2 + 12), W - D / 2 - 12)
        T.over(dst, rgba, x - D / 2, LY.y(y) - rgba.shape[0] / 2, op)


@functools.lru_cache(maxsize=1)
def title_layers():
    tl = T.text_layer(PT['title']['text'], 'display', LY.px(PT['title']['px']), T.CREAM)
    g = T.glow(np.pad(tl[0], ((40, 40), (40, 40), (0, 0))), 18, T.GLOW, 0.55)
    return tl, g


def draw_title(dst, t, cx=W / 2, baseline=LY.y(1000)):
    t0 = PT['title']['t']
    if t < t0:
        return
    u = ease_out((t - t0) / 0.28)
    (rgba, base, w), g = title_layers()
    y = baseline + LY.px(40) * (1 - u)
    # a soft dark scrim keeps the title clean over faces
    scr_h = LY.px(260)
    ys = np.arange(scr_h, dtype=np.float32)
    band = np.exp(-((ys - scr_h / 2) / (scr_h / 3.2)) ** 2) * 0.55 * u
    y0 = int(y - base * 0.65 - scr_h / 2)
    ya, yb = max(0, y0), min(H, y0 + scr_h)
    dst[ya:yb] *= (1 - band[ya - y0:yb - y0, None, None])
    T.add(dst, g, cx - g.shape[1] / 2, y - base - 40, u)
    T.over(dst, rgba, cx - rgba.shape[1] / 2, y - base, u)


def render(dst, t, fps=30, layer='all'):
    """dst: background (already the darkened, defocused H4), float BGR. layer='image' draws bokeh,
    faces and cards; 'type' draws the names and the title (after the bloom); 'all' draws both."""
    if layer in ('all', 'image'):
        draw_bokeh(dst, t, 0.6 + 0.8 * smooth(PT['flypast_t0'] - 0.3, PT['flypast_t0'] + 0.3, t))
        if t >= PT['flypast_t0']:
            draw_flypast(dst, t, fps)
    for k, slug in enumerate(HERO_SLUGS):
        st = hero_state(k, t)
        if st is None:
            continue
        x, s, op, su, nop = st
        if layer in ('all', 'image'):
            draw_card(dst, slug, W / 2 + x * W * 1.02, CARD_CY, s, op, su, nop, 'image')
        if layer in ('all', 'type'):
            draw_card(dst, slug, W / 2 + x * W * 1.02, CARD_CY, s, op, su, nop, 'type')
    if layer in ('all', 'type'):
        draw_title(dst, t)
    return dst
