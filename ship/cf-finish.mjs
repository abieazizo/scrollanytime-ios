#!/usr/bin/env node
// ship/cf-finish.mjs — the Cloudflare jobs the wrangler OAuth token cannot do.
//
//   CF_API_TOKEN=xxxxx node ship/cf-finish.mjs
//
// 1. DNS for mail.scrollanytime.com, so sign-in codes send from OUR domain instead of
//    clipflow.shefabuilders.com — a domain with no relationship to this product, which is exactly
//    the kind of mismatch a spam filter weighs. Records come from ship/resend-dns.json, generated
//    by Resend's own API.
// 2. DMARC on every sending domain, plus the RFC 7489 external-destination authorization records
//    that reports actually require.
// 3. Turn off Cloudflare's Web Analytics beacon injection.
//
// This was a bash script first and that was the wrong tool: building JSON bodies through shell
// quoting, and reading records from a TSV, meant Windows CRLF endings turned a priority field into
// "\r" and the request bodies came out malformed. All of it is string and JSON handling, which is
// what a real language is for.
//
// Idempotent: existing records are updated in place, never duplicated. Safe to re-run.
import { readFileSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const API = 'https://api.cloudflare.com/client/v4';
const ACCOUNT = '582077fa96c12544552377cb16fc4a36';
const TOK = process.env.CF_API_TOKEN;

const G = '\x1b[32m', R = '\x1b[31m', Y = '\x1b[33m', B = '\x1b[1m', D = '\x1b[2m', N = '\x1b[0m';
let fails = 0;
const ok = (m) => console.log(`  ${G}OK${N}   ${m}`);
const bad = (m) => { console.log(`  ${R}FAIL${N} ${m}`); fails++; };
const warn = (m) => console.log(`  ${Y}warn${N} ${m}`);
const info = (m) => console.log(`  ${D}${m}${N}`);

if (!TOK) {
  console.error(`\n${R}CF_API_TOKEN is not set.${N}\n`);
  console.error(`  https://dash.cloudflare.com/profile/api-tokens → Create Custom Token →`);
  console.error(`  Zone·DNS·Edit·All zones  +  Account·Account Settings·Edit\n`);
  process.exit(1);
}

async function cf(path, init = {}) {
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${TOK}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  });
  const body = await res.json().catch(() => null);
  return { http: res.status, ...(body ?? {}) };
}

const errsOf = (r) => (r.errors ?? []).map((e) => `${e.code} ${e.message}`).join('; ') || `http ${r.http}`;

console.log(`\n${B}Cloudflare — finishing the remaining API jobs${N}\n`);

// ── token ──────────────────────────────────────────────────────────────────────────────────
const verify = await cf('/user/tokens/verify');
console.log(`${B}token${N}`);
verify.success ? ok(`token ${verify.result?.status}`) : bad(`token check: ${errsOf(verify)}`);
if (!verify.success) process.exit(1);

// ── zones ──────────────────────────────────────────────────────────────────────────────────
async function zoneId(name) {
  const r = await cf(`/zones?name=${name}`);
  return r.success ? (r.result?.[0]?.id ?? null) : null;
}
const ZSA = await zoneId('scrollanytime.com');
const ZSB = await zoneId('shefabuilders.com');
ZSA ? ok(`zone scrollanytime.com ${ZSA}`) : bad('cannot read the scrollanytime.com zone — needs Zone:DNS:Edit');
ZSB ? ok(`zone shefabuilders.com ${ZSB}`) : warn('cannot read shefabuilders.com — its DMARC will be skipped');
if (!ZSA) process.exit(1);

/** Create or update one record. Matches on name+type so a re-run never leaves duplicates. */
async function upsert(zone, { type, name, content, priority }, label) {
  const found = await cf(`/zones/${zone}/dns_records?type=${type}&name=${encodeURIComponent(name)}`);
  const id = found.success ? found.result?.[0]?.id : null;
  const body = { type, name, content, ttl: 3600, comment: 'PHASE LAUNCH - ship/cf-finish.mjs' };
  if (priority != null) body.priority = Number(priority);
  const res = await cf(`/zones/${zone}/dns_records${id ? `/${id}` : ''}`, {
    method: id ? 'PUT' : 'POST',
    body: JSON.stringify(body),
  });
  res.success ? ok(`${label}${id ? ' (updated)' : ''}`) : bad(`${label} — ${errsOf(res)}`);
  return res.success;
}

// ── 1. the sending domain ──────────────────────────────────────────────────────────────────
console.log(`\n${B}1. mail.scrollanytime.com (Resend sending domain)${N}`);
const resendDns = JSON.parse(readFileSync(join(ROOT, 'ship/resend-dns.json'), 'utf8'));
for (const r of resendDns.records) {
  const name = `${r.name}.scrollanytime.com`;
  await upsert(ZSA, { type: r.type, name, content: r.value, priority: r.priority }, `${r.type} ${name}`);
}

