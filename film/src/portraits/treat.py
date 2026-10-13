"""Treated portraits from the real app frames in the repo.

Heroes become 4:5 card portraits; the others become face-only rounds for the fly-past. Each source is
cropped from a real Scroll Anytime screen (feed frame, clip poster or rabbi avatar), upscaled with
EDSR (OpenCV dnn_superres), then given one shared treatment: warm low-contrast grade, soft vignette,
fine grain. Writes assets/portraits/<slug>_card.png and <slug>_face.png + portraits.json.
"""
import json, os, sys
import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
S = os.path.join(ROOT, 'assets/src/screens')
OUT = os.path.join(ROOT, 'assets/portraits')
os.makedirs(OUT, exist_ok=True)

# (slug, display name, source, crop box x0,y0,x1,y1 in source pixels, role)
PORTRAITS = [
    # heroes: composed frames, eyes open (community review: no mid-word, no closed eyes, no grimace)
    ('ovadia', 'Rabbi Ovadia Yosef', 'audit/13-A-seder.png', (187, 150, 611, 680), 'hero'),
    ('joey-haber', 'Rabbi Joey Haber', 'audit/02-A-scroll-1.png', (105, 336, 543, 884), 'hero'),
    ('farhi', 'Rabbi Shlomo Farhi', '54-search-results.png', (37, 1000, 257, 1275), 'hero'),
    # fly-past, faces only: (cx, cy, half-size) around the detected face
    ('harari', 'Rabbi Yaakov Harari', '19-saves-scoped-feed.png', (233 + 160, 454 + 195, 290), 'face'),
    ('galimidi', 'Rabbi Yosef Galimidi', '46-ob-rabbis.png', (355 + 34, 337 + 40, 66), 'face'),
    ('mansour', 'Rabbi Eli Mansour', '15-rabbis-list-bottom.png', (180 + 26, 428 + 34, 60), 'face'),
    ('zeytouneh', 'Rabbi Eliezer Zeytouneh', '15-rabbis-list-bottom.png', (553 + 22, 433 + 26, 56), 'face'),
    ('moshe-haber', 'Rabbi Moshe Haber', '14-rabbis-list.png', (548 + 22, 1314 + 31, 58), 'face'),
]

sr = {}
def upscale(img, factor):
    k = 4 if factor > 2.2 else 2
    if k not in sr:
        m = cv2.dnn_superres.DnnSuperResImpl_create()
        m.readModel(os.path.join(ROOT, f'assets/models/EDSR_x{k}.pb'))
        m.setModel('edsr', k)
        sr[k] = m
    return sr[k].upsample(img)

def treat(img, seed):
    f = img.astype(np.float32) / 255.0
    # warm, slightly lifted blacks, gentle S
    f = f ** np.array([1.0, 1.02, 1.08], np.float32)[None, None, ::-1]  # BGR: cool channel gets the most gamma
    f = 0.035 + f * 0.95
    f = f + 0.06 * (f - cv2.GaussianBlur(f, (0, 0), 6))                    # local contrast after the upscale
    lum = f.mean(axis=2, keepdims=True)
    f = lum + (f - lum) * 0.86                                              # a little less saturation
    h, w = f.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    r = np.sqrt(((xx - w / 2) / (w / 2)) ** 2 + ((yy - h * 0.45) / (h / 2)) ** 2)
    f *= (1 - 0.28 * np.clip(r - 0.55, 0, 1) ** 1.6)[..., None]
    rng = np.random.default_rng(seed)
    g = cv2.GaussianBlur(rng.normal(0, 1, (h, w)).astype(np.float32), (0, 0), 0.7)
    f += (g * 0.018)[..., None]
    return np.clip(f * 255, 0, 255).astype(np.uint8)

meta = []
for i, (slug, name, src, box, role) in enumerate(PORTRAITS):
    im = cv2.imread(os.path.join(S, src))
    if role == 'hero':
        x0, y0, x1, y1 = box
        crop = im[y0:y1, x0:x1]
        tw, th = 1000, 1250
    else:
        cx, cy, hs = box
        crop = im[max(0, cy - hs):cy + hs, max(0, cx - hs):cx + hs]
        tw = th = 720
    factor = tw / crop.shape[1]
    dst = os.path.join(OUT, f'{slug}_{"card" if role == "hero" else "face"}.png')
    if os.path.exists(dst) and '--force' not in sys.argv:
        meta.append({'slug': slug, 'name': name, 'role': role, 'source': src, 'box': box,
                     'source_px': [int(crop.shape[1]), int(crop.shape[0])], 'upscale': round(factor, 2)})
        continue
    up = upscale(crop, factor) if factor > 1.6 else crop
    out = cv2.resize(up, (tw, th), interpolation=cv2.INTER_AREA if up.shape[1] > tw else cv2.INTER_CUBIC)
    out = treat(out, 100 + i)
    cv2.imwrite(os.path.join(OUT, f'{slug}_{"card" if role == "hero" else "face"}.png'), out)
    meta.append({'slug': slug, 'name': name, 'role': role, 'source': src, 'box': box,
                 'source_px': [int(crop.shape[1]), int(crop.shape[0])], 'upscale': round(factor, 2)})
    print(f'{slug:12s} {role:5s} src {crop.shape[1]}x{crop.shape[0]} -> {tw}x{th} ({factor:.1f}x)')
json.dump(meta, open(os.path.join(OUT, 'portraits.json'), 'w'), indent=1)
