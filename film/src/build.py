"""Assemble the film: plates (generated if present in assets/plates, else the coded fallbacks), the
keyed screens, the rabbanim, type, grade and finish, then encode with the mix.

  python3 src/build.py [--frames a:b] [--jobs 4] [--no-encode] [--tag pass1]
"""
import argparse, functools, glob, json, os, subprocess, sys, time
from multiprocessing import Pool
import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for d in ('src/key', 'src/content', 'src/portraits', 'src/type'):
    sys.path.insert(0, os.path.join(ROOT, d))
import layout as LY
import keyer, screens, section, typeset as T

TL = json.load(open(os.path.join(ROOT, 'spec/timeline.json')))
FPS = TL['fps']
W, H = LY.W, LY.H
NF = int(round(TL['duration'] * FPS))
WORK = os.path.join(ROOT, 'work')
OUTF = os.path.join(WORK, 'frames' + LY.SUFFIX)


# ------------------------------------------------------------------------------- plates
def plate_source(shot):
    """Generated plate wins over the coded fallback."""
    gen = os.path.join(ROOT, 'assets/plates', f'{shot}{LY.SUFFIX}.mp4')
    if os.path.exists(gen):
        d = os.path.join(WORK, 'plates_gen' + LY.SUFFIX, shot, 'frames')
        if not glob.glob(os.path.join(d, '*.png')):
            os.makedirs(d, exist_ok=True)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', gen, '-vf', f'fps={FPS},scale={W}:{H}:flags=lanczos',
                            os.path.join(d, '%04d.png')], check=True)
            for k, f in enumerate(sorted(glob.glob(os.path.join(d, '*.png')))):
                os.rename(f, os.path.join(d, f'{k:04d}.png'))
        return 'generated', os.path.dirname(d)
    return 'fallback', os.path.join(WORK, 'plates' + LY.SUFFIX, shot)


@functools.lru_cache(maxsize=8)
def plate_frames(shot):
    kind, d = plate_source(shot)
    return kind, sorted(glob.glob(os.path.join(d, 'frames', '*.png'))), d


def plate_frame(shot, k):
    _, fs, _ = plate_frames(shot)
    return cv2.imread(fs[min(max(k, 0), len(fs) - 1)])


@functools.lru_cache(maxsize=8)
def track(shot):
    _, fs, d = plate_frames(shot)
    p = os.path.join(d, 'track.json')
    if os.path.exists(p) and os.path.getmtime(p) > max(os.path.getmtime(f) for f in fs[:1] + fs[-1:]):
        return json.load(open(p))
    res = keyer.track(fs, shot)
    json.dump(res, open(p, 'w'))
    return res


# ------------------------------------------------------------------------------- grade: match H4
def _stats(img, mask=None):
    f = img.astype(np.float32) / 255
    lum = f @ np.array([0.0722, 0.7152, 0.2126], np.float32)
    keep = np.ones(lum.shape, bool) if mask is None else (mask == 0)
    black = float(np.percentile(lum[keep], 1.0))
    mid = keep & (lum > 0.12) & (lum < 0.85)
    warm = float((f[..., 2] - f[..., 0])[mid].mean()) if mid.sum() > 500 else 0.0
    return black, warm


@functools.lru_cache(maxsize=1)
def grade_params():
    p = os.path.join(WORK, f'grade{LY.SUFFIX}.json')
    out = {}
    tb, tw = None, None
    for shot in ('H4', 'H1', 'H2', 'H3', 'H5', 'H6'):
        _, fs, _ = plate_frames(shot)
        if not fs:
            continue
        samples = [cv2.imread(fs[k]) for k in np.linspace(0, len(fs) - 1, 5).astype(int)]
        st = [_stats(s, keyer.screen_mask(s) if shot != 'H4' else None) for s in samples]
        b, w = float(np.mean([s[0] for s in st])), float(np.mean([s[1] for s in st]))
        if shot == 'H4':
            tb, tw = b, w
        out[shot] = {'black': b, 'warm': w}
    for shot in out:
        out[shot]['target_black'] = tb
        out[shot]['target_warm'] = tw
        out[shot]['warm_shift'] = float(np.clip(tw - out[shot]['warm'], -0.09, 0.09))
    json.dump(out, open(p, 'w'), indent=1)
    return out


