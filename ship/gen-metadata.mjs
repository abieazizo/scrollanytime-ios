#!/usr/bin/env node
// Generates ship/metadata/ (fastlane deliver format) from the /store documents.
//
// ONE source of truth: the listing and review notes live in store/*.md, where they are reviewed and
// version-controlled as prose. This turns them into the flat text files deliver expects, so nobody
// ever has to keep two copies of the description in sync — and so the Mac has nothing to author.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { reviewCode } from '../scripts/_review_code.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const EN = join(ROOT, 'ship/metadata/en-US');
const RI = join(ROOT, 'ship/metadata/review_information');
mkdirSync(EN, { recursive: true });
mkdirSync(RI, { recursive: true });

const listing = readFileSync(join(ROOT, 'store/APP_STORE_LISTING.md'), 'utf8');

/**
 * Body of a `## Heading ...` section, up to the next `## `.
 * Matched on the heading's PREFIX, so "## Keywords (100 chars max)" is found by "Keywords" and the
 * parenthetical can be reworded without silently emptying a metadata file.
 */
function section(prefix) {
  const lines = listing.split('\n');
  const start = lines.findIndex((l) => l.startsWith('## ') && l.slice(3).trim().toLowerCase().startsWith(prefix.toLowerCase()));
  if (start === -1) throw new Error(`APP_STORE_LISTING.md has no "## ${prefix}..." section`);
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((l) => l.startsWith('## '));
  return (end === -1 ? rest : rest.slice(0, end))
    .filter((l) => !l.trimStart().startsWith('>')) // editorial notes to ourselves are not metadata
    .join('\n')
    .trim();
}

const files = {
  'name.txt': section('App name'),
  'subtitle.txt': section('Subtitle'),
  'promotional_text.txt': section('Promotional text'),
  'description.txt': section('Description'),
  'keywords.txt': section('Keywords'),
  'release_notes.txt': 'First release.',
  'support_url.txt': 'https://scrollanytime.com/support',
  'marketing_url.txt': 'https://scrollanytime.com',
  'privacy_url.txt': 'https://scrollanytime.com/privacy',
};

// Apple's hard limits. A file that is empty or over length is caught HERE, on a machine where it
// can be fixed, rather than by a deliver error on the Mac.
const LIMITS = { 'name.txt': 30, 'subtitle.txt': 30, 'promotional_text.txt': 170, 'keywords.txt': 100, 'description.txt': 4000 };
let bad = 0;
for (const [f, v] of Object.entries(files)) {
  if (!v.trim()) {
    console.error(`  EMPTY  ${f} — extraction failed, refusing to write a blank metadata file`);
    bad++;
    continue;
  }
  const cap = LIMITS[f];
  if (cap && v.length > cap) {
    console.error(`  LONG   ${f} is ${v.length} chars, Apple's limit is ${cap}`);
    bad++;
    continue;
  }
  writeFileSync(join(EN, f), `${v}\n`, 'utf8');
  console.log(`  ${f.padEnd(22)} ${String(v.length).padStart(5)} chars${cap ? ` / ${cap}` : ''}`);
}

// review information
const notes = readFileSync(join(ROOT, 'store/APP_REVIEW_NOTES.md'), 'utf8').replace(/^# .*$/m, '').trim();
const ri = {
  'notes.txt': notes,
  'demo_user.txt': 'review@scrollanytime.com',
  'demo_password.txt': reviewCode(),
  'email_address.txt': 'hello@scrollanytime.com',
  'first_name.txt': 'Scroll Anytime',
  'last_name.txt': 'Owner',
  // The owner's real phone number is required by App Store Connect and is deliberately NOT in the
  // repo. mac-run.sh reads ASC_PHONE if it is set; otherwise the field is filled by hand once.
  'phone_number.txt': process.env.ASC_PHONE ?? '',
};
for (const [f, v] of Object.entries(ri)) {
  if (f === 'phone_number.txt' && !v) {
    console.log('  phone_number.txt       (left blank — set ASC_PHONE, or type it once in App Store Connect)');
    continue;
  }
  writeFileSync(join(RI, f), `${v}\n`, 'utf8');
}
console.log(`  review_information written (${Object.keys(ri).length - (ri['phone_number.txt'] ? 0 : 1)} files)`);

if (bad > 0) {
  console.error(`\n  ${bad} metadata file(s) could not be written. Fix store/APP_STORE_LISTING.md and re-run.\n`);
  process.exit(1);
}
console.log('\n  ship/metadata is ready for `fastlane deliver`.\n');
