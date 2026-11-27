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


def clock_skew_ms():
    """the live site's clock minus this runner's (GET /version's `now` against the request's midpoint), so the
    app's own `[boot] ready` row (stamped by the server) can be put on this run's time line"""
    # curl, not urllib: the runner's python.org Python has no CA bundle (run 41451702694 measured no skew at all)
    best = None
    for _ in range(3):
        try:
            t1 = time.time()
            body = subprocess.run(['curl', '-s', '-m', '8', 'https://scrollanytime.com/version'], capture_output=True, text=True).stdout
            t2 = time.time()
            now = json.loads(body)['now']
            cand = (round(now - (t1 + t2) / 2 * 1000), round((t2 - t1) * 1000))
            if best is None or cand[1] < best[1]:
                best = cand
        except Exception:
            pass
    return {'skew_ms': best[0], 'rtt_ms': best[1]} if best else None


def start_recorder(simctl, udid, path, events):
    """simctl's own screen recording: every frame with its timestamp, unlike a screenshot call, which stalled for
    up to 5.9 s on the runner (run 41447382148). Returns (process, the instant it said 'Recording started')."""
    p = subprocess.Popen([simctl, 'io', udid, 'recordVideo', '--codec=h264', '--force', path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    started = {}
    lines = []

    def read():
        for line in p.stdout:
            lines.append(line.strip())
            if 'started' in line.lower() and 't' not in started:
                started['t'] = time.time()
    th = threading.Thread(target=read, daemon=True)
    th.start()
    t = time.time()
    while time.time() - t < 25 and 't' not in started and p.poll() is None:
        time.sleep(0.05)
    events.append({'event': 'recorder', 'started': 't' in started, 'waited_s': round(time.time() - t, 2), 'out': ' | '.join(lines)[-300:]})
    if 't' not in started:
        p.kill()
        return None, None
    return p, started['t']


def capture(a):
    os.makedirs(os.path.join(a.dir, 'frames'), exist_ok=True)
    simctl = subprocess.run(['xcrun', '-f', 'simctl'], capture_output=True, text=True).stdout.strip() or 'simctl'
    frames, events = [], []
    skew = clock_skew_ms()
    rec, t_rec = (None, None)
    if a.record:
        rec, t_rec = start_recorder(simctl, a.udid, os.path.join(a.dir, 'rec.mp4'), events)
        time.sleep(1.2)  # the Home Screen before the launch, as the recording's own reference
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
    if rec is not None:
        # recording: no screenshot calls during the window (they would compete with the launch); one at the end
        while time.time() - t0 < a.window:
            time.sleep(0.1)
        rec.send_signal(2)  # SIGINT: the file is finalised only on a clean stop
        try:
            rec.wait(timeout=60)
        except Exception:
            rec.kill()
        events.append({'event': 'recorder stopped', 'done_ms': now_ms(t0), 'rc': rec.returncode, 'bytes': os.path.getsize(os.path.join(a.dir, 'rec.mp4')) if os.path.exists(os.path.join(a.dir, 'rec.mp4')) else 0})
    while rec is None and time.time() - t0 < a.window:
        path = os.path.join(a.dir, 'frames', '%04d.jpg' % i)
        s = now_ms(t0)
        rr = subprocess.run([simctl, 'io', a.udid, 'screenshot', '--type=jpeg', path], capture_output=True, text=True)
        e = now_ms(t0)
        if rr.returncode == 0 and os.path.exists(path):
            frames.append({'i': i, 'file': os.path.basename(path), 'began_ms': s, 'returned_ms': e})
            i += 1
        else:
            time.sleep(0.05)
    if rec is not None:
        path = os.path.join(a.dir, 'frames', 'final.jpg')
        s = now_ms(t0)
        subprocess.run([simctl, 'io', a.udid, 'screenshot', '--type=jpeg', path], capture_output=True, text=True)
        if os.path.exists(path):
            frames.append({'i': 0, 'file': 'final.jpg', 'began_ms': s, 'returned_ms': now_ms(t0)})
    if timer:
        timer.join(timeout=15)
    json.dump({'label': a.label, 'launch_utc': launch_wall, 'launch_epoch_ms': round(t0 * 1000), 'launch_args': a.launch_args,
               'clock': skew, 'recording': {'file': 'rec.mp4', 'started_ms': round((t_rec - t0) * 1000)} if rec is not None else None,
               'release_at_s': a.release_at if a.release_cmd else None, 'window_s': a.window, 'events': sorted(events, key=lambda x: x.get('done_ms', 0)),
               'frames': frames}, open(os.path.join(a.dir, 'capture.json'), 'w'), indent=1)
    if rec is not None:
        print('  recorded the launch (recorder said started %d ms before the launch call); clock: %s; launch at %s' % (round((t0 - t_rec) * 1000), skew, launch_wall))
        return
    gaps = [f['returned_ms'] - f['began_ms'] for f in frames]
    print('  captured %d frames in %.1f s (screenshot call %d-%d ms, median %d ms); launch at %s' % (
        len(frames), a.window, min(gaps or [0]), max(gaps or [0]), sorted(gaps)[len(gaps) // 2] if gaps else 0, launch_wall))


WALL = ('needs a connection', 'connection for your first open', 'your torah is worth it')
WELCOME = ('endless torah', 'nothing else', 'continue with email', 'sign in with apple', 'continue with google')


DARK, LIT = 31, 40   # full-range grey mean: the splash and launch still read 11-16 (29 under a system banner), the welcome 55, the Home Screen ~35


def ocr_text(a, img, name):
    import cv2
    h, w = img.shape[:2]
    p = os.path.join(a.dir, 'ocr', name + '.jpg')
    cv2.imwrite(p, cv2.resize(img, (w // 2, h // 2), interpolation=cv2.INTER_AREA), [cv2.IMWRITE_JPEG_QUALITY, 90])
    if not a.ocr:
        return ''
    t = subprocess.run([a.ocr, p], capture_output=True, text=True).stdout
    open(os.path.join(a.dir, 'ocr', name + '.txt'), 'w').write(t)
    return ' / '.join(l.strip() for l in t.splitlines() if l.strip())[:300]


def analyze_video(a, cap):
    """the recording: every frame's grey level on the run's time line (ms after the launch call), the launch's
    first visible change, the dark launch still/splash, and the first frame that is lit and stays lit"""
    import cv2
    rec = os.path.join(a.dir, cap['recording']['file'])
    for d in ('ocr', 'thumbs'):
        os.makedirs(os.path.join(a.dir, d), exist_ok=True)
    ts = []
    try:
        out = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'csv=p=0', rec],
                             capture_output=True, text=True, timeout=240).stdout
        ts = [float(x.strip().strip(',')) for x in out.split() if x.strip().strip(',') not in ('', 'N/A')]
    except Exception as e:
        print('  ffprobe failed:', e, file=sys.stderr)
    vc = cv2.VideoCapture(rec)
    lums, pos = [], []
    while True:
        ok, img = vc.read()
        if not ok:
            break
        pos.append(vc.get(cv2.CAP_PROP_POS_MSEC) / 1000)
        g = cv2.cvtColor(cv2.resize(img, (img.shape[1] // 8, img.shape[0] // 8), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        lums.append(round(float(g.mean()), 1))
    vc.release()
    source = 'ffprobe' if len(ts) == len(lums) and ts else 'opencv'
    if source == 'opencv':
        ts = pos
    if not lums:
        return {'error': 'the recording could not be read', 'ffprobe_frames': len(ts)}
    start = cap['recording']['started_ms']
    wall = [round(start + (t - ts[0]) * 1000) for t in ts]
    before = [l for l, w in zip(lums, wall) if w < -100]
    base = sorted(before)[len(before) // 2] if before else lums[0]
    vis = next((k for k, l in enumerate(lums) if wall[k] > -1000 and abs(l - base) > 3), None)
    dark = next((k for k in range((vis or 0), len(lums)) if lums[k] < DARK), None)
    lit = None
    if dark is not None:
        for k in range(dark, len(lums)):
            if lums[k] >= LIT and all(lums[j] >= LIT - 5 for j in range(k, len(lums)) if wall[j] - wall[k] <= 500):
                lit = k
                break
    # the frames to keep: the one before, the first lit one, and 700 ms later (the welcome has faded in by then)
    want = {}
    if lit is not None:
        want[max(lit - 1, 0)] = 'before-first-lit'
        want[lit] = 'first-lit'
        later = next((k for k in range(lit, len(lums)) if wall[k] - wall[lit] >= 700), len(lums) - 1)
        want[later] = 'first-lit+700ms'
    if dark is not None:
        want.setdefault(dark, 'first-dark')
    grid, nxt = {}, -1000
    for k, w in enumerate(wall):
        if w >= nxt:
            grid[k] = w
            nxt = w + 250
    texts = {}
    vc = cv2.VideoCapture(rec)
    k = 0
    while True:
        ok, img = vc.read()
        if not ok:
            break
        if k in want:
            cv2.imwrite(os.path.join(a.dir, 'frames', want[k] + '.png'), img)
            texts[want[k]] = ocr_text(a, img, want[k])
        if k in grid:
            h, w = img.shape[:2]
            cv2.imwrite(os.path.join(a.dir, 'thumbs', 't%+06d.jpg' % grid[k]), cv2.resize(img, (240, int(240 * h / w)), interpolation=cv2.INTER_AREA), [cv2.IMWRITE_JPEG_QUALITY, 70])
        k += 1
    vc.release()

    def at(k):
        return None if k is None else {'ms': wall[k], 'prev_frame_ms': wall[k - 1] if k > 0 else None, 'lum': lums[k]}
    v = {'source': source, 'frames': len(lums), 'recording_started_ms': start, 'home_screen_lum': base,
         'launch_visible': at(vis), 'first_dark': at(dark), 'first_lit': at(lit), 'texts': texts,
         'lum_series': [[wall[k], lums[k]] for k in range(len(lums)) if k == 0 or k == len(lums) - 1 or abs(lums[k] - lums[k - 1]) >= 1.0 or k in want]}
    t = (texts.get('first-lit+700ms') or '').lower()
    v['first_lit_is_welcome'] = any(p in t for p in WELCOME)
    v['first_lit_is_wall'] = any(p in t for p in WALL)
    return v


def analyze(a):
    import cv2  # the workflow installs opencv-python-headless (with numpy) for the icon finder

    cap = json.load(open(os.path.join(a.dir, 'capture.json')))
    video = analyze_video(a, cap) if cap.get('recording') else None
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
        # the Home Screen behind the launch is lit too: only a lit frame AFTER the dark launch still counts
        dark0 = next((k for k, f in enumerate(good) if not f['lit']), len(good))
        for k, f in enumerate(good):
            if k <= dark0:
                continue
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
    if video is not None:
        # with a recording, the verdict's time comes from it; the screenshots (just the final one) only say where it ended
        verdict['video'] = video
        fl = video.get('first_lit')
        right = fl and (video['first_lit_is_welcome'] if a.mode == 'welcome' else not video['first_lit_is_welcome'] and not video['first_lit_is_wall'])
        verdict['first_frame'] = {'frame': 'first-lit.png', 'seen_by_ms': fl['ms'], 'not_before_ms': fl['prev_frame_ms'], 'lum': fl['lum'],
                                  'text': video['texts'].get('first-lit+700ms', ''), 'from': 'recording'} if right else None
        last = good[-1] if good else None
        verdict['final_screenshot'] = {'text': last['text'], 'welcome': last['welcome'], 'wall': last['wall']} if last else None
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
    p.add_argument('--record', action='store_true')
    a = p.parse_args()
    capture(a) if a.cmd == 'capture' else analyze(a)


if __name__ == '__main__':
    sys.exit(main())
