"""Small synthesis kit for the score and the sound design. 48 kHz, float32, stereo arrays (n, 2)."""
import numpy as np
from scipy.signal import butter, sosfilt, fftconvolve

SR = 48000


def secs(n):
    return int(round(n * SR))


def midi_hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def env_adsr(n, a, d, s, r, hold=None):
    """n samples; a,d,r in seconds; s level; hold = sustain length (default fills)."""
    A, D, R = secs(a), secs(d), secs(r)
    H = n - A - D - R if hold is None else secs(hold)
    H = max(H, 0)
    e = np.concatenate([np.linspace(0, 1, max(A, 1), endpoint=False), np.linspace(1, s, max(D, 1), endpoint=False),
                        np.full(H, s), np.linspace(s, 0, max(R, 1))])
    if len(e) < n:
        e = np.pad(e, (0, n - len(e)))
    return e[:n].astype(np.float32)


def lp(x, fc, order=2):
    sos = butter(order, min(fc, SR * 0.45), 'low', fs=SR, output='sos')
    return sosfilt(sos, x, axis=0).astype(np.float32)


def hp(x, fc, order=2):
    sos = butter(order, fc, 'high', fs=SR, output='sos')
    return sosfilt(sos, x, axis=0).astype(np.float32)


def bp(x, f0, f1, order=2):
    sos = butter(order, [f0, min(f1, SR * 0.45)], 'band', fs=SR, output='sos')
    return sosfilt(sos, x, axis=0).astype(np.float32)


def pan(mono, p):
    """p in -1..1, constant power."""
    a = (p + 1) * np.pi / 4
    return np.stack([mono * np.cos(a), mono * np.sin(a)], axis=1).astype(np.float32)


def place(buf, sig, t):
    i = secs(t)
    if i >= len(buf):
        return
    j = min(len(buf), i + len(sig))
    if i < 0:
        sig = sig[-i:]
        j = min(len(buf), len(sig))
        i = 0
    buf[i:j] += sig[:j - i]


def polyblep_saw(freq, n, phase0=0.0):
    """freq: scalar or per-sample array (Hz)."""
    f = np.broadcast_to(np.asarray(freq, np.float64), (n,))
    dt = f / SR
    ph = (phase0 + np.cumsum(dt)) % 1.0
    y = 2 * ph - 1
    m1 = ph < dt
    x = ph[m1] / dt[m1]
    y[m1] -= x + x - x * x - 1
    m2 = ph > 1 - dt
    x = (ph[m2] - 1) / dt[m2]
    y[m2] -= x * x + x + x + 1
    return y.astype(np.float32)


# ------------------------------------------------------------------------------ instruments
def piano(m, vel=0.7, dur=3.0, rng=None):
    """Additive piano-ish note: inharmonic partials, per-partial decay, hammer noise, 3 strings."""
    rng = rng or np.random.default_rng(int(m * 100 + vel * 10))
    n = secs(dur + 2.5)
    t = np.arange(n, dtype=np.float32) / SR
    f0 = midi_hz(m)
    B = 0.00035 * (1 + (m - 60) / 40)
    out = np.zeros(n, np.float32)
    bright = 0.6 + 0.8 * vel
    for k in range(1, 16):
        fk = f0 * k * np.sqrt(1 + B * k * k)
        if fk > 16000:
            break
        amp = (1.0 / k ** (1.25 - 0.35 * bright)) * (1 if k == 1 else 0.9)
        t60 = max(0.25, (7.5 - (m - 48) * 0.07) / (1 + 0.32 * (k - 1)))
        dec = np.exp(-6.9 * t / t60)
        for det in (-0.6, 0.0, 0.7):                               # three slightly detuned strings
            ph = rng.uniform(0, 2 * np.pi)
            out += (amp / 3) * dec * np.sin(2 * np.pi * fk * (1 + det / 1731) * t + ph)
    att = np.minimum(1, t / 0.003)
    rel = np.ones(n, np.float32)
    r0 = secs(dur)
    rel[r0:] = np.exp(-(t[r0:] - dur) / 0.25)                      # damper
    noise = lp(rng.normal(0, 1, secs(0.03)).astype(np.float32), 2500 + 3000 * vel) * np.exp(-np.arange(secs(0.03)) / secs(0.006))
    out[:len(noise)] += noise * 0.06 * vel
    return (out * att * rel * vel * 0.32).astype(np.float32)


