"""The score: modern, uplifting, piano and strings over a cinematic pulse. D major / B minor, 120 BPM
after a free-time intro. Silence from 6.8, the big percussive hit and sub drop at 7.0. No oud.
Writes work/audio/music.wav (48 kHz stereo float) and work/audio/music_stems/*.wav."""
import json, os
import numpy as np
import soundfile as sf
from synth import SR, secs, place, piano, strings, pulse_note, kick, noise_burst, pan, lp, hp, reverb

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TL = json.load(open(os.path.join(ROOT, 'spec/timeline.json')))
DUR = TL['duration']
N = secs(DUR + 0.0)

CH = {  # voicings: (bass, pad tones, arpeggio tones)
    'D':   (38, [50, 57, 62, 66, 69], [62, 66, 69, 74, 78]),
    'Bm':  (35, [47, 54, 59, 62, 66], [59, 62, 66, 71, 74]),
    'G':   (31, [43, 50, 55, 59, 62], [55, 59, 62, 67, 71]),
    'A':   (33, [45, 52, 57, 61, 64], [57, 61, 64, 69, 73]),
    'A/C#': (37, [49, 52, 57, 61, 64], [57, 61, 64, 69, 73]),
    'Asus': (33, [45, 52, 57, 62, 64], [57, 62, 64, 69, 74]),
}


