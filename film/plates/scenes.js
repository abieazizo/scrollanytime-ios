// Coded fallback plates for the six Higgsfield shots. Every screen is flat #00FF00 (toneMapped off,
// fog off) so the plate goes through the same keyer a generated plate would. Each frame also
// reports the screen's true corners (TL, TR, BR, BL, in content orientation) so QA can measure the
// keyer against ground truth. Deterministic: every random draw comes from a seeded PRNG.
import * as THREE from 'three';
import { RectAreaLightUniformsLib } from 'three/addons/lights/RectAreaLightUniformsLib.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { BokehPass } from 'three/addons/postprocessing/BokehPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';

RectAreaLightUniformsLib.init();

export const SEEDS = { H1: 1101, H2: 1202, H3: 1303, H4: 1404, H5: 1505, H6: 1606 };

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// smooth pseudo-noise from a few incommensurate sines (hand-held drift)
function drift(t, s) {
  return Math.sin(t * 1.31 + s) * 0.5 + Math.sin(t * 2.17 + s * 1.7) * 0.3 + Math.sin(t * 3.73 + s * 2.3) * 0.2;
}
const ease = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x));

// ---------------------------------------------------------------- textures (procedural, no text)
function canvasTex(w, h, draw, srgb = true, repeat = null) {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  draw(c.getContext('2d'), w, h);
  const t = new THREE.CanvasTexture(c);
  if (srgb) t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  if (repeat) { t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(repeat[0], repeat[1]); }
  return t;
}

function woodTex(seed, base = [92, 58, 34], w = 1024, h = 1024) {
  const r = rng(seed);
  return canvasTex(w, h, (g) => {
    g.fillStyle = `rgb(${base})`; g.fillRect(0, 0, w, h);
    for (let i = 0; i < 900; i++) {
      const y = r() * h, k = 0.75 + r() * 0.5, a = 0.05 + r() * 0.12;
      g.strokeStyle = `rgba(${Math.floor(base[0] * k * 0.6)},${Math.floor(base[1] * k * 0.6)},${Math.floor(base[2] * k * 0.6)},${a})`;
      g.lineWidth = 0.6 + r() * 2.2;
      g.beginPath();
      let x = 0, yy = y;
      g.moveTo(x, yy);
      const amp = 2 + r() * 8, fr = 0.002 + r() * 0.01, ph = r() * 6;
      for (x = 0; x <= w; x += 16) g.lineTo(x, yy + Math.sin(x * fr + ph) * amp);
      g.stroke();
    }
    for (let i = 0; i < 9; i++) { // knots
      const x = r() * w, y = r() * h;
      const gr = g.createRadialGradient(x, y, 0, x, y, 10 + r() * 22);
      gr.addColorStop(0, 'rgba(30,16,8,0.55)'); gr.addColorStop(1, 'rgba(30,16,8,0)');
      g.fillStyle = gr; g.beginPath(); g.ellipse(x, y, 40, 12, 0, 0, 7); g.fill();
    }
  });
}

function noiseTex(seed, w, h, lo, hi, srgb = true) {
  const r = rng(seed);
  return canvasTex(w, h, (g) => {
    const im = g.createImageData(w, h);
    for (let i = 0; i < w * h; i++) {
      const v = lo + (hi - lo) * r();
      im.data[i * 4] = im.data[i * 4 + 1] = im.data[i * 4 + 2] = v; im.data[i * 4 + 3] = 255;
    }
    g.putImageData(im, 0, 0);
  }, srgb);
}

function fabricTex(seed) {
  const r = rng(seed);
  return canvasTex(512, 512, (g, w, h) => {
    g.fillStyle = '#f2f2f2'; g.fillRect(0, 0, w, h);
    for (let i = 0; i < 160; i++) {
      const x = r() * w, y = r() * h, rad = 30 + r() * 110;
      const gr = g.createRadialGradient(x, y, 0, x, y, rad);
      const v = r() < 0.5 ? 255 : 200;
      gr.addColorStop(0, `rgba(${v},${v},${v},0.10)`); gr.addColorStop(1, `rgba(${v},${v},${v},0)`);
      g.fillStyle = gr; g.fillRect(0, 0, w, h);
    }
    g.globalAlpha = 0.05;
    for (let y = 0; y < h; y += 2) { g.fillStyle = y % 4 ? '#000' : '#fff'; g.fillRect(0, y, w, 1); }
    g.globalAlpha = 1;
  }, true, [3, 3]);
}

function softDot() {
  return canvasTex(64, 64, (g) => {
    const gr = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(0.35, 'rgba(255,255,255,0.55)');
    gr.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = gr; g.fillRect(0, 0, 64, 64);
  });
}

// ---------------------------------------------------------------- the phone
function rrShape(w, h, r) {
  const s = new THREE.Shape();
  const x = -w / 2, y = -h / 2;
  s.moveTo(x + r, y);
  s.lineTo(x + w - r, y); s.absarc(x + w - r, y + r, r, -Math.PI / 2, 0, false);
  s.lineTo(x + w, y + h - r); s.absarc(x + w - r, y + h - r, r, 0, Math.PI / 2, false);
  s.lineTo(x + r, y + h); s.absarc(x + r, y + h - r, r, Math.PI / 2, Math.PI, false);
  s.lineTo(x, y + r); s.absarc(x + r, y + r, r, Math.PI, 1.5 * Math.PI, false);
  return s;
}

export const SCREEN_W = 0.0652, SCREEN_H = 0.0652 * 2556 / 1179;