// ── 2. DMARC ───────────────────────────────────────────────────────────────────────────────
console.log(`\n${B}2. DMARC${N}`);
// p=quarantine is safe: verified before choosing it that the live sender's SPF
// (send.clipflow.shefabuilders.com, include:amazonses.com) and DKIM (resend._domainkey,
// d=clipflow.shefabuilders.com) both authenticate AND align under relaxed alignment, sharing the
// organisational domain shefabuilders.com. Quarantine cannot catch our own mail.
// fo=1 asks for a failure report when ANY mechanism fails, not only when both do.
const DMARC = 'v=DMARC1; p=quarantine; rua=mailto:hello@scrollanytime.com; fo=1; adkim=r; aspf=r';
await upsert(ZSA, { type: 'TXT', name: '_dmarc.scrollanytime.com', content: DMARC }, '_dmarc.scrollanytime.com');
// explicit on the sending subdomain, so its policy is independent of whatever happens to the apex
await upsert(ZSA, { type: 'TXT', name: '_dmarc.mail.scrollanytime.com', content: DMARC }, '_dmarc.mail.scrollanytime.com');
if (ZSB) {
  await upsert(ZSB, { type: 'TXT', name: '_dmarc.clipflow.shefabuilders.com', content: DMARC }, '_dmarc.clipflow.shefabuilders.com');
  await upsert(ZSB, { type: 'TXT', name: '_dmarc.shefabuilders.com', content: DMARC }, '_dmarc.shefabuilders.com (parent)');
}
// EXTERNAL DESTINATION AUTHORIZATION (RFC 7489 §7.1). rua points at hello@scrollanytime.com, a
// DIFFERENT domain from the clipflow/shefabuilders sender — without these, most reporters silently
// refuse to send reports while the rua looks perfectly configured. The record lives on the
// DESTINATION domain, named after the sending domain.
for (const sender of ['shefabuilders.com', 'clipflow.shefabuilders.com']) {
  await upsert(ZSA, { type: 'TXT', name: `${sender}._report._dmarc.scrollanytime.com`, content: 'v=DMARC1' },
    `report authorization: ${sender} → hello@`);
}

// ── 3. the Web Analytics beacon ────────────────────────────────────────────────────────────
console.log(`\n${B}3. Web Analytics beacon injection${N}`);
const sites = await cf(`/accounts/${ACCOUNT}/rum/site_info/list?per_page=100`);
if (!sites.success) {
  warn(`cannot read the Web Analytics API — ${errsOf(sites)}`);
  console.log(`  ${Y}Add ${B}Account · Account Settings · Edit${N}${Y} to the token and re-run.${N}`);
} else {
  const mine = (sites.result ?? []).filter((s) => {
    const host = s.ruleset?.zone_name ?? s.host ?? '';
    return host.includes('scrollanytime');
  });
  if (mine.length === 0) ok('no Web Analytics site is configured for scrollanytime.com');
  for (const s of mine) {
    info(`site ${s.site_tag} (${s.ruleset?.zone_name ?? s.host}) auto_install=${s.auto_install}`);
    const del = await cf(`/accounts/${ACCOUNT}/rum/site_info/${s.site_tag}`, { method: 'DELETE' });
    del.success ? ok('removed the Web Analytics site — nothing left to inject') : bad(`could not remove it — ${errsOf(del)}`);
  }
}

// ── verify from PUBLIC DNS, not from the API's own answer ──────────────────────────────────
console.log(`\n${B}verifying against public DNS${N}`);
info('waiting 20s for propagation');
await new Promise((r) => setTimeout(r, 20_000));

async function txt(name, type = 'TXT') {
  const num = { TXT: 16, MX: 15 }[type];
  const r = await fetch(`https://cloudflare-dns.com/dns-query?name=${name}&type=${type}`, {
    headers: { accept: 'application/dns-json' },
  }).then((x) => x.json()).catch(() => null);
  return (r?.Answer ?? []).filter((a) => a.type === num).map((a) => String(a.data).replace(/^"|"$/g, ''));
}

const checks = [
  ['resend._domainkey.mail.scrollanytime.com', 'TXT', 'p='],
  ['send.mail.scrollanytime.com', 'TXT', 'v=spf1'],
  ['send.mail.scrollanytime.com', 'MX', 'amazonses'],
  ['_dmarc.scrollanytime.com', 'TXT', 'v=DMARC1'],
  ['_dmarc.mail.scrollanytime.com', 'TXT', 'v=DMARC1'],
  ['_dmarc.clipflow.shefabuilders.com', 'TXT', 'v=DMARC1'],
  ['_dmarc.shefabuilders.com', 'TXT', 'v=DMARC1'],
];
for (const [name, type, expect] of checks) {
  const got = await txt(name, type);
  const hit = got.some((g) => g.includes(expect));
  hit ? ok(`${type.padEnd(3)} ${name} → ${got[0].slice(0, 46)}`) : bad(`${type} ${name} → ${got.length ? got[0].slice(0, 60) : 'ABSENT'}`);
}

const html = await fetch('https://scrollanytime.com/', {
  headers: {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36',
    Accept: 'text/html',
  },
}).then((r) => r.text()).catch(() => '');
html.includes('cloudflareinsights') ? bad('the beacon is STILL injected into live HTML') : ok('beacon gone from live HTML');

console.log('');
if (fails > 0) {
  console.log(`${R}${B}CF-FINISH: ${fails} item(s) still failing${N}\n`);
  process.exit(1);
}
console.log(`${G}${B}CF-FINISH: DNS DONE${N}\n`);
console.log(`  ${B}One step left.${N} Resend must now SEE these records and mark the domain verified;`);
console.log(`  only then may EMAIL_FROM change — switching it first would bounce every code.\n`);
console.log(`  Say in Claude Code:  ${B}finish the sending domain${N}\n`);
