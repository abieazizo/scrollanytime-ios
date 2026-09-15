# PART 6 STEP 1 — wrap the web app as the iOS app

**This runs on the Mac. Nothing in this file can be done on Windows.**

Before you start, `./ship/preflight.sh` must print **READY**, and all four parts of
`SETUP-APPLE.md` must be finished. If either is not true, stop and do that first — every problem
this file can cause is ten times harder to read once it appears as a rejection email.

---

## What we are building, in one paragraph

Scroll Anytime is already a complete, live web app at `https://scrollanytime.com`. The iOS app is a
thin native shell — a full-screen `WKWebView` that loads that site with `?app=ios` on the end. The
`?app=ios` flag is not cosmetic: `app/src/lib/platform.ts` reads it and switches the whole app into
app mode (no Sponsor tab, no push prompt, no external links, the one-time intro card). The shell
contributes four things and nothing else: the icon, the launch screen, correct media/autoplay
settings, and an offline page for the very first launch.

**The shell must never contain product logic.** If something needs to change about how the app
behaves, it changes in `app/`, gets deployed to the Worker, and the shell picks it up on next
launch. That is the entire point of this architecture.

---

## STEP 1.1 — Generate the package with PWABuilder

1. On the Mac, open **https://www.pwabuilder.com** in Safari or Chrome.
2. Type `https://scrollanytime.com` into the box and press Return.
3. Wait for the report card. The manifest and service-worker scores should be green.
   - If it reports a problem with the **manifest**, stop and tell the developer. Do not "fix" it on
     PWABuilder's site — the real manifest lives at `app/public/manifest.webmanifest` in this repo
     and must stay the single source of truth.
4. Click **Package For Stores**, then choose **iOS**.
5. Fill the iOS options with the values from the table in STEP 1.3 below. Take them from the table,
   not from PWABuilder's defaults — several defaults are wrong for this app (see the warning under
   the table).
6. Click **Download Package**. You get a `.zip`.

## STEP 1.2 — Put it in the repo

Unzip the package so that the Xcode project ends up **inside `ship/ios/`**, next to this README and
next to `offline.html`.

```bash
cd /path/to/zerem
unzip ~/Downloads/ScrollAnytime-iOS.zip -d ship/ios/
ls ship/ios
```

You should now see PWABuilder's own `README` / `next-steps.html`, a `src/` folder, and an
`.xcodeproj` or `.xcworkspace` somewhere inside. Open the project in Xcode:

```bash
open ship/ios/**/*.xcodeproj      # or the .xcworkspace if there is one
```

**Never edit files under `app/` or `worker/` to make the shell work.** If the shell needs something
the web app does not do, that is a conversation, not a patch.

---

## STEP 1.3 — The exact configuration

Every value below is deliberate. Where a value is described as load-bearing, changing it breaks a
feature or causes a rejection.

### The web app it loads

| Setting | Value | Why |
|---|---|---|
| `rootUrl` / start URL | `https://scrollanytime.com/?app=ios` | **Load-bearing.** `?app=ios` switches the web app into app mode. Without it the app shows the Sponsor tab, external links and a push prompt — all three are review problems. |
| `allowedOrigins` / scope | `scrollanytime.com`, `www.scrollanytime.com` | Everything the app itself serves lives on this origin. Anything outside it must not open inside the web view. |
| `authOrigins` (also called permitted navigation origins) | `accounts.google.com`, `appleid.apple.com` | **Load-bearing.** Sign-in redirects leave the site and come back. If these two are not allowed, the web view blocks the redirect and Sign in with Apple / Google simply do nothing. |
| `customUserAgent` | see "The user agent" below | **Load-bearing.** Google refuses sign-in from a default `WKWebView` user agent (`disallowed_useragent`). |