function makePhone({ screenLight = 0xdde6ff, screenLightI = 6, titanium = 0x9b958c } = {}) {
  const g = new THREE.Group();
  const T = 0.0060, B = 0.0011;
  const bodyGeo = new THREE.ExtrudeGeometry(rrShape(0.0715 - 2 * B, 0.1496 - 2 * B, 0.0112), {
    depth: T, bevelEnabled: true, bevelThickness: B, bevelSize: B, bevelSegments: 8, curveSegments: 40,
  });
  bodyGeo.translate(0, 0, -T / 2);
  const ti = new THREE.MeshPhysicalMaterial({ color: titanium, metalness: 1.0, roughness: 0.34, envMapIntensity: 0.25 });
  g.add(new THREE.Mesh(bodyGeo, ti));
  const zf = T / 2 + B;
  const glass = new THREE.Mesh(new THREE.ShapeGeometry(rrShape(0.0703, 0.1484, 0.0106), 40),
    new THREE.MeshPhysicalMaterial({ color: 0x030303, roughness: 0.06, metalness: 0, clearcoat: 1, clearcoatRoughness: 0.04 }));
  glass.position.z = zf + 0.00005;
  g.add(glass);
  const screen = new THREE.Mesh(new THREE.ShapeGeometry(rrShape(SCREEN_W, SCREEN_H, 0.0094), 48),
    new THREE.MeshBasicMaterial({ color: 0x00ff00, toneMapped: false, fog: false }));
  screen.position.z = zf + 0.0001;
  g.add(screen);
  const back = new THREE.Mesh(new THREE.ShapeGeometry(rrShape(0.0703, 0.1484, 0.0106), 40),
    new THREE.MeshPhysicalMaterial({ color: 0x2b2a28, roughness: 0.55 }));
  back.position.z = -zf - 0.00005; back.rotation.y = Math.PI;
  g.add(back);
  // buttons: action + volume on the left, side + camera control on the right
  const btn = (x, y, h) => {
    const m = new THREE.Mesh(new THREE.BoxGeometry(0.0012, h, 0.0034), ti);
    m.position.set(x, y, 0); g.add(m);
  };
  btn(-0.0362, 0.046, 0.007); btn(-0.0362, 0.031, 0.011); btn(-0.0362, 0.017, 0.011);
  btn(0.0362, 0.033, 0.016); btn(0.0362, -0.012, 0.010);
  if (screenLightI > 0) {
    const L = new THREE.RectAreaLight(screenLight, screenLightI, SCREEN_W, SCREEN_H);
    L.position.set(0, 0, zf + 0.0005);
    L.rotation.y = Math.PI; // RectAreaLight emits along its -z; flip it to face out of the screen
    g.add(L);
  }
  const hz = zf + 0.0001;
  g.userData.corners = [
    new THREE.Vector3(-SCREEN_W / 2, SCREEN_H / 2, hz), new THREE.Vector3(SCREEN_W / 2, SCREEN_H / 2, hz),
    new THREE.Vector3(SCREEN_W / 2, -SCREEN_H / 2, hz), new THREE.Vector3(-SCREEN_W / 2, -SCREEN_H / 2, hz),
  ];
  g.userData.screen = screen;
  return g;
}

// ---------------------------------------------------------------- shared furniture
function fabricPlane(seed, w, d, segs, amp, color, rough = 0.95) {
  const r = rng(seed);
  const geo = new THREE.PlaneGeometry(w, d, segs, segs);
  geo.rotateX(-Math.PI / 2);
  const p = geo.attributes.position;
  const waves = Array.from({ length: 14 }, () => ({ kx: (r() - 0.5) * 30, kz: (r() - 0.5) * 30, ph: r() * 6, a: amp * (0.3 + r()) }));
  for (let i = 0; i < p.count; i++) {
    const x = p.getX(i), z = p.getZ(i);
    let y = 0;
    for (const wv of waves) y += Math.sin(x * wv.kx + z * wv.kz + wv.ph) * wv.a / waves.length;
    p.setY(i, y);
  }
  geo.computeVertexNormals();
  return new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color, roughness: rough, map: fabricTex(seed + 7) }));
}

// ---------------------------------------------------------------- shots
function H1(rnd) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);
  const camera = new THREE.PerspectiveCamera(24, 9 / 16, 0.01, 20);
  const phone = makePhone({ screenLightI: 7, screenLight: 0xe8eeff });
  const holder = new THREE.Group();
  holder.add(phone);
  scene.add(holder);
  const glow = new THREE.PointLight(0xe8eeff, 0.05, 0.6, 2); glow.position.set(0, 0, 0.05); phone.add(glow);
  const duvet = fabricPlane(77, 1.4, 1.4, 200, 0.035, 0x3a3734);
  duvet.position.set(0, -0.085, -0.06);
  scene.add(duvet);
  const rim = new THREE.SpotLight(0xff9c50, 2.4, 2.5, 0.16, 0.8, 2);
  rim.position.set(-0.32, 0.22, -0.30); rim.target = holder;
  scene.add(rim);
  const rim2 = new THREE.SpotLight(0xffc890, 1.2, 2.5, 0.3, 0.9, 2);
  rim2.position.set(0.30, 0.16, -0.26); rim2.target = holder;
  scene.add(rim2);
  const flicks = [0.30, 0.78];
  const update = (t) => {
    let dy = 0, rx = 0;
    for (const f of flicks) {
      const u = t - f;
      if (u > 0 && u < 0.5) {
        const k = u < 0.14 ? ease(u / 0.14) : 1 - ease((u - 0.14) / 0.36);
        dy += 0.0005 * k; rx += 0.0035 * k;
      }
    }
    holder.position.set(drift(t, 1) * 0.0004, dy + drift(t, 2) * 0.0004, 0);
    holder.rotation.set(-0.86 + rx + drift(t, 3) * 0.002, -0.12, 0.16);
    camera.position.set(0.0, 0.215, 0.47);
    camera.lookAt(0, -0.006, 0);
  };
  return { scene, camera, phone, update, dof: { focus: 0.50, aperture: 0.05, maxblur: 0.018 } };
}