def build():
    stems = {k: np.zeros((N + secs(4), 2), np.float32) for k in ('piano', 'strings', 'pulse', 'drums', 'sub')}
    P, S, U, D, B = (stems[k] for k in ('piano', 'strings', 'pulse', 'drums', 'sub'))

    def pn(m, t, vel, dur=2.0, p=None):
        p = (m - 66) / 30 if p is None else p
        place(P, pan(piano(m, vel, dur), float(np.clip(p, -0.7, 0.7))), t)

    # ---------------------------------------------------------------- intro, free time (0 - 3.0)
    for m in (62, 69, 78):
        pn(m, 0.04, 0.22, 2.4)
    for m in (59, 62, 66, 73):
        pn(m, 1.40, 0.30, 1.8)
    pn(78, 2.25, 0.16, 1.0)
    place(S, strings([47, 54, 62, 66], 1.75, vel=0.18, a=0.9, r=0.4, cutoff=1800), 1.30)

    # ---------------------------------------------------------------- A: the swipes (3.0 - 6.8)
    A = [(3.0, 4.0, 'Bm'), (4.0, 5.0, 'G'), (5.0, 6.0, 'D'), (6.0, 6.8, 'Asus')]
    for k, (t0, t1, c) in enumerate(A):
        bass, pad, arp = CH[c]
        lvl = 0.25 + 0.6 * (t0 - 3.0) / 3.6
        place(S, strings(pad + [pad[-1] + 12], (t1 - t0) + 0.15, vel=lvl, a=0.25 if k else 0.5, r=0.3, cutoff=2400 + 2600 * lvl), t0)
        step = 0.25
        pat = [0, 2, 1, 3, 2, 4, 3, 1]
        t, i = t0, 0
        while t < t1 - 1e-6:
            pn(arp[pat[i % 8]] + (12 if t >= 5.0 else 0), t, 0.26 + 0.34 * (t - 3.0) / 3.6, 0.6)
            t += step; i += 1
        # pulse: eighths, sixteenths in the last bar
        sub = 0.25 if t0 < 6.0 else 0.125
        t = t0
        while t < t1 - 1e-6:
            place(U, pan(pulse_note(bass + 12, sub * 0.9, 0.35 + 0.45 * (t - 3.0) / 3.6), 0.0), t)
            t += sub
    for t in np.arange(5.0, 6.8, 0.5):
        place(D, pan(kick(0.35 + 0.3 * (t - 5.0) / 1.8, 90, 50, 0.25), 0), float(t))
    # the riser: strings swell + a rising filtered noise, cut dead at 6.8
    n = secs(1.2)
    tt = np.arange(n) / SR
    rs = np.random.default_rng(5).normal(0, 1, n).astype(np.float32)
    out = np.zeros(n, np.float32)
    for j in range(0, n, 2400):                                  # stepped band sweep
        seg = rs[j:j + 2400]
        fc = 400 * 2 ** (5.0 * j / n)
        out[j:j + 2400] = lp(seg, fc, 2)
    out *= (tt / 1.2) ** 2.2 * 0.35
    place(U, pan(out, 0), 5.6)

    # ---------------------------------------------------------------- B: the rabbanim (7.0 - 11.0)
    Bc = [(7.0, 8.0, 'D'), (8.0, 9.0, 'A/C#'), (9.0, 10.0, 'Bm'), (10.0, 11.0, 'G')]
    for t0, t1, c in Bc:
        bass, pad, arp = CH[c]
        place(S, strings(pad + [pad[-2] + 12, pad[-1] + 12], (t1 - t0) + 0.1, vel=0.75, a=0.06 if t0 == 7.0 else 0.2, r=0.35, cutoff=5200), t0)
        pn(bass + 12, t0, 0.55, 1.0, -0.3)
        pn(bass + 24, t0, 0.45, 1.0, -0.2)
        t = t0
        while t < t1 - 1e-6:
            place(U, pan(pulse_note(bass + 12, 0.22, 0.62), 0.0), t)
            t += 0.25
    melody = [(7.0, 78, 1.0), (8.0, 76, 0.5), (8.5, 73, 0.5), (9.0, 74, 1.0), (10.0, 71, 0.5), (10.5, 74, 0.25), (10.75, 76, 0.25)]
    for t, m, d in melody:
        pn(m, t, 0.62, d + 0.2, 0.15)
        pn(m + 12, t, 0.30, d + 0.2, 0.25)
    for t in np.arange(7.5, 11.0, 0.5):
        place(D, pan(kick(0.55 if (t * 2) % 2 == 0 else 0.35, 95, 48, 0.3), 0), float(t))

    # ---------------------------------------------------------------- C: every day (11.0 - 14.0)
    Cc = [(11.0, 12.5, 'G'), (12.5, 13.5, 'D'), (13.5, 14.0, 'A')]
    for t0, t1, c in Cc:
        bass, pad, arp = CH[c]
        place(S, strings(pad[1:] + [pad[-1] + 12], (t1 - t0) + 0.1, vel=0.48, a=0.3, r=0.35, cutoff=3800), t0)
        pn(bass + 12, t0, 0.42, 1.2, -0.3)
        t, i = t0, 0
        while t < t1 - 1e-6:
            pn(arp[[0, 2, 4, 3][i % 4]] + 12, t, 0.30, 0.5)
            place(U, pan(pulse_note(bass + 12, 0.2, 0.38), 0.0), t)
            t += 0.25; i += 1
    pn(81, 12.5, 0.45, 1.2, 0.3)       # a lift as the flame takes
    pn(86, 12.65, 0.28, 1.0, 0.35)

    # ---------------------------------------------------------------- D: Free. No ads. Only Torah. (14 - 17)
    Dc = [(14.0, 15.0, 'Bm'), (15.0, 16.0, 'G'), (16.0, 17.0, 'Asus')]
    for t0, t1, c in Dc:
        bass, pad, arp = CH[c]
        place(S, strings(pad + [pad[-1] + 12, pad[-2] + 12], (t1 - t0) + 0.1, vel=0.85, a=0.08, r=0.3, cutoff=5600), t0)
        t = t0
        while t < t1 - 1e-6:
            place(U, pan(pulse_note(bass + 12, 0.22, 0.75), 0.0), t)
            t += 0.25
    for w in TL['words']:
        c = next(c for t0, t1, c in Dc if t0 <= w['t'] < t1)
        for m in CH[c][2][:4]:
            pn(m + 12, w['t'], 0.55, 0.6)
        pn(CH[c][0] + 12, w['t'], 0.6, 0.8, -0.3)
    for t in np.arange(14.0, 17.0, 0.5):
        place(D, pan(kick(0.75, 100, 46, 0.32), 0), float(t))

    # ---------------------------------------------------------------- E: the end card, resolve (17 - 20)
    bass, pad, arp = CH['D']
    s = strings(pad + [74, 78, 81], 1.9, vel=0.7, a=0.05, r=1.0, cutoff=5000)
    place(S, s, 17.0)
    for m in (38, 50, 57, 66, 74):
        pn(m, 17.0, 0.6, 2.4)
    for t, m in ((17.25, 78), (17.5, 81), (17.75, 86), (18.5, 78), (19.0, 74)):
        pn(m, t, 0.34, 1.4, 0.3)
    place(D, pan(kick(0.9, 105, 44, 0.5), 0), 17.0)
    place(U, pan(pulse_note(50, 0.4, 0.6), 0.0), 17.0)

    # ---------------------------------------------------------------- the hit and sub drop at 7.0
    n = secs(2.4)
    t = np.arange(n) / SR
    f = 26 + (72 - 26) * np.exp(-t / 0.55)
    sub = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 1.1) * np.minimum(1, t / 0.006)
    sub = np.tanh(sub * 1.6) / np.tanh(1.6)
    place(B, pan(sub.astype(np.float32) * 0.9, 0), 7.0)
    place(D, pan(kick(1.0, 130, 40, 0.7), 0), 7.0)
    hit = noise_burst(2.2, 60, 9000, 0.35, seed=11)
    place(D, np.stack([hit, noise_burst(2.2, 60, 9000, 0.35, seed=12)], 1) * 0.55, 7.0)

    # ---------------------------------------------------------------- reverb, silence, sum
    stems['piano'] = reverb(P, wet=0.32, t60=2.4, seed=1)
    stems['strings'] = reverb(S, wet=0.38, t60=2.8, seed=2)
    stems['pulse'] = reverb(hp(U, 45), wet=0.12, t60=1.2, seed=3)
    stems['drums'] = reverb(D, wet=0.2, t60=1.8, seed=4)
    stems['sub'] = lp(B, 140)
    gains = {'piano': 1.0, 'strings': 0.85, 'pulse': 0.7, 'drums': 0.9, 'sub': 0.8}
    mix = sum(stems[k] * g for k, g in gains.items())[:N]
    # silence at the peak: nothing from 6.8 to 7.0, reverb tails included
    s0, s1 = secs(TL['h3']['silence'][0]), secs(TL['h3']['silence'][1])
    fade = secs(0.006)
    mix[s0 - fade:s0] *= np.linspace(1, 0, fade)[:, None]
    mix[s0:s1] = 0
    for k in stems:
        stems[k] = stems[k][:N]
        stems[k][s0:s1] = 0
    # loop: fade the tail to near-silence so 20.0 meets 0.0
    f0 = secs(19.0)
    mix[f0:] *= np.linspace(1, 0.04, N - f0)[:, None] ** 1.5
    return mix, stems


if __name__ == '__main__':
    out = os.path.join(ROOT, 'work/audio')
    os.makedirs(os.path.join(out, 'music_stems'), exist_ok=True)
    mix, stems = build()
    peak = np.abs(mix).max()
    mix = mix / peak * 0.7
    sf.write(os.path.join(out, 'music.wav'), mix, SR, subtype='FLOAT')
    for k, v in stems.items():
        sf.write(os.path.join(out, 'music_stems', f'{k}.wav'), v / peak * 0.7, SR, subtype='FLOAT')
    print('music', mix.shape, 'peak normalised from', round(float(peak), 3))
