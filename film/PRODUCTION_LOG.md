# Scroll Anytime — the film: production log

Session date 2026-10-12. Each entry says what was asked, what happened, and why.

## Blockers found before any work

| # | asked | what this session has | consequence |
|---|---|---|---|
| B1 | Higgsfield generates every environment and human moment (nano_banana_pro stills, seedance_2_0 motion) | The Higgsfield connector is read-only: `balance`, `models_list`, `models_get`, `show_generations`, `list_workspaces`, `workspace_select`, `import-claude-motion-from-url`. Its own instructions say it "cannot generate media". | **0 credits spent** (balance 110 before and after). All six plates use coded fallbacks (three.js), logged per shot below. The full job sheet is in `higgsfield/JOBS.md`. |
| B2 | Keep Will take 1 | Not in any branch of `abieazizo/scrollanytime` or `abieazizo/scrollanytime-ios`, and not in Drive. The earlier film pass lived in a container that is gone. | The master **with voice cannot be made**. The no-voice master is delivered. The mixer and timeline carry the five voice cues and drop the take in when `assets/voice/will_take1/v1..v5.wav` exist. |
| B3 | Keep the clip set incl. Ovadia's face-tracked crop | Only `app/public/hero/ovadia.mp4` (8 s, 720×1280, **no audio track**) exists in the repo. scrollanytime.com and zerem.*.workers.dev are blocked by this environment's network policy, and the simulator recordings in `ui-screens/launch-sim*` are 0-byte files. | Ovadia's crop was redone from the hero clip (face-tracked). The other swipes use real app screenshots of the feed (the real UI playing real clips) as stills with motion. **Ovadia's own voice (0.8 s) cannot be used**: the only copy of his clip is silent. |
| B4 | Keep the treated portraits | Not recoverable (same as B2). | Re-treated from the best real sources in the repo: Ovadia from the 1170×2080 hero poster; Joey Haber, Harari, Moshe Haber and Mizrahi from 780-px feed screenshots; Farhi, Mansour, Zeytouneh and Galimidi from the app's rabbi avatars (≈110–180 px). The avatar-sourced cards are visibly soft at 72% frame width. |
| B5 | Keep the fonts, the music renderer and qa.mjs | Fonts: Frank Ruhl Libre and Inter are the app's own (DESIGN tokens in CLAUDE.md), taken in full weights from npm @fontsource. The music renderer and qa.mjs are gone (B2). | Rebuilt: `src/audio/music.py` and `qa/qa.mjs`. The finishing-pass type spec is also gone; it is rewritten in `spec/TYPE.md` from the app's design tokens. |
| B6 | push to the private repo | Write access to `abieazizo/scrollanytime` was refused for this session (read-only attach). `scrollanytime-ios` is public. | Pipeline code goes to the designated branch of `scrollanytime-ios` under `film/`. Rabbi media, clips, renders and fonts are gitignored and stay out of the public repo. |

## Credit spend

| when | action | credits |
|---|---|---|
| start | `balance` | 110 |
| — | no generation possible (B1) | 0 |
| end | `balance` | 110. **Total spent: 0** |

## Shots: what stands in for each Higgsfield plate

Every shot is a coded fallback, because generation was impossible (B1), not because credits ran low.
Seeds are the PRNG seeds in `plates/scenes.js` (`SEEDS`). The renders are deterministic.

