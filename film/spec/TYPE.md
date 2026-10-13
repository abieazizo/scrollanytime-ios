# Finishing-pass type spec (rewritten 2026-10-12)

The original finishing-pass spec did not survive with the earlier container. This rewrite takes the
app's own design tokens (CLAUDE.md: bg #0B0B0F, surface #14141B, text #F5F2EA, gold #C9A24B, glow
#E3C87A; Frank Ruhl Libre display, Inter UI) and the sizes the film brief fixes. Master frame
1080×1920. Reels safe area: nothing important above y=220 or below y=1560, or right of x=940.

| element | face | size | colour | placement | motion |
|---|---|---|---|---|---|
| clock "11:47 PM" (H1) | Frank Ruhl Libre 700 | 56 px | white, 70% | top-left, x=72, baseline y=290 | fades in over 0.2 s |
| rabbi name (H3 + portraits) | Frank Ruhl Libre 700 | 92 px | cream #F5F2EA | centred; H3 baseline y=1300 (on the robe, under the face; a 60% scrim keeps it clear of the clip), portraits beneath the card | in 0.12 s after the swipe settles, out with the next swipe |
| honorific zt”l | Frank Ruhl Libre 700 | 54 px | cream #F5F2EA | its own line, centred under the name (+70 px) | with the name |
| gold rule | — | 3 × 160 px | gold #C9A24B, glow #E3C87A | 30 px above the name's cap height, i.e. above the caption band | draws out from the centre in 0.2 s |
| caption band | Inter 600 | 52 px | cream | centred, baseline y=1540 (H5: y=330, above the phone); soft gradient band behind | 0.15 s fades |
| title "Scroll Anytime" | Frank Ruhl Libre 700 | 120 px | cream with a gold glow | portraits: centre, baseline y=1000 (faces kept clear of it); end card: y=420 | rises 40 px from below; 0.28 s (portraits), 0.35 s (end card) |
| words "Free." "No ads." "Only Torah." | Frank Ruhl Libre 700 | 150 px | cream; gold rule 4 px under, half the word's width | centre, baseline y=1010 | hit: lands at 50% on the beat frame, full in 0.03 s, scale 1.10→1.00 over 0.18 s; out 0.10 s |
| App Store badge | Apple's official artwork (developer.apple.com) | 340 px wide | as supplied | centre, y=640 | fades in 0.3 s at 17.35 |
| "Link in bio" | Inter 500 | 48 px | cream 80% | centre, baseline y=790 | fades in 0.3 s at 17.5 |

Captions carry the five voice lines so the reel reads with the sound off. Line 5 is not captioned
because the three words say it.

**Bloom:** luminance above 0.72, Gaussian σ 28 px at quarter resolution, strength 0.35. At the flare
(6.6–6.8) the strength ramps to fill the frame. **Grain:** luma, σ 0.8 px, 1.0% after the blur, new every frame (matched to the look of a clean 1080p plate; heavier grain doubles the bitrate).
**Vignette:** 16% at the corners. **Grade:** each plate is matched to H4's black level and warmth
(1st-percentile luminance, mean R−B of the midtones) before the screen is keyed. The content stays
true to the app.

**Order of operations:** image (plates, keyed screens, cards, faces) → bloom → type → flash → vignette
→ grain. Bloom never touches type, so large type stays cream (#F5F2EA) with only its own tight gold
glow. **Flare:** the screen whitens from 6.6 and peaks pure white at 6.75; 6.8–7.0 is white and
silent; 7.0 is a hard cut to the first card, with a 0.12 s flash from 50%. **End card:** title
17.15, badge 17.35, "Link in bio" 17.5. The type fades out from 19.2 to 19.45, then the background
crossfades into the first frame from 19.45 to 20.0, so nothing double-exposes. **Names over the
H3 screen:** the screen carries its own lower-third gradient (black 0→86% over the bottom half of
the screen) from 3.0 to 5.6, so the app's own labels and burned-in captions never double the name.
