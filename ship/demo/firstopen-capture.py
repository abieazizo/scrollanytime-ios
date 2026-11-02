#!/usr/bin/env python3
# THE FIRST OPEN, MEASURED (incident 2026-11-02) — the timed part of ship/demo/walk-firstopen.sh.
#
#   capture: `simctl launch` the app on a freshly erased Simulator and take screenshots as fast as simctl gives
#            them until the window closes. Every frame keeps the moments its screenshot call began and returned,
#            in ms after the instant just before `simctl launch` was called. Optionally a command runs at a set
#            moment after launch (the network block's release, leg C) and its own moment is kept too.
#   analyze: what each frame shows — its luminance (dark launch still / splash vs a lit picture) and its words
#            (Vision OCR, ship/demo/ocr.swift compiled) — and the leg's verdict:
#              feed     the first frame of the feed's video: the first LIT frame (and the next one lit too) that is
#                       neither the welcome nor the bundled offline page
#              welcome  the onboarding's first screen: the first frame whose words are the welcome's
#              wall     the network leg: every frame that reads "needs a connection", and the first welcome frame
#            A time is reported as a bracket: the screen changed after the previous frame's call BEGAN and before
#            this frame's call RETURNED. `seen_by_ms` (the upper end) is the number the legs are judged on.
import argparse
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import threading
import time

BUNDLE = 'com.scrollanytime.app'


def now_ms(t0):
    return round((time.time() - t0) * 1000)