| shot | brief's fallback | used | seed | notes |
|---|---|---|---|---|
| H1 | three.js phone close-up | three.js phone, tilted, on a dark duvet, warm rims, shallow focus | 1101 | no thumb. The flick is carried by the screen's scroll and a small jolt. Pass 1's jolt measured 2.1 px/frame² of corner acceleration (QA limit 1.5), so the fallback's flick was softened to 0.61. |
| H2 | none specified | three.js dark bedroom: phone glowing on the duvet, window with a distant streetlight, slow push | 1202 | no person, so no over-the-shoulder. **Regenerated once**: the first render's push carried the phone off the bottom of the frame, and the keyer logged 16 consecutive lost-corner frames (spec: >6 means regenerate). It was re-framed and re-rendered with 0 failures. |
| H3 | three.js phone | three.js phone to camera, titanium edges with warm rims, bokeh practicals, 6% push | 1303 | — |
| H4 | none specified | three.js beit midrash: ~14k instanced sefarim with gilded bands (no lettering), high windows, light shafts, haze, 4,200 gold dust motes, slow push | 1404 | rendered 5 s: 0–4 s behind the portraits, 2–5 s behind the words |
| H5 | none specified | three.js morning kitchen: phone propped on a navy velvet tallit bag, coffee with steam, sun through the window | 1505 | no hands |
| H6 | three.js phone on a dark surface | three.js nightstand at 45°, phone face up, unlit lamp, faint streetlight through blinds | 1606 | streetlight halved after review ("faint flicker") |

Keyer against ground truth (the fallbacks report their true screen corners): mean corner error
0.8–1.6 px per shot, max 2.3 px, 0 failed frames after the H2 regenerate.

## QA and review passes

**qa.mjs, pass 1:** 17/20.
- **Green near a screen.** The ring was measuring the screen's own edge pixels. The check now excludes the composited screen.
- **Corner acceleration 2.1 px/frame².** It came from the H1 fallback's own flick jolt, which was 7.6 px/frame² in the ground truth. The jolt was softened, and acceleration is now 0.61.
- **Seven fly-past portraits.** Not fixable from this repo; see B4.

**Pass 2:** 19/20, with only the portrait count failing.

The three review passes and the stranger test then ran as four independent reviewers with fresh context, on the pass-2 frames.

**Engineer.** No blockers.
- Fixed:
  - plates had no anti-aliasing (the composer target lacked MSAA; now 4× MSAA)
  - the title animated downward (now rises 40 px)
  - Ovadia's clip had an internal cut and 24→30 fps judder (now one clean take, frame-blended)
  - the cover frame at 8.0 was mid-transition (cards now land on their arrive times, so 8.0 is clean)
  - the Farhi letterbox had hard edges (now feathered)
  - the scrim had hard edges (replaced by a screen-space gradient)
  - "Every day." sat on the phone's tab bar (now above the phone)
  - flat-sided face circles (the photo now fills the mask)
  - H6 horizon touched the badge (camera re-aimed, edge defocused, badge lowered)
- Not taken: shrinking the names to ≤800 px. The brief fixes them at 92 px, so the honorific moved under the name instead.

**Designer.** Fixed:
- gold re-tinted to #C9A24B / #E3C87A, with a thinner moulding
- bloom no longer touches type, which stays cream
- the flare peaks pure white at 6.75, then a hard cut at 7.0
- the end card builds from 17.15, and its type fades out before the loop crossfade, so nothing double-exposes
- the H5 phone is centred and large and the window no longer clips
- the H6 phone is centred and its icon is about 320 px
- bokeh now drifts
- captions moved to 52 px

Not taken: H2's over-the-shoulder framing. It needs a person, which a coded fallback can't honestly fake.

**Community (frum) reviewer.** Fixed:
- dropped the "Reform Synagogue Joke" clip, the "Because it's Elul" frame, and the clip with a third-party watermark
- the flare now whitens a wide shot, not a rav's face
- cards never slide over another rav's portrait (carousel move)
- hero portraits re-chosen: composed, eyes open, no mid-word or grimace
- fly-past faces are sharp, still, wholly in frame, and kept clear of the title; Rabbi Mizrahi was dropped (hand over face, watermark)
- the phone has its own stand, apart from the tallit bag
- zt"l is cream, display weight, on its own line
- the streak note now reads "Seven-day streak. Shabbos never breaks it." That is true of the app: its streak forgives one missed day a week, per CLAUDE.md.

**Stranger test.** Passed on product, name, price and where to get it. Fixed: the title was half-hidden (now clean, faster rise), captions were small (44→52 px), and the streak meaning was unclear (the note now says it). Not changed: the wordless first 1.4 s, which is the brief's design; Will's first line lands at 1.4.