> **PWABuilder's default `rootUrl` is wrong for this app.** It reads the manifest's `start_url`,
> which is `/?app=pwa` (correct for the website, wrong for the shell). You must change the `pwa` to
> `ios` by hand. Check it twice — this is the single easiest thing to get wrong in this whole step,
> and the symptom (a Sponsor tab visible to the reviewer) is a rejection.

### The user agent

Set `customUserAgent` to a current Mobile Safari string. What matters is that it contains `iPhone`,
a `Version/NN.N`, `Mobile/15E148` and `Safari/604.1`, and that it does **not** look like a bare
`WKWebView`:

```
Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1
```

Set the two version numbers (`26_0` and `26.0`) to the iOS major version of the iPhone you test on.
Do not invent a version that is newer than any shipping iPhone. If you want the real string from the
device, connect the iPhone, open Safari on the Mac → **Develop** → your iPhone → the Scroll Anytime
tab → console → type `navigator.userAgent`.

Re-check this string every time the shell is rebuilt. A user agent that is years stale eventually
gets refused by Google as well.

### Appearance

| Setting | Value | Why |
|---|---|---|
| Display mode | `standalone` | Full screen, no browser chrome, no URL bar. |
| Status bar | dark background, **light** text (`UIStatusBarStyleLightContent`), web view extends underneath | The app is safe-area aware and paints its own background under the status bar. |
| Splash / launch screen background | `#0B0B0F` | Identical to the web app's own first paint (`app/index.html` boot splash), so the handoff from native to web is invisible. Any other colour produces a visible flash. |
| Splash logo | the "Scroll Anytime" wordmark, centred, gold `#E3C87A` | Matches the boot splash. |
| Pull-to-refresh | **OFF** | **Load-bearing.** The feed owns every vertical gesture. Leaving this on makes a downward swipe at the top of the feed reload the app instead of scrolling. |
| Orientation | portrait only | There is no landscape layout. |

### Identity and version

| Setting | Value |
|---|---|
| Bundle identifier | `com.scrollanytime.app` |
| Display name | `Scroll Anytime` |
| Version (`CFBundleShortVersionString`) | `1.0.0` |
| Build (`CFBundleVersion`) | `1` |
| Devices | **iPhone only** — `UIDeviceFamily` = `[1]`, build setting `TARGETED_DEVICE_FAMILY = 1` |
| `ITSAppUsesNonExemptEncryption` | `NO` |
| App icon | from `app/public/icons/icon-512.png` (PWABuilder generates the full set). The 1024×1024 marketing icon is `store/appicon-1024.png` and **must have no alpha channel**. |

The bundle identifier must match the App ID you registered in `SETUP-APPLE.md` PART 3 **exactly**.
Not `com.scrollanytime.ios`, not `com.pwabuilder.scrollanytime` — `com.scrollanytime.app`.

The build number is the one value here that legitimately changes: every upload to App Store Connect
needs a build number nobody has used before. The version stays `1.0.0` until there is a real 1.0.1.

### Deployment target — "current iOS minus two"

The rule is: support the current iOS release and the two before it. Apple renumbered iOS from 18
straight to 26 in 2025, so plain subtraction gives a version that does not exist. Use the SDK your
Xcode has:

```bash
xcodebuild -showsdks | grep iphoneos
```

| If the SDK is | Set the deployment target to |
|---|---|
| `iphoneos26.x` | **iOS 17.0** (26 → 18 → 17) |
| `iphoneos27.x` | **iOS 18.0** (27 → 26 → 18) |

Set it in Xcode → target → **General** → **Minimum Deployments** → iOS. PWABuilder's default is
usually different; change it. Too high and you lose users on older phones for no reason; too low and
you are claiming support for iOS versions nobody has tested the web app on.

---

## STEP 1.4 — WKWebView settings (autoplay dies without these)

Find where the shell builds its `WKWebViewConfiguration`. PWABuilder's file names change between
template versions, so find it rather than guessing:

