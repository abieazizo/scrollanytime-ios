# Higgsfield job sheet — Scroll Anytime, the film

The Higgsfield connector attached to the Claude session that built this pipeline is **read-only**
(balance, model catalog, generation history, import of a Claude Motion MP4). It has no generate
call, so none of these jobs could be run from that session, and **0 credits were spent**. Run them in
Higgsfield's own app. A later Claude session can find the results with `show_generations` and download
them into `film/assets/plates/` (see the last section).

Priority if credits run low: **H3, H4, H6, H5, H2, H1**. Stop spending at 10 credits. Every shot
not generated stays on its coded fallback, and the production log records it.

## Settings for every shot

| stage | model | settings |
|---|---|---|
| still | `nano_banana_pro` | aspect 9:16, resolution 2k, 4 variants |
| motion draft | `seedance_2_0` | aspect 9:16, start_image only, duration 5, generate_audio false, genre drama, mode fast, resolution 720p, 2 drafts |
| motion final | `seedance_2_0` | the chosen draft re-run (same start_image, same seed) at mode std, resolution 1080p, bitrate_mode high |

For each shot, iterate on the still until it passes every rejection rule below. Spend nothing on
motion until it does. Then save the result's seed (the pipeline keeps a seeds ledger).

## Rejection rules (reject and regenerate, never repair)

- any face
- any readable text or logo
- any wrong finger count or warped hand
- any phone screen that is not uniform flat #00FF00 (no reflection, no UI, no text)
- any screen corner that is occluded or out of frame (all four visible, never covered by a finger)
- any melting geometry

`python3 film/src/check_plate.py <still-or-mp4>` checks the machine-checkable rules: green uniformity,
four corners, a quad that is stable over time, and faces (OpenCV YuNet). Hands, text and geometry
still need a human look.

## The shots

### H1 — 0.0 to 1.4 (fallback: three.js phone close-up)
Still: Macro shot in a pitch-dark bedroom at night, a young man's thumb resting on the screen of an iPhone held in his hand, the screen solid flat bright green with no content, its glow lighting his fingertip and knuckles, shallow depth of field, 85mm macro, photoreal, cinematic, true blacks, no face.
Motion: The thumb flicks upward twice as if scrolling, the hand otherwise still, the screen stays solid green, nothing else moves.

> Note: this prompt puts the thumb ON the screen, which collides with the "corner never covered"
> rule only if the thumb reaches a corner. Reject any variant whose thumb crosses a corner.

### H2 — 1.4 to 3.0 (no fallback specified; coded stand-in used)
Still: Over-the-shoulder shot from behind a young man lying in bed in a dark Brooklyn bedroom at night, a black velvet kippah on the back of his head, white t-shirt, holding an iPhone above him, the screen solid flat bright green and the only light, glowing on the pillow and his hand, a window with a distant streetlight, no face visible, photoreal, cinematic, 35mm, muted warm grade.
Motion: Very slow push in toward the phone, his thumb scrolls once, nothing else moves, the screen stays solid green.

### H3 — 3.0 to 6.8 (fallback: three.js phone)
Still: Close-up of a hand holding an iPhone toward the camera in a dark room, the screen facing the lens and filling most of the frame, solid flat bright green with no content, titanium edges catching a warm rim light, fingers only on the sides, photoreal, cinematic, 50mm, shallow depth of field, true blacks.
Motion: The hand holds the phone steady with tiny natural movement, very slow push in, the screen stays solid green.

### H4 — 7.0 to 11.0 and behind 14.0 to 17.0 (no fallback specified; coded stand-in used)
Still: A vast old beit midrash at night, tall wooden shelves of worn sefarim with gilded spines, warm shafts of light falling from high windows through haze, gold dust in the air, empty, no people, no readable text, cinematic, 35mm, warm grade.
Motion: Very slow push forward down the aisle, dust drifting in the light shafts, nothing else moves.

### H5 — 11.0 to 14.0 (no fallback specified; coded stand-in used)
Still: Morning in a Brooklyn kitchen, soft sunlight through a window, a young man's hands holding an iPhone above a wooden table beside a cup of coffee and a folded tallit bag, the screen solid flat bright green with no content facing the camera at a slight angle, no face visible, photoreal, cinematic, 50mm, warm natural grade.
Motion: Steam rises from the coffee, the hands hold the phone steady with tiny natural movement, the screen stays solid green.

### H6 — 17.0 to 20.0 (fallback: three.js phone on a dark surface)
Still: A dark bedroom at night, an iPhone lying face up on a wooden nightstand beside an unlit lamp, the screen solid flat bright green with no content, its glow the only light on the wood, shot from 45 degrees above, photoreal, cinematic, 50mm, true blacks.
Motion: Static camera, nothing moves except a faint flicker of streetlight on the wall.

## Bringing generated plates in

Drop each final 1080p MP4 into `film/assets/plates/H<n>.mp4` (and its chosen still into
`film/assets/plates/H<n>.png`), add the seed to `film/higgsfield/seeds.json`, then run
`python3 film/src/build.py`. The build prefers a generated plate over the fallback wherever both
exist, keys it with the spec keyer, and re-runs QA.
