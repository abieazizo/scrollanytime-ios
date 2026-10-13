"""Sound design: flick ticks, swipe air, the quickening heartbeat, the flare shimmer, silence, the boom,
a chime per hero portrait, fly-past air, the flame ignition, the day roll, an impact per word, the
seal press, room tone. Writes work/audio/sfx.wav and work/audio/sfx_cues.json."""
import json, os, sys
import numpy as np
import soundfile as sf
from synth import SR, secs, place, pan, lp, hp, bp, chime, kick, noise_burst, reverb

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'src/content'))
TL = json.load(open(os.path.join(ROOT, 'spec/timeline.json')))
N = secs(TL['duration'])
rng = np.random.default_rng(2026)
cues = []


def cue(name, t, **k):
    cues.append(dict(name=name, t=round(float(t), 3), **k))


def tick(vel=0.5):
    n = secs(0.09)
    t = np.arange(n) / SR
    click = bp(rng.normal(0, 1, n).astype(np.float32), 2500, 7500) * np.exp(-t / 0.0025)
    sw = bp(rng.normal(0, 1, n).astype(np.float32), 900, 3500) * np.exp(-t / 0.03) * 0.25
    return (click + sw) * vel


def whoosh(dur=0.16, f_hi=4200, f_lo=900, vel=0.3, seed=0):
    n = secs(dur)
    x = np.random.default_rng(seed).normal(0, 1, n).astype(np.float32)
    out = np.zeros(n, np.float32)
    for j in range(0, n, 480):
        u = j / n
        fc = f_hi * (f_lo / f_hi) ** u
        out[j:j + 480] = bp(x[j:j + 480], fc * 0.6, fc * 1.4, 1)
    env = np.sin(np.pi * np.clip(np.arange(n) / n, 0, 1)) ** 1.5
    return out * env * vel


def heartbeat(gap, vel=0.8):
    def thump(f0, d):
        n = secs(d)
        t = np.arange(n) / SR
        f = f0 * (0.75 + 0.25 * np.exp(-t / 0.02))
        y = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (d * 0.35)) * np.minimum(1, t / 0.004)
        return lp(y.astype(np.float32), 180)
    lub = thump(58, 0.14)
    dub = thump(72, 0.11) * 0.7
    g = secs(min(0.14, gap * 0.42))
    out = np.zeros(max(g + len(dub), len(lub)), np.float32)
    out[:len(lub)] += lub
    out[g:g + len(dub)] += dub
    return out * vel


