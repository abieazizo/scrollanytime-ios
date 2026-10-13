"""Encode the deliverables from rendered frames + mixes.

  python3 src/deliver.py master|cuts|aspect <tag> [--frames work/frames] [--size 1080x1920]
"""
import json, os, subprocess, sys
import numpy as np
import soundfile as sf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'src/audio'))
TL = json.load(open(os.path.join(ROOT, 'spec/timeline.json')))
FPS = TL['fps']
OUT = os.path.join(ROOT, 'out')
A = os.path.join(ROOT, 'work/audio')
os.makedirs(OUT, exist_ok=True)

VENC = ['-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-tune', 'grain', '-profile:v', 'high', '-level', '4.2',
        '-pix_fmt', 'yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
        '-color_range', 'tv', '-g', '30', '-bf', '2', '-movflags', '+faststart']
AENC = ['-c:a', 'aac', '-b:a', '320k', '-ar', '48000', '-ac', '2']


def encode(frames_dir, wav, out, start_frame=0, nframes=None, frame_list=None):
    if frame_list is not None:
        lst = os.path.join(ROOT, 'work', os.path.basename(out) + '.frames.txt')
        with open(lst, 'w') as f:
            for k in frame_list:
                f.write(f"file '{os.path.join(frames_dir, f'{k:04d}.png')}'\nduration {1 / FPS:.6f}\n")
            f.write(f"file '{os.path.join(frames_dir, f'{frame_list[-1]:04d}.png')}'\n")
        vin = ['-f', 'concat', '-safe', '0', '-i', lst]
        n = len(frame_list)
    else:
        vin = ['-framerate', str(FPS), '-start_number', str(start_frame), '-i', os.path.join(frames_dir, '%04d.png')]
        n = nframes
    cmd = ['ffmpeg', '-v', 'error', '-y', *vin, '-i', wav,
           '-vf', f'fps={FPS},scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
           *VENC, *AENC, '-frames:v', str(n), '-t', f'{n / FPS:.4f}', '-shortest', out]
    subprocess.run(cmd, check=True)
    print('wrote', out)


def cut_audio(src_wav, ranges, out_wav, tail_fade=0.0, xf=0.04):
    import mix as M
    import pyloudnorm as pyln
    x, sr = sf.read(src_wav, dtype='float32')
    parts = [x[int(round(a * sr)):int(round(b * sr))].copy() for a, b in ranges]
    n = int(sr * xf)
    for k in range(len(parts)):
        if k > 0:
            parts[k][:n] *= np.linspace(0, 1, n)[:, None]
        if k < len(parts) - 1:
            parts[k][-n:] *= np.linspace(1, 0, n)[:, None]
    y = np.concatenate(parts)
    if tail_fade:
        m = int(sr * tail_fade)
        y[-m:] *= np.linspace(1, 0, m)[:, None] ** 1.5
    meter = pyln.Meter(sr)
    for _ in range(5):
        L = meter.integrated_loudness(y.astype(np.float64))
        y = y * 10 ** ((TL['loudness']['lufs'] - L) / 20)
        y = M.limit(y, TL['loudness']['true_peak_db'] - 0.1)
    sf.write(out_wav, y, sr, subtype='PCM_24')
    return out_wav


def frames_for(ranges):
    ks = []
    for a, b in ranges:
        ks += list(range(int(round(a * FPS)), int(round(b * FPS))))
    return ks


if __name__ == '__main__':
    what = sys.argv[1]
    tag = sys.argv[2] if len(sys.argv) > 2 else 'pass1'
    frames = os.path.join(ROOT, 'work/frames')
    if '--frames' in sys.argv:
        frames = sys.argv[sys.argv.index('--frames') + 1]
    NF = int(round(TL['duration'] * FPS))
    if what == 'master':
        encode(frames, os.path.join(A, 'mix_novoice.wav'), os.path.join(OUT, f'ScrollAnytime_{tag}_master_novoice.mp4'), 0, NF)
        if os.path.exists(os.path.join(A, 'mix_voice.wav')):
            encode(frames, os.path.join(A, 'mix_voice.wav'), os.path.join(OUT, f'ScrollAnytime_{tag}_master_voice.mp4'), 0, NF)
    elif what == 'cuts':
        for name, key, fade in (('12s', 'c12', 0.0), ('6s', 'c6', 0.35)):
            rng = TL['cuts'][key]
            for kind in ('novoice', 'voice'):
                src = os.path.join(A, f'mix_{kind}.wav')
                if not os.path.exists(src):
                    continue
                wav = cut_audio(src, rng, os.path.join(A, f'cut_{name}_{kind}.wav'), fade)
                encode(frames, wav, os.path.join(OUT, f'ScrollAnytime_{tag}_{name}_{kind}.mp4'), frame_list=frames_for(rng))
    elif what == 'extras':
        import shutil, cv2
        # the cover at cover_t, full frame and a 4:5 crop for the grid
        k = int(round(TL['cover_t'] * FPS))
        im = cv2.imread(os.path.join(frames, f'{k:04d}.png'))
        cv2.imwrite(os.path.join(OUT, f'ScrollAnytime_{tag}_cover_t{TL["cover_t"]:.1f}.png'), im)
        cv2.imwrite(os.path.join(OUT, f'ScrollAnytime_{tag}_cover_t{TL["cover_t"]:.1f}.jpg'), im, [cv2.IMWRITE_JPEG_QUALITY, 95])
        # chosen stills + plates (fallbacks), with seeds
        sd = os.path.join(OUT, 'stills_and_plates')
        os.makedirs(sd, exist_ok=True)
        seeds = {'H1': 1101, 'H2': 1202, 'H3': 1303, 'H4': 1404, 'H5': 1505, 'H6': 1606}
        man = {}
        for shot, seed in seeds.items():
            gen = os.path.join(ROOT, 'assets/plates', f'{shot}.mp4')
            src_dir = os.path.join(ROOT, 'work/plates', shot, 'frames')
            first = sorted(os.listdir(src_dir))[0]
            shutil.copy(os.path.join(src_dir, first), os.path.join(sd, f'{shot}_still_seed{seed}.png'))
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', os.path.join(src_dir, '%04d.png'),
                            '-c:v', 'libx264', '-crf', '16', '-preset', 'slow', '-pix_fmt', 'yuv420p', os.path.join(sd, f'{shot}_plate_seed{seed}.mp4')], check=True)
            man[shot] = {'source': 'generated' if os.path.exists(gen) else 'coded fallback (three.js)', 'seed': seed,
                         'still': f'{shot}_still_seed{seed}.png', 'plate': f'{shot}_plate_seed{seed}.mp4',
                         'frames': len(os.listdir(src_dir))}
        json.dump(man, open(os.path.join(sd, 'seeds.json'), 'w'), indent=1)
        print('extras written')
    elif what == 'aspect':
        size = sys.argv[sys.argv.index('--size') + 1]
        for kind in ('novoice', 'voice'):
            src = os.path.join(A, f'mix_{kind}.wav')
            if os.path.exists(src):
                encode(frames, src, os.path.join(OUT, f'ScrollAnytime_{tag}_{size}_{kind}.mp4'), 0, NF)
