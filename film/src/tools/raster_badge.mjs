// Rasterise Apple's official App Store badge SVG at an exact width (transparent background).
import fs from 'node:fs';
import { chromium } from 'playwright-core';
const [src, out, width] = process.argv.slice(2);
const svg = fs.readFileSync(src, 'utf8');
const w = Number(width);
const h = Math.round(w * 40 / 119.66407);
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
await page.setContent(`<html><body style="margin:0;background:transparent"><img style="display:block;width:${w}px;height:${h}px" src="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}"></body></html>`);
await page.waitForTimeout(200);
await page.screenshot({ path: out, omitBackground: true });
await browser.close();
console.log(out, w, h);
