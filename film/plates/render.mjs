// Render coded fallback plates in headless Chromium (SwiftShader WebGL).
//   node plates/render.mjs H1 [H2 ...] [--still] [--t=0.5] [--fps=30] [--dur=1.4]
// Writes work/plates/<H>/frames/%04d.png and work/plates/<H>/corners.json (true screen corners).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DUR = { H1: 1.4, H2: 1.6, H3: 3.8, H4: 5.0, H5: 3.0, H6: 3.0 };
const args = process.argv.slice(2);
const shots = args.filter((a) => /^H\d$/.test(a));
const opt = Object.fromEntries(args.filter((a) => a.startsWith('--')).map((a) => { const [k, v] = a.slice(2).split('='); return [k, v ?? true]; }));
const fps = Number(opt.fps || 30);
const [SW, SH] = String(opt.size || '1080x1920').split('x').map(Number);
const SUFFIX = opt.size && opt.size !== '1080x1920' ? `_${SW === SH ? '1x1' : '16x9'}` : '';

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json' };
const server = http.createServer((req, res) => {
  const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]));
  if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': MIME[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const browser = await chromium.launch({
  executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--disable-gpu-vsync'],
});

for (const shot of shots) {
  const page = await browser.newPage({ viewport: { width: SW, height: SH } });
  page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') console.log(`[${shot}] ${m.type()}: ${m.text()}`); });
  page.on('pageerror', (e) => console.log(`[${shot}] pageerror: ${e.message}`));
  await page.goto(`http://127.0.0.1:${port}/plates/index.html`);
  await page.waitForFunction(() => window.__ready === true, null, { timeout: 60000 });
  await page.evaluate(([s, w, h]) => { window.__p = window.__plates(s, w, h); }, [shot, SW, SH]);
  const outDir = path.join(ROOT, 'work/plates' + SUFFIX, shot, opt.still ? 'stills' : 'frames');
  fs.mkdirSync(outDir, { recursive: true });
  const times = opt.still
    ? String(opt.t ?? '0').split(',').map(Number)
    : Array.from({ length: Math.round((Number(opt.dur) || DUR[shot]) * fps) }, (_, i) => i / fps);
  const corners = [];
  const t0 = Date.now();
  for (let i = 0; i < times.length; i++) {
    const r = await page.evaluate((t) => window.__p.frame(t), times[i]);
    const name = opt.still ? `${shot}_t${times[i].toFixed(2)}.png` : `${String(i).padStart(4, '0')}.png`;
    fs.writeFileSync(path.join(outDir, name), Buffer.from(r.url.split(',')[1], 'base64'));
    corners.push({ i, t: times[i], corners: r.corners, normalDot: r.normalDot });
    if (i % 15 === 0) process.stdout.write(`${shot} ${i + 1}/${times.length} ${((Date.now() - t0) / (i + 1) / 1000).toFixed(2)}s/f\n`);
  }
  fs.writeFileSync(path.join(path.dirname(outDir), opt.still ? 'stills_corners.json' : 'corners.json'), JSON.stringify({ shot, fps, frames: corners }, null, 1));
  await page.close();
}
await browser.close();
server.close();
