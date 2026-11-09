# PART 6 STEP 4 — when something goes wrong

Read this when a command fails, an upload is refused, or a rejection arrives. Find the heading that
matches what you are actually looking at, do the numbered steps, then go back to where you were.

**Two rules before anything else.**

1. **Nothing here is an emergency.** No failure in this file loses work, costs money, or damages the
   app. A refused upload is a refused upload — the app on `scrollanytime.com` keeps running the
   whole time, and it is the same app.
2. **Never change the bundle identifier to make an error go away.** It is `com.scrollanytime.app`,
   it matches the App ID and the App Store Connect record, and changing it turns one clear problem
   into three unclear ones.

---

## 1. Code signing — "No signing certificate", "no team found", "Signing for … requires a development team"

This means Xcode does not know who you are.

1. Open Xcode → **Settings…** → **Accounts**.
2. Is your Apple ID listed?
   - **No** → click **+** → **Apple ID** → **Continue** → sign in with the Apple ID that has the
     Developer Program membership. This is `SETUP-APPLE.md` PART 1, steps 6–11.
   - **Yes but with a warning triangle** → click it, sign in again. Session tokens expire.
3. Select your name, then your team, then click **Manage Certificates…**
4. If the list has no **Apple Distribution** row: click **+** in the bottom-left → **Apple
   Distribution**. Wait for it to appear.
5. Close Settings. In the project: select the target → **Signing & Capabilities** tab.
   - Tick **Automatically manage signing**.
   - Set **Team** to your team.
6. Confirm from the terminal:

   ```bash
   ./ship/preflight.sh
   ```

   The "signing identity" line must be green.

**If it still fails with "no profiles found":** your Apple Developer membership may not be active
yet. Go to **developer.apple.com/account** and look for a renewal or "complete your enrollment"
banner. Nothing on the Mac can fix an inactive membership.

**If it fails with "Command CodeSign failed" and a keychain prompt in the log:** your keychain is
locked. Unlock it once in Keychain Access, or run:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

---

## 2. "Bundle ID not found" / "No matching provisioning profiles" / the bundle ID is missing from a dropdown

The App ID has not been registered, or it does not match.

1. First check what the project is actually using:

   ```bash
   grep -rn "PRODUCT_BUNDLE_IDENTIFIER" ship/ios --include=project.pbxproj | head
   ```

   Every line must say `com.scrollanytime.app`. If one says something else (PWABuilder sometimes
   fills in its own), fix it in Xcode → target → **Signing & Capabilities** → **Bundle Identifier**.
2. Then register the App ID if it does not exist. **This is `SETUP-APPLE.md` PART 3** — the
   indented block under "If it is not in the dropdown":
   developer.apple.com/account → **Certificates, Identifiers & Profiles** → **Identifiers** → **+**
   → **App IDs** → **App** → Description `Scroll Anytime`, **Explicit** bundle ID
   `com.scrollanytime.app`, tick **Sign in with Apple**, **Continue** → **Register**.
3. Reload the App Store Connect page. The bundle ID now appears in the dropdown.
4. Back in Xcode, **Product → Clean Build Folder** (Shift-Cmd-K), then archive again.

Registering the App ID with Sign in with Apple ticked is what the **web** sign-in flow needs. It
does **not** mean you add the Sign in with Apple capability to the Xcode target — see
`ship/ios/README.md` STEP 1.6.

---

## 3. The upload is blocked by pending agreements

Symptoms: the upload fails with a message about contracts, "agreements", or "your account does not
have permission"; or the build uploads but never appears in App Store Connect.

1. Go to **appstoreconnect.apple.com** and look at the top of the page for a yellow or blue banner
   about agreements, contracts or terms.
2. Click it, or go to **Business** → **Agreements**.
3. Click **Review Agreement**, scroll all the way to the bottom, tick the box, click **Agree**.
4. If it asks for contact / bank / tax details: fill in the **contact** section. Scroll Anytime is a
   free app, so bank and tax are usually skippable — if the page forces them, that is Apple's
   requirement, not ours.
5. Wait about five minutes. Agreements take a moment to propagate. Then upload again.

This is `SETUP-APPLE.md` PART 4. It comes back every time Apple publishes new terms, which they do
a few times a year, so do not be surprised to see it again on a later release.

---

## 4. Screenshots rejected for the wrong size

App Store Connect only accepts exact pixel dimensions. "Close" is rejected.

**6.9-inch display** (iPhone 16/17 Pro Max class) — required:

| Orientation | Accepted sizes |
|---|---|
| Portrait | **1320 × 2868** or **1290 × 2796** |
| Landscape | 2868 × 1320 or 2796 × 1290 |