function H2(rnd) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x020203);
  scene.fog = new THREE.FogExp2(0x05060a, 0.08);
  const camera = new THREE.PerspectiveCamera(54.4, 9 / 16, 0.02, 40);
  // room
  const wallMat = new THREE.MeshStandardMaterial({ color: 0x2a2724, roughness: 0.95 });
  const back = new THREE.Mesh(new THREE.PlaneGeometry(6, 3.2), wallMat);
  back.position.set(0, 1.4, -2.6); scene.add(back);
  const left = new THREE.Mesh(new THREE.PlaneGeometry(6, 3.2), wallMat);
  left.rotation.y = Math.PI / 2; left.position.set(-1.6, 1.4, -0.5); scene.add(left);
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(6, 6), new THREE.MeshStandardMaterial({ map: woodTex(21, [70, 46, 30]), roughness: 0.7 }));
  floor.rotation.x = -Math.PI / 2; floor.position.y = -0.0; scene.add(floor);
  // window with a distant streetlight
  const win = new THREE.Group();
  const sky = new THREE.Mesh(new THREE.PlaneGeometry(1.1, 1.3), new THREE.MeshBasicMaterial({ color: 0x0b1222, fog: false }));
  win.add(sky);
  const lamp = new THREE.Sprite(new THREE.SpriteMaterial({ map: softDot(), color: 0xffb35c, transparent: true, blending: THREE.AdditiveBlending, fog: false, depthWrite: false }));
  lamp.scale.set(0.16, 0.16, 1); lamp.position.set(0.28, 0.12, 0.01); win.add(lamp);
  const lampCore = new THREE.Sprite(new THREE.SpriteMaterial({ map: softDot(), color: 0xfff0d0, transparent: true, blending: THREE.AdditiveBlending, fog: false, depthWrite: false }));
  lampCore.scale.set(0.035, 0.035, 1); lampCore.position.set(0.28, 0.12, 0.012); win.add(lampCore);
  const frameMat = new THREE.MeshStandardMaterial({ color: 0x15130f, roughness: 0.8 });
  for (const [w, h, x, y] of [[1.2, 0.05, 0, 0.67], [1.2, 0.05, 0, -0.67], [0.05, 1.4, -0.57, 0], [0.05, 1.4, 0.57, 0], [0.03, 1.3, 0, 0], [1.1, 0.03, 0, 0.05]]) {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, 0.05), frameMat); m.position.set(x, y, 0.02); win.add(m);
  }
  win.position.set(0.30, 1.30, -2.58); scene.add(win);
  const street = new THREE.SpotLight(0xffa859, 2.2, 8, 0.45, 0.9, 2);
  street.position.set(0.9, 2.3, -2.9); street.target.position.set(-0.2, 0.5, 0.4);
  scene.add(street, street.target);
  // bed
  const bed = new THREE.Group();
  const mattress = new THREE.Mesh(new THREE.BoxGeometry(1.5, 0.28, 2.1), new THREE.MeshStandardMaterial({ color: 0x77736c, roughness: 0.95 }));
  mattress.position.set(0, 0.36, 0); bed.add(mattress);
  const duvet = fabricPlane(31, 1.62, 1.6, 220, 0.045, 0xa9a39a);
  duvet.position.set(0, 0.52, -0.1); bed.add(duvet);
  const pillow = new THREE.Mesh(new THREE.SphereGeometry(0.5, 48, 24), new THREE.MeshStandardMaterial({ color: 0xd8d3ca, roughness: 0.92 }));
  pillow.scale.set(0.62, 0.16, 0.34); pillow.position.set(-0.28, 0.6, 0.62); bed.add(pillow);
  const head = new THREE.Mesh(new THREE.BoxGeometry(1.6, 0.9, 0.08), new THREE.MeshStandardMaterial({ map: woodTex(33, [60, 40, 28]), roughness: 0.6 }));
  head.position.set(0, 0.75, 1.1); bed.add(head);
  bed.position.set(-0.2, 0, -0.4);
  scene.add(bed);
  // the phone, face up on the duvet, the room's only real light
  const phone = makePhone({ screenLightI: 15, screenLight: 0xe2eaff });
  const pglow = new THREE.PointLight(0xdfe7ff, 0.016, 0.9, 2); pglow.position.set(0, 0, 0.03); phone.add(pglow);
  phone.rotation.set(-Math.PI / 2 + 0.62, 0.05, -0.16);
  phone.position.set(-0.30, 0.585, -0.62);
  scene.add(phone);
  scene.add(new THREE.AmbientLight(0x10131c, 0.05));
  const update = (t) => {
    const k = t / 1.6;
    const p0 = new THREE.Vector3(-0.40, 0.86, 0.08), p1 = new THREE.Vector3(-0.385, 0.84, 0.0);
    camera.position.lerpVectors(p0, p1, ease(k) * 0.6 + k * 0.4);
    camera.position.x += drift(t, 5) * 0.0015; camera.position.y += drift(t, 6) * 0.0015;
    camera.lookAt(-0.16, 0.50, -1.6);
  };
  return { scene, camera, phone, update, dof: { focus: 0.52, aperture: 0.03, maxblur: 0.018 } };
}

function H3(rnd) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);
  const camera = new THREE.PerspectiveCamera(39.6, 9 / 16, 0.01, 30);
  const phone = makePhone({ screenLightI: 0 });
  const holder = new THREE.Group(); holder.add(phone); scene.add(holder);
  // warm rim from behind on both titanium edges, nothing on the screen
  const r1 = new THREE.SpotLight(0xffa25a, 9, 3, 0.28, 0.6, 2); r1.position.set(-0.30, 0.20, -0.16); r1.target = holder;
  const r2 = new THREE.SpotLight(0xffbf80, 7, 3, 0.28, 0.6, 2); r2.position.set(0.30, -0.12, -0.14); r2.target = holder;
  const top = new THREE.SpotLight(0xffd2a0, 1.4, 3, 0.3, 0.8, 2); top.position.set(0.05, 0.45, -0.05); top.target = holder;
  scene.add(r1, r2, top);
  // far warm practicals that turn into bokeh
  const r = rng(1303);
  const bokeh = [];
  for (let i = 0; i < 26; i++) {
    const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: softDot(), color: new THREE.Color().setHSL(0.08 + r() * 0.04, 0.8, 0.45 + r() * 0.2), transparent: true, opacity: 0.35 + r() * 0.4, blending: THREE.AdditiveBlending, depthWrite: false }));
    const z = -2.5 - r() * 3;
    s.position.set((r() - 0.5) * 3.2, (r() - 0.5) * 4.5, z); s.scale.setScalar(0.06 + r() * 0.08);
    s.userData.base = s.position.clone(); s.userData.ph = r() * 6.28; s.userData.sp = 0.2 + r() * 0.5; s.userData.s0 = s.scale.x;
    scene.add(s); bokeh.push(s);
  }
  const wall = new THREE.Mesh(new THREE.PlaneGeometry(12, 12), new THREE.MeshStandardMaterial({ color: 0x1a120c, roughness: 1 }));
  wall.position.z = -6; scene.add(wall);
  const wash = new THREE.PointLight(0xff9a50, 1.6, 10, 2); wash.position.set(-1, 1.2, -4.5); scene.add(wash);
  const update = (t) => {
    holder.rotation.set(0.06 + drift(t, 11) * 0.006, -0.16 + drift(t, 12) * 0.008, 0.035 + drift(t, 13) * 0.004);
    holder.position.set(drift(t, 14) * 0.0009, drift(t, 15) * 0.0009, 0);
    for (const b of bokeh) {           // practicals drift and breathe, never wallpaper
      const u = b.userData;
      b.position.set(u.base.x + Math.sin(t * u.sp + u.ph) * 0.18 - t * 0.05, u.base.y + t * 0.06 * u.sp + Math.cos(t * u.sp * 0.7 + u.ph) * 0.1, u.base.z);
      b.scale.setScalar(u.s0 * (0.85 + 0.25 * Math.sin(t * 1.3 * u.sp + u.ph)));
    }
    const z = 0.262 * (1 - 0.06 * ease(t / 3.8));
    camera.position.set(0, -0.002, z);
    camera.lookAt(0, -0.002, 0);
  };
  return { scene, camera, phone, update, dof: { focus: 0.25, aperture: 0.02, maxblur: 0.012 } };
}

