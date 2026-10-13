"""Keying, face and portrait checks on the rendered master frames (work/frames) and the plates.

1. no pixel of green hue above 0.4 saturation within 40 px of any screen
2. screen-corner acceleration under 1.5 px/frame^2 (smoothed tracks)
3. no face detected in any plate outside the composited screens (and the portraits section, which
   uses no plate people at all)
4. no duplicate portraits: every rabbi appears once in the portrait section, and no two portrait
   images are perceptually the same
Prints a human report, or with --json a JSON list of {name, ok, detail}.
"""
import glob, json, os, sys
import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'src'))
sys.path.insert(0, os.path.join(ROOT, 'src/portraits'))
TL = json.load(open(os.path.join(ROOT, 'spec/timeline.json')))
FPS = TL['fps']
SEG = {'H1': (0, 42), 'H2': (42, 90), 'H3': (90, 204), 'H5': (330, 420), 'H6': (510, 600)}
res = []


def check(name, ok, detail=''):
    res.append({'name': name, 'ok': bool(ok), 'detail': detail})


def plate_dir(shot):
    g = os.path.join(ROOT, 'work/plates_gen', shot)
    return g if os.path.isdir(g) else os.path.join(ROOT, 'work/plates', shot)


def quad_mask(shape, q, dilate=0):
    m = np.zeros(shape[:2], np.uint8)
    cv2.fillConvexPoly(m, np.round(np.array(q) * 16).astype(np.int32), 255, cv2.LINE_AA, 4)
    if dilate:
        m = cv2.dilate(m, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * dilate + 1,) * 2))
    return m


# 1 + 2 ------------------------------------------------------------------------------------
worst_green, worst_where = 0, ''
max_acc, acc_where = 0.0, ''
for shot, (a, b) in SEG.items():
    tr = json.load(open(os.path.join(plate_dir(shot), 'track.json')))
    sm = np.array(tr['smoothed'])                                   # n,4,2
    acc = np.linalg.norm(sm[2:] - 2 * sm[1:-1] + sm[:-2], axis=2)  # n-2,4
    if acc.size and acc.max() > max_acc:
        max_acc = float(acc.max())
        k = np.unravel_index(acc.argmax(), acc.shape)
        acc_where = f'{shot} frame {k[0] + 1} corner {k[1]}'
    for i in range(a, b):
        f = os.path.join(ROOT, 'work/frames', f'{i:04d}.png')
        if not os.path.exists(f):
            continue
        im = cv2.imread(f)
        q = sm[min(i - a, len(sm) - 1)]
        inner = quad_mask(im.shape, q, 0)
        ring = (quad_mask(im.shape, q, 40) > 0) & (quad_mask(im.shape, q, 1) == 0)    # around the screen, not the composited content
        hsv = cv2.cvtColor(im, cv2.COLOR_BGR2HSV)
        h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
        green = (h >= 38) & (h <= 82) & (s > 0.4 * 255) & (v > 0.08 * 255) & ring
        n = int(green.sum())
        if n > worst_green:
            worst_green, worst_where = n, f'{shot} frame {i}'
check('no green (hue 75-165°, sat > 0.4) within 40 px of any screen', worst_green == 0,
      f'worst {worst_green} px at {worst_where}' if worst_green else 'every keyed frame checked')
check('screen-corner acceleration < 1.5 px/frame²', max_acc < 1.5, f'max {max_acc:.3f} px/frame² ({acc_where})')

# 3 ----------------------------------------------------------------------------------------
det = cv2.FaceDetectorYN.create(os.path.join(ROOT, 'assets/models/face_detection_yunet_2023mar.onnx'), '', (320, 320), 0.6, 0.3, 50)
hits = []
for shot in ('H1', 'H2', 'H3', 'H4', 'H5', 'H6'):
    d = plate_dir(shot)
    fs = sorted(glob.glob(os.path.join(d, 'frames', '*.png')))
    trp = os.path.join(d, 'track.json')
    tr = json.load(open(trp)) if os.path.exists(trp) and shot != 'H4' else None
    for k in range(0, len(fs), 3):
        im = cv2.imread(fs[k])
        if tr is not None:
            q = tr['smoothed'][min(k, tr['n'] - 1)]
            im[quad_mask(im.shape, q, 6) > 0] = 0                    # the screen is composited content
        det.setInputSize((im.shape[1], im.shape[0]))
        _, faces = det.detect(im)
        if faces is not None and len(faces):
            hits.append(f'{shot}#{k} score {faces[0][-1]:.2f}')
check('no face in any plate outside the composited screens', not hits, ', '.join(hits[:8]) or f'YuNet over every 3rd frame of all six plates')

# 4 ----------------------------------------------------------------------------------------
import section
slugs = [s for s in section.HERO_SLUGS] + [f[0] for f in section.FLY]
dupes = sorted({s for s in slugs if slugs.count(s) > 1})
check('every rabbi appears once in the portrait section', not dupes, f'{len(slugs)} portraits: ' + ', '.join(slugs) + (f'; dupes {dupes}' if dupes else ''))


def dhash(p, n=16):
    g = cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2GRAY)
    g = cv2.resize(g, (n + 1, n), interpolation=cv2.INTER_AREA)
    return (g[:, 1:] > g[:, :-1]).flatten()


paths = [os.path.join(ROOT, 'assets/portraits', f'{s}_card.png') for s in section.HERO_SLUGS] + \
        [os.path.join(ROOT, 'assets/portraits', f'{f[0]}_face.png') for f in section.FLY]
hs = [dhash(p) for p in paths]
close = []
for i in range(len(hs)):
    for j in range(i + 1, len(hs)):
        d = int((hs[i] != hs[j]).sum())
        if d < 40:
            close.append(f'{os.path.basename(paths[i])}~{os.path.basename(paths[j])} ({d})')
check('no two portrait images are perceptually the same (dHash distance >= 40/256)', not close, ', '.join(close) or 'all pairs distinct')
expected = 7
check(f'the fly-past carries {expected} portraits', len(section.FLY) == expected,
      f'{len(section.FLY)} — the repo holds only {len(section.FLY)} rabbis beyond the three heroes (see PRODUCTION_LOG B4)')

if '--json' in sys.argv:
    print(json.dumps(res))
else:
    for r in res:
        print(('PASS ' if r['ok'] else 'FAIL ') + r['name'] + ('  — ' + r['detail'] if r['detail'] else ''))
