"""Screen content for every phone in the film, at the phone's native 1179x2556.

scroll_frame(t)   H1/H2: a fast, colourful, blurred, unbranded scroll of abstract colour blocks.
montage_frame(t)  H3:    Ovadia's clip (face-tracked crop of the real hero clip), then the swipes
                         through real Scroll Anytime feed frames, accelerating, then the white flare.
icon_frame(t)     H6:    the real app icon on the dark screen with the seal press.
Each returns (BGR uint8 image, info dict). info carries the spill pulse for the compositor.
"""
import json, os, functools
import cv2
import numpy as np
from scipy.signal import savgol_filter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TL = json.load(open(os.path.join(ROOT, 'spec/timeline.json')))
CW, CH = TL['screen_content_size']
SCR = os.path.join(ROOT, 'assets/src/screens')


def ease_io(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * x * (x * (6 * x - 15) + 10)


# ------------------------------------------------------------------------- H1/H2 abstract scroll
@functools.lru_cache(maxsize=1)
def _feed_strip():
    rng = np.random.default_rng(4711)
    pal = [(255, 64, 129), (255, 145, 0), (0, 200, 255), (255, 214, 0), (124, 77, 255), (0, 230, 118),
           (255, 82, 82), (64, 196, 255), (234, 128, 252), (255, 171, 64), (29, 233, 182), (255, 110, 64)]
    H = 16000
    strip = np.zeros((H, CW, 3), np.uint8)
    strip[:] = (14, 12, 16)
    y = 30
    while y < H - 1500:
        h = int(rng.integers(700, 1500))
        x0, x1 = 34, CW - 34
        a, b = rng.choice(len(pal), 2, replace=False)
        ca, cb = np.array(pal[a], np.float32), np.array(pal[b], np.float32)
        tt = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
        ss = np.linspace(0, 1, x1 - x0, dtype=np.float32)[None, :, None]
        g = ca * (1 - (tt * 0.7 + ss * 0.3)) + cb * (tt * 0.7 + ss * 0.3)
        card = g.copy()
        for _ in range(int(rng.integers(2, 5))):   # soft blobs of a third colour
            c = np.array(pal[int(rng.integers(len(pal)))], np.float32)
            cx, cy, r = rng.uniform(0, x1 - x0), rng.uniform(0, h), rng.uniform(140, 420)
            yy, xx = np.mgrid[0:h, 0:x1 - x0].astype(np.float32)
            m = np.exp(-(((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * r * r)))[..., None]
            card = card * (1 - 0.8 * m) + c * 0.8 * m
        mask = np.zeros((h, x1 - x0), np.uint8)
        cv2.rectangle(mask, (0, 0), (x1 - x0 - 1, h - 1), 255, -1)
        R = 46
        for (cx, cy) in ((R, R), (x1 - x0 - R, R), (R, h - R), (x1 - x0 - R, h - R)):
            pass
        mask[:] = 0
        cv2.rectangle(mask, (R, 0), (x1 - x0 - R, h), 255, -1)
        cv2.rectangle(mask, (0, R), (x1 - x0, h - R), 255, -1)
        for (cx, cy) in ((R, R), (x1 - x0 - R - 1, R), (R, h - R - 1), (x1 - x0 - R - 1, h - R - 1)):
            cv2.circle(mask, (cx, cy), R, 255, -1, cv2.LINE_AA)
        m = (mask.astype(np.float32) / 255)[..., None]
        bgr = card[..., ::-1]
        strip[y:y + h, x0:x1] = (strip[y:y + h, x0:x1] * (1 - m) + bgr * m).astype(np.uint8)
        # a header row of grey bars + a dot: shapes only, nothing readable
        cy = y + h + 42
        cv2.circle(strip, (x0 + 40, cy), 30, (120, 120, 130), -1, cv2.LINE_AA)
        cv2.rectangle(strip, (x0 + 92, cy - 18), (x0 + 92 + int(rng.integers(220, 460)), cy - 2), (95, 95, 105), -1)
        cv2.rectangle(strip, (x0 + 92, cy + 12), (x0 + 92 + int(rng.integers(140, 300)), cy + 24), (70, 70, 80), -1)
        y += h + 120
    return strip


def _scroll_pos(t):
    """Scroll offset in px. Flick impulses from the timeline, exponentially decaying velocity."""
    flicks = TL['h1']['flicks'] + TL['h2']['flicks']
    tau, A = 0.32, 7400.0
    base = 380.0 * t                                    # idle drift
    pos, vel = base, 380.0
    for f in flicks:
        if t > f:
            u = t - f
            pos += A * tau * (1 - np.exp(-u / tau))
            vel += A * np.exp(-u / tau)
    return pos, vel


def scroll_frame(t, fps=30):
    strip = _feed_strip()
    pos, vel = _scroll_pos(t)
    H = strip.shape[0]
    y0 = int(pos) % (H - CH)
    img = strip[y0:y0 + CH].copy()
    blur = vel / fps * 0.5                               # 180-degree shutter
    if blur > 2:
        k = int(min(blur, 900)) | 1
        img = cv2.blur(img, (1, k))
    img = cv2.GaussianBlur(img, (0, 0), 7)              # "blurred": nothing readable, ever
    return img, {'pulse': 0.0, 'vel': vel}


# ------------------------------------------------------------------------------- H3 montage
OV_TAKE = (22, 45)          # source frames 0.917-1.875 s: one clean take (cuts at 0.917 and 1.875)


@functools.lru_cache(maxsize=1)
def _ovadia_track():
    """The real hero clip, cover-cropped to the screen the way the app plays it (2x), with the
    horizontal crop tracking his face (YuNet, Savitzky-Golay smoothed)."""
    cap = cv2.VideoCapture(os.path.join(ROOT, 'assets/src/ovadia.mp4'))
    det = cv2.FaceDetectorYN.create(os.path.join(ROOT, 'assets/models/face_detection_yunet_2023mar.onnx'), '', (720, 1280), 0.6)
    frames, xs = [], []
    k = 0
    while True:
        ok, f = cap.read()
        if not ok or k >= OV_TAKE[1]:
            break
        if k >= OV_TAKE[0]:
            frames.append(f)
            _, faces = det.detect(f)
            xs.append(max(faces, key=lambda r: r[2] * r[3])[0] + max(faces, key=lambda r: r[2] * r[3])[2] / 2 if faces is not None and len(faces) else np.nan)
        k += 1
    xs = np.array(xs, np.float64)
    good = ~np.isnan(xs)
    xs = np.interp(np.arange(len(xs)), np.flatnonzero(good), xs[good])
    xs = savgol_filter(xs, 9 if len(xs) >= 9 else (len(xs) // 2) * 2 - 1, 2)
    sc = CH / 1280.0
    cw = CW / sc                                       # source width visible on screen
    x0 = np.clip(xs - cw / 2, 0, 720 - cw)
    return frames, x0, sc


def _ovadia(t_local, dur):
    """Map the slot onto the clean take (slightly slowed), blending neighbouring source frames."""
    frames, x0, sc = _ovadia_track()
    u = min(max(t_local / dur, 0), 1) * (len(frames) - 1)
    i0 = int(np.floor(u)); i1 = min(i0 + 1, len(frames) - 1); w = u - i0
    def crop(i):
        M = np.float32([[sc, 0, -x0[i] * sc], [0, sc, 0]])
        return cv2.warpAffine(frames[i], M, (CW, CH), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE)
    im = cv2.addWeighted(crop(i0), 1 - w, crop(i1), w, 0) if w > 0.01 else crop(i0)
    soft = cv2.GaussianBlur(im, (0, 0), 2.0)
    im = cv2.addWeighted(im, 1.35, soft, -0.35, 0)
    ch = _chrome()
    a = ch[..., 3:4].astype(np.float32) / 255
    return (im.astype(np.float32) * (1 - a) + ch[..., :3].astype(np.float32) * a).astype(np.uint8)


@functools.lru_cache(maxsize=1)
def _chrome():
    """The app's feed chrome (status bar, tabs, rail, progress, nav), rendered from chrome.html."""
    return cv2.imread(os.path.join(ROOT, 'work/content/chrome.png'), cv2.IMREAD_UNCHANGED)


@functools.lru_cache(maxsize=32)
def _shot(name):
    im = cv2.imread(os.path.join(SCR, name))
    h, w = im.shape[:2]
    tw = int(round(h * CW / CH))
    x0 = (w - tw) // 2
    im = cv2.resize(im[:, x0:x0 + tw], (CW, CH), interpolation=cv2.INTER_CUBIC)
    if name == 'audit/04-A-scroll-3.png':
        # the clip's own green top sits under the app header and reads as a key leak: neutralise it
        hsv = cv2.cvtColor(im[:340], cv2.COLOR_BGR2HSV)
        hsv[..., 1] = (hsv[..., 1] * 0.25).astype(np.uint8)
        im[:340] = cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR)
    return im


# real feed frames: the named rabbis, then eight more clips (all different clips)
NAMED_SRC = {'Rabbi Joey Haber': 'audit/02-A-scroll-1.png', 'Rabbi Shlomo Farhi': None}
FAST_SRC = ['01-feed-playing.png', 'audit/12-A-back-to-feed.png', '32-feed-safe-areas.png', 'cold-open-firstframe.png',
            'audit/03-A-scroll-2.png', 'audit/28-B-reload.png', 'returning-open.png', 'audit/04-A-scroll-3.png']


@functools.lru_cache(maxsize=1)
def _farhi_frame():
    """No feed frame of Farhi exists in the repo; his clip poster from My Torah is the real frame
    of his clip. Crop the poster (above its overlay labels), upscale, set full-screen."""
    p = os.path.join(ROOT, 'assets/portraits/farhi_card.png')
    im = cv2.imread(p)
    h, w = im.shape[:2]
    bg = cv2.resize(im, (CW, int(CW * h / w)), interpolation=cv2.INTER_CUBIC)
    bg = cv2.resize(bg, (int(bg.shape[1] * CH / bg.shape[0] + 1), CH))
    x0 = (bg.shape[1] - CW) // 2
    bg = cv2.GaussianBlur(bg[:, x0:x0 + CW], (0, 0), 40)
    bg = (bg.astype(np.float32) * 0.45).astype(np.uint8)
    fg = cv2.resize(im, (CW, int(CW * h / w)), interpolation=cv2.INTER_CUBIC)
    y0 = int(CH * 0.40 - fg.shape[0] / 2)
    ramp = np.ones(fg.shape[0], np.float32)
    f = 140
    ramp[:f] = np.linspace(0, 1, f) ** 1.5
    ramp[-f:] = np.linspace(1, 0, f) ** 1.5
    out = bg.astype(np.float32)
    out[y0:y0 + fg.shape[0]] = out[y0:y0 + fg.shape[0]] * (1 - ramp[:, None, None]) + fg.astype(np.float32) * ramp[:, None, None]
    return out.astype(np.uint8)


def montage_plan():
    h3 = TL['h3']
    slots = [{'kind': 'ovadia', 't0': h3['ovadia']['t0'], 't1': h3['ovadia']['t1'], 'name': 'Rabbi Ovadia Yosef'}]
    t = h3['ovadia']['t1']
    for n in h3['named']:
        slots.append({'kind': 'named', 'who': n['who'], 't0': t, 't1': t + n['dur'], 'name': n['who']})
        t += n['dur']
    for k, d in enumerate(h3['fast']):
        slots.append({'kind': 'fast', 'src': FAST_SRC[k], 't0': t, 't1': t + d, 'name': None})
        t += d
    return slots


def _slot_img(s, t):
    u = (t - s['t0']) / max(1e-6, s['t1'] - s['t0'])
    if s['kind'] == 'ovadia':
        im = _ovadia(t - s['t0'], s['t1'] - s['t0'])
    elif s['kind'] == 'named':
        im = _shot(NAMED_SRC[s['who']]) if NAMED_SRC.get(s['who']) else _farhi_frame()
    else:
        im = _shot(s['src'])
    z = 1.0 + 0.035 * min(max(u, 0), 1.5)               # a slow push keeps stills alive
    if abs(z - 1) > 1e-3:
        M = cv2.getRotationMatrix2D((CW / 2, CH * 0.42), 0, z)
        im = cv2.warpAffine(im, M, (CW, CH), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    return im


def montage_frame(t, fps=30):
    h3 = TL['h3']
    slots = montage_plan()
    f0, f1 = h3['flare']
    tt = min(t, f0)
    cur = next((i for i, s in enumerate(slots) if s['t0'] <= tt < s['t1']), len(slots) - 1)
    s = slots[cur]
    dur = s['t1'] - s['t0']
    sw = min(h3['swipe_max'], dur * h3['swipe_frac']) if cur > 0 else 0
    u = (tt - s['t0']) / sw if sw > 0 else 1.0
    pulse = 0.0
    if u < 1.0:
        e = ease_io(u)
        prev = _slot_img(slots[cur - 1], tt)
        nxt = _slot_img(s, tt)
        off = int(round(e * CH))
        img = np.zeros_like(nxt)
        img[:CH - off] = prev[off:]
        img[CH - off:] = nxt[:off]
        # velocity of the swipe (px/frame) -> vertical motion blur
        de = (ease_io(min(1, u + 1 / (fps * sw))) - e) * CH
        k = int(min(abs(de) * 0.5, 400)) | 1
        if k > 2:
            img = cv2.blur(img, (1, k))
        pulse = np.sin(np.pi * u)
    else:
        img = _slot_img(s, tt)
    lt = _lower_third_amount(t)
    if lt > 0:
        img = (img.astype(np.float32) * (1 - _lower_third() * lt)).astype(np.uint8)
    if t >= f0:                                         # the flare: the screen goes white
        w = ease_io((t - f0) / (f1 - f0))
        img = (img.astype(np.float32) * (1 - w) + 255 * w).astype(np.uint8)
        pulse = max(pulse, 2.5 * w)
    return img, {'pulse': float(pulse), 'slot': cur, 'name': s['name'] if u >= 0.5 or cur == 0 else slots[cur - 1]['name']}


@functools.lru_cache(maxsize=1)
def _lower_third():
    y = np.linspace(0, 1, CH, dtype=np.float32)
    g = np.clip((y - 0.44) / 0.20, 0, 1) ** 1.3 * 0.95
    return g[:, None, None]


def _lower_third_amount(t):
    """On while the names and the 'So we changed' caption sit over the screen (3.0-5.6)."""
    a, b = 3.0, 5.6
    if t < a or t > b:
        return 0.0
    return float(min(1.0, (b - t) / 0.18))


# ------------------------------------------------------------------------------- H6 icon seal
@functools.lru_cache(maxsize=1)
def _icon():
    ic = cv2.imread(os.path.join(ROOT, 'assets/brand/appicon-1024.png'), cv2.IMREAD_UNCHANGED)
    if ic.shape[2] == 4:
        ic = ic[..., :3]
    return ic


def icon_frame(t):
    """t = film time. The real icon, iOS superellipse mask, the seal press at endcard.seal_press."""
    ec = TL['endcard']
    img = np.zeros((CH, CW, 3), np.float32)
    yy, xx = np.mgrid[0:CH, 0:CW].astype(np.float32)
    r = np.sqrt(((xx - CW / 2) / CW) ** 2 + ((yy - CH * 0.46) / CW) ** 2)
    img += np.clip(0.10 - r * 0.09, 0, 1)[..., None] * np.array([0.30, 0.52, 0.78], np.float32)  # warm ground, BGR
    u = t - ec['seal_press']
    # press: down 0.12 s, hold 0.06, release with a little overshoot
    if u < 0:
        s = 1.0
    elif u < 0.12:
        s = 1 - 0.09 * ease_io(u / 0.12)
    elif u < 0.18:
        s = 0.91
    else:
        v = (u - 0.18) / 0.5
        s = 0.91 + 0.09 * (1 + 0.12 * np.sin(min(v, 1) * np.pi) ) if v < 1 else 1.0
        s = min(s, 1.03)
    size = int(CW * 0.62 * s)
    ic = cv2.resize(_icon(), (size, size), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
    m = np.zeros((size, size), np.float32)
    n = 5.0                                            # superellipse, iOS-like
    a = np.linspace(-1, 1, size, dtype=np.float32)
    X, Y = np.meshgrid(a, a)
    m = ((np.abs(X) ** n + np.abs(Y) ** n) <= 1).astype(np.float32)
    m = cv2.GaussianBlur(m, (0, 0), 1.0)
    cx, cy = CW // 2, int(CH * 0.46)
    x0, y0 = cx - size // 2, cy - size // 2
    # contact shadow tightens as it presses
    sh = np.zeros((CH, CW), np.float32)
    cv2.rectangle(sh, (x0 + 30, y0 + 60), (x0 + size - 30, y0 + size + 40), 1.0, -1)
    sh = cv2.GaussianBlur(sh, (0, 0), 50 * s) * (0.75 if u < 0 else 0.55)
    img *= (1 - 0.8 * sh[..., None])
    roi = img[y0:y0 + size, x0:x0 + size]
    img[y0:y0 + size, x0:x0 + size] = roi * (1 - m[..., None]) + ic * m[..., None]
    # gold ripple from the press
    if 0.10 < u < 1.1:
        v = (u - 0.10) / 1.0
        rad = size * 0.5 * (1.05 + 0.9 * ease_io(v))
        ring = np.zeros((CH, CW), np.float32)
        cv2.circle(ring, (cx, cy), int(rad), 1.0, int(10 + 18 * (1 - v)), cv2.LINE_AA)
        ring = cv2.GaussianBlur(ring, (0, 0), 6 + 10 * v) * (1 - v) ** 1.5
        gold = np.array([75, 162, 201], np.float32) / 255     # #C9A24B in BGR
        img += ring[..., None] * gold * 1.6
    glow = 0.0 if u < 0.1 else max(0.0, 1 - (u - 0.1) / 0.9)
    return np.clip(img * 255, 0, 255).astype(np.uint8), {'pulse': float(glow)}


if __name__ == '__main__':
    import sys
    os.makedirs(os.path.join(ROOT, 'work/content_test'), exist_ok=True)
    for t in (0.1, 0.35, 0.9, 2.1):
        cv2.imwrite(os.path.join(ROOT, f'work/content_test/scroll_{t:.2f}.jpg'), scroll_frame(t)[0])
    for t in (3.2, 4.3, 4.9, 5.5, 6.0, 6.5, 6.7):
        im, info = montage_frame(t)
        cv2.imwrite(os.path.join(ROOT, f'work/content_test/montage_{t:.2f}.jpg'), im)
        print(t, info)
    for t in (17.0, 17.42, 17.7):
        cv2.imwrite(os.path.join(ROOT, f'work/content_test/icon_{t:.2f}.jpg'), icon_frame(t)[0])
