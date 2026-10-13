"""Screen keyer and compositor, per the film spec.

track(plate_frames)  -> per-frame quad (raw, validated, Savitzky-Golay smoothed) + failure log
composite(plate, content, quad, ...) -> the plate with the content keyed onto its screen

Per frame:
  1. HSV threshold for the green screen, cleaned with a small open/close.
  2. Largest contour -> approxPolyDP to four sides (epsilon widened until it is four).
  3. Sub-pixel corners: a robust line fit (cv2.fitLine, Huber) on each side's straight middle,
     corners = intersections of adjacent side lines. The screen's corners are rounded, so there is
     no pixel corner for cornerSubPix to lock onto; the side lines are what define the rectangle.
  4. Validation against the previous accepted quad: area change > 8% or a lost corner (fewer than
     four sides, or a corner on the frame edge) holds the previous smoothed quad and is logged.
     More than 6 failures in a row flags the plate for regeneration.
  5. Savitzky-Golay over time (window 9, order 2) on every corner coordinate.
Compositing: content (1179x2556) warped into the quad with a 1.5 px feathered edge; despill (G
clamped to max(R,B)) within 24 px of the screen, and again within 40 px after the light spill; a glass layer at 4% (blurred, flipped plate);
light spill (content mean colour, 60 px blur, 15%) falling off with distance from the screen; plate
grain and motion blur matched on the content.
"""
import json
import cv2
import numpy as np
from scipy.signal import savgol_filter

H_LO, H_HI = 40, 85            # OpenCV hue (0..179): ~80..170 degrees
S_MIN, V_MIN = 0.45 * 255, 0.30 * 255


def screen_mask(bgr):
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    m = cv2.inRange(hsv, (H_LO, S_MIN, V_MIN), (H_HI, 255, 255))
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, k)
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, k)
    return m


def _intersect(l1, l2):
    (vx1, vy1, x1, y1), (vx2, vy2, x2, y2) = l1, l2
    A = np.array([[vx1, -vx2], [vy1, -vy2]], np.float64)
    b = np.array([x2 - x1, y2 - y1], np.float64)
    if abs(np.linalg.det(A)) < 1e-9:
        return None
    s = np.linalg.solve(A, b)[0]
    return np.array([x1 + s * vx1, y1 + s * vy1])


def detect_quad(bgr):
    """Return (corners[4,2] float or None, reason)."""
    h, w = bgr.shape[:2]
    m = screen_mask(bgr)
    cs, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not cs:
        return None, 'no green'
    c = max(cs, key=cv2.contourArea)
    if cv2.contourArea(c) < 400:
        return None, 'green too small'
    peri = cv2.arcLength(c, True)
    approx = None
    for eps in (0.02, 0.03, 0.04, 0.05, 0.065, 0.08):
        a = cv2.approxPolyDP(c, eps * peri, True)
        if len(a) == 4:
            approx = a.reshape(4, 2).astype(np.float64)
            break
    if approx is None:
        return None, 'not four-sided'
    pts = c.reshape(-1, 2).astype(np.float64)
    # index of the contour point nearest each approx corner
    idx = [int(np.argmin(((pts - p) ** 2).sum(1))) for p in approx]
    order = np.argsort(idx)
    idx = [idx[i] for i in order]
    approx = approx[order]
    n = len(pts)
    lines = []
    for k in range(4):
        i0, i1 = idx[k], idx[(k + 1) % 4]
        seg = pts[i0:i1 + 1] if i1 > i0 else np.vstack([pts[i0:], pts[:i1 + 1]])
        L = len(seg)
        if L < 12:
            return None, 'side too short'
        trim = int(L * 0.18)           # drop the rounded corners at both ends
        core = seg[trim:L - trim]
        lines.append(cv2.fitLine(core.astype(np.float32), cv2.DIST_HUBER, 0, 0.01, 0.01).reshape(4))
    corners = []
    for k in range(4):
        p = _intersect(lines[(k - 1) % 4], lines[k])
        if p is None:
            return None, 'parallel sides'
        corners.append(p)
    corners = np.array(corners)
    if (corners[:, 0] < 2).any() or (corners[:, 0] > w - 3).any() or (corners[:, 1] < 2).any() or (corners[:, 1] > h - 3).any():
        return None, 'corner off frame'
    return corners, 'ok'


def order_tl(corners):
    """Cyclic order starting at the corner nearest the frame's top-left, clockwise on screen."""
    c = corners.mean(0)
    ang = np.arctan2(corners[:, 1] - c[1], corners[:, 0] - c[0])
    cw = corners[np.argsort(ang)]                       # image coords: increasing angle = clockwise
    start = int(np.argmin(cw.sum(1)))
    return np.roll(cw, -start, axis=0)


