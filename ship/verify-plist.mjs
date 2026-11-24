// ship/verify-plist.mjs — PHASE LAUNCH PART 3.3: the capability whitelist, enforced.
//
// WHAT THIS IS FOR
// Scroll Anytime asks the phone for nothing. No camera, no microphone, no photos, no location, no
// contacts, no push, no background modes. Every one of those, if it appears in the built app, is
// either an instant App Store rejection (2.5.4 "declared a background mode it does not use",
// 5.1.1 "requests data it does not need") or an ITMS upload error (ITMS-90683, a usage-description
// key with no explanation). PWABuilder templates and Xcode both add keys on their own, so the
// question "what did the build actually declare?" must be ANSWERED, not assumed.
//
// This script reads the built Info.plist and the .entitlements file and fails on ANY key that is
// not on an exact whitelist. Unknown key = failure. That is deliberate: a key nobody has thought
// about is exactly the key that gets the build rejected.
//
// USAGE
//   node ship/verify-plist.mjs
//   node ship/verify-plist.mjs path/to/Info.plist
//   node ship/verify-plist.mjs path/to/Info.plist --entitlements path/to/App.entitlements
//
// With no arguments it searches ship/ios for the most build-like Info.plist and the first
// .entitlements file, and prints which files it chose. Run it AFTER archiving, against the
// Info.plist inside the built .app — the source plist is what you wrote, the built plist is what
// Apple receives, and they are not always the same file.
//
// FLAGS
//   --entitlements <path>     use this entitlements file instead of searching
//   --allow-background-audio  permit UIBackgroundModes = ["audio"] and nothing else. OFF BY
//                             DEFAULT AND IT SHOULD STAY OFF. See "LISTEN MODE" below.
//   --json                    machine-readable output as well as the table
//
// LISTEN MODE — READ THIS BEFORE YOU REACH FOR THE FLAG
// store/XCODE_CHECKLIST.md documents that Listen Mode's screen-locked audio needs BOTH
// UIBackgroundModes=audio AND an ACTIVATED AVAudioSession(.playback) in the shell. A stock
// PWABuilder shell does neither. Declaring the background mode without the audio session gives you
// the textbook 2.5.4 rejection: a declared-but-unused background mode. So the default here is
// strict — no background modes at all, Listen Mode still works while the app is open, and the
// screen-locked case is a v1.1 feature. Only pass --allow-background-audio if the shell really
// activates an AVAudioSession AND someone has watched audio keep playing on a locked real iPhone.
//
// Exit code 0 = every check passed. Exit code 1 = at least one failure; do not upload the build.

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const IOS_DIR = join(ROOT, 'ship', 'ios');

const BUNDLE_ID = 'com.scrollanytime.app';
const ASSOCIATED_DOMAIN = 'applinks:scrollanytime.com';
const APP_BOUND_DOMAIN = 'scrollanytime.com';

// ── output ──────────────────────────────────────────────────────────────────────────────────────
const COLOR = !process.env.NO_COLOR && process.env.TERM !== 'dumb';
const c = {
  red: (s) => (COLOR ? `\x1b[31m${s}\x1b[0m` : s),
  grn: (s) => (COLOR ? `\x1b[32m${s}\x1b[0m` : s),
  yel: (s) => (COLOR ? `\x1b[33m${s}\x1b[0m` : s),
  dim: (s) => (COLOR ? `\x1b[2m${s}\x1b[0m` : s),
  bld: (s) => (COLOR ? `\x1b[1m${s}\x1b[0m` : s),
};

const rows = [];
let fails = 0;
let warns = 0;
const pass = (what, detail) => rows.push({ s: 'PASS', what, detail });
const fail = (what, detail, fix) => { fails++; rows.push({ s: 'FAIL', what, detail, fix }); };
const warn = (what, detail, fix) => { warns++; rows.push({ s: 'WARN', what, detail, fix }); };
const info = (what, detail) => rows.push({ s: 'INFO', what, detail });

// ── 1. what Scroll Anytime is allowed to declare ────────────────────────────────────────────────

