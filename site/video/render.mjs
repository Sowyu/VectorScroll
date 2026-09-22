// Records a real web page in headless Chromium, frame by frame, with a cursor and the VectorScroll
// indicator drawn on top. Scroll speed follows the app's rules: 10 px dead zone, then distance.
// Usage: node render.mjs [path-to-chrome]    Needs playwright-core and ffmpeg (libx264, libvpx-vp9).
// A real screen recording from a Mac is better than this. Replace demo.mp4 and demo.webm when you have one.
import { chromium } from 'playwright-core';
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const URL = 'https://en.wikipedia.org/wiki/Scrolling';
const W = 1024, H = 680, FPS = 60, SECONDS = 12;
const DEAD = 10, GAIN = 0.11, MAX = 26;
const here = path.dirname(fileURLToPath(import.meta.url));
const frames = path.join(here, 'frames');

const ease = t => t < .5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
const seg = (ms, a, b) => Math.min(1, Math.max(0, (ms - a) / (b - a)));
const lerp = (a, b, t) => a + (b - a) * t;
const O = { x: 560, y: 330 };

// Waypoints: time in ms, pointer position, button state. Straight-ish moves with pauses, like a person.
function pose(ms) {
  if (ms < 900) return { x: lerp(900, 590, ease(seg(ms, 0, 900))), y: lerp(600, 345, ease(seg(ms, 0, 900))), down: false };
  if (ms < 1500) return { x: lerp(590, O.x, ease(seg(ms, 900, 1400))), y: lerp(345, O.y, ease(seg(ms, 900, 1400))), down: false };
  if (ms < 1800) return { ...O, down: true };                                                     // press, hesitate
  if (ms < 4800) return { x: O.x + 14 * seg(ms, 1800, 4800), y: O.y + 55 * ease(seg(ms, 1800, 3200)), down: true };
  if (ms < 6000) return { x: O.x + lerp(14, 9, seg(ms, 4800, 6000)), y: O.y + lerp(55, 22, ease(seg(ms, 4800, 6000))), down: true };
  if (ms < 9200) return { x: O.x + lerp(9, -6, seg(ms, 6000, 9200)), y: O.y + lerp(22, -90, ease(seg(ms, 6000, 7600))), down: true };
  if (ms < 10200) return { x: O.x + lerp(-6, 2, seg(ms, 9200, 10200)), y: O.y + lerp(-90, 3, ease(seg(ms, 9200, 10000))), down: ms < 10000 };
  return { x: lerp(O.x + 2, 900, ease(seg(ms, 10400, 12000))), y: lerp(O.y + 3, 600, ease(seg(ms, 10400, 12000))), down: false };
}

const browser = await chromium.launch({ executablePath: process.argv[2] || process.env.CHROME });
const page = await browser.newPage({
  viewport: { width: W, height: H }, deviceScaleFactor: 1,
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15',
});
await page.goto(URL, { waitUntil: 'networkidle' });
// Linux has no Helvetica or SF, so load Inter for the body text. Headings keep Wikipedia's serif stack.
await page.addStyleTag({ url: 'https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=block' });
await page.addStyleTag({ content: `*, *::before, *::after { animation: none !important; transition: none !important; } html { scroll-behavior: auto !important; }
  body, .vector-body, .mw-body-content, .vector-menu, .vector-header, .cdx-button, input { font-family: Inter, sans-serif !important; }` });
