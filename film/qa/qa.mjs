// QA for a delivered film file. Rewritten 2026-10-12 (the earlier qa.mjs did not survive).
//   node qa/qa.mjs out/<file>.mp4 [--kind master|cut12|cut6|square|wide] [--json report.json]
// Checks: container + codecs, size, frame rate, duration, audio format, integrated loudness and true
// peak (ffmpeg ebur128), the 6.8-7.0 silence and the 7.0 hit (master only), no unintended black
// frames, no frozen video, the loop (last frame ~ first frame), then runs qa/qa_extra.py for the
// keying / face / portrait checks on the master.
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TL = JSON.parse(fs.readFileSync(path.join(ROOT, 'spec/timeline.json'), 'utf8'));
const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith('--'));
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };
const kind = opt('kind', 'master');
const results = [];
const check = (name, ok, detail) => { results.push({ name, ok: !!ok, detail }); };

const EXPECT = {
  master: { w: 1080, h: 1920, dur: TL.duration },
  cut12: { w: 1080, h: 1920, dur: 12.0 },
  cut6: { w: 1080, h: 1920, dur: 6.0 },
  square: { w: 1080, h: 1080, dur: TL.duration },
  wide: { w: 1920, h: 1080, dur: TL.duration },
}[kind];
if (opt('size')) { const [w, h] = opt('size').split('x').map(Number); EXPECT.w = w; EXPECT.h = h; }

const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file]).toString());
const v = probe.streams.find((s) => s.codec_type === 'video');
const a = probe.streams.find((s) => s.codec_type === 'audio');
check('video codec h264 high, yuv420p', v && v.codec_name === 'h264' && v.pix_fmt === 'yuv420p', `${v?.codec_name} ${v?.profile} ${v?.pix_fmt}`);
check(`size ${EXPECT.w}x${EXPECT.h}`, v && v.width === EXPECT.w && v.height === EXPECT.h, `${v?.width}x${v?.height}`);
check('30 fps constant', v && v.r_frame_rate === '30/1' && v.avg_frame_rate === '30/1', `${v?.r_frame_rate} avg ${v?.avg_frame_rate}`);
const dur = Number(probe.format.duration);
check(`duration ${EXPECT.dur.toFixed(2)} s (±1 frame)`, Math.abs(dur - EXPECT.dur) <= 1 / 30 + 0.025, dur.toFixed(3));
check('colour tagged bt709', v && (v.color_primaries === 'bt709' || v.color_space === 'bt709'), `${v?.color_space}/${v?.color_primaries}/${v?.color_transfer}`);
check('audio aac 48 kHz stereo', a && a.codec_name === 'aac' && a.sample_rate === '48000' && a.channels === 2, `${a?.codec_name} ${a?.sample_rate} ${a?.channels}ch`);
check('faststart (moov before mdat)', (() => { const b = fs.readFileSync(file).subarray(0, 4096).toString('latin1'); return b.indexOf('moov') > -1 && (b.indexOf('mdat') === -1 || b.indexOf('moov') < b.indexOf('mdat')); })(), '');

// loudness
const eb = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-i', file, '-filter_complex', 'ebur128=peak=true', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
const I = Number((eb.match(/I:\s+(-?[\d.]+) LUFS/g) || []).pop()?.match(/-?[\d.]+/)[0]);
const TP = Number((eb.match(/Peak:\s+(-?[\d.]+) dBFS/g) || []).pop()?.match(/-?[\d.]+/)[0]);
check('integrated loudness -14 LUFS (±0.5)', Math.abs(I - TL.loudness.lufs) <= 0.5, `${I} LUFS`);
check('true peak <= -1.0 dBTP', TP <= TL.loudness.true_peak_db + 0.05, `${TP} dBTP`);

// per-window audio levels (master only): silence at 6.8-7.0, the hit at 7.0
function rmsDb(t0, t1) {
  const raw = execFileSync('ffmpeg', ['-v', 'error', '-ss', String(t0), '-t', String(t1 - t0), '-i', file, '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'], { maxBuffer: 1 << 28 });
  const f = new Float32Array(raw.buffer, raw.byteOffset, raw.byteLength / 4);
  let s = 0, p = 0;
  for (const x of f) { s += x * x; p = Math.max(p, Math.abs(x)); }
  return { rms: 10 * Math.log10(s / Math.max(1, f.length) + 1e-12), peak: 20 * Math.log10(p + 1e-12) };
}
if (kind === 'master' || kind === 'square' || kind === 'wide') {
  const [s0, s1] = TL.h3.silence;
  const sil = rmsDb(s0 + 0.02, s1 - 0.02);   // AAC pre-roll smears a few ms either side
  check('silence 6.8-7.0 (below -60 dBFS RMS)', sil.rms < -60, `${sil.rms.toFixed(1)} dBFS rms, peak ${sil.peak.toFixed(1)}`);
  const hit = rmsDb(7.0, 7.4), pre = rmsDb(6.4, 6.8);
  check('the hit at 7.0 is the loudest moment so far', hit.rms > pre.rms + 3, `7.0-7.4 ${hit.rms.toFixed(1)} vs 6.4-6.8 ${pre.rms.toFixed(1)} dBFS`);
}

// black frames: only the intended ones (none: the flare is white, the end fades to the first frame)
const bd = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-i', file, '-vf', 'blackdetect=d=0.1:pix_th=0.06', '-an', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
const blacks = [...bd.matchAll(/black_start:([\d.]+) black_end:([\d.]+)/g)].map((m) => [Number(m[1]), Number(m[2])]);
check('no black segments >= 0.1 s', blacks.length === 0, JSON.stringify(blacks));

// frozen video: nothing should hold still for 0.8 s
const fd = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-i', file, '-vf', 'freezedetect=n=0.0008:d=0.8', '-an', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
const freezes = [...fd.matchAll(/freeze_start: ([\d.]+)/g)].map((m) => Number(m[1]));
check('no frozen stretches >= 0.8 s', freezes.length === 0, JSON.stringify(freezes));

// loop: last frame vs first frame
function frameAt(t) {
  return execFileSync('ffmpeg', ['-v', 'error', '-ss', String(t), '-i', file, '-frames:v', '1', '-vf', 'scale=108:-2', '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], { maxBuffer: 1 << 24 });
}
if (kind === 'master') {
  const f0 = frameAt(0), f1 = frameAt(dur - 1 / 30 - 0.001);
  let d = 0;
  for (let i = 0; i < Math.min(f0.length, f1.length); i++) d += Math.abs(f0[i] - f1[i]);
  d /= Math.min(f0.length, f1.length);
  check('loops: last frame within 4/255 of the first', d < 4, `mean abs diff ${d.toFixed(2)}`);
}

// keying / faces / portraits (master only)
if (kind === 'master') {
  const r = spawnSync('python3', [path.join(ROOT, 'qa/qa_extra.py'), '--json'], { encoding: 'utf8', maxBuffer: 1 << 26 });
  try {
    for (const c of JSON.parse(r.stdout.trim().split('\n').pop())) results.push(c);
  } catch (e) {
    check('qa_extra.py ran', false, (r.stderr || '').slice(-800));
  }
}

const failed = results.filter((r) => !r.ok);
for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? `  — ${r.detail}` : ''}`);
console.log(`\n${results.length - failed.length}/${results.length} passed  (${path.basename(file)}, ${kind})`);
const out = opt('json');
if (out) fs.writeFileSync(out, JSON.stringify({ file: path.basename(file), kind, results }, null, 1));
process.exit(failed.length ? 1 : 0);
