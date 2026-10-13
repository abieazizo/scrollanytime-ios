"""Mix music + sfx (+ Will take 1 and Ovadia's own voice when present) to -14 LUFS integrated and
-1 dBTP true peak. Voice lines duck the music 7 dB. The 6.8-7.0 silence stays digital silence.
  python3 mix.py [--voice]   -> work/audio/mix_novoice.wav  (and mix_voice.wav with --voice)"""
import json, os, sys
import numpy as np
import soundfile as sf
import pyloudnorm as pyln
from scipy.signal import resample_poly
from synth import SR, secs, place, lp

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TL = json.load(open(os.path.join(ROOT, 'spec/timeline.json')))
A = os.path.join(ROOT, 'work/audio')
VOICE_DIR = os.path.join(ROOT, 'assets/voice/will_take1')
N = secs(TL['duration'])


def true_peak_env(x, os_=4):
    """Per-sample true peak (max over channels of the 4x-oversampled |x|)."""
    up = resample_poly(x, os_, 1, axis=0)
    a = np.abs(up).max(1)
    a = a[:len(x) * os_].reshape(-1, os_).max(1)
    return a


def limit(x, ceiling_db=-1.0, look=0.0015, release=0.08):
    thr = 10 ** (ceiling_db / 20)
    for _ in range(4):
        tp = true_peak_env(x)
        g = np.minimum(1.0, thr / np.maximum(tp, 1e-9))
        L = secs(look)
        from scipy.ndimage import minimum_filter1d
        g = minimum_filter1d(g, size=2 * L + 1)
        a = np.exp(-1 / (SR * release))
        out = np.empty_like(g)
        cur = 1.0
        for i in range(len(g)):            # instant attack (lookahead covers it), smooth release
            cur = g[i] if g[i] < cur else a * cur + (1 - a) * g[i]
            out[i] = cur
        x = x * out[:, None]
        if true_peak_env(x).max() <= thr * 1.0001:
            break
    return x


def load(name):
    p = os.path.join(A, name)
    x, sr = sf.read(p, dtype='float32')
    assert sr == SR
    return x[:N] if len(x) >= N else np.pad(x, ((0, N - len(x)), (0, 0)))


def mix(with_voice):
    music = load('music.wav')
    sfx = load('sfx.wav')
    voice = np.zeros((N, 2), np.float32)
    present = []
    if with_voice:
        for ln in TL['voice']['lines']:
            p = os.path.join(VOICE_DIR, f"{ln['id']}.wav")
            if os.path.exists(p):
                v, sr = sf.read(p, dtype='float32')
                v = v if v.ndim == 2 else np.stack([v, v], 1)
                if sr != SR:
                    v = resample_poly(v, SR, sr, axis=0).astype(np.float32)
                place(voice, v, ln['t'])
                present.append(ln['id'])
    duck = np.ones(N, np.float32)
    if present:
        env = lp(np.abs(voice).max(1), 8, 1)
        duck = 1 - 0.55 * np.clip(env / (env.max() + 1e-9) * 3, 0, 1)
    x = music * 0.62 * duck[:, None] + sfx * 0.55 + voice * 1.0
    meter = pyln.Meter(SR)
    s0, s1 = secs(TL['h3']['silence'][0]), secs(TL['h3']['silence'][1])
    for it in range(6):
        L = meter.integrated_loudness(x.astype(np.float64))
        x = x * 10 ** ((TL['loudness']['lufs'] - L) / 20)
        x = limit(x, TL['loudness']['true_peak_db'] - 0.1)
        x[s0:s1] = 0
        L2 = meter.integrated_loudness(x.astype(np.float64))
        if abs(L2 - TL['loudness']['lufs']) < 0.05:
            break
    tp = 20 * np.log10(true_peak_env(x).max())
    return x.astype(np.float32), {'lufs': round(L2, 2), 'true_peak_dbtp': round(float(tp), 2), 'voice_lines': present, 'iterations': it + 1}


if __name__ == '__main__':
    report = {}
    x, r = mix(False)
    sf.write(os.path.join(A, 'mix_novoice.wav'), x, SR, subtype='PCM_24')
    report['novoice'] = r
    if '--voice' in sys.argv:
        x, r = mix(True)
        if r['voice_lines']:
            sf.write(os.path.join(A, 'mix_voice.wav'), x, SR, subtype='PCM_24')
        report['voice'] = r
    json.dump(report, open(os.path.join(A, 'mix_report.json'), 'w'), indent=1)
    print(json.dumps(report))
