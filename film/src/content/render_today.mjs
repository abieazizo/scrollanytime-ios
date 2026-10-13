// Render the H5 Today screen (1179x2556) for film time 11.0..14.0 -> work/content/today/%04d.png
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const TL = JSON.parse(fs.readFileSync(path.join(ROOT, 'spec/timeline.json'), 'utf8'));
const MIME = { '.html': 'text/html', '.ttf': 'font/ttf', '.js': 'text/javascript' };
const server = http.createServer((req, res) => {
  const p = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]));
  if (!p.startsWith(ROOT) || !fs.existsSync(p)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': MIME[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const page = await browser.newPage({ viewport: { width: 1179, height: 2556 }, deviceScaleFactor: 1 });
page.on('pageerror', (e) => console.log('pageerror', e.message));
await page.goto(`http://127.0.0.1:${server.address().port}/src/content/today.html?tl=${encodeURIComponent(JSON.stringify(TL))}`);
await page.waitForFunction(() => window.__ready === true);
await page.evaluate(() => document.fonts.ready);
const out = path.join(ROOT, 'work/content/today');
fs.mkdirSync(out, { recursive: true });
const only = process.argv[2] ? process.argv[2].split(',').map(Number) : null;
const n = Math.round(3.0 * TL.fps);
for (let i = 0; i < n; i++) {
  const t = 11.0 + i / TL.fps;
  if (only && !only.some((x) => Math.abs(x - t) < 0.5 / TL.fps)) continue;
  await page.evaluate((tt) => window.render(tt), t);
  await page.screenshot({ path: path.join(out, `${String(i).padStart(4, '0')}.png`) });
}
await browser.close();
server.close();
console.log('today frames', fs.readdirSync(out).length);