await page.evaluate(() => document.fonts.ready);
await page.evaluate(() => {
  document.body.insertAdjacentHTML('beforeend', `
    <svg id="vs-ring" style="position:fixed;width:64px;height:64px;margin:-32px 0 0 -32px;opacity:0;pointer-events:none;z-index:2147483646" viewBox="0 0 64 64">
      <ellipse cx="32" cy="34" rx="30" ry="30" fill="rgba(0,0,0,.18)"/>
      <circle cx="32" cy="32" r="30" fill="rgba(0,0,0,.88)" stroke="rgba(255,255,255,.72)" stroke-width="2"/>
      <circle cx="32" cy="32" r="4" fill="rgba(255,255,255,.78)"/>
      <g stroke="rgba(255,255,255,.78)" stroke-width="4" stroke-linecap="round" fill="none">
        <path d="M32 24V10M26 15l6-5 6 5"/><path d="M32 40v14M26 49l6 5 6-5"/><path d="M24 32H10M15 26l-5 6 5 6"/><path d="M40 32h14M49 26l5 6-5 6"/>
      </g>
    </svg>
    <svg id="vs-cursor" style="position:fixed;width:22px;height:32px;margin:-2px 0 0 -2px;pointer-events:none;z-index:2147483647" viewBox="0 0 28 40">
      <path d="M3 2l20 17-9 1 5 12-4 2-5-12-7 7z" fill="#000" stroke="#fff" stroke-width="2.2" stroke-linejoin="round"/>
    </svg>`);
  window.scrollTo(0, 0);
});

rmSync(frames, { recursive: true, force: true });
mkdirSync(frames);
let scroll = 0, pressAt = null, releaseAt = null, wasDown = false;
const total = SECONDS * FPS;
for (let n = 0; n < total; n++) {
  const ms = n * 1000 / FPS;
  const p = pose(ms);
  const t = ms / 1000;
  const x = p.x + 0.7 * Math.sin(t * 8.1) + 0.4 * Math.sin(t * 13.7), y = p.y + 0.6 * Math.sin(t * 9.3 + 1) + 0.4 * Math.sin(t * 15.1);
  if (p.down && !wasDown) { pressAt = ms; releaseAt = null; }
  if (!p.down && wasDown) releaseAt = ms;
  wasDown = p.down;
  if (p.down) {
    const dy = p.y - O.y;
    const v = Math.abs(dy) <= DEAD ? 0 : (dy > 0 ? dy - DEAD : dy + DEAD) * GAIN;
    scroll = Math.max(0, scroll + Math.max(-MAX, Math.min(MAX, v)));
  }
  let op = 0, sc = .6;
  if (pressAt !== null && p.down) { const t = seg(ms, pressAt, pressAt + 200); op = Math.min(1, t * 2); sc = lerp(.6, 1, 1 - Math.pow(1 - t, 3)); }
  else if (releaseAt !== null) { const t = seg(ms, releaseAt, releaseAt + 180); op = 1 - t; sc = 1; }
  await page.evaluate(([scroll, x, y, op, sc, ox, oy]) => {
    window.scrollTo(0, scroll);
    const c = document.getElementById('vs-cursor'); c.style.left = x + 'px'; c.style.top = y + 'px';
    const r = document.getElementById('vs-ring'); r.style.left = ox + 'px'; r.style.top = oy + 'px'; r.style.opacity = op; r.style.transform = `scale(${sc})`;
  }, [scroll, x, y, op, sc, O.x, O.y]);
  writeFileSync(path.join(frames, String(n).padStart(4, '0') + '.png'), await page.screenshot({ type: 'png' }));
  if (n % 60 === 0) console.log(`frame ${n}/${total}`);
}
await browser.close();

const input = ['-framerate', String(FPS), '-i', path.join(frames, '%04d.png')];
const run = (args) => { const r = spawnSync('ffmpeg', ['-y', '-v', 'error', ...args], { stdio: 'inherit' }); if (r.status !== 0) process.exit(r.status); };
run([...input, '-c:v', 'libx264', '-preset', 'slow', '-crf', '19', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path.join(here, '..', 'demo.mp4')]);
run([...input, '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '30', '-row-mt', '1', '-pix_fmt', 'yuv420p', path.join(here, '..', 'demo.webm')]);
run(['-i', path.join(frames, '0240.png'), '-q:v', '3', path.join(here, '..', 'poster.jpg')]);
rmSync(frames, { recursive: true, force: true });
console.log('done');
