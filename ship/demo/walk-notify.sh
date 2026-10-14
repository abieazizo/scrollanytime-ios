# THE NOTIFY WALK (2026-10-14) — sourced by drive.sh when the marker ship/demo/walk-notify exists.
#
# The owner's question, the day of the release: "if somebody downloads the app right now, will the
# notification thing come up? Does it pop up on somebody's screen? He presses Allow — does it work?"
# This answers it in the REAL shell binary on real iOS (the Simulator), against the LIVE site:
#
#   1. a fresh guest from the live server (POST /auth/guest — what the app mints on a first open),
#      on No limit, so a day counts at one minute; started past the welcome card by -saSeed (the
#      Simulator cannot sign in: no credential ever rides on a public runner)
#   2. the feed plays a real minute; a swipe ends the clip that makes the day count
#   3. the reminder card must come up ("Day one." / "Remind me at …"), found by its WORDS (OCR)
#   4. its gold pill is tapped like a person; the iOS system prompt must appear; "Allow" is tapped
#   5. the card must answer "Reminder set for …"; the shell's own log says what it sent the page
#   6. Profile → Reminders → "Send a test": a LOCAL notification five seconds out, the app sent to
#      the Home Screen, the banner must be on screen
#   7. a push in our APNs payload's shape (simctl push) on the Home Screen; tapping it must open
#      the app on the notification's page
#   8. the guest is deleted (DELETE /me), whatever happened
#
# Every step: a screenshot under shots/, its words under ocr/ and ax/ocr-*.json; the verdicts in
# crash/notify.txt (the workflow uploads crash/* and ax/*.json). Run it with mode=calibrate: the two
# moments that matter are filmed as short segments under crash/ (walk-signin.sh seg_start/seg_stop) -
# mode=record films the whole run, gigabytes nobody can take home.
#
# Uses drive.sh's helpers and walk-signin.sh's (tap_text, ocr, shot, swipe, W, H, UDID, OUT).

NOTE="$OUT/crash/notify.txt"
mkdir -p "$OUT/crash"
say_n() { echo "$*" | tee -a "$NOTE"; }
verdict() { # verdict PASS|FAIL "what"
  say_n "[$1] $2"
}
sees() { # sees <shot> <regex> : the shot's words match
  grep -qiE "$2" "$OUT/ocr/$1.txt" 2>/dev/null
}
look() { # look <name> : a screenshot and its words
  shot "$1"; ocr "$1"
  say_n "    $1: $(tr '\n' ' ' < "$OUT/ocr/$1.txt" 2>/dev/null | tr -s ' ' | cut -c1-200)"
}

NOTIFY_TOKEN=""
notify_cleanup() {
  [ -n "$NOTIFY_TOKEN" ] || return 0
  local s
  s=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X DELETE https://scrollanytime.com/me \
        -H "authorization: Bearer $NOTIFY_TOKEN" -H 'user-agent: Playwright notify walk (Simulator)')
  say_n "    the walk's guest deleted: DELETE /me → $s"
  NOTIFY_TOKEN=""
}