def match_order(corners, prev):
    c = order_tl(corners)
    if prev is None:
        return c
    best = min(range(4), key=lambda r: ((np.roll(c, -r, 0) - prev) ** 2).sum())
    return np.roll(c, -best, 0)


def area(q):
    return 0.5 * abs(np.dot(q[:, 0], np.roll(q[:, 1], 1)) - np.dot(q[:, 1], np.roll(q[:, 0], 1)))


def track(frames, name='plate', log=None, init_order=None):
    """frames: list of BGR images (or paths). Returns dict with raw/accepted/smoothed corners + log."""
    raw, reasons = [], []
    prev = init_order
    for f in frames:
        im = cv2.imread(f) if isinstance(f, str) else f
        q, why = detect_quad(im)
        if q is not None:
            q = match_order(q, prev)
            prev = q
        raw.append(q)
        reasons.append(why)
    n = len(raw)
    acc = [None] * n
    fails, run, worst_run = [], 0, 0
    last = None
    for i, q in enumerate(raw):
        bad = None
        if q is None:
            bad = reasons[i]
        elif last is not None and abs(area(q) / area(last) - 1) > 0.08:
            bad = f'area jump {100 * (area(q) / area(last) - 1):+.1f}%'
        if bad:
            fails.append({'frame': i, 'reason': bad})
            run += 1
            worst_run = max(worst_run, run)
            acc[i] = None
        else:
            run = 0
            acc[i] = q
            last = q
    # fill gaps for the filter with the previous accepted quad (or the next one at the head)
    filled, lastq = [], None
    first_ok = next((q for q in acc if q is not None), None)
    if first_ok is None:
        raise RuntimeError(f'{name}: no frame keyed')
    for q in acc:
        lastq = q if q is not None else (lastq if lastq is not None else first_ok)
        filled.append(lastq)
    arr = np.array(filled)                                 # n,4,2
    win = min(9, n if n % 2 == 1 else n - 1)
    sm = savgol_filter(arr, win, 2, axis=0, mode='interp') if win >= 5 else arr.copy()
    # a failed frame holds the previous smoothed quad
    for i in range(n):
        if acc[i] is None and i > 0:
            sm[i] = sm[i - 1]
    res = {'name': name, 'n': n, 'raw': [None if q is None else q.tolist() for q in raw],
           'smoothed': sm.tolist(), 'fails': fails, 'worst_fail_run': worst_run,
           'regenerate': worst_run > 6}
    if log is not None:
        log.append({'plate': name, 'frames': n, 'fails': len(fails), 'worst_run': worst_run,
                    'regenerate': worst_run > 6, 'detail': fails[:20]})
    return res


# ------------------------------------------------------------------------------- compositing
def _poly_mask(shape, quad, dilate=0):
    m = np.zeros(shape[:2], np.uint8)
    cv2.fillConvexPoly(m, np.round(quad * 16).astype(np.int32), 255, lineType=cv2.LINE_AA, shift=4)
    if dilate:
        m = cv2.dilate(m, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * dilate + 1, 2 * dilate + 1)))
    return m


def plate_grain(bgr, screen):
    """Noise std of the plate outside the screen (high-pass, robust)."""
    g = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
    hp = g - cv2.GaussianBlur(g, (0, 0), 1.2)
    outside = hp[(screen == 0)]
    if outside.size == 0:
        return 0.0
    return float(1.4826 * np.median(np.abs(outside - np.median(outside))))


def motion_blur(img, v, shutter=0.5):
    L = float(np.hypot(*v)) * shutter
    if L < 1.0:
        return img
    k = int(np.ceil(L)) | 1
    ker = np.zeros((k, k), np.float32)
    c = k // 2
    d = np.array(v, np.float64) / (np.hypot(*v) + 1e-9)
    for t in np.linspace(-L / 2, L / 2, max(3, k * 2)):
        x, y = int(round(c + d[0] * t)), int(round(c + d[1] * t))
        if 0 <= x < k and 0 <= y < k:
            ker[y, x] = 1
    ker /= ker.sum()
    return cv2.filter2D(img, -1, ker)