def grade(img, shot):
    g = grade_params()[shot]
    f = img.astype(np.float32) / 255
    if shot == 'H4':
        return f
    b, tb = g['black'], g['target_black']
    f = (f - b) / max(1e-3, 1 - b) * (1 - tb) + tb
    lum = f @ np.array([0.0722, 0.7152, 0.2126], np.float32)
    m = np.clip(lum * 2.2, 0, 1) * np.clip((1 - lum) * 3, 0, 1)      # midtones carry the warmth
    ds = g['warm_shift'] * m
    f[..., 2] += ds / 2
    f[..., 0] -= ds / 2
    return np.clip(f, 0, 1)


# ------------------------------------------------------------------------------- finishing
def defocus(img, radius, scale=2):
    small = cv2.resize(img, (W // scale, H // scale), interpolation=cv2.INTER_AREA)
    r = max(1, int(round(radius / scale)))
    k = np.zeros((2 * r + 1, 2 * r + 1), np.float32)
    cv2.circle(k, (r, r), r, 1.0, -1, cv2.LINE_AA)
    k /= k.sum()
    small = cv2.filter2D(small, -1, k)
    return cv2.resize(small, (W, H), interpolation=cv2.INTER_LINEAR)


def bloom(img, strength=0.35, thresh=0.72, sigma=28):
    lum = img.max(2)
    hi = img * np.clip((lum - thresh) / (1 - thresh), 0, 1)[..., None]
    s = cv2.resize(hi, (W // 4, H // 4), interpolation=cv2.INTER_AREA)
    s = cv2.GaussianBlur(s, (0, 0), sigma / 4)
    return img + cv2.resize(s, (W, H), interpolation=cv2.INTER_LINEAR) * strength


@functools.lru_cache(maxsize=1)
def vignette():
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    r = np.sqrt(((xs - W / 2) / (W / 2)) ** 2 * 0.8 + ((ys - H / 2) / (H / 2)) ** 2)
    return (1 - 0.16 * np.clip(r - 0.45, 0, 1) ** 1.5 / 0.84 ** 1.5)[..., None].astype(np.float32)


def grain(img, i):
    rng = np.random.default_rng(10_000 + i)
    n = cv2.GaussianBlur(rng.normal(0, 1, (H, W)).astype(np.float32), (0, 0), 0.8) * 0.0285   # 1.0% luma after the 0.8 px blur
    return img + n[..., None]


def finish(img, i, bloom_strength=0.35):
    img = bloom(img, bloom_strength)
    img = img * vignette()
    img = grain(img, i)
    return img


# ------------------------------------------------------------------------------- type helpers
CAPS = [(1.4, 2.95, 'You were going to scroll tonight anyway.', 'low'), (4.0, 5.5, 'So we changed what\u2019s on it.', 'low'),
        (8.05, 9.05, 'The rabbanim you grew up on.', 'low'), (9.05, 9.62, 'In your pocket.', 'low'), (11.6, 12.95, 'Every day.', 'high')]


def caption(dst, t):
    for t0, t1, text, where in CAPS:
        if t0 <= t < t1:
            op = min(1.0, (t - t0) / 0.15, (t1 - t) / 0.15)
            band = band_layer()
            base = LY.y(1540) if where == 'low' else LY.y(330)
            y0 = int(base - LY.y(170))
            ya, yb = max(0, y0), min(H, y0 + band.shape[0])
            dst[ya:yb] *= (1 - band[ya - y0:yb - y0] * op)
            lines = [text]
            if T.measure(text, 'ui', LY.px(52))[0] > W - 2 * LY.x(110):
                words_ = text.split(' ')
                cut = min(range(1, len(words_)), key=lambda k: abs(len(' '.join(words_[:k])) - len(text) / 2))
                lines = [' '.join(words_[:cut]), ' '.join(words_[cut:])]
            for n, ln in enumerate(lines):
                lay = T.text_layer(ln, 'ui', LY.px(52), T.CREAM)
                T.centered(dst, lay, W / 2, base - (len(lines) - 1 - n) * LY.px(66), op)


@functools.lru_cache(maxsize=1)
def band_layer():
    n = int(LY.y(310))
    ys = np.arange(n, dtype=np.float32) / n
    return (np.sin(np.pi * ys) ** 0.8 * 0.58)[:, None, None].astype(np.float32)


@functools.lru_cache(maxsize=1)
def gold_rule():
    return T.rule(LY.px(160), max(2, LY.px(3)))


def name_with_rule(dst, name, op, baseline=LY.y(1300), rule_u=1.0):
    if op <= 0 or not name:
        return
    main = T.text_layer(name, 'display', LY.px(92), T.CREAM)
    T.over(dst, main[0], W / 2 - main[2] / 2 - 8, baseline - main[1], op)
    if 'Ovadia' in name:
        s = T.text_layer('zt\u201dl', 'display', LY.px(54), T.CREAM)
        T.over(dst, s[0], W / 2 - s[2] / 2 - 8, baseline + LY.px(70) - s[1], op)
    r, g, pad = gold_rule()
    full = LY.px(160)
    rw = max(2, int(full * rule_u))
    r2 = cv2.resize(r, (rw + 2 * pad, r.shape[0])) if rw != full else r
    g2 = cv2.resize(g, (rw + 2 * pad, g.shape[0])) if rw != full else g
    ry = baseline - LY.px(92) * 0.72 - LY.px(30)
    T.add(dst, g2, W / 2 - r2.shape[1] / 2, ry - pad, op)
    T.over(dst, r2, W / 2 - r2.shape[1] / 2, ry - pad, op)


# ------------------------------------------------------------------------------- segments
_prev_quads = {}


def keyed(shot, k, content, pulse=0.0):
    raw = plate_frame(shot, k)
    tr = track(shot)
    q = np.array(tr['smoothed'][min(k, tr['n'] - 1)])
    pq = np.array(tr['smoothed'][max(0, min(k, tr['n'] - 1) - 1)]) if k > 0 else None
    graded = grade(raw, shot)
    out, alpha = keyer.composite(raw, content, q, pq, rng=np.random.default_rng(k), extra_glow=0.15 * pulse, plate_color=graded)
    # the 40 px ring outside the screen, kept free of green through bloom (see render)
    hard = (alpha > 0.5).astype(np.uint8)
    dist = cv2.distanceTransform(1 - hard, cv2.DIST_L2, 5)
    _ring[0] = (dist <= 42) & (hard == 0)
    return out.astype(np.float32) / 255


_ring = [None]


def clamp_green_ring(img):
    if _ring[0] is not None:
        r = _ring[0]
        img[..., 1] = np.where(r, np.minimum(img[..., 1], np.maximum(img[..., 0], img[..., 2])), img[..., 1])


@functools.lru_cache(maxsize=4)
def today_frame(k):
    return cv2.imread(os.path.join(WORK, 'content/today', f'{k:04d}.png'))


WHITE = np.array([1.0, 1.0, 1.0], np.float32)


def render(i, loop=True):
    t = i / FPS
    bloom_s = 0.35
    type_fx = []
    flash = 0.0
    if t < 1.4:                                                   # H1
        c, info = screens.scroll_frame(t)
        img = keyed('H1', i, c)
        def clock(im):
            lay = T.text_layer(TL['h1']['clock_text'], 'display', LY.px(TL['h1']['clock_px']), T.WHITE, TL['h1']['clock_alpha'])
            T.over(im, lay[0], LY.x(72) - 8, LY.y(290) - lay[1], 1.0)
        type_fx.append(clock)
    elif t < 3.0:                                                 # H2
        c, info = screens.scroll_frame(t)
        img = keyed('H2', i - 42, c)
    elif t < 6.8:                                                 # H3
        c, info = screens.montage_frame(t)
        img = keyed('H3', i - 90, c, info['pulse'])
        plan = screens.montage_plan()
        for s_ in plan[:3]:
            sw = 0 if s_['kind'] == 'ovadia' else min(TL['h3']['swipe_max'], (s_['t1'] - s_['t0']) * TL['h3']['swipe_frac'])
            a = s_['t0'] + sw + (0.12 if s_['kind'] == 'ovadia' else 0.0)
            if a <= t < s_['t1']:
                op = min(1.0, (t - a) / 0.12)
                ru = min(1.0, (t - a) / 0.2)
                type_fx.append(lambda im, n=s_['name'], op=op, ru=ru: name_with_rule(im, n, op, rule_u=ru))
        f0, peak = TL['h3']['flare'][0], TL['h3']['flare_peak']
        if t >= f0:
            w = min(1.0, (t - f0) / (peak - f0))
            bloom_s = 0.35 + 3.0 * w ** 1.5
            img = img * (1 - w ** 2) + WHITE * w ** 2
    elif t < 7.0:                                                 # the white, the silence
        img = np.ones((H, W, 3), np.float32)
        return np.clip(grain(img * 0.985, i), 0, 1)
    elif t < 11.0:                                                # the rabbanim over H4
        bg = grade(plate_frame('H4', i - 210), 'H4')
        img = defocus(bg, 14) * 0.70
        section.render(img, t, FPS, 'image')
        type_fx.append(lambda im, t=t: section.render(im, t, FPS, 'type'))
        u = (t - 7.0) / 0.12
        flash = 0.5 * (1 - u) ** 2 if u < 1 else 0.0
    elif t < 14.0:                                                # H5 Today
        img = keyed('H5', i - 330, today_frame(i - 330), 0.0)
    elif t < 17.0:                                                # Free. No ads. Only Torah.
        bg = grade(plate_frame('H4', 60 + (i - 420)), 'H4')
        img = defocus(bg, 34, 4) * 0.20
        type_fx.append(lambda im, t=t: words(im, t))
    else:                                                         # H6 end card
        c, info = screens.icon_frame(t)
        img = keyed('H6', i - 510, c, info['pulse'])
        type_fx.append(lambda im, t=t: endcard(im, t))
    type_fx.append(lambda im, t=t: caption(im, t))
    img = bloom(img, bloom_s)
    clamp_green_ring(img)
    _ring[0] = None
    for fx in type_fx:
        fx(img)
    if flash > 0:
        img = img + (1 - img) * flash
    img = grain(img * vignette(), i)
    lf0, lf1 = TL['endcard']['loop_fade']
    if loop and t >= lf0:
        u = (t - lf0) / (lf1 - lf0)
        u = u * u * (3 - 2 * u)
        img = img * (1 - u) + first_frame() * u
    return img


@functools.lru_cache(maxsize=1)
def first_frame():
    return render(0, loop=False)


@functools.lru_cache(maxsize=4)
def word_layers(text):
    lay = T.text_layer(text, 'display', LY.px(150), T.CREAM)
    g = T.glow(np.pad(lay[0], ((30, 30), (30, 30), (0, 0))), 16, T.GLOW, 0.35)
    return lay, g


def words(img, t):
    ws = TL['words']
    for k, w in enumerate(ws):
        t0 = w['t']
        t1 = ws[k + 1]['t'] if k + 1 < len(ws) else 17.0
        if not (t0 <= t < t1):
            continue
        u = (t - t0)
        op = min(1.0, 0.5 + u / 0.06, (t1 - t) / 0.10) if k + 1 < len(ws) else min(1.0, 0.5 + u / 0.06)
        sc = 1.10 - 0.10 * (1 - (1 - min(1, u / 0.18)) ** 3)
        lay, g = word_layers(w['text'])
        by = LY.y(1010)
        T.add(img, T.scaled(g, sc), W / 2 - T.scaled(g, sc).shape[1] / 2, by - lay[1] * sc - 30 * sc, op * 0.45)
        x, y, ww, hh = T.centered(img, lay, W / 2, by, op, None, 0, sc)
        r, gl, pad = T.rule(int(lay[2] * 0.5), max(2, LY.px(4)))
        T.add(img, gl, W / 2 - gl.shape[1] / 2, by + LY.px(42) - pad, op)
        T.over(img, r, W / 2 - r.shape[1] / 2, by + LY.px(42) - pad, op)


@functools.lru_cache(maxsize=1)
def badge():
    im = cv2.imread(os.path.join(ROOT, 'assets/brand/appstore-badge-340.png'), cv2.IMREAD_UNCHANGED).astype(np.float32) / 255
    if LY.TYPE_S != 1.0:
        im = cv2.resize(im, (int(im.shape[1] * LY.TYPE_S), int(im.shape[0] * LY.TYPE_S)), interpolation=cv2.INTER_AREA)
    a = im[..., 3:4]
    return np.concatenate([im[..., :3] * a, a], -1)


def endcard(img, t):
    ec = TL['endcard']
    o0, o1 = ec['type_out']
    out = 1.0 - min(1.0, max(0.0, (t - o0) / (o1 - o0)))
    if out <= 0:
        return
    def fade(t0, d=0.3):
        return min(1.0, max(0.0, (t - t0) / d)) * out
    u = fade(ec['title_in'], 0.35)
    if u > 0:
        (lay, base, w), g = section.title_layers()
        e = 1 - (1 - min(1.0, (t - ec['title_in']) / 0.35)) ** 3
        y = LY.y(420) + LY.px(40) * (1 - e)
        T.add(img, g, W / 2 - g.shape[1] / 2, y - base - 40, u)
        T.over(img, lay, W / 2 - lay.shape[1] / 2, y - base, u)
    u = fade(ec['badge_in'])
    if u > 0:
        b = badge()
        T.over(img, b, W / 2 - b.shape[1] / 2, LY.y(640) - b.shape[0] / 2, u)
    u = fade(ec['bio_in'])
    if u > 0:
        lay = T.text_layer('Link in bio', 'ui500', LY.px(ec['bio_px']), T.CREAM, 0.8)
        T.centered(img, lay, W / 2, LY.y(790), u)


# ------------------------------------------------------------------------------- driver
def work(i):
    img = render(i)
    out = np.clip(img * 255 + 0.5, 0, 255).astype(np.uint8)
    cv2.imwrite(os.path.join(OUTF, f'{i:04d}.png'), out, [cv2.IMWRITE_PNG_COMPRESSION, 1])
    return i


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', default=f'0:{NF}')
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--no-encode', action='store_true')
    a = ap.parse_args()
    os.makedirs(OUTF, exist_ok=True)
    s, e = (int(x) for x in a.frames.split(':'))
    # warm caches in the parent: tracks + grade (the workers reuse the json)
    log = {}
    for shot in ('H1', 'H2', 'H3', 'H5', 'H6'):
        if plate_frames(shot)[1]:
            tr = track(shot)
            log[shot] = {'source': plate_frames(shot)[0], 'fails': len(tr['fails']), 'worst_run': tr['worst_fail_run'], 'regenerate': tr['regenerate']}
    log['H4'] = {'source': plate_frames('H4')[0]}
    grade_params()
    json.dump(log, open(os.path.join(WORK, f'key_log{LY.SUFFIX}.json'), 'w'), indent=1)
    t0 = time.time()
    with Pool(a.jobs) as p:
        for k, _ in enumerate(p.imap_unordered(work, range(s, e), chunksize=4)):
            if k % 60 == 0:
                print(f'{k}/{e - s} frames, {time.time() - t0:.0f}s', flush=True)
    print('done', time.time() - t0)


if __name__ == '__main__':
    main()