**6.5-inch display** (iPhone 11 Pro Max / XS Max class):

| Orientation | Accepted sizes |
|---|---|
| Portrait | **1284 × 2778** or **1242 × 2688** |
| Landscape | 2778 × 1284 or 2688 × 1242 |

This repo generates **1320 × 2868** and **1284 × 2778**, which are both on the list.

Also required, and easy to miss:

- PNG or JPEG. No other format.
- **No alpha channel / no transparency.**
- At least 1 and at most 10 screenshots per size.
- Portrait screenshots for a portrait-only app. Do not mix in a landscape shot.
- No rounded corners, no device frame drawn by you, no status-bar edits.

**To fix:**

1. Check what you actually have:

   ```bash
   magick identify store/screenshots/*.png
   ```

   (Or `sips -g pixelWidth -g pixelHeight store/screenshots/*.png` if you prefer Apple's tool.)
2. Regenerate from production rather than resizing by hand — resizing produces soft text that looks
   cheap next to other apps:

   ```bash
   npm run store:screenshots
   ```
3. If one file has an alpha channel, flatten it:

   ```bash
   magick input.png -background '#0B0B0F' -alpha remove -alpha off output.png
   ```

The same "no alpha" rule applies to the 1024 × 1024 marketing icon (`store/appicon-1024.png`). An
icon with transparency is rejected at upload, not at review.

---

## 5. The common ITMS error codes

These arrive either in Xcode's upload dialog or in an email from Apple minutes after the upload.
They are **not** review rejections — the build never got to a human.

### ITMS-90683 — "Missing purpose string in Info.plist"

The build declares a permission without an explanation, or includes a usage key at all.

**For this app the fix is always to remove the key, never to write a purpose string.** Scroll
Anytime uses no camera, microphone, photos, location or contacts. A purpose string is a promise to
the reviewer that the app uses that capability, and it will be tested.

```bash
node ship/verify-plist.mjs        # names the exact key
```

Delete the named key from `Info.plist`, bump the build number (see ITMS-4238), archive and upload
again.

### ITMS-90713 — "Missing Info.plist value: CFBundleIconName"

The app icon is not coming from an asset catalog.

1. In Xcode, open `Assets.xcassets`. There must be an **AppIcon** image set with every slot filled,
   including the 1024 × 1024 App Store slot.
2. Target → **Build Settings** → search `ASSETCATALOG_COMPILER_APPICON_NAME` → it must be `AppIcon`.
3. Target → **General** → **App Icons and Launch Screen** → **App Icon Source** = `AppIcon`.
4. **Product → Clean Build Folder**, archive again. `CFBundleIconName` appears on its own once the
   icon set is correct — you do not add it by hand.

### ITMS-90809 — "Deprecated API Usage: UIWebView"

Something in the project uses `UIWebView`, which Apple no longer accepts. Our shell uses
`WKWebView`; an old PWABuilder template or a stray file is the usual cause.

```bash
grep -rn "UIWebView" ship/ios
```

Every hit must be removed or changed to `WKWebView`. If the hits are inside a third-party file you
did not write, delete that file — nothing in this shell needs it. If PWABuilder itself generated
`UIWebView`, the template is too old: regenerate the package (STEP 1.1) and redo the configuration.

### ITMS-90478 — "Invalid Version"

The version number is not acceptable. Usually one of:

- `CFBundleShortVersionString` is lower than or equal to a version already approved.
- It has a format Apple rejects: it must be one to three numbers separated by dots
  (`1.0.0`), with no letters, no leading zeros (`1.0.01` is invalid), and no fourth component.
- It does not match the version of the App Store Connect record you are uploading into.

Fix it in Xcode → target → **General** → **Version**. For the first submission it is `1.0.0`.

### ITMS-4238 — "Redundant Binary Upload"

A build with this build number already exists for this version. Build numbers can never be reused,
even for a build that was deleted or rejected.

1. Xcode → target → **General** → **Build** → increase it by one (`1` → `2` → `3` …).
2. **Leave the Version at `1.0.0`.** The version is what customers see; the build number is just a
   counter.
3. Archive and upload again.

This is the normal, expected fix after **any** change to the binary. Every re-archive gets a new
build number.

---

## 6. Re-running the airplane-mode test

Do this after any change to the shell, the offline page, or `WKAppBoundDomains`. It has to be a
genuinely first launch, or the test proves nothing — a previously-run app already has its service
worker and cached clips, and will look fine even when the offline page is broken.

1. On the iPhone, **delete the app completely** (press and hold the icon → Remove App → Delete App).
2. Install the build again (from Xcode, or from TestFlight).
3. **Do not open it yet.**
4. Turn on **Airplane Mode** in Control Centre. Check Wi-Fi is off too — airplane mode sometimes
   leaves Wi-Fi on.
5. Open the app.
6. **Must happen:** the dark page appears with the gold "Scroll Anytime" wordmark, the line about
   needing a connection for the first open, and a **Retry** button.
7. **Must never happen:** a white screen, a grey page, the words "cannot open page", a browser error,
   or the app closing.
8. Turn airplane mode off. Within a few seconds the page reloads itself into the real app.
9. Now watch three or four clips, then turn airplane mode on again. This time the app's own offline
   screen appears, My Torah lists your saved clips, and recently watched clips still play.

If step 6 fails, the offline page is not wired into the navigation-failure handler — go back to
`ship/ios/README.md` STEP 1.5. If step 9 fails but step 6 passed, `WKAppBoundDomains` is missing —
STEP 1.4.

---

## 7. If review rejects the app

A rejection is a normal part of shipping. It is not a verdict on the app, and roughly every app gets
one at some point.

**What arrives:** a message in App Store Connect → your app → **App Review** → **Resolution Center**,
naming a **guideline number** (like 2.1, 4.2, 5.1.1) and usually a screenshot or a short description
of what the reviewer saw.

**Do this, in order:**

1. **Read the guideline number.** It is the only part that matters. The prose around it is a
   template.
2. **Open `store/RESOLUTION_CENTER_REPLIES.md`** and find the reply prepared for that guideline
   number. Those replies exist because the answers are already true and already documented — the app
   genuinely has no location code, genuinely has account deletion, genuinely has permission for the
   content. Send the prepared reply from the Resolution Center.
3. **Never argue and never speculate.** Answer the question asked, point at the fact, stop. If the
   reviewer asked for something the app really does have, tell them exactly where it is
   ("Profile → Delete account", "Profile → About & Credits").
4. **Work out which kind of fix it needs:**

   | Kind | What changed | What to do |
   |---|---|---|
   | **Metadata only** — description, screenshots, review notes, privacy answers, the reviewer just needed information | nothing in the app | Fix the metadata in App Store Connect, reply in Resolution Center, and **submit the same build again**. Do not upload a new binary. |
   | **Binary change** — anything at all in the shell or the web app | the app | Deploy the web change first if it is a web change (`cd worker && npx wrangler deploy`), then **bump the build number** (Xcode → General → Build, `1` → `2`) and **re-run STEP 2 and STEP 3** — archive, upload, submit. A reused build number is refused with ITMS-4238. |

5. **If the fix was in the web app only** (`app/` or `worker/`), remember the shell just loads the
   live site: deploying is enough for the behaviour to change, but the reviewer needs a build to
   look at, so you still resubmit. Bump the build number anyway — it costs nothing and removes all
   ambiguity about which binary they tested.
6. Re-run the gates before resubmitting:

   ```bash
   ./ship/preflight.sh
   node ship/verify-plist.mjs
   ```

**The rejections this app is most exposed to, and where the answer already lives:**

| Guideline | What it means here | Where the answer is |
|---|---|---|
| 4.2 minimum functionality | "this is just a website" | `store/APP_REVIEW_NOTES.md` — offline mode, saves, streaks, personalised feed. The airplane-mode test (section 6) is the proof. |
| 2.1 crashes and bugs / needs more information | usually a blank first launch, or missing sign-in details | the offline page (section 6) and the review account in `store/APP_REVIEW_NOTES.md` |
| 5.1.1 data collection | account deletion, or asking for data the app does not need | account deletion is in-app: Profile → Delete account. `store/PRIVACY_NUTRITION.md` has the filed answers. |
| 5.2 / content rights | "prove you can use these videos" | `store/APP_REVIEW_NOTES.md` — content is used with written permission; the letters are attached to the submission. |
| 2.5.4 background modes | a declared background mode that is not used | there should be none at all — `node ship/verify-plist.mjs` fails on any. See `ship/ios/README.md` STEP 1.6. |

---

## 8. Still stuck

Write down, in this order, and send it to the developer:

1. What you were doing (which STEP, which command).
2. The **exact** error text or code — take a screenshot; do not retype it.
3. The output of:

   ```bash
   ./ship/preflight.sh
   node ship/verify-plist.mjs
   ```

Do not start changing settings to see what happens. Every setting in `ship/ios/README.md` has a
reason, and an undocumented change made under pressure is the hardest kind of problem to find later.