def composite(plate, content, quad, prev_quad=None, rng=None, glass=0.04, spill=0.15,
              despill_px=24, feather=1.5, spill_blur=60, extra_glow=0.0, plate_color=None):
    """plate: HxWx3 uint8 BGR (keyed); plate_color: optional float 0..1 graded copy that supplies the
    colour; content: 2556x1179x3 uint8 BGR (or float 0..1); quad: 4x2 TL,TR,BR,BL."""
    H, W = plate.shape[:2]
    quad = np.asarray(quad, np.float64)
    p = plate.astype(np.float32) / 255.0
    near = _poly_mask(plate.shape, quad, dilate=12)
    green = screen_mask(plate)
    # soft key inside the quad: green-difference matte
    d = p[..., 1] - np.maximum(p[..., 0], p[..., 2])
    key = np.clip((d - 0.12) / 0.45, 0, 1) * (near > 0)
    hard = ((key > 0.5) | ((_poly_mask(plate.shape, quad, dilate=0) > 0) & (green > 0))).astype(np.float32)
    alpha = cv2.GaussianBlur(hard, (0, 0), feather / 2.0)
    alpha = np.maximum(alpha * (near > 0), key * (alpha > 0.02))
    if plate_color is not None:
        p = plate_color.astype(np.float32).copy()
    # despill within despill_px of the screen
    dist = cv2.distanceTransform((hard < 0.5).astype(np.uint8), cv2.DIST_L2, 5)
    zone = dist <= despill_px
    mrb = np.maximum(p[..., 0], p[..., 2])
    g = p[..., 1]
    p[..., 1] = np.where(zone, np.minimum(g, mrb), g)
    # content into the quad
    c = content.astype(np.float32) / 255.0 if content.dtype == np.uint8 else content
    edge = max(np.linalg.norm(quad[0] - quad[1]), np.linalg.norm(quad[1] - quad[2]), np.linalg.norm(quad[2] - quad[3]), np.linalg.norm(quad[3] - quad[0]))
    ch, cw = c.shape[:2]
    s = min(1.0, (edge * 1.5) / max(ch, cw))
    if s < 1.0:
        c = cv2.resize(c, (max(2, int(cw * s)), max(2, int(ch * s))), interpolation=cv2.INTER_AREA)
    ch2, cw2 = c.shape[:2]
    src = np.array([[0, 0], [cw2, 0], [cw2, ch2], [0, ch2]], np.float32)
    M = cv2.getPerspectiveTransform(src, quad.astype(np.float32))
    warped = cv2.warpPerspective(c, M, (W, H), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_CONSTANT)
    warped = np.clip(warped, 0, 1)
    if prev_quad is not None:
        v = (quad - np.asarray(prev_quad)).mean(0)
        warped = motion_blur(warped, v)
    if rng is not None:
        sd = plate_grain(plate, green) / 255.0
        if sd > 0.002:
            warped = warped + rng.normal(0, sd, warped.shape[:2]).astype(np.float32)[..., None]
    # glass: blurred, flipped plate at 4%, screen-blended over the content
    gl = cv2.GaussianBlur(cv2.flip(p, -1), (0, 0), 18)
    scr = 1 - (1 - warped) * (1 - gl * glass)
    a3 = alpha[..., None]
    out = p * (1 - a3) + scr * a3
    # light spill: content mean colour, blurred 60 px from the screen, 15%, falling off with distance
    if spill > 0:
        m = warped.reshape(-1, 3)[alpha.reshape(-1) > 0.5]
        col = m.mean(0) if len(m) else np.zeros(3, np.float32)
        small = cv2.resize(alpha, (W // 4, H // 4), interpolation=cv2.INTER_AREA)
        fall = cv2.GaussianBlur(small, (0, 0), spill_blur / 4.0)
        fall = cv2.resize(fall, (W, H), interpolation=cv2.INTER_LINEAR)
        fall = fall / (fall.max() + 1e-6)
        light = (spill + extra_glow) * fall[..., None] * col[None, None, :]
        out = out + light * (0.25 + out) * (1 - a3)
    # second despill after the spill: within 40 px of the screen nothing outside it may go green
    zone2 = (dist <= 40) & (alpha < 0.5)
    out[..., 1] = np.where(zone2, np.minimum(out[..., 1], np.maximum(out[..., 0], out[..., 2])), out[..., 1])
    return np.clip(out * 255, 0, 255).astype(np.uint8), alpha


if __name__ == '__main__':
    import sys, glob, os
    plate_dir = sys.argv[1]
    frames = sorted(glob.glob(os.path.join(plate_dir, 'frames', '*.png')))
    log = []
    res = track(frames, os.path.basename(plate_dir.rstrip('/')), log)
    json.dump(res, open(os.path.join(plate_dir, 'track.json'), 'w'))
    gt_path = os.path.join(plate_dir, 'corners.json')
    if os.path.exists(gt_path):
        gt = np.array([f['corners'] for f in json.load(open(gt_path))['frames']])
        sm = np.array(res['smoothed'])
        err = np.linalg.norm(sm - gt, axis=2)
        print(f'{res["name"]}: {res["n"]} frames, fails {len(res["fails"])}, worst run {res["worst_fail_run"]}, '
              f'corner error vs ground truth mean {err.mean():.2f}px max {err.max():.2f}px')
    else:
        print(json.dumps(log, indent=1))
