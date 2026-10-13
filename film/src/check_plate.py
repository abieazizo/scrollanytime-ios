"""Machine-checkable rejection rules for a Higgsfield still or plate.

  python3 src/check_plate.py <still.png | plate.mp4> [...]

Checks: a single green screen that is uniform #00FF00-ish (no reflection, UI or text), all four
corners inside the frame, no face anywhere (YuNet), and for video: the screen keys on every frame,
with no area jump over 8% and no run of more than 6 failures. Hands, readable text and melting
geometry still need a human look. Exit code 1 if anything fails."""
import json, os, subprocess, sys, tempfile
import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'src/key'))
import keyer

det = cv2.FaceDetectorYN.create(os.path.join(ROOT, 'assets/models/face_detection_yunet_2023mar.onnx'), '', (320, 320), 0.6, 0.3, 50)


def still_checks(im):
    out = []
    q, why = keyer.detect_quad(im)
    out.append(('four-sided green screen, corners inside the frame', q is not None, why))
    m = keyer.screen_mask(im)
    if q is not None:
        inner = np.zeros(m.shape, np.uint8)
        cv2.fillConvexPoly(inner, np.round(q).astype(np.int32), 255)
        inner = cv2.erode(inner, np.ones((25, 25), np.uint8))
        px = im[inner > 0].astype(np.float32)
        dev = np.abs(px - np.array([0, 255, 0], np.float32)).max(1)
        frac = float((dev > 60).mean()) if len(px) else 1.0
        out.append(('screen uniform flat green (≤2% of the screen off by >60/255)', frac <= 0.02, f'{100 * frac:.2f}% off-green'))
        cov = float((m[inner > 0] > 0).mean()) if inner.any() else 0
        out.append(('nothing covers the screen (≥99% keyable)', cov >= 0.99, f'{100 * cov:.2f}% keyable'))
    det.setInputSize((im.shape[1], im.shape[0]))
    _, faces = det.detect(im)
    out.append(('no face', faces is None or len(faces) == 0, f'{0 if faces is None else len(faces)} detected'))
    return out


def main(path):
    results = []
    if path.lower().endswith(('.mp4', '.mov', '.webm')):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-vf', 'fps=30', os.path.join(d, '%04d.png')], check=True)
            fs = sorted(os.path.join(d, f) for f in os.listdir(d))
            tr = keyer.track(fs, os.path.basename(path))
            results.append((f'keys on every frame ({tr["n"]} frames)', not tr['fails'], f'{len(tr["fails"])} fails, worst run {tr["worst_fail_run"]}'))
            results.append(('not a regenerate (no run of >6 failures)', not tr['regenerate'], ''))
            for k in (0, len(fs) // 2, len(fs) - 1):
                for name, ok, det_ in still_checks(cv2.imread(fs[k])):
                    results.append((f'frame {k}: {name}', ok, det_))
    else:
        results = still_checks(cv2.imread(path))
    bad = [r for r in results if not r[1]]
    for name, ok, d in results:
        print(('PASS ' if ok else 'FAIL ') + name + (f'  — {d}' if d else ''))
    print(f'{os.path.basename(path)}: {"REJECT" if bad else "passes the machine rules"} (hands, text and geometry still need a look)')
    return not bad


if __name__ == '__main__':
    ok = all([main(p) for p in sys.argv[1:]])
    sys.exit(0 if ok else 1)