// Info.plist keys that may legitimately appear. Anything else fails.
const PLIST_ALLOWED = new Set([
  // bundle identity
  'CFBundleAllowMixedLocalizations',
  'CFBundleDevelopmentRegion',
  'CFBundleDisplayName',
  'CFBundleExecutable',
  'CFBundleIconName',
  'CFBundleIcons',
  'CFBundleIdentifier',
  'CFBundleInfoDictionaryVersion',
  'CFBundleLocalizations',
  'CFBundleName',
  'CFBundleNumericVersion',
  'CFBundlePackageType',
  'CFBundleShortVersionString',
  'CFBundleSupportedPlatforms',
  'CFBundleURLTypes',
  'CFBundleVersion',
  // launch + chrome
  'LSApplicationCategoryType',
  'LSMinimumSystemVersion',
  'LSRequiresIPhoneOS',
  'MinimumOSVersion',
  'UIApplicationSceneManifest',
  'UIApplicationSupportsIndirectInputEvents',
  'UIDeviceFamily',
  'UILaunchScreen',
  'UILaunchStoryboardName',
  'UIPrerenderedIcon',
  'UIRequiredDeviceCapabilities',
  'UIRequiresFullScreen',
  'UIStatusBarHidden',
  'UIStatusBarStyle',
  'UISupportedInterfaceOrientations',
  'UIUserInterfaceStyle',
  'UIViewControllerBasedStatusBarAppearance',
  // web view
  'NSAppTransportSecurity',
  'WKAppBoundDomains',
  // export compliance
  'ITSAppUsesNonExemptEncryption',
  'ITSEncryptionExportComplianceCode',
  // legal / build metadata Xcode injects
  'NSHumanReadableCopyright',
  'BuildMachineOSBuild',
]);

// Xcode writes these into the BUILT plist. They are metadata, never capabilities.
const PLIST_ALLOWED_PREFIXES = ['DT'];

// Keys that get a specific, plain-language failure instead of "not on the whitelist".
// Order matters: the first matching rule wins.
const PLIST_BANNED = [
  {
    match: (k) => k === 'UIBackgroundModes',
    why: 'the app must not declare ANY background mode',
    fix:
      'Delete UIBackgroundModes from Info.plist (Xcode: target → Signing & Capabilities → remove\n' +
      '  "Background Modes" entirely). A declared-but-unused background mode is guideline 2.5.4,\n' +
      '  one of the most common rejections there is. Listen Mode still works while the app is open.\n' +
      '  See the LISTEN MODE note at the top of this file before overriding.',
  },
  {
    match: (k) => k === 'NSCameraUsageDescription',
    why: 'the app has no camera code and must never ask for the camera',
    fix: 'Delete NSCameraUsageDescription from Info.plist.',
  },
  {
    match: (k) => k === 'NSMicrophoneUsageDescription',
    why: 'the app has no microphone code and must never ask for the microphone',
    fix: 'Delete NSMicrophoneUsageDescription from Info.plist.',
  },
  {
    match: (k) => k.startsWith('NSPhotoLibrary'),
    why: 'the app never reads or writes the photo library',
    fix: 'Delete every NSPhotoLibrary* key from Info.plist.',
  },
  {
    match: (k) => k.startsWith('NSLocation'),
    why: 'there is NO location code anywhere in this product (see CLAUDE.md) and store/PRIVACY_NUTRITION.md answers "not collected"',
    fix:
      'Delete every NSLocation* key from Info.plist. Shipping one contradicts the privacy answers\n' +
      '  already filed in App Store Connect, which is a 5.1.1 problem, not a paperwork problem.',
  },
  {
    match: (k) => k === 'NSContactsUsageDescription',
    why: 'the app never reads contacts',
    fix: 'Delete NSContactsUsageDescription from Info.plist.',
  },
  {
    match: (k) => /^NS(Calendars|Reminders|Motion|SpeechRecognition|FaceID|Bluetooth|Health|Siri|UserTracking|LocalNetwork|AppleMusic|HomeKit|Nearby|Sensor|Video|Desktop|Documents|Downloads|RemovableVolumes|NetworkVolumes|FileProvider)/.test(k),
    why: 'a permission Scroll Anytime does not use',
    fix: `Delete ${'this key'} from Info.plist. Every usage-description string in the build is a promise to the reviewer that the app uses that capability.`,
  },
  {
    match: (k) => k === 'UIFileSharingEnabled' || k === 'LSSupportsOpeningDocumentsInPlace',
    why: 'the app exposes no documents and should not appear in the Files app',
    fix: 'Delete this key from Info.plist.',
  },
  {
    match: (k) => k === 'UIApplicationExitsOnSuspend',
    why: 'deprecated and rejected by the App Store',
    fix: 'Delete UIApplicationExitsOnSuspend from Info.plist.',
  },
];