function H4(rnd) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x0a0705);
  scene.fog = new THREE.FogExp2(0x24170c, 0.032);
  const camera = new THREE.PerspectiveCamera(54.4, 9 / 16, 0.05, 80);
  const r = rng(1404);
  const AISLE = 1.25, LEN = 34, SHELF_TOP = 5.6, LEVELS = 13, Z0 = 3, D = 0.36;
  const wood = new THREE.MeshStandardMaterial({ map: woodTex(41, [64, 38, 22]), roughness: 0.62, color: 0xffffff });
  const darkWood = new THREE.MeshStandardMaterial({ map: woodTex(42, [44, 27, 16]), roughness: 0.7 });
  // shelving walls
  for (const side of [-1, 1]) {
    const x = side * (AISLE + D / 2);
    const backBoard = new THREE.Mesh(new THREE.BoxGeometry(0.04, SHELF_TOP + 0.4, LEN), darkWood);
    backBoard.position.set(side * (AISLE + D), SHELF_TOP / 2, Z0 - LEN / 2); scene.add(backBoard);
    for (let l = 0; l <= LEVELS; l++) {
      const y = 0.12 + l * (SHELF_TOP - 0.12) / LEVELS;
      const b = new THREE.Mesh(new THREE.BoxGeometry(D + 0.04, 0.035, LEN), wood);
      b.position.set(x, y, Z0 - LEN / 2); scene.add(b);
    }
    for (let z = Z0; z > Z0 - LEN; z -= 1.9) {
      const post = new THREE.Mesh(new THREE.BoxGeometry(D + 0.06, SHELF_TOP + 0.3, 0.07), wood);
      post.position.set(x, (SHELF_TOP + 0.3) / 2, z); scene.add(post);
    }
    const cornice = new THREE.Mesh(new THREE.BoxGeometry(D + 0.16, 0.22, LEN), wood);
    cornice.position.set(x, SHELF_TOP + 0.35, Z0 - LEN / 2); scene.add(cornice);
  }
  // sefarim: instanced, leather tones, gilded bands (texture alpha = band mask), no lettering
  const spine = canvasTex(64, 256, (g, w, h) => {
    const im = g.createImageData(w, h);
    const rr = rng(9);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4, n = 200 + rr() * 55;
      const v = y / h;
      const band = (v > 0.08 && v < 0.11) || (v > 0.14 && v < 0.155) || (v > 0.84 && v < 0.855) || (v > 0.885 && v < 0.915) || (v > 0.46 && v < 0.54 && (x < 6 || x > w - 6 ? 0 : 0));
      im.data[i] = im.data[i + 1] = im.data[i + 2] = n; im.data[i + 3] = band ? 255 : 0;
    }
    g.putImageData(im, 0, 0);
  }, false);
  const white = new THREE.DataTexture(new Uint8Array([255, 255, 255, 255]), 1, 1); white.needsUpdate = true;
  const bookMat = new THREE.MeshStandardMaterial({ roughness: 0.62, metalness: 0.0, map: white });
  bookMat.onBeforeCompile = (sh) => {
    sh.uniforms.spineMap = { value: spine };
    sh.fragmentShader = sh.fragmentShader
      .replace('#include <common>', '#include <common>\nuniform sampler2D spineMap;')
      .replace('#include <map_fragment>', `#include <map_fragment>
        vec4 sp = texture2D(spineMap, vMapUv);
        diffuseColor.rgb = mix(diffuseColor.rgb * sp.rgb, vec3(0.62, 0.43, 0.14), sp.a * 0.9);
        float gild = sp.a;`)
      .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\nroughnessFactor = mix(roughnessFactor, 0.28, gild);')
      .replace('#include <metalnessmap_fragment>', '#include <metalnessmap_fragment>\nmetalnessFactor = mix(metalnessFactor, 0.85, gild);');
  };
  const palette = [[0.20, 0.05, 0.04], [0.12, 0.06, 0.03], [0.05, 0.05, 0.10], [0.03, 0.03, 0.03], [0.06, 0.09, 0.05], [0.24, 0.13, 0.06], [0.30, 0.20, 0.10], [0.16, 0.03, 0.03]];
  const books = [];
  for (const side of [-1, 1]) {
    for (let l = 0; l < LEVELS; l++) {
      const y0 = 0.12 + l * (SHELF_TOP - 0.12) / LEVELS + 0.018;
      const space = (SHELF_TOP - 0.12) / LEVELS - 0.05;
      let z = Z0;
      while (z > Z0 - LEN) {
        if (r() < 0.012) { z -= 0.08 + r() * 0.2; continue; }
        const w = 0.028 + r() * 0.05, h = Math.min(space, 0.24 + r() * 0.14), d = 0.22 + r() * 0.1;
        const lean = r() < 0.04 ? (r() - 0.5) * 0.25 : 0;
        books.push({ x: side * (AISLE + D - d / 2 - 0.02), y: y0 + h / 2, z: z - w / 2, w, h, d, lean, c: palette[Math.floor(r() * palette.length)], k: 0.6 + r() * 0.8 });
        z -= w + 0.002;
      }
    }
  }
  const im = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), bookMat, books.length);
  const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), e = new THREE.Euler(), col = new THREE.Color();
  books.forEach((b, i) => {
    e.set(b.lean, 0, 0); q.setFromEuler(e);
    m4.compose(new THREE.Vector3(b.x, b.y, b.z), q, new THREE.Vector3(b.d, b.h, b.w));
    im.setMatrixAt(i, m4);
    col.setRGB(b.c[0] * b.k, b.c[1] * b.k, b.c[2] * b.k); im.setColorAt(i, col);
  });
  scene.add(im);
  // floor, upper walls with high windows, ceiling beams
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(8, LEN + 6), new THREE.MeshStandardMaterial({ map: woodTex(43, [58, 36, 22], 1024, 2048), roughness: 0.55 }));
  floor.rotation.x = -Math.PI / 2; floor.position.set(0, 0, Z0 - LEN / 2); scene.add(floor);
  const wallMat = new THREE.MeshStandardMaterial({ color: 0x3a2a1c, roughness: 0.95 });
  for (const side of [-1, 1]) {
    const w = new THREE.Mesh(new THREE.PlaneGeometry(LEN, 5), wallMat);
    w.rotation.y = -side * Math.PI / 2; w.position.set(side * (AISLE + D), SHELF_TOP + 0.4 + 2.5, Z0 - LEN / 2); scene.add(w);
  }
  const ceil = new THREE.Mesh(new THREE.PlaneGeometry(4, LEN), darkWood); ceil.rotation.x = Math.PI / 2; ceil.position.set(0, SHELF_TOP + 4.6, Z0 - LEN / 2); scene.add(ceil);
  for (let z = Z0; z > Z0 - LEN; z -= 2.4) {
    const beam = new THREE.Mesh(new THREE.BoxGeometry(2 * (AISLE + D), 0.22, 0.2), darkWood);
    beam.position.set(0, SHELF_TOP + 4.45, z); scene.add(beam);
  }
  const endWall = new THREE.Mesh(new THREE.PlaneGeometry(4, 11), wallMat); endWall.position.set(0, 5, Z0 - LEN); scene.add(endWall);
  // high windows on the left: warm glowing panes; shafts fall across the aisle to the right
  const shaftMat = new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
    uniforms: { uColor: { value: new THREE.Color(0xffb15e) }, uT: { value: 0 }, uI: { value: 0.10 } },
    vertexShader: `varying vec3 vN; varying vec3 vV; varying float vH; varying vec3 vP;
      void main(){ vN = normalize(normalMatrix*normal); vec4 mv = modelViewMatrix*vec4(position,1.); vV = normalize(-mv.xyz);
        vH = uv.y; vP = position; gl_Position = projectionMatrix*mv; }`,
    fragmentShader: `uniform vec3 uColor; uniform float uT; uniform float uI; varying vec3 vN; varying vec3 vV; varying float vH; varying vec3 vP;
      float h(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233)))*43758.5453); }
      float n(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
        return mix(mix(h(i),h(i+vec2(1,0)),f.x), mix(h(i+vec2(0,1)),h(i+vec2(1,1)),f.x), f.y); }
      void main(){ float edge = pow(abs(dot(vN, vV)), 2.2);
        float len = smoothstep(0.0, 0.35, vH) * smoothstep(1.0, 0.75, vH);
        float streak = 0.65 + 0.35*n(vec2(atan(vP.x, vP.z)*3.0, vH*2.0 + uT*0.05));
        gl_FragColor = vec4(uColor * edge * len * streak * uI, 1.0); }`,
  });
  const shafts = [];
  const winMat = new THREE.MeshBasicMaterial({ color: 0xffc27a, fog: false });
  for (let i = 0; i < 6; i++) {
    const z = 0.5 - i * 4.4;
    const pane = new THREE.Mesh(new THREE.PlaneGeometry(1.1, 2.2), winMat);
    pane.rotation.y = Math.PI / 2; pane.position.set(-(AISLE + D) + 0.02, SHELF_TOP + 2.4, z); scene.add(pane);
    for (const [dx, dy] of [[0, 0]]) {
      const bars = new THREE.Mesh(new THREE.BoxGeometry(0.04, 2.2, 0.05), darkWood); bars.position.set(-(AISLE + D) + 0.04, SHELF_TOP + 2.4, z); scene.add(bars);
      const bar2 = new THREE.Mesh(new THREE.BoxGeometry(0.04, 0.05, 1.1), darkWood); bar2.position.set(-(AISLE + D) + 0.04, SHELF_TOP + 2.0, z); scene.add(bar2);
    }
    const len = 10.5;
    const geo = new THREE.CylinderGeometry(0.30, 0.62, len, 32, 1, true);
    const s = new THREE.Mesh(geo, shaftMat);
    // from the window down across the aisle toward the right shelves' lower half
    const top = new THREE.Vector3(-(AISLE + D), SHELF_TOP + 2.4, z);
    const bot = new THREE.Vector3(AISLE + D * 0.2, 1.1 + (i % 3) * 0.5, z - 1.9);
    s.position.copy(top).add(bot).multiplyScalar(0.5);
    s.quaternion.setFromUnitVectors(new THREE.Vector3(0, -1, 0), bot.clone().sub(top).normalize());
    s.scale.set(1, (top.distanceTo(bot) + 1.5) / len, 1);
    scene.add(s); shafts.push(s);
    const spot = new THREE.SpotLight(0xffb468, 90, 18, 0.12, 0.55, 1.6);
    spot.position.copy(top); spot.target.position.copy(bot);
    scene.add(spot, spot.target);
  }
  // a few hanging lamps keep the aisle warm and readable at night
  for (let i = 0; i < 5; i++) {
    const z = -1.5 - i * 5.5;
    for (const sx of [-0.7, 0.7]) { const glow = new THREE.PointLight(0xffa04a, 1.8, 6, 1.8); glow.position.set(sx, 2.2, z); scene.add(glow); }
  }
  scene.add(new THREE.HemisphereLight(0x8a6238, 0x1a1008, 0.55));
  // gold dust
  const N = 4200, pos = new Float32Array(N * 3), seeds = [];
  for (let i = 0; i < N; i++) {
    pos[i * 3] = (r() - 0.5) * 2 * AISLE; pos[i * 3 + 1] = 0.2 + r() * 5.5; pos[i * 3 + 2] = 2.2 - r() * 18;
    seeds.push([r() * 6.28, 0.3 + r() * 0.7, r()]);
  }
  const pgeo = new THREE.BufferGeometry(); pgeo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  const base = pos.slice();
  const dust = new THREE.Points(pgeo, new THREE.PointsMaterial({ map: softDot(), color: 0xffcf7a, size: 0.016, transparent: true, opacity: 0.85, blending: THREE.AdditiveBlending, depthWrite: false, sizeAttenuation: true }));
  scene.add(dust);
  const update = (t) => {
    camera.position.set(0.04 + drift(t, 21) * 0.004, 1.58 + drift(t, 22) * 0.003, 1.2 - 0.2 * t);
    camera.lookAt(0.02, 2.35, -14);
    shaftMat.uniforms.uT.value = t;
    for (let i = 0; i < N; i++) {
      const s = seeds[i];
      pos[i * 3] = base[i * 3] + Math.sin(t * 0.35 * s[1] + s[0]) * 0.05;
      pos[i * 3 + 1] = base[i * 3 + 1] + Math.sin(t * 0.22 * s[1] + s[0] * 1.3) * 0.04 - t * 0.012 * s[2];
      pos[i * 3 + 2] = base[i * 3 + 2] + Math.cos(t * 0.28 * s[1] + s[0]) * 0.05;
    }
    pgeo.attributes.position.needsUpdate = true;
  };
  return { scene, camera, phone: null, update, dof: null };
}