```bash
grep -rn "WKWebViewConfiguration\|allowsInlineMediaPlayback\|customUserAgent" ship/ios --include=*.swift
```

These two are the difference between a working feed and a dead app:

```swift
webConfiguration.allowsInlineMediaPlayback = true
webConfiguration.mediaTypesRequiringUserActionForPlayback = []
```

Without them every clip renders a native play button, nothing autoplays, and the product does not
work at all. A reviewer opening that build sees a broken app.

The rest of the web view configuration:

```swift
webConfiguration.allowsPictureInPictureMediaPlayback = false
webView.scrollView.bounces = false
webView.scrollView.contentInsetAdjustmentBehavior = .never
webView.allowsBackForwardNavigationGestures = false      // edge-swipe must not pop web history
webView.customUserAgent = "…"                            // the string from STEP 1.3
```

And in `Info.plist`, so the service worker (and therefore offline mode) runs at all:

```xml
<key>WKAppBoundDomains</key>
<array><string>scrollanytime.com</string></array>
```

Service workers only run inside `WKWebView` for **app-bound domains**. Miss this key and everything
looks fine until the airplane-mode test, which then fails for a reason that is invisible from the
outside.

---

## STEP 1.5 — Wire up `offline.html`

`ship/ios/offline.html` is in this folder. It is the page the shell shows when the **first**
navigation fails — a reviewer who installs the build, turns on airplane mode and opens it cold.
The web app's own offline screen and its cached clips do not exist yet at that moment, so without
this file WKWebView shows its grey "cannot open page" error or a white screen. That is an automatic
rejection (2.1 crashes and bugs, 4.2 minimum functionality).

1. Drag `offline.html` into the Xcode project. In the dialog, tick **Copy items if needed** and tick
   your app target under **Add to targets**, so it is bundled inside the app.
2. In the navigation-failure handler, load it from the bundle instead of showing an error. The
   delegate methods are `webView(_:didFail:withError:)` and
   `webView(_:didFailProvisionalNavigation:withError:)`:

   ```swift
   if let offline = Bundle.main.url(forResource: "offline", withExtension: "html") {
       webView.loadFileURL(offline, allowingReadAccessTo: offline.deletingLastPathComponent())
   }
   ```
3. Confirm it never fetches anything: the file has no external links of any kind, by design. Do not
   add fonts, images, scripts or analytics to it.

**Test it before you archive** (this is also step 2 of `OWNER-DEVICE-TEST.md`):

1. Install the build on a real iPhone.
2. Delete the app, then reinstall it — you need a truly first launch.
3. Turn on airplane mode.
4. Open the app.
5. You must see the dark page with the gold "Scroll Anytime" wordmark and a Retry button.
   You must **never** see a white screen, a grey error page, or the words "cannot open page".
6. Turn airplane mode off. The page reloads into the app on its own.

---

## STEP 1.6 — The capability whitelist (PART 3.3)

Scroll Anytime asks the phone for **nothing**. This list is not a preference — each item is a
rejection or an upload error if it appears.

### Must NOT be present

| Must not be there | Why |
|---|---|
| `UIBackgroundModes` (any value) | A declared-but-unused background mode is guideline **2.5.4**, one of the most common rejections. See the Listen Mode note below. |
| Push Notifications capability / `aps-environment` | Push is not in v1.0. `store/APP_REVIEW_NOTES.md` states the app never asks for notification permission — an unused push entitlement contradicts a document already filed with Apple. |
| `NSCameraUsageDescription` | No camera code exists. |
| `NSMicrophoneUsageDescription` | No microphone code exists. |
| `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` | The app never touches photos. |
| Any `NSLocation*` key | **There is no location code anywhere in this product.** `store/PRIVACY_NUTRITION.md` answers "not collected" and `store/APP_REVIEW_NOTES.md` says so in writing. Shipping a location key contradicts both. |
| `NSContactsUsageDescription` | The app never reads contacts. |
| App Groups, HealthKit, iCloud, Siri, and every other capability | Nothing in the app uses them. |
| `com.apple.developer.applesignin` | Sign in with Apple happens as a **web redirect** to `appleid.apple.com` inside the web view, not through the native API. Keep Sign in with Apple enabled on the **App ID** in the developer portal (that is what the web flow needs); do not add the entitlement to the Xcode target. |