const ENTITLEMENTS_ALLOWED = new Set([
  'application-identifier',
  'com.apple.developer.team-identifier',
  'com.apple.developer.associated-domains',
  'get-task-allow',
  'keychain-access-groups',
  // 2026-10-12: push is real. The Push Notifications capability is on the App ID and an APNs
  // key (79W6F475G5, Sandbox & Production, team-scoped) is in the Worker's secrets, so the
  // entitlement is now earned rather than left over from the PWABuilder template.
  'aps-environment',
]);

const ENTITLEMENTS_BANNED = [
  {
    // the macOS-style spelling is still wrong; only the plain `aps-environment` above is right
    match: (k) => k === 'com.apple.developer.aps-environment',
    why: 'the iOS key is plain `aps-environment`; this spelling is the macOS one and signs nothing',
    fix: 'use <key>aps-environment</key> in Entitlements.plist.',
  },
  {
    match: (k) => k.startsWith('com.apple.developer.usernotifications'),
    why: 'the app sends no notifications of any kind in v1.0',
    fix: 'Remove the notifications capability in Signing & Capabilities.',
  },
  {
    match: (k) => k === 'com.apple.security.application-groups',
    why: 'there is no extension or second target to share with',
    fix: 'Remove the "App Groups" capability in Signing & Capabilities.',
  },
  {
    match: (k) => k === 'com.apple.developer.applesignin',
    why: 'Sign in with Apple happens in the web view (appleid.apple.com), not through the native API — the entitlement is unused',
    fix:
      'Remove the "Sign in with Apple" capability from the Xcode target. Keep it enabled on the App\n' +
      '  ID in the developer portal (SETUP-APPLE.md PART 3) — that is what the web flow needs.',
  },
  {
    match: (k) => k.startsWith('com.apple.developer.'),
    why: 'a capability Scroll Anytime does not use',
    fix: 'Remove this capability in Xcode → target → Signing & Capabilities.',
  },
];

// ── 2. arguments ────────────────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
let plistArg = null;
let entArg = null;
let allowBackgroundAudio = false;
let asJson = false;

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--entitlements') entArg = argv[++i];
  else if (a === '--allow-background-audio') allowBackgroundAudio = true;
  else if (a === '--json') asJson = true;
  else if (a === '-h' || a === '--help') {
    console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').filter((l) => l.startsWith('//')).map((l) => l.slice(3)).join('\n'));
    process.exit(0);
  } else if (a.startsWith('-')) {
    console.error(`Unknown option: ${a}  (try --help)`);
    process.exit(2);
  } else if (!plistArg) plistArg = a;
}

// ── 3. finding the files ────────────────────────────────────────────────────────────────────────
const SKIP_DIRS = new Set(['node_modules', '.git', 'Pods', 'Carthage', '.build', 'DerivedData']);

function walk(dir, out = [], depth = 0) {
  if (depth > 12) return out;
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      if (e.name.endsWith('.dSYM')) continue;
      walk(p, out, depth + 1);
    } else if (e.isFile()) {
      out.push(p);
    }
  }
  return out;
}