function H5(rnd) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0xf3e6cf);
  const camera = new THREE.PerspectiveCamera(39.6, 9 / 16, 0.02, 30);
  const r = rng(1505);
  // table
  const table = new THREE.Mesh(new THREE.BoxGeometry(1.8, 0.04, 1.1), new THREE.MeshStandardMaterial({ map: woodTex(51, [150, 104, 64], 2048, 1024), roughness: 0.55 }));
  table.position.set(0, -0.02, -0.1); table.receiveShadow = true; scene.add(table);
  // kitchen behind: wall, window, cabinets, counter — all far, all soft
  const wall = new THREE.Mesh(new THREE.PlaneGeometry(6, 4), new THREE.MeshStandardMaterial({ color: 0xf1e4cc, roughness: 0.9, emissive: 0xb89a70, emissiveIntensity: 0.55 }));
  wall.position.set(0, 0.8, -1.6); scene.add(wall);
  const sky = new THREE.Mesh(new THREE.PlaneGeometry(0.95, 1.05), new THREE.MeshBasicMaterial({ color: 0xd9c4a0 }));
  sky.position.set(-0.32, 0.5, -1.58); sky.scale.set(0.9, 0.9, 1);
  const glare = new THREE.Sprite(new THREE.SpriteMaterial({ map: softDot(), color: 0x8a7a62, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false })); glare.scale.set(1.6, 1.6, 1); glare.position.set(-0.3, 0.5, -1.5); scene.add(glare); scene.add(sky);
  const mull = new THREE.MeshStandardMaterial({ color: 0xf4efe6, roughness: 0.6 });
  for (const [w, h, x, y] of [[0.9, 0.04, -0.32, 0.98], [0.9, 0.04, -0.32, 0.02], [0.04, 1.0, -0.77, 0.5], [0.04, 1.0, 0.13, 0.5], [0.025, 0.95, -0.32, 0.5], [0.86, 0.025, -0.32, 0.5]]) {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, 0.04), mull); m.position.set(x, y, -1.56); scene.add(m);
  }
  const cab = new THREE.MeshStandardMaterial({ color: 0xb9c2b4, roughness: 0.55, emissive: 0x3a3a32, emissiveIntensity: 0.6 });
  for (let i = 0; i < 3; i++) { const c = new THREE.Mesh(new THREE.BoxGeometry(0.42, 0.6, 0.3), cab); c.position.set(0.35 + i * 0.45, 1.2, -1.45); scene.add(c); }

  // sun through the window, soft shadows
  const sun = new THREE.DirectionalLight(0xffdcae, 4.2);
  sun.position.set(-1.6, 1.9, -1.2); sun.target.position.set(0.05, 0, 0.05);
  sun.castShadow = true; sun.shadow.mapSize.set(2048, 2048); sun.shadow.radius = 6; sun.shadow.bias = -0.0004;
  Object.assign(sun.shadow.camera, { left: -0.6, right: 0.6, top: 0.6, bottom: -0.6, near: 0.5, far: 5 });
  scene.add(sun, sun.target);
  scene.add(new THREE.HemisphereLight(0xfff1dc, 0x6b5238, 1.15));
  const bounce = new THREE.PointLight(0xffe2bc, 0.35, 3, 2); bounce.position.set(0.6, 0.6, 0.8); scene.add(bounce);
  // coffee
  const prof = [[0, 0], [0.036, 0], [0.04, 0.004], [0.043, 0.06], [0.045, 0.09], [0.041, 0.09], [0.039, 0.062], [0.035, 0.008], [0, 0.008]].map(([x, y]) => new THREE.Vector2(x, y));
  const cup = new THREE.Mesh(new THREE.LatheGeometry(prof, 64), new THREE.MeshPhysicalMaterial({ color: 0xf2ece2, roughness: 0.2, clearcoat: 0.6 }));
  cup.castShadow = true; cup.receiveShadow = true;
  const cupG = new THREE.Group(); cupG.add(cup);
  const coffee = new THREE.Mesh(new THREE.CircleGeometry(0.0405, 48), new THREE.MeshPhysicalMaterial({ color: 0x2a160b, roughness: 0.08, clearcoat: 1 }));
  coffee.rotation.x = -Math.PI / 2; coffee.position.y = 0.078; cupG.add(coffee);
  const handle = new THREE.Mesh(new THREE.TorusGeometry(0.022, 0.006, 16, 40, Math.PI * 1.25), cup.material);
  handle.position.set(0.047, 0.05, 0); handle.rotation.z = -Math.PI * 0.62; handle.castShadow = true; cupG.add(handle);
  cupG.position.set(0.045, 0, -0.10); cupG.rotation.y = -0.6; scene.add(cupG);
  // steam: soft noisy billboards rising from the cup
  const steamTex = canvasTex(128, 256, (g, w, h) => {
    const rr = rng(55);
    for (let i = 0; i < 70; i++) {
      const x = w / 2 + (rr() - 0.5) * w * 0.4 + Math.sin(i * 0.7) * 10, y = rr() * h;
      const gr = g.createRadialGradient(x, y, 0, x, y, 10 + rr() * 24);
      gr.addColorStop(0, 'rgba(255,255,255,0.10)'); gr.addColorStop(1, 'rgba(255,255,255,0)');
      g.fillStyle = gr; g.fillRect(0, 0, w, h);
    }
  });
  const steam = [];
  for (let i = 0; i < 7; i++) {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(0.07, 0.16), new THREE.MeshBasicMaterial({ map: steamTex, transparent: true, depthWrite: false, opacity: 0.0, color: 0xffffff }));
    m.userData.noDepth = true; m.userData.ph = i / 7; scene.add(m); steam.push(m);
  }
  // folded tallit bag: navy velvet, gold piping, no lettering
  const bagG = new THREE.Group();
  const bagShape = rrShape(0.24, 0.19, 0.05);
  const bagGeo = new THREE.ExtrudeGeometry(bagShape, { depth: 0.012, bevelEnabled: true, bevelThickness: 0.022, bevelSize: 0.02, bevelSegments: 10, curveSegments: 32 });
  { // pillow it: thicker in the middle, like a folded tallit inside
    const pa = bagGeo.attributes.position;
    for (let i = 0; i < pa.count; i++) {
      const x = pa.getX(i), y = pa.getY(i), z = pa.getZ(i);
      const k = Math.max(0, 1 - (x * x) / 0.016 - (y * y) / 0.0105);
      pa.setZ(i, z > 0.006 ? z + 0.016 * k : z);
    }
    bagGeo.computeVertexNormals();
  }
  const bag = new THREE.Mesh(bagGeo, new THREE.MeshPhysicalMaterial({ color: 0x18224a, roughness: 0.95, specularIntensity: 0.15, sheen: 1, sheenColor: new THREE.Color(0x6f7fc0), sheenRoughness: 0.35 }));
  bag.rotation.x = -Math.PI / 2; bag.position.y = 0.022; bag.castShadow = true; bag.receiveShadow = true; bagG.add(bag);
  const pts = rrShape(0.262, 0.212, 0.055).getPoints(64).map((p) => new THREE.Vector3(p.x, 0.034, -p.y));
  const piping = new THREE.Mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts, true), 240, 0.0022, 8, true), new THREE.MeshStandardMaterial({ color: 0xc9a24b, metalness: 0.9, roughness: 0.35 }));
  bagG.add(piping);
  bagG.position.set(-0.20, 0, -0.30); bagG.rotation.y = 0.55; scene.add(bagG);   // the tallit bag rests apart
  const standMat = new THREE.MeshStandardMaterial({ map: woodTex(57, [92, 58, 36]), roughness: 0.45 });   // the phone gets its own stand (below)
  // phone leaning on the bag's front edge, screen to camera at a slight angle
  const phone = makePhone({ screenLightI: 3.5, screenLight: 0xf0f2ff });
  phone.traverse((o) => { if (o.isMesh) o.castShadow = true; });
  phone.rotation.set(-0.58, 0.22, 0.03);
  phone.position.set(-0.05, 0.072, -0.045);
  scene.add(phone);
  // its own small walnut stand: a back plate behind the phone, a ledge under it, a base on the table
  const plate = new THREE.Mesh(new THREE.BoxGeometry(0.06, 0.085, 0.006), standMat);
  plate.position.set(0, -0.022, -0.0075); plate.castShadow = true; phone.add(plate);
  const ledge = new THREE.Mesh(new THREE.BoxGeometry(0.078, 0.006, 0.016), standMat);
  ledge.position.set(0, -0.0785, 0.003); ledge.castShadow = true; phone.add(ledge);
  const sbase = new THREE.Mesh(new THREE.BoxGeometry(0.088, 0.008, 0.075), standMat);
  sbase.position.set(-0.05, 0.004, -0.03); sbase.rotation.y = 0.22; sbase.castShadow = true; sbase.receiveShadow = true; scene.add(sbase);
  const update = (t) => {
    camera.position.set(-0.045 + drift(t, 31) * 0.0010, 0.150 + drift(t, 32) * 0.0010, 0.255);
    camera.lookAt(-0.05, 0.072, -0.045);
    steam.forEach((m, i) => {
      const u = (t * 0.32 + m.userData.ph) % 1;
      m.position.set(0.045 + Math.sin(u * 5 + i) * 0.012, 0.10 + u * 0.15, -0.10);
      m.scale.set(0.8 + u * 1.2, 0.8 + u * 0.8, 1);
      m.material.opacity = Math.sin(u * Math.PI) * 0.8;
      m.rotation.z = Math.sin(u * 3 + i) * 0.3;
      m.quaternion.copy(camera.quaternion);
    });
  };
  return { scene, camera, phone, update, dof: { focus: 0.30, aperture: 0.018, maxblur: 0.016 } };
}

