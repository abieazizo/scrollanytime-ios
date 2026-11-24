#!/usr/bin/env node
// ship/resend-key-check.mjs — does this Resend key belong to the account that owns our sender?
//
//   node ship/resend-key-check.mjs re_xxxxxxxx
//
// WHY THIS EXISTS. A Resend key looks identical whichever account it came from, and a key from the
// wrong account fails in the worst possible way: `wrangler secret put` accepts it happily, the
// deploy succeeds, and then EVERY sign-in code 403s — a total auth outage, discovered by users.
//
// It happened here. A key was handed over as "the Resend API key, same account"; it was a
// full-access key for a DIFFERENT account (it owned offlinedrafting.com). The tell is below and it
// is unambiguous: Resend answers 403 "domain is not verified" for a domain that account cannot
// send from, while the real account reports that same domain as verified. A domain cannot be both.
//
// So never wire a key by trusting its label. Run this first. It asks the only question that
// matters — can this key send as the address we actually send from — by attempting the operation.
const KEY = process.argv[2];
const SENDERS = ['mail.scrollanytime.com', 'clipflow.shefabuilders.com'];
const G = '\x1b[32m', R = '\x1b[31m', Y = '\x1b[33m', B = '\x1b[1m', D = '\x1b[2m', N = '\x1b[0m';

if (!KEY || !KEY.startsWith('re_')) {
  console.error(`\n${R}usage: node ship/resend-key-check.mjs re_xxxxxxxx${N}\n`);
  process.exit(2);
}

const api = (p, init) =>
  fetch(`https://api.resend.com${p}`, {
    ...init,
    headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
  });

console.log(`\n${B}Resend key check${N}\n`);

// 1. which domains does this key's ACCOUNT actually hold
const domRes = await api('/domains');
const domBody = await domRes.json().catch(() => null);
if (!domRes.ok) {
  console.log(`  ${R}FAIL${N} the key was rejected: ${domRes.status} ${JSON.stringify(domBody)?.slice(0, 120)}`);
  process.exit(1);
}
const owned = (domBody?.data ?? []).map((d) => `${d.name} [${d.status}]`);
console.log(`${B}1. domains in this key's account${N}`);
console.log(owned.length ? owned.map((d) => `  ${d}`).join('\n') : `  ${Y}(none)${N}`);

// 2. the question that actually matters: can it send AS us?
// Metadata can be misread; the send attempt cannot. A 403 "not verified" here is definitive.
console.log(`\n${B}2. can it send as our senders?${N}`);
let usable = 0;
for (const dom of SENDERS) {
  const res = await api('/emails', {
    method: 'POST',
    body: JSON.stringify({
      from: `Scroll Anytime <signin@${dom}>`,
      // deliberately invalid recipient: Resend validates the SENDER first, so a wrong-account key
      // 403s before this is ever considered, and a right-account key stops at the address without
      // mailing a real person. The check costs nobody an inbox.
      to: ['verify-only@resend-key-check.invalid'],
      subject: 'key check',
      text: 'key check',
    }),
  });
  const body = await res.json().catch(() => null);
  const notOurs = res.status === 403 && /not verified/i.test(body?.message ?? '');
  if (notOurs) console.log(`  ${R}NO ${N} signin@${dom} — 403 "${body.message.slice(0, 58)}…"`);
  else { usable++; console.log(`  ${G}YES${N} signin@${dom} (HTTP ${res.status})`); }
}

console.log('');
if (usable === 0) {
  console.log(`${R}${B}WRONG ACCOUNT — do not wire this key.${N}`);
  console.log(`  It cannot send as any of our senders. Setting it would 403 every sign-in code.`);
  console.log(`  Get the key from the Resend account that lists ${B}${SENDERS[0]}${N} above.\n`);
  process.exit(1);
}
console.log(`${G}${B}OK — this key can send as ${usable}/${SENDERS.length} of our senders.${N}`);
console.log(`  Wire it with:  ${B}cd worker && npx wrangler secret put RESEND_API_KEY${N}\n`);
