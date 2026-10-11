#!/usr/bin/env node
// Embeds ship/ios/offline.html into ship/ios/pwa-shell/Settings.swift as a compiled-in string.
//
// It goes into Settings.swift — a file the Xcode project ALREADY compiles — rather than into a new
// .swift file or a bundled resource. Both of those would require registering the file in
// project.pbxproj, and hand-editing that is the most fragile thing anyone can do to an Xcode
// project: get it wrong and the app either fails to build on the Mac, or builds with the file
// silently missing, which surfaces as a blank screen in airplane mode — the exact rejection this
// page exists to prevent. A string in an already-compiled file cannot go missing.
//
// The HTML remains the single source of truth. ship/ios-lint.sh re-runs this and fails if the
// embedded copy has drifted from the HTML.
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const html = readFileSync(join(ROOT, 'ship/ios/offline.html'), 'utf8');

// Swift multi-line strings are delimited by """ — the HTML must not contain that sequence, and
// the raw-string form (#"""..."""#) means backslashes and \( are literal, so nothing in the page
// can be read as Swift interpolation.
if (html.includes('"""')) {
  console.error('offline.html contains a triple quote — it cannot be embedded as a Swift string.');
  process.exit(1);
}

const MARK = '// ─── GENERATED: offline fallback ───';
const block = `${MARK}
// Source: ship/ios/offline.html    Regenerate: node ship/gen-offline-swift.mjs
// Do not edit below this line by hand.
//
// Shown when the FIRST navigation fails (an airplane-mode cold launch, which is what an App Store
// reviewer does first). Raw string (#"""..."""#): no escaping, no Swift interpolation.
let offlineFallbackHTML = #"""
${html}
"""#
`;

const settingsPath = join(ROOT, 'ship/ios/pwa-shell/Settings.swift');
const current = readFileSync(settingsPath, 'utf8');
const head = current.includes(MARK) ? current.slice(0, current.indexOf(MARK)) : `${current.replace(/\s*$/, '')}

`;
writeFileSync(settingsPath, head + block, 'utf8');
console.log(`  embedded ${html.length} bytes of offline.html into Settings.swift`);