function H6(rnd) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x000000);
  const camera = new THREE.PerspectiveCamera(39.6, 9 / 16, 0.02, 20);
  const top = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.035, 0.46), new THREE.MeshStandardMaterial({ map: woodTex(61, [96, 60, 36], 2048, 1536), roughness: 0.42 }));
  top.position.set(0, -0.0175, -0.05); top.receiveShadow = true; scene.add(top);
  const body = new THREE.Mesh(new THREE.BoxGeometry(0.6, 0.5, 0.44), new THREE.MeshStandardMaterial({ map: woodTex(62, [70, 44, 27]), roughness: 0.6 }));
  body.position.set(0, -0.285, -0.05); scene.add(body);
  const wall = new THREE.Mesh(new THREE.PlaneGeometry(3, 2.4), new THREE.MeshStandardMaterial({ color: 0x5a5650, roughness: 0.98, map: noiseTex(63, 512, 512, 215, 255) }));
  wall.position.set(0, 0.6, -0.3); wall.receiveShadow = true; scene.add(wall);
  // unlit lamp
  const lampG = new THREE.Group();
  const base = new THREE.Mesh(new THREE.LatheGeometry([[0, 0], [0.055, 0], [0.06, 0.02], [0.05, 0.09], [0.03, 0.15], [0.012, 0.17], [0, 0.17]].map(([x, y]) => new THREE.Vector2(x, y)), 48),
    new THREE.MeshPhysicalMaterial({ color: 0x3b3a36, roughness: 0.3, clearcoat: 0.6 }));
  const stem = new THREE.Mesh(new THREE.CylinderGeometry(0.005, 0.005, 0.12), new THREE.MeshStandardMaterial({ color: 0x8a7a5a, metalness: 0.9, roughness: 0.3 }));
  stem.position.y = 0.23;
  const shade = new THREE.Mesh(new THREE.CylinderGeometry(0.075, 0.12, 0.16, 48, 1, true), new THREE.MeshStandardMaterial({ color: 0xcfc6b4, roughness: 0.95, side: THREE.DoubleSide }));
  shade.position.y = 0.33;
  [base, stem, shade].forEach((m) => { m.castShadow = true; lampG.add(m); });
  lampG.position.set(0.205, 0, -0.215); scene.add(lampG);
  // the phone, face up; its glow is the light on the wood
  const phone = makePhone({ screenLightI: 9, screenLight: 0xe4ecff });
  const pglow = new THREE.PointLight(0xdfe7ff, 0.06, 0.5, 2); pglow.position.set(0, 0, 0.035); phone.add(pglow);
  phone.rotation.set(-Math.PI / 2, 0, 0.12);
  phone.position.set(0.0, 0.0041, 0.05);
  scene.add(phone);
  // streetlight through blinds onto the wall, faintly flickering
  const blinds = canvasTex(256, 256, (g, w, h) => {
    g.fillStyle = '#000'; g.fillRect(0, 0, w, h);
    const gr = g.createRadialGradient(w / 2, h / 2, 10, w / 2, h / 2, w / 2);
    gr.addColorStop(0, '#fff'); gr.addColorStop(1, '#000');
    g.fillStyle = gr; g.fillRect(0, 0, w, h);
    g.fillStyle = '#000';
    for (let y = 0; y < h; y += 22) g.fillRect(0, y, w, 9);
  });
  const street = new THREE.SpotLight(0xffb26a, 4.5, 6, 0.42, 0.5, 1.5);
  street.position.set(-0.9, 1.25, 0.9); street.target.position.set(0.05, 0.55, -0.3);
  street.map = blinds; street.castShadow = true; street.shadow.mapSize.set(1024, 1024);
  scene.add(street, street.target);
  scene.add(new THREE.AmbientLight(0x0c0d12, 0.08));
  const update = (t) => {
    camera.position.set(0, 0.30, 0.33);
    camera.lookAt(0.0, 0.012, 0.012);
    // faint flicker: slow breathing plus two short dips
    let f = 1 + 0.06 * Math.sin(t * 7.3) * Math.sin(t * 1.9);
    for (const d of [0.9, 2.15]) { const u = (t - d) / 0.12; if (u > 0 && u < 1) f *= 1 - 0.35 * Math.sin(u * Math.PI); }
    street.intensity = 4.5 * f;
  };
  return { scene, camera, phone, update, dof: { focus: 0.40, aperture: 0.03, maxblur: 0.016 } };
}