notify_walk() {
  say_n "── THE NOTIFY WALK: the reminder ask in the real shell, against the live site ──"
  say_n "    $(date -u +%FT%TZ) · $(xcrun simctl list devices | grep -i booted | head -1 | tr -s ' ')"

  # 1. the guest
  local g user seed
  g=$(curl -s --max-time 30 -X POST https://scrollanytime.com/auth/guest \
        -H 'content-type: application/json' -H 'user-agent: Playwright notify walk (Simulator)' -d '{}')
  NOTIFY_TOKEN=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['token'])" "$g" 2>/dev/null || true)
  if [ -z "$NOTIFY_TOKEN" ]; then verdict FAIL "no guest from POST /auth/guest: $(echo "$g" | cut -c1-120)"; return 1; fi
  echo "::add-mask::$NOTIFY_TOKEN"
  trap notify_cleanup EXIT
  user=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1])['user']))" "$g")
  curl -s -o /dev/null --max-time 30 -X PATCH https://scrollanytime.com/me \
    -H "authorization: Bearer $NOTIFY_TOKEN" -H 'content-type: application/json' -H 'user-agent: Playwright notify walk (Simulator)' \
    -d '{"tz":"America/New_York","daily_goal_minutes":null}'
  say_n "    a fresh guest on the live server, No limit (a day counts at one minute)"
  seed=$(python3 - "$NOTIFY_TOKEN" "$user" <<'PY'
import base64, json, sys
tok, user = sys.argv[1], sys.argv[2]
s = {'zerem.token': tok, 'zerem.user': user, 'zerem.captions': '0'}
# what every automated walk sets (scripts/_verify_remind.mjs): past the welcome card and the one-time
# cards; muted (the Simulator's audio is nobody's)
for k in ['zerem.suite', 'zerem.onboarded', 'zerem.launch.seen', 'zerem.intro.done', 'zerem.landing.seen',
          'zerem.card.rabbis', 'zerem.ask.account', 'zerem.soundprompt', 'zerem.muted', 'zerem.dlcard.seen',
          'zerem.coach.swipe', 'zerem.coach.doubletap', 'zerem.coach.speed']:
    s[k] = '1'
print(base64.b64encode(json.dumps(s).encode()).decode())
PY
)

  # 2. the real shell, as that guest, on the live site
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl launch "$UDID" "$BUNDLE" -saSeed "$seed" >/dev/null 2>&1 || true
  sleep 22
  look "notify-01-feed"
  # a real minute of the feed: let it play, then keep it playing past 60 s
  sleep 40
  look "notify-02-feed-40s"
  sleep 28
  look "notify-03-feed-68s"
  # the clip end: a swipe up to the next clip, as a person moves on. A swipe the Simulator drops (run
  # 38581512053: an overloaded runner, the same clip on screen five minutes later) is no clip end, so
  # each attempt is a swipe and a short look for the card; no card, the next attempt swipes again —
  # every clip end after the first minute is one where the card must come up.
  seg_start "notify-ask"
  local i a up=""
  for a in 1 2 3 4; do
    swipe "$MID_X" $((H * 3 / 4)) "$MID_X" $((H / 5)) 0.35 0.6
    for i in 1 2 3 4 5; do
      shot "notify-04-card"; ocr "notify-04-card"
      if sees notify-04-card "remind me at"; then up=1; break; fi
      sleep 1
    done
    [ -n "$up" ] && { say_n "    the card came up after swipe $a"; break; }
    say_n "    swipe $a: no card yet — $(tr '\n' ' ' < "$OUT/ocr/notify-04-card.txt" 2>/dev/null | tr -s ' ' | cut -c1-120)"
    sleep 4
  done
  say_n "    notify-04-card: $(tr '\n' ' ' < "$OUT/ocr/notify-04-card.txt" 2>/dev/null | tr -s ' ' | cut -c1-200)"
  [ -z "$up" ] && verdict FAIL "the reminder card did not come up at any of four clip ends after the first minute"
  if [ -z "$up" ]; then
    look "notify-04c-no-card"
    seg_stop "notify-ask"
    notify_log
    return 1
  fi
  sees notify-04-card "day one" && verdict PASS "the card came up at the clip end that made the day count, and reads \"Day one.\"" \
    || verdict PASS "the card came up (headline not read as \"Day one.\" by OCR)"
  sees notify-04-card "not now" && verdict PASS "it offers \"Not now\" beside the gold pill"

  # 4. the gold pill → the system prompt → Allow
  sleep 1.5
  tap_text "remind me at" || { verdict FAIL "could not tap Remind me"; seg_stop "notify-ask"; notify_log; return 1; }
  local prompt=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    shot "notify-05-system-prompt"; ocr "notify-05-system-prompt"
    if sees notify-05-system-prompt "would like to send you notifications|send you notifications"; then prompt=1; break; fi
  done
  say_n "    notify-05-system-prompt: $(tr '\n' ' ' < "$OUT/ocr/notify-05-system-prompt.txt" 2>/dev/null | tr -s ' ' | cut -c1-200)"
  if [ -n "$prompt" ]; then
    verdict PASS "the iOS system prompt is on screen: \"Scroll Anytime\" Would Like to Send You Notifications"
  else
    verdict FAIL "no iOS system prompt within 10 s of the tap"
    seg_stop "notify-ask"
    notify_log
    return 1
  fi
  sleep 1
  # the prompt is native: the accessibility tree names its buttons; the words on screen are the fallback
  if tap_named "Allow" || tap_text "allow" --exact; then
    say_n "    tapped Allow"
  else
    verdict FAIL "could not tap Allow"
    seg_stop "notify-ask"
    notify_log
    return 1
  fi

  # 5. the answer, on the card
  local set=""
  for i in 1 2 3 4 5 6 7 8; do
    sleep 1
    shot "notify-06-after-allow"; ocr "notify-06-after-allow"
    if sees notify-06-after-allow "reminder set for"; then set=1; break; fi
  done
  say_n "    notify-06-after-allow: $(tr '\n' ' ' < "$OUT/ocr/notify-06-after-allow.txt" 2>/dev/null | tr -s ' ' | cut -c1-200)"
  [ -n "$set" ] && verdict PASS "after Allow the card says \"Reminder set for …\"" \
    || verdict FAIL "after Allow the card never said \"Reminder set for …\""
  sleep 4
  look "notify-07-settled"
  seg_stop "notify-ask"
  notify_log
  # the round trip: did a device token reach the live server for this guest? (the Simulator only
  # gets one where the build's signature carries aps-environment — say what happened either way)
  local hp
  hp=$(curl -s --max-time 30 https://scrollanytime.com/me -H "authorization: Bearer $NOTIFY_TOKEN" -H 'user-agent: Playwright notify walk (Simulator)' \
        | python3 -c "import json,sys; d=json.load(sys.stdin); m=d.get('user', d); print(m.get('has_push'))" 2>/dev/null || echo "?")
  say_n "    the live server's /me for this guest after Allow: has_push=$hp"

  # 6. a real local notification: Profile → Reminders → Send a test, then the Home Screen
  tap "$PROFILE_X" "$NAVY" 3
  look "notify-08-profile"
  # the row's words are "Send a test"; its button is the pill "Send" on the right (run 38576067448
  # tapped the label, and nothing was sent). Find the row with the page at rest, then the pill.
  local found=""
  # (run 38588988681 reached REMINDERS after eight quarter-screen swipes and stopped one screen short:
  # the row sits below Shabbat & Yom Tov — swipe most of a screen at a time, and keep going)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 1.5
    shot "notify-08b-find"; ocr "notify-08b-find"
    if sees notify-08b-find "send a test"; then found=1; break; fi
    swipe "$MID_X" $((H * 4 / 5)) "$MID_X" $((H / 5)) 0.3 1.5
  done
  # the recorder takes ~3 s to start, and the test fires five seconds after the tap — with nothing
  # shown while the app is in front (AppDelegate willPresent → []). Run 38591947765 started the
  # recorder AFTER the tap and pressed Home ~9 s later: the notification had already come and gone
  # unseen. So: film first, then tap Send and leave for the Home Screen at once.
  [ -n "$found" ] && seg_start "notify-banners"
  if [ -n "$found" ] && tap_text "send" --exact; then
    idb ui button --udid "$UDID" HOME || true
    local banner=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      shot "notify-09-local-banner"; ocr "notify-09-local-banner"
      if sees notify-09-local-banner "what a reminder looks like"; then banner=1; break; fi
    done
    say_n "    notify-09-local-banner: $(tr '\n' ' ' < "$OUT/ocr/notify-09-local-banner.txt" 2>/dev/null | tr -s ' ' | cut -c1-200)"
    if [ -n "$banner" ]; then
      verdict PASS "a LOCAL notification from the app is on the Home Screen: \"This is what a reminder looks like\""
    else
      verdict FAIL "no local banner within 10 s of Send (see notify-09-local-banner)"
    fi
    xcrun simctl spawn "$UDID" log show --last 1m --style compact --predicate 'eventMessage CONTAINS "asked: test"' 2>/dev/null       | grep -q "asked: test" && say_n "    the shell's log: the page asked for the test notification"       || say_n "    the shell's log: NO test request from the page"
  else
    verdict FAIL "Profile shows no Send a test row with its Send pill (see notify-08b-find)"
    [ -z "$found" ] && seg_start "notify-banners"
    idb ui button --udid "$UDID" HOME || true
  fi
  sleep 6

  # 7. a push in our APNs payload's shape, on the Home Screen, tapped
  local payload="$OUT/.push.json"
  printf '%s' '{"Simulator Target Bundle":"com.scrollanytime.app","aps":{"alert":{"title":"Today’s seder is waiting.","body":"3 clips, about 7 minutes. Day 2 if you learn today."},"sound":"default","thread-id":"scroll-anytime"},"url":"/seder"}' > "$payload"
  xcrun simctl push "$UDID" "$BUNDLE" "$payload" >/dev/null 2>&1 || true
  sleep 3
  look "notify-10-push-banner"
  if sees notify-10-push-banner "seder is waiting"; then
    verdict PASS "a push in our APNs shape is on the Home Screen"
    tap_text "seder is waiting" || true
    sleep 6
    look "notify-11-opened-from-push"
    sees notify-11-opened-from-push "seder" && verdict PASS "tapping it opened the app on today's seder" \
      || verdict FAIL "tapping the push did not land on the seder (see notify-11-opened-from-push)"
  else
    verdict FAIL "no banner for the simulated push (see notify-10-push-banner)"
  fi
  seg_stop "notify-banners"
  notify_log
  notify_cleanup
  python3 -c "import json,sys; print(json.dumps({'lines': open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()}))" "$NOTE" > "$OUT/ax/notify.json" 2>/dev/null || true
  say_n "── end of the notify walk: $(grep -c '^\[PASS\]' "$NOTE") PASS, $(grep -c '^\[FAIL\]' "$NOTE") FAIL ──"
}

# what the shell itself sent and heard, from the unified log
notify_log() {
  xcrun simctl spawn "$UDID" log show --last 6m --style compact --predicate 'eventMessage CONTAINS "SA-SELFTEST"' 2>/dev/null \
    | grep "SA-SELFTEST" | grep -v "snap" | sed 's/^\([0-9:. -]*\).*SA-SELFTEST/    \1 shell:/' | tail -30 | tee -a "$NOTE"
}