def build():
    S = np.zeros((N + secs(3), 2), np.float32)

    # room tone: bedroom air at the head and the tail (the reel loops)
    n = secs(TL['duration'])
    pink = np.cumsum(rng.normal(0, 1, n)).astype(np.float32)
    pink = hp(pink - lp(pink, 2), 40)
    pink = lp(pink, 1600)
    pink /= np.abs(pink).max() + 1e-9
    t = np.arange(n) / SR
    env = np.zeros(n, np.float32)
    env[t < 3.0] = 1.0
    m = (t >= 3.0) & (t < 3.5); env[m] = 1 - (t[m] - 3.0) / 0.5
    m = (t >= 17.0) & (t < 17.8); env[m] = (t[m] - 17.0) / 0.8
    env[t >= 17.8] = 1.0
    room = pink * env * 0.018
    S[:n] += np.stack([room, np.roll(room, 911)], 1)
    cue('room tone', 0.0, until=3.5); cue('room tone', 17.0, until=20.0)

    # flick ticks
    for f in TL['h1']['flicks'] + TL['h2']['flicks']:
        place(S, pan(tick(0.55), 0.15), f)
        place(S, pan(whoosh(0.2, 3000, 800, 0.10, int(f * 100)), 0.1), f + 0.01)
        cue('flick tick', f)

    # montage: swipe air + the heartbeat, one beat per swipe, quickening
    from screens import montage_plan
    slots = montage_plan()
    beats = [3.35, 3.95] + [s['t0'] for s in slots[1:]]
    for k, b in enumerate(beats):
        gap = (beats[k + 1] - b) if k + 1 < len(beats) else 0.06
        place(S, pan(heartbeat(max(gap, 0.06), 0.55 + 0.35 * k / len(beats)), 0), b)
        cue('heartbeat', b)
    for s in slots[1:]:
        d = s['t1'] - s['t0']
        place(S, pan(whoosh(min(0.18, max(0.06, d * 0.6)), 5000, 1200, 0.16, int(s['t0'] * 1000)), -0.2), s['t0'] - 0.02)
        cue('swipe', s['t0'])

    # the flare shimmer, rising into the white, cut dead at 6.8
    f0, f1 = TL['h3']['flare']
    n = secs(f1 - (f0 - 0.25))
    t = np.arange(n) / SR
    sh = np.zeros(n, np.float32)
    for k, m in enumerate((98, 102, 105, 110, 114)):
        fr = 440 * 2 ** ((m - 69) / 12)
        sh += np.sin(2 * np.pi * fr * t + k) * (0.6 + 0.4 * np.sin(2 * np.pi * (11 + k * 2.3) * t))
    sh += hp(rng.normal(0, 1, n).astype(np.float32), 6000) * 0.5
    sh *= (t / t[-1]) ** 2.5 * 0.16
    place(S, np.stack([sh, np.roll(sh, 200)], 1), f0 - 0.25)
    cue('flare shimmer', f0 - 0.25, until=f1)

    # silence at the peak
    s0, s1 = TL['h3']['silence']
    cue('silence', s0, until=s1)

    # the boom
    n = secs(3.0)
    t = np.arange(n) / SR
    f = 34 + 40 * np.exp(-t / 0.08)
    boom = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.9)
    boom = lp(boom.astype(np.float32), 120) * 0.9 + noise_burst(3.0, 40, 400, 0.6, 21) * 0.5
    place(S, pan(boom, 0), 7.0)
    cue('boom', 7.0)

    # a chime per hero portrait, in key: D6, F#6, A6
    for h, m in zip(TL['portraits']['heroes'], (86, 90, 93)):
        place(S, pan(chime(m, 0.5), 0.0), h['arrive'] + 0.05)
        cue('chime', h['arrive'] + 0.05, who=h['who'])
    # fly-past air, alternating sides
    t0, t1 = TL['portraits']['flypast_t0'], TL['portraits']['flypast_t1']
    for k in range(6):
        tt = t0 + 0.05 + k * (t1 - t0 - 0.25) / 6
        place(S, pan(whoosh(0.32, 2600, 500, 0.12, 300 + k), -0.6 if k % 2 else 0.6), tt)
        cue('fly-past', tt)
    # title rise: a reversed bell into 10.3
    c = chime(93, 0.35, 1.0)[::-1]
    place(S, pan(c, 0), TL['portraits']['title']['t'] - 1.0 + 0.12)
    cue('title swell', TL['portraits']['title']['t'])

    # the flame ignition
    ft = TL['h5']['flame']
    n = secs(0.9)
    t = np.arange(n) / SR
    x = rng.normal(0, 1, n).astype(np.float32)
    out = np.zeros(n, np.float32)
    for j in range(0, n, 480):
        fc = 250 * 2 ** (3.2 * min(1, j / secs(0.35)))
        out[j:j + 480] = bp(x[j:j + 480], fc * 0.5, fc * 1.6, 1)
    out *= np.minimum(1, t / 0.03) * np.exp(-t / 0.28) * 0.45
    crack = np.zeros(n, np.float32)
    for _ in range(26):
        i = int(rng.uniform(0.02, 0.8) * SR)
        L = secs(0.004)
        crack[i:i + L] += hp(rng.normal(0, 1, L).astype(np.float32), 2500)[:len(crack[i:i + L])] * rng.uniform(0.1, 0.4) * np.exp(-i / SR / 0.35)
    thump = np.zeros(n, np.float32)
    kk = kick(0.3, 80, 50, 0.15)[:n]
    thump[:len(kk)] = kk
    place(S, pan(out + crack + thump, 0.1), ft)
    cue('flame ignition', ft)
    for tt in (TL['h5']['day_roll'], TL['h5']['day_roll'] + 0.13):
        place(S, pan(tick(0.25), 0.2), tt)
        cue('day roll tick', tt)

    # an impact per word
    for w in TL['words']:
        imp = kick(0.9, 120, 38, 0.55)
        n = len(imp)
        imp = imp + noise_burst(n / SR, 300, 9000, 0.05, int(w['t'] * 10)) * 0.4
        imp = imp + chime(62, 0.25, n / SR)[:n] * 0.5
        place(S, pan(imp, 0), w['t'])
        cue('impact', w['t'], word=w['text'])

    # the seal press
    sp = TL['endcard']['seal_press']
    n = secs(0.25)
    t = np.arange(n) / SR
    thock = np.sin(2 * np.pi * 150 * t) * np.exp(-t / 0.045) + bp(rng.normal(0, 1, n).astype(np.float32), 800, 2400) * np.exp(-t / 0.006) * 0.6
    place(S, pan(thock.astype(np.float32) * 0.7, 0), sp + 0.1)
    place(S, pan(chime(98, 0.22, 1.6), 0.1), sp + 0.2)
    cue('seal press', sp + 0.1)

    S = reverb(S, wet=0.14, t60=1.6, seed=9)[:N]
    a, b = secs(s0), secs(s1)
    S[a - secs(0.004):a] *= np.linspace(1, 0, secs(0.004))[:, None]
    S[a:b] = 0
    return S


if __name__ == '__main__':
    out = os.path.join(ROOT, 'work/audio')
    os.makedirs(out, exist_ok=True)
    S = build()
    sf.write(os.path.join(out, 'sfx.wav'), S, SR, subtype='FLOAT')
    json.dump(cues, open(os.path.join(out, 'sfx_cues.json'), 'w'), indent=1)
    print('sfx', S.shape, len(cues), 'cues')