const BUILDERS = { H1, H2, H3, H4, H5, H6 };

class SelectiveBokehPass extends BokehPass {
  render(...a) {
    const hidden = [];
    this.scene.traverse((o) => { if (o.userData.noDepth && o.visible) { o.visible = false; hidden.push(o); } });
    super.render(...a);
    hidden.forEach((o) => { o.visible = true; });
  }
}

export function setup(shotId, W = 1080, H = 1920) {
  const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
  renderer.setPixelRatio(1);
  renderer.setSize(W, H);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.NoToneMapping;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  document.body.appendChild(renderer.domElement);
  const shot = BUILDERS[shotId](rng(SEEDS[shotId]));
  const { scene, camera, phone, update, dof } = shot;
  camera.aspect = W / H;            // same vertical field of view at every aspect
  camera.updateProjectionMatrix();
  // render into a 4x MSAA target: EffectComposer's default target has no anti-aliasing
  const rt = new THREE.WebGLRenderTarget(W, H, { type: THREE.HalfFloatType, samples: 4 });
  const composer = new EffectComposer(renderer, rt);
  composer.addPass(new RenderPass(scene, camera));
  if (dof) composer.addPass(new SelectiveBokehPass(scene, camera, { focus: dof.focus, aperture: dof.aperture, maxblur: dof.maxblur }));
  composer.addPass(new OutputPass());
  const v = new THREE.Vector3();
  return {
    frame(t) {
      update(t);
      scene.updateMatrixWorld(true);
      camera.updateMatrixWorld(true);
      composer.render();
      let corners = null, normalDot = null;
      if (phone) {
        corners = phone.userData.corners.map((c) => {
          v.copy(c); phone.localToWorld(v); v.project(camera);
          return [(v.x + 1) / 2 * W, (1 - v.y) / 2 * H];
        });
        const n = new THREE.Vector3(0, 0, 1).transformDirection(phone.matrixWorld);
        const toCam = camera.position.clone().sub(phone.getWorldPosition(new THREE.Vector3())).normalize();
        normalDot = n.dot(toCam);
      }
      return { url: renderer.domElement.toDataURL('image/png'), corners, normalDot };
    },
  };
}