**Your call:** the brief says '"Day seven" rolling up'. The reviewer noted that seven days in a row reads as "on Shabbos too?". I kept "Day seven" and added the Shabbos note. "Six days a week" is the alternative.

**Verification (pass 3 → pass 4).** A fresh reviewer re-checked all 14 findings: 9 fixed, 5 partly fixed, and 2 new majors.

The two new majors, both fixed in pass 4:
- Ovadia's hero card was blown out: 14% of the card clipped. An exposure cap plus a highlight shoulder brought that to 0%.
- A green patch showed inside the screen at 6.57 s. It came from the source clip's own green top under the app header, not from the keyer. It is now neutralised.

Also fixed in pass 4:
- the "Rosh Hashanah"-tagged clip swapped out
- the lower-third gradient made darker and higher, so burned-in names stop doubling
- fly-past discs re-spaced so none overlaps another
- word glow drawn under the word, so the type measures cream (242/237/224)
- long captions wrap to two lines
- the streak note made larger
- a second green clamp after bloom (the bloom was halo-ing green screens into the 40 px ring)
- the 6 s cut now ends on the full end card

Left as is:
- Joey Haber and Farhi are caught mid-speech in their hero cards. These are the only sharp sources; the composed alternatives are 60–75 px thumbnails.
- A tiny specular sparkle where the phone model's bottom corner meets its edge.

## Final QA

| file | result |
|---|---|
| 9:16 master | 19/20. The fly-past carries 5 portraits, not 7 (B4). |
| 9:16 12 s and 6 s | 11/11 each |
| 1:1 master | 13/13 |
| 1:1 12 s and 6 s | 11/11 each |
| 16:9 master | 13/13 |
| 16:9 12 s and 6 s | 11/11 each |

On the 9:16 master:
- **Loudness:** −14.0 LUFS integrated, −1.0 dBTP.
- **The peak:** 6.8–7.0 is digital silence; the 7.0 hit is the loudest moment so far.
- **Picture:** no black or frozen stretches, and the last frame is within 0.6/255 of the first, so it loops.
- **Keying and plates:**
  - no green within 40 px of any screen, checked on every keyed frame
  - corner acceleration max 0.61 px/frame²
  - no faces in any plate
  - no duplicate portraits

The JSON reports are in `out/qa/`.

## Deliverables (`out/`)

- `ScrollAnytime_final_{9x16,1x1,16x9}_{master,12s,6s}_novoice.mp4`: H.264 High, BT.709, 30 fps, AAC 320k 48 kHz, −14 LUFS / −1 dBTP. The 1:1 and 16:9 versions are re-rendered natively, not cropped: the plates were re-rendered at each aspect, and type and cards were re-laid out.
- **No "with voice" files.** Will take 1 is not available (B2). `mix.py --voice` plus `deliver.py` produce them once the take is in `assets/voice/will_take1/`.
- `ScrollAnytime_final_cover_t8.0.{png,jpg}`: the frame at 8.0, Rabbi Joey Haber's card.
- `ScrollAnytime_final_contact_2fps.jpg`, plus the earlier `contact_stills_pass1.jpg` and `contact_pass1_2fps.jpg`, the two sheets already sent.
- `stills_and_plates/`: the six chosen stills and plates (coded fallbacks), and `seeds.json`.
- `credit_spend.json`: 0 credits.
- `qa/`: QA reports for all nine files.

**Final stranger test** (on the final master, sound off, no context). Passed on the product, the name, the price ("Free.") and where to get it (the App Store, "Link in bio"). Remembered: "Free. / No ads. / Only Torah."

Left by design:
- the captions follow the voice timing; they are short and too small to read on a contact-sheet thumbnail
- the 0.12 s flash at 7.0
- the fly-past faces carry no names (the brief says faces only)
- the last frames clear the type so the reel loops into its first frame (the 6 s cut ends on the full card)
- "zt"l" and "rabbanim" are for the audience, not for outsiders
