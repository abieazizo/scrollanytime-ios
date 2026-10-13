# Scroll Anytime — the film

A 20-second, 9:16 ad cut on the music. Six environment plates (H1–H6), meant to be generated in
Higgsfield. Claude keys the real app onto every phone screen, builds the rabbanim section from real
portraits, and does the type, sound, grade and QA. This pass had no way to generate in Higgsfield
(see `PRODUCTION_LOG.md`), so every plate is a coded three.js fallback.

```
spec/timeline.json     every time in the film: shots, swipes, cards, words, voice cues, cuts
spec/TYPE.md           the finishing-pass type, bloom, grain and grade spec
higgsfield/JOBS.md     the exact Higgsfield jobs (stills, then motion) and the rejection rules
plates/                coded fallback plates: three.js scenes rendered headless (scenes.js, render.mjs)
src/key/keyer.py       the screen keyer: HSV, quad, sub-pixel sides, Savitzky-Golay 9, warp, despill,
                       glass 4%, spill 15% @ 60 px, grain + motion-blur match, hold-and-log
src/content/           what each phone shows: the abstract scroll, the clip montage (Ovadia's
                       face-tracked crop + real feed frames), the Today card (HTML), the icon seal
src/portraits/         treat.py (real app frames → EDSR upscale → treated portraits), section.py
                       (gold cards, fly-past, title)
src/audio/             synth.py, music.py (the score), sfx.py, mix.py (-14 LUFS, -1 dBTP)
src/build.py           frame assembly (FILM_ASPECT=9x16 | 1x1 | 16x9)
src/deliver.py         encodes: master, 12 s and 6 s cuts, aspect versions
qa/qa.mjs              file QA (format, loudness, silence, hit, black, freeze, loop) + qa_extra.py
                       (green near screens, corner acceleration, faces in plates, duplicate portraits)
```

## Run it

```
npm i                                         # three, playwright-core, fonts
pip install opencv-contrib-python-headless scipy pyloudnorm soundfile fonttools brotli
node plates/render.mjs H1 H2 H3 H4 H5 H6      # fallback plates (skip any shot you have generated)
python3 src/portraits/treat.py                # treated portraits (needs the app screenshots in assets/src)
node src/content/render_today.mjs             # the Today card frames
(cd src/audio && python3 music.py && python3 sfx.py && python3 mix.py --voice)
python3 src/build.py                          # 600 frames -> work/frames
python3 src/deliver.py master <tag> && python3 src/deliver.py cuts <tag>
node qa/qa.mjs out/ScrollAnytime_<tag>_master_novoice.mp4
```

Generated plates replace fallbacks automatically: put `assets/plates/H<n>.mp4` (1080×1920) in place
and rebuild. Will take 1 replaces the silence under the captions the same way: put
`assets/voice/will_take1/v1.wav … v5.wav` in place (cue times in `spec/timeline.json`) and run
`mix.py --voice`. `assets/`, `work/` and `out/` are gitignored. They hold rabbi media and renders,
which do not belong in this public repository.
