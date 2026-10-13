"""audioviz.py in.wav out.png [title] -- waveform + log spectrogram with second ticks."""
import sys
import numpy as np, soundfile as sf
from PIL import Image, ImageDraw, ImageFont
from scipy.signal import stft
x, sr = sf.read(sys.argv[1]); title = sys.argv[3] if len(sys.argv) > 3 else sys.argv[1]
m = x.mean(1) if x.ndim > 1 else x
W, H1, H2 = 2000, 220, 520
img = Image.new('RGB', (W, H1 + H2 + 60), (12, 12, 14)); d = ImageDraw.Draw(img)
dur = len(m) / sr
cols = np.array_split(m, W)
for i, c in enumerate(cols):
    a = np.abs(c).max() if len(c) else 0
    r = np.sqrt((c ** 2).mean()) if len(c) else 0
    d.line((i, 40 + H1 / 2 - a * H1 / 2, i, 40 + H1 / 2 + a * H1 / 2), fill=(90, 110, 140))
    d.line((i, 40 + H1 / 2 - r * H1 / 2, i, 40 + H1 / 2 + r * H1 / 2), fill=(200, 210, 230))
f, t, Z = stft(m, sr, nperseg=2048, noverlap=1536)
S = 20 * np.log10(np.abs(Z) + 1e-9)
fl = np.logspace(np.log10(30), np.log10(sr / 2), H2)
idx = np.clip(np.searchsorted(f, fl), 0, len(f) - 1)
S = S[idx][::-1]
S = np.clip((S + 100) / 80, 0, 1)
ti = np.linspace(0, S.shape[1] - 1, W).astype(int)
S = S[:, ti]
rgb = np.stack([S ** 0.8 * 255, S ** 1.6 * 220, S ** 3 * 160], -1).astype(np.uint8)
img.paste(Image.fromarray(rgb), (0, 40 + H1))
fnt = ImageFont.truetype('assets/fonts/Inter-500.ttf', 16)
for s in range(int(dur) + 1):
    x0 = s / dur * W
    d.line((x0, 40, x0, 40 + H1 + H2), fill=(70, 70, 70))
    d.text((x0 + 3, 40 + H1 + H2 + 4), f'{s}s', font=fnt, fill=(200, 200, 200))
d.text((6, 8), title, font=fnt, fill=(240, 220, 150))
img.save(sys.argv[2]); print(sys.argv[2])