def capture(a):
    os.makedirs(os.path.join(a.dir, 'frames'), exist_ok=True)
    simctl = subprocess.run(['xcrun', '-f', 'simctl'], capture_output=True, text=True).stdout.strip() or 'simctl'
    frames, events = [], []
    t0 = time.time()
    launch_wall = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(t0)) + '.%03dZ' % int((t0 % 1) * 1000)

    def at(delay, cmd, name):
        def run():
            s = now_ms(t0)
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            events.append({'event': name, 'began_ms': s, 'done_ms': now_ms(t0), 'rc': r.returncode, 'out': (r.stdout + r.stderr)[-400:]})
        t = threading.Timer(delay, run)
        t.daemon = True
        t.start()
        return t

    timer = at(a.release_at, a.release_cmd, 'network released') if a.release_cmd else None
    args = [simctl, 'launch', a.udid, BUNDLE] + (a.launch_args.split() if a.launch_args else [])
    r = subprocess.run(args, capture_output=True, text=True)
    events.append({'event': 'simctl launch returned', 'done_ms': now_ms(t0), 'rc': r.returncode, 'out': (r.stdout + r.stderr).strip()[-300:]})
    i = 0
    while time.time() - t0 < a.window:
        path = os.path.join(a.dir, 'frames', '%04d.jpg' % i)
        s = now_ms(t0)
        rr = subprocess.run([simctl, 'io', a.udid, 'screenshot', '--type=jpeg', path], capture_output=True, text=True)
        e = now_ms(t0)
        if rr.returncode == 0 and os.path.exists(path):
            frames.append({'i': i, 'file': os.path.basename(path), 'began_ms': s, 'returned_ms': e})
            i += 1
        else:
            time.sleep(0.05)
    if timer:
        timer.join(timeout=15)
    json.dump({'label': a.label, 'launch_utc': launch_wall, 'launch_epoch_ms': round(t0 * 1000), 'launch_args': a.launch_args,
               'release_at_s': a.release_at if a.release_cmd else None, 'window_s': a.window, 'events': sorted(events, key=lambda x: x.get('done_ms', 0)),
               'frames': frames}, open(os.path.join(a.dir, 'capture.json'), 'w'), indent=1)
    gaps = [f['returned_ms'] - f['began_ms'] for f in frames]
    print('  captured %d frames in %.1f s (screenshot call %d-%d ms, median %d ms); launch at %s' % (
        len(frames), a.window, min(gaps or [0]), max(gaps or [0]), sorted(gaps)[len(gaps) // 2] if gaps else 0, launch_wall))


WALL = ('needs a connection', 'connection for your first open', 'your torah is worth it')
WELCOME = ('endless torah', 'nothing else', 'continue with email', 'sign in with apple', 'continue with google')


def analyze(a):
    import cv2  # the workflow installs opencv-python-headless (with numpy) for the icon finder

    cap = json.load(open(os.path.join(a.dir, 'capture.json')))
    frames = cap['frames']
    os.makedirs(os.path.join(a.dir, 'small'), exist_ok=True)
    os.makedirs(os.path.join(a.dir, 'thumbs'), exist_ok=True)
    os.makedirs(os.path.join(a.dir, 'ocr'), exist_ok=True)

    def one(f):
        src = os.path.join(a.dir, 'frames', f['file'])
        img = cv2.imread(src, cv2.IMREAD_COLOR)
        if img is None:
            f.update(lum=None, lit_frac=None, text='', ok=False)
            return f
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        f['lum'] = round(float(gray.mean()), 1)
        f['lit_frac'] = round(float((gray > 90).mean()), 3)
        h, w = gray.shape
        small = cv2.resize(img, (w // 2, h // 2), interpolation=cv2.INTER_AREA)
        sp = os.path.join(a.dir, 'small', f['file'])
        cv2.imwrite(sp, small, [cv2.IMWRITE_JPEG_QUALITY, 90])
        cv2.imwrite(os.path.join(a.dir, 'thumbs', f['file']), cv2.resize(img, (240, int(240 * h / w)), interpolation=cv2.INTER_AREA), [cv2.IMWRITE_JPEG_QUALITY, 70])
        txt = ''
        if a.ocr:
            r = subprocess.run([a.ocr, sp], capture_output=True, text=True)
            txt = r.stdout
        open(os.path.join(a.dir, 'ocr', f['file'] + '.txt'), 'w').write(txt)
        low = ' '.join(txt.lower().split())
        f['text'] = ' / '.join(l.strip() for l in txt.splitlines() if l.strip())[:300]
        f['wall'] = any(p in low for p in WALL)
        f['welcome'] = any(p in low for p in WELCOME)
        f['still_connecting'] = 'still connecting' in low
        # where it sits says whose it is: the shell's label (f9f54c88) is under the launch art, 72 pt above the
        # safe area's bottom (~0.86 of the screen down); the web splash's own line (splash.markSlow) is elsewhere
        f['still_connecting_at'] = None
        if f['still_connecting'] and a.ocr:
            r = subprocess.run([a.ocr, sp, '--find', 'still connecting'], capture_output=True, text=True)
            f['still_connecting_at'] = r.stdout.strip() or None
        f['lit'] = f['lum'] >= a.lit_lum or f['lit_frac'] >= a.lit_frac
        f['ok'] = True
        return f

    with cf.ThreadPoolExecutor(max_workers=3) as ex:
        frames = list(ex.map(one, frames))
    frames.sort(key=lambda f: f['i'])
    good = [f for f in frames if f.get('ok')]

    def bracket(k):
        f = good[k]
        prev = good[k - 1] if k > 0 else None
        return {'frame': f['file'], 'seen_by_ms': f['returned_ms'], 'not_before_ms': prev['began_ms'] if prev else 0,
                'frame_call_ms': [f['began_ms'], f['returned_ms']], 'lum': f['lum'], 'lit_frac': f['lit_frac'], 'text': f['text']}

    verdict = {'mode': a.mode, 'frames': len(good),
               'still_connecting_frames': [[f['began_ms'], f['returned_ms'], f['still_connecting_at']] for f in good if f['still_connecting']]}
    if a.mode == 'feed':
        hit = None
        for k, f in enumerate(good):
            nxt = good[k + 1] if k + 1 < len(good) else f
            if f['lit'] and nxt['lit'] and not f['wall'] and not f['welcome']:
                hit = k
                break
        verdict['first_frame'] = bracket(hit) if hit is not None else None
        verdict['welcome_seen'] = any(f['welcome'] for f in good)
    elif a.mode == 'welcome':
        hit = next((k for k, f in enumerate(good) if f['welcome']), None)
        verdict['first_frame'] = bracket(hit) if hit is not None else None
        lit = next((k for k, f in enumerate(good) if f['lit']), None)
        verdict['first_lit'] = bracket(lit) if lit is not None else None
    if a.mode in ('wall', 'welcome'):
        rel = next((e for e in cap['events'] if e['event'] == 'network released'), None)
        rel_ms = rel['done_ms'] if rel else None
        walls = [f for f in good if f['wall']]
        verdict['released_ms'] = rel_ms
        verdict['wall_frames'] = [[f['began_ms'], f['returned_ms']] for f in walls]
        verdict['wall_seen'] = bool(walls)
        verdict['wall_after_release'] = [[f['began_ms'], f['returned_ms']] for f in walls if rel_ms is not None and f['returned_ms'] > rel_ms]
        first_wall = next((k for k, f in enumerate(good) if f['wall']), None)
        verdict['first_wall'] = bracket(first_wall) if first_wall is not None else None
        after = next((k for k, f in enumerate(good) if f['welcome'] and (rel_ms is None or f['began_ms'] >= rel_ms)), None)
        if after is None:
            after = next((k for k, f in enumerate(good) if f['welcome']), None)
        verdict['first_welcome'] = bracket(after) if after is not None else None
        if rel_ms is not None and verdict['first_welcome']:
            verdict['welcome_after_release_ms'] = verdict['first_welcome']['seen_by_ms'] - rel_ms
        last = good[-1] if good else None
        verdict['last_frame'] = {'frame': last['file'], 'ms': last['returned_ms'], 'wall': last['wall'], 'welcome': last['welcome'], 'text': last['text']} if last else None
    cap['frames'] = frames
    cap['verdict'] = verdict
    json.dump(cap, open(os.path.join(a.dir, 'analysis.json'), 'w'), indent=1)
    # a compact timeline for the log: one line per frame
    with open(os.path.join(a.dir, 'timeline.txt'), 'w') as tl:
        for f in good:
            tl.write('%5d-%5d ms  lum %5.1f lit %.3f %s%s%s%s  %s\n' % (f['began_ms'], f['returned_ms'], f['lum'], f['lit_frac'], 'LIT ' if f['lit'] else '    ',
                     'WALL ' if f['wall'] else '', 'WELCOME ' if f['welcome'] else '',
                     ('STILL-CONNECTING@%s ' % (f['still_connecting_at'] or '?')) if f['still_connecting'] else '', f['text'][:120]))
    print(json.dumps(verdict, indent=1))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('cmd', choices=['capture', 'analyze'])
    p.add_argument('--udid')
    p.add_argument('--label', default='')
    p.add_argument('--dir', required=True)
    p.add_argument('--window', type=float, default=20)
    p.add_argument('--launch-args', default='')
    p.add_argument('--release-at', type=float, default=0)
    p.add_argument('--release-cmd', default='')
    p.add_argument('--mode', choices=['feed', 'welcome', 'wall'], default='feed')
    p.add_argument('--ocr', default='')
    p.add_argument('--lit-lum', type=float, default=45)
    p.add_argument('--lit-frac', type=float, default=0.12)
    a = p.parse_args()
    capture(a) if a.cmd == 'capture' else analyze(a)


if __name__ == '__main__':
    sys.exit(main())