If Xcode has added any of these on its own — it does, sometimes, when you tick a capability and
untick it again — delete the leftover key from `Info.plist` and the leftover entitlement from the
`.entitlements` file by hand.

### Must be present — exactly one thing

**Associated Domains**, with one entry and no others:

```
applinks:scrollanytime.com
```

Xcode → target → **Signing & Capabilities** → **+ Capability** → **Associated Domains**.

The site already serves the matching file at
`https://scrollanytime.com/.well-known/apple-app-site-association` for the `/c/*` and `/r/*` paths
(worker `src/routes/misc.ts`). **It is inert until the owner sets `apple_app_id` in `/admin` →
Config**, in the form `TEAMID.com.scrollanytime.app`. Until that value is set the file returns an
empty `details` list, which is valid and harmless — shared links simply open the website instead of
the app. Set it after the app is approved and you know the Team ID; nothing about the review depends
on it.

Never list a second domain here. Any domain in this list that does not serve a matching AASA file
makes the whole capability fail silently, including the one that would have worked.

### The Listen Mode exception, stated honestly

`store/XCODE_CHECKLIST.md` documents that Listen Mode's **screen-locked** audio needs two things
together: `UIBackgroundModes = audio` **and** a shell that actually activates an
`AVAudioSession(.playback)`. A stock PWABuilder shell does neither.

This whitelist chooses the strict path for v1.0: **no background modes at all.** Listen Mode still
works while the app is open — hands-free advance, media controls, audio continuing when you switch
tabs — and audio stops when the screen locks. That is a smaller feature, not a broken one, and it
avoids the exact 2.5.4 rejection that a declared-but-unused background mode produces.

If someone later builds the `AVAudioSession` activation into the shell **and verifies on a real
locked iPhone** that audio keeps playing and keeps advancing, then and only then add `audio` back
and run the verifier with `--allow-background-audio`. Do not do it the other way round.

---

## STEP 1.7 — Prove it, do not assume it

After the project is configured, and again after every archive:

```bash
node ship/verify-plist.mjs
```

With no arguments it finds the most build-like `Info.plist` under `ship/ios` and the first
`.entitlements` file, and prints which ones it used. After archiving, point it at the real thing —
the plist inside the archive is what Apple actually receives:

```bash
node ship/verify-plist.mjs \
  ~/Library/Developer/Xcode/Archives/*/ScrollAnytime*.xcarchive/Products/Applications/*.app/Info.plist
```

It fails on any key outside the whitelist, and asserts `ITSAppUsesNonExemptEncryption` is false, the
bundle id is `com.scrollanytime.app`, and `UIDeviceFamily` is `[1]`. **A red line there means do not
upload.** Fix it in Xcode, archive again, re-run.

Then work through `store/XCODE_CHECKLIST.md` for the on-device checks (autoplay with sound after the
first tap, no URL bar, no pinch zoom, no long-press menus, the intro card showing exactly once), and
`OWNER-DEVICE-TEST.md` for the owner's own pass on a real phone.

---

## When STEP 1 is done

- `./ship/preflight.sh` prints READY.
- `node ship/verify-plist.mjs` prints CLEAN.
- The app runs on a real iPhone: the feed autoplays, sound comes on after the first tap, there is no
  URL bar and no Sponsor tab anywhere.
- Airplane mode on a fresh install shows the dark offline page, never a white screen.

Then continue to STEP 2 (archive) and STEP 3 (upload and submit). If anything goes wrong in any of
them, `ship/TROUBLESHOOT.md` is written for exactly that moment.