def strings(notes, dur, vel=0.6, a=0.45, r=0.9, cutoff=3200, rng=None, vib=5.2):
    """Ensemble pad: per note 6 detuned polyBLEP saws with vibrato, lowpassed. Returns stereo."""
    rng = rng or np.random.default_rng(int(sum(notes)))
    n = secs(dur + r)
    t = np.arange(n) / SR
    L = np.zeros(n, np.float32)
    R = np.zeros(n, np.float32)
    for m in notes:
        f0 = midi_hz(m)
        for v in range(6):
            det = (v - 2.5) * 3.2 + rng.normal(0, 1.2)            # cents
            vr = vib * (1 + rng.normal(0, 0.06))
            fv = f0 * 2 ** ((det + 7 * np.sin(2 * np.pi * vr * t + rng.uniform(0, 6))) / 1200)
            s = polyblep_saw(fv, n, rng.uniform())
            p = (v / 5) * 2 - 1
            L += s * np.cos((p + 1) * np.pi / 4)
            R += s * np.sin((p + 1) * np.pi / 4)
    x = np.stack([L, R], 1) / (6 * len(notes)) ** 0.5
    x = lp(x, cutoff, 2)
    x = lp(x, cutoff * 1.6, 2)
    e = env_adsr(n, a, 0.2, 0.9, r, hold=max(0.0, dur - a - 0.2))
    return (x * e[:, None] * vel * 0.5).astype(np.float32)


def pulse_note(m, dur=0.2, vel=0.7):
    """Cinematic pulse: saw+sine, plucky lowpass envelope."""
    n = secs(dur + 0.15)
    t = np.arange(n) / SR
    f = midi_hz(m)
    s = 0.6 * polyblep_saw(f, n) + 0.8 * np.sin(2 * np.pi * f * t).astype(np.float32)
    env = np.exp(-t / (dur * 0.55)).astype(np.float32) * np.minimum(1, t / 0.004)
    s = lp(s * env, 600 + 1400 * vel)
    return (s * vel * 0.5).astype(np.float32)


def kick(vel=1.0, f_hi=110, f_lo=45, decay=0.45):
    n = secs(decay * 2.2)
    t = np.arange(n) / SR
    f = f_lo + (f_hi - f_lo) * np.exp(-t / 0.045)
    ph = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(ph) * np.exp(-t / decay)
    click = lp(np.random.default_rng(3).normal(0, 1, n).astype(np.float32), 4000) * np.exp(-t / 0.004) * 0.3
    return ((body + click) * vel * 0.9).astype(np.float32)


def noise_burst(dur, lo=200, hi=6000, decay=0.2, seed=0):
    n = secs(dur)
    t = np.arange(n) / SR
    x = np.random.default_rng(seed).normal(0, 1, n).astype(np.float32)
    x = bp(x, lo, hi)
    return (x * np.exp(-t / decay)).astype(np.float32)


def chime(m, vel=0.6, dur=2.6):
    """FM bell."""
    n = secs(dur)
    t = np.arange(n) / SR
    f = midi_hz(m)
    I = 2.2 * np.exp(-t / 0.5)
    y = np.sin(2 * np.pi * f * t + I * np.sin(2 * np.pi * f * 3.5 * t))
    y += 0.35 * np.sin(2 * np.pi * f * 2.76 * t) * np.exp(-t / 0.4)
    env = np.exp(-t / 0.9) * np.minimum(1, t / 0.002)
    return (y * env * vel * 0.35).astype(np.float32)


def reverb_ir(t60=2.2, seed=7, predelay=0.012, damp=4500):
    n = secs(t60 * 1.2)
    t = np.arange(n) / SR
    rng = np.random.default_rng(seed)
    ir = rng.normal(0, 1, (n, 2)).astype(np.float32) * np.exp(-6.9 * t / t60)[:, None]
    # darken the tail progressively: crossfade a lowpassed copy in
    dark = lp(ir, damp * 0.35)
    w = np.clip(t / (t60 * 0.6), 0, 1)[:, None]
    ir = ir * (1 - w) + dark * w
    ir = lp(ir, damp)
    pd = secs(predelay)
    ir = np.vstack([np.zeros((pd, 2), np.float32), ir])
    for k, (d, g) in enumerate([(0.007, 0.5), (0.013, 0.4), (0.019, 0.35), (0.027, 0.3)]):
        i = secs(d)
        ir[i, k % 2] += g
    return ir / np.sqrt((ir ** 2).sum(0, keepdims=True))


def reverb(x, wet=0.25, t60=2.2, seed=7):
    ir = reverb_ir(t60, seed)
    y = np.stack([fftconvolve(x[:, 0], ir[:, 0])[:len(x)], fftconvolve(x[:, 1], ir[:, 1])[:len(x)]], 1)
    return (x * (1 - wet) + y.astype(np.float32) * wet * 1.4).astype(np.float32)