/** The plist we care about is the one Apple receives: the one inside the built .app. */
function rankPlist(p) {
  const u = p.split(sep).join('/');
  if (/\/Frameworks\/|\/PlugIns\/|\/Watch\/|\/Intermediates/.test(u)) return -1;
  let score = 0;
  if (/\.app\/Info\.plist$/.test(u)) score += 100; // built app bundle — the real thing
  if (/\.xcarchive\//.test(u)) score += 20;
  if (/\/build\//i.test(u)) score += 10;
  score -= u.split('/').length; // prefer the shallower of equals
  return score;
}

function discover() {
  if (!existsSync(IOS_DIR)) return { files: [], plist: null, ent: null };
  const files = walk(IOS_DIR);
  const plists = files
    .filter((f) => f.endsWith(`${sep}Info.plist`))
    .map((f) => ({ f, r: rankPlist(f) }))
    .filter((x) => x.r >= 0)
    .sort((a, b) => b.r - a.r);
  const ents = files.filter((f) => f.endsWith('.entitlements')).sort((a, b) => a.length - b.length);
  return { files, plist: plists[0]?.f ?? null, ent: ents[0] ?? null };
}

const found = discover();
const plistPath = plistArg ? resolve(plistArg) : found.plist;
const entPath = entArg ? resolve(entArg) : found.ent;

// ── 4. reading a plist (binary or XML) ──────────────────────────────────────────────────────────

/** macOS ships plutil, and the built Info.plist is a BINARY plist — plutil is the reliable read. */
function viaPlutil(path, format) {
  return execFileSync('plutil', ['-convert', format, '-o', '-', path], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    maxBuffer: 32 * 1024 * 1024,
  });
}

/** Fallback for machines without plutil (and for the XML .entitlements files). */
function parseXmlPlist(xml) {
  const re = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<(\/?)([A-Za-z0-9_.-]+)([^>]*?)(\/?)>|([^<]+)/g;
  const toks = [];
  let m;
  while ((m = re.exec(xml)) !== null) {
    if (m[2]) toks.push({ t: m[1] ? 'close' : 'open', name: m[2], self: m[4] === '/' });
    else if (m[5] !== undefined && m[5].trim() !== '') toks.push({ t: 'text', v: m[5] });
  }

  let p = 0;
  const decode = (s) =>
    s
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
      .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
      .replace(/&amp;/g, '&');

  function textUntilClose(name) {
    let out = '';
    while (p < toks.length && toks[p].t === 'text') out += toks[p++].v;
    if (p < toks.length && toks[p].t === 'close' && toks[p].name === name) p++;
    return decode(out);
  }

  function value() {
    const tk = toks[p];
    if (!tk || tk.t !== 'open') return undefined;
    const { name, self } = tk;
    p++;
    switch (name) {
      case 'true':
        if (!self) textUntilClose('true');
        return true;
      case 'false':
        if (!self) textUntilClose('false');
        return false;
      case 'string':
      case 'data':
      case 'date':
      case 'uid':
        return self ? '' : textUntilClose(name);
      case 'integer':
      case 'real': {
        const t = self ? '' : textUntilClose(name);
        return t === '' ? 0 : Number(t);
      }
      case 'dict': {
        const d = {};
        if (self) return d;
        while (p < toks.length && !(toks[p].t === 'close' && toks[p].name === 'dict')) {
          if (toks[p].t === 'open' && toks[p].name === 'key') {
            const selfKey = toks[p].self;
            p++;
            const k = selfKey ? '' : textUntilClose('key');
            d[k] = value();
          } else p++;
        }
        p++;
        return d;
      }
      case 'array': {
        const a = [];
        if (self) return a;
        while (p < toks.length && !(toks[p].t === 'close' && toks[p].name === 'array')) {
          const before = p;
          const v = value();
          if (p === before) { p++; continue; }
          a.push(v);
        }
        p++;
        return a;
      }
      default: {
        // Unknown wrapper (<plist>, etc.) — descend into it.
        if (self) return undefined;
        let v;
        while (p < toks.length && !(toks[p].t === 'close' && toks[p].name === name)) {
          const before = p;
          const inner = value();
          if (p === before) { p++; continue; }
          if (inner !== undefined) v = inner;
        }
        p++;
        return v;
      }
    }
  }

  while (p < toks.length && !(toks[p].t === 'open' && toks[p].name === 'plist')) p++;
  return value() ?? {};
}

function readPlist(path) {
  const head = readFileSync(path).subarray(0, 8).toString('binary');
  const isBinary = head.startsWith('bplist');
  if (isBinary || process.platform === 'darwin') {
    try {
      return JSON.parse(viaPlutil(path, 'json'));
    } catch {
      /* plutil json refuses some types (dates, data) — fall through to xml */
    }
    try {
      return parseXmlPlist(viaPlutil(path, 'xml1'));
    } catch {
      /* plutil not available — fall through */
    }
  }
  if (isBinary) {
    throw new Error(
      `${path} is a binary plist and plutil could not read it. Run this on the Mac, or convert it first:\n  plutil -convert xml1 -o converted.plist "${path}"`,
    );
  }
  return parseXmlPlist(readFileSync(path, 'utf8'));
}

const rel = (p) => (p ? relative(ROOT, p).split(sep).join('/') : null);
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ── 5. the checks ───────────────────────────────────────────────────────────────────────────────
console.log(`\n${c.bld('Scroll Anytime — Info.plist / entitlements whitelist')}  ${c.dim('(PART 3.3)')}`);

if (!plistPath || !existsSync(plistPath)) {
  console.log(
    `\n  ${c.red('●')} No Info.plist found.\n\n` +
      `    Looked under: ${rel(IOS_DIR)}\n` +
      `    Either the iOS project has not been generated yet (see ship/ios/README.md, STEP 1),\n` +
      `    or you need to point this script at the file:\n\n` +
      `      node ship/verify-plist.mjs "path/to/YourApp.app/Info.plist"\n\n` +
      `    After archiving, the right file is inside the archive:\n` +
      `      ~/Library/Developer/Xcode/Archives/<date>/<name>.xcarchive/Products/Applications/<App>.app/Info.plist\n`,
  );
  process.exit(1);
}

let plist;
try {
  plist = readPlist(plistPath);
} catch (err) {
  console.log(`\n  ${c.red('●')} Could not read ${rel(plistPath)}\n    ${err.message}\n`);
  process.exit(1);
}

console.log(`${c.dim(`Info.plist:    ${rel(plistPath)}`)}`);
console.log(`${c.dim(`entitlements:  ${entPath ? rel(entPath) : '(none found — see note below)'}`)}\n`);

// 5a. banned + unknown Info.plist keys
for (const key of Object.keys(plist)) {
  if (key === 'UIBackgroundModes' && allowBackgroundAudio) {
    const modes = plist[key];
    if (eq(modes, ['audio'])) {
      warn(
        'UIBackgroundModes',
        'audio — allowed only because --allow-background-audio was passed',
        'This is only safe if the shell ACTIVATES an AVAudioSession(.playback) at launch AND someone\n' +
          '  has watched audio keep playing on a real locked iPhone. If not, remove the flag and the\n' +
          '  key: an unused background mode is a guideline 2.5.4 rejection.',
      );
    } else {
      const rule = PLIST_BANNED.find((b) => b.match('UIBackgroundModes'));
      fail('UIBackgroundModes', `${JSON.stringify(modes)} — only ["audio"] can ever be allowed`, rule.fix);
    }
    continue;
  }

  const banned = PLIST_BANNED.find((b) => b.match(key));
  if (banned) {
    fail(key, banned.why, banned.fix.replace('this key', key));
    continue;
  }

  if (PLIST_ALLOWED.has(key)) continue;
  if (PLIST_ALLOWED_PREFIXES.some((pre) => key.startsWith(pre))) continue;

  fail(
    key,
    'not on the whitelist — nobody has decided this key belongs in the build',
    `Either delete "${key}" from Info.plist, or — if it genuinely belongs — add it to\n` +
      '  PLIST_ALLOWED in ship/verify-plist.mjs with a comment saying why. Do not silence this by\n' +
      '  skipping the check.',
  );
}

// 5b. the three hard assertions
if (plist.ITSAppUsesNonExemptEncryption === false) {
  pass('ITSAppUsesNonExemptEncryption', 'false');
} else if (!('ITSAppUsesNonExemptEncryption' in plist)) {
  fail(
    'ITSAppUsesNonExemptEncryption',
    'missing — every upload will stop and ask the export-compliance questions',
    'Add to Info.plist:  <key>ITSAppUsesNonExemptEncryption</key><false/>\n' +
      '  (In Xcode\'s plist editor the row is "App Uses Non-Exempt Encryption" = NO.)\n' +
      '  The app uses only HTTPS, which is exempt.',
  );
} else {
  fail(
    'ITSAppUsesNonExemptEncryption',
    `is ${JSON.stringify(plist.ITSAppUsesNonExemptEncryption)}, must be false`,
    'Set it to NO / <false/> in Info.plist. Scroll Anytime uses only standard HTTPS.',
  );
}

if (plist.CFBundleIdentifier === BUNDLE_ID) {
  pass('CFBundleIdentifier', BUNDLE_ID);
} else {
  fail(
    'CFBundleIdentifier',
    `${JSON.stringify(plist.CFBundleIdentifier ?? null)} — must be exactly ${BUNDLE_ID}`,
    `Xcode → target → Signing & Capabilities → Bundle Identifier → ${BUNDLE_ID}\n` +
      '  This must match the App ID registered in SETUP-APPLE.md PART 3 exactly, or the upload is\n' +
      '  rejected with "bundle ID not found".',
  );
}

if (eq(plist.UIDeviceFamily, [1])) {
  pass('UIDeviceFamily', '[1] — iPhone only');
} else {
  fail(
    'UIDeviceFamily',
    `${JSON.stringify(plist.UIDeviceFamily ?? null)} — must be exactly [1] (iPhone only)`,
    'Xcode → target → General → Deployment Info → Supported Destinations: keep iPhone, remove iPad\n' +
      '  (and Mac / Vision). The feed is a portrait phone experience and has no iPad layout; shipping\n' +
      '  an untested iPad build is a 4.0/2.1 rejection waiting to happen.\n' +
      '  Build setting: TARGETED_DEVICE_FAMILY = 1',
  );
}

// 5c. things that are not on the assertion list but will still sink the build
if (Array.isArray(plist.WKAppBoundDomains) && plist.WKAppBoundDomains.includes(APP_BOUND_DOMAIN)) {
  pass('WKAppBoundDomains', plist.WKAppBoundDomains.join(', '));
} else {
  warn(
    'WKAppBoundDomains',
    `does not list ${APP_BOUND_DOMAIN} — service workers will NOT run in the web view`,
    'Add to Info.plist:\n' +
      '    <key>WKAppBoundDomains</key><array><string>scrollanytime.com</string></array>\n' +
      '  Without it there is no service worker, so no offline mode — and the airplane-mode test in\n' +
      '  store/XCODE_CHECKLIST.md fails. Treat this warning as a launch blocker.',
  );
}

if (plist.CFBundleIconName) {
  pass('CFBundleIconName', String(plist.CFBundleIconName));
} else {
  warn(
    'CFBundleIconName',
    'missing — the upload will be rejected with ITMS-90713',
    'Add an asset-catalog app icon set named AppIcon and set ASSETCATALOG_COMPILER_APPICON_NAME.\n' +
      '  In a normal Xcode build this key appears on its own once the icon set exists.',
  );
}

const orientations = plist.UISupportedInterfaceOrientations;
if (Array.isArray(orientations)) {
  const landscape = orientations.filter((o) => String(o).includes('Landscape'));
  if (landscape.length === 0) pass('orientation', orientations.join(', ') || 'portrait only');
  else warn('orientation', `allows ${landscape.join(', ')} — the app is portrait only`,
    'Xcode → target → General → Deployment Info → tick Portrait only.');
}

const ats = plist.NSAppTransportSecurity;
if (ats && (ats.NSAllowsArbitraryLoads === true || ats.NSAllowsArbitraryLoadsInWebContent === true)) {
  warn(
    'NSAppTransportSecurity',
    'allows arbitrary (non-HTTPS) loads',
    'Remove NSAllowsArbitraryLoads. Everything Scroll Anytime loads is HTTPS, and leaving this on\n' +
      '  contradicts ITSAppUsesNonExemptEncryption=NO if a reviewer looks.',
  );
}

info('CFBundleShortVersionString', String(plist.CFBundleShortVersionString ?? '(unset)') + '   ' + c.dim('(store version, e.g. 1.0.0)'));
info('CFBundleVersion', String(plist.CFBundleVersion ?? '(unset)') + '   ' + c.dim('(build number — must increase on every upload)'));
info('MinimumOSVersion', String(plist.MinimumOSVersion ?? plist.LSMinimumSystemVersion ?? '(unset)') + '   ' + c.dim('(deployment target)'));

// 5d. entitlements
if (!entPath || !existsSync(entPath)) {
  warn(
    'entitlements file',
    'none found — capabilities were not checked',
    'If the project genuinely has no .entitlements file, that is the safest possible state and you\n' +
      '  can ignore this. If it has one, point at it:\n' +
      '    node ship/verify-plist.mjs <Info.plist> --entitlements <path/to/App.entitlements>',
  );
} else {
  let ent;
  try {
    ent = readPlist(entPath);
  } catch (err) {
    fail('entitlements file', `could not read ${rel(entPath)}: ${err.message}`, 'Check the path and run again.');
    ent = null;
  }

  if (ent) {
    for (const key of Object.keys(ent)) {
      const banned = ENTITLEMENTS_BANNED.find((b) => b.match(key));
      if (banned && !ENTITLEMENTS_ALLOWED.has(key)) {
        fail(key, banned.why, banned.fix);
        continue;
      }
      if (ENTITLEMENTS_ALLOWED.has(key)) continue;
      fail(
        key,
        'entitlement not on the whitelist',
        `Remove "${key}" from ${rel(entPath)} (Xcode: target → Signing & Capabilities), or add it to\n` +
          '  ENTITLEMENTS_ALLOWED in ship/verify-plist.mjs with a comment saying why it is needed.',
      );
    }

    const domains = ent['com.apple.developer.associated-domains'];
    if (domains === undefined) {
      warn(
        'associated domains',
        'not set — shared /c/ and /r/ links will open Safari, not the app',
        'Xcode → target → Signing & Capabilities → + Capability → Associated Domains → add\n' +
          `    ${ASSOCIATED_DOMAIN}\n` +
          '  This is optional for approval but it is the whole point of the universal-links work.',
      );
    } else if (eq(domains, [ASSOCIATED_DOMAIN])) {
      pass('associated domains', ASSOCIATED_DOMAIN);
    } else {
      fail(
        'associated domains',
        `${JSON.stringify(domains)} — must be exactly ["${ASSOCIATED_DOMAIN}"]`,
        `Remove every other domain. The site serves /.well-known/apple-app-site-association for\n` +
          '  /c/* and /r/* only, and any domain listed here that does not serve a matching AASA file\n' +
          '  makes the whole capability fail silently.',
      );
    }
  }
}

// ── 6. the table ────────────────────────────────────────────────────────────────────────────────
const mark = { PASS: c.grn('●'), FAIL: c.red('●'), WARN: c.yel('●'), INFO: c.dim('·') };
const width = Math.min(34, Math.max(...rows.map((r) => r.what.length), 10));

for (const r of rows) {
  console.log(`  ${mark[r.s]} ${r.what.padEnd(width)}  ${r.s === 'PASS' || r.s === 'INFO' ? c.dim(r.detail) : r.detail}`);
}

const fixes = rows.filter((r) => r.fix && (r.s === 'FAIL' || r.s === 'WARN'));
if (fixes.length) {
  console.log(`\n${c.bld('HOW TO FIX')}`);
  fixes.forEach((r, i) => {
    const head = r.s === 'FAIL' ? c.red(`${i + 1}) ${r.what}`) : c.yel(`${i + 1}) ${r.what}`);
    console.log(`\n${head}\n  ${r.fix}`);
  });
}

console.log('');
if (fails === 0 && warns === 0) {
  console.log(`${c.grn(c.bld('CLEAN.'))} The build declares nothing it should not. Safe to upload.\n`);
} else if (fails === 0) {
  console.log(`${c.grn(c.bld('NO FAILURES'))} — ${warns} warning(s) above. Read every one before uploading.\n`);
} else {
  console.log(
    `${c.red(c.bld('DO NOT UPLOAD'))} — ${fails} failure(s)${warns ? `, ${warns} warning(s)` : ''}.\n` +
      `${c.dim('Fix them in Xcode, archive again, and re-run this against the NEW build.')}\n`,
  );
}

if (asJson) {
  console.log(JSON.stringify({ plist: rel(plistPath), entitlements: rel(entPath), fails, warns, rows }, null, 2));
}

process.exit(fails === 0 ? 0 : 1);
