import XCTest

/// THE RELEASE GATE'S WALK (the owner, 2026-11-02: "NOTHING DEPLOYS WITHOUT PASSING IT"). The real shell on the iOS
/// Simulator, a cleared install, throttled 4G, every request pinned to the build being judged (ship/ios/gate-walk.sh
/// sets all of that up and runs one method a leg). The shell runs with -saGate: the page's REAL first-run path,
/// watched — what it put on screen, every clip's start, the route, the shell's own moments — in a host folder
/// (UITestHooks.gateScript / record). This test drives it like a person and polls that record instead of slow
/// accessibility queries on the feed. Every verdict is printed as `SA-GATE-CHECK {json}`, every moment as
/// `SA-GATE-MARK <ms>\t<what>\t<detail>`; scripts/gate/run.mjs reads both with what the server and the record say.
final class GateWalkUITests: XCTestCase {
    static let appId = "com.scrollanytime.app"
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let env = ProcessInfo.processInfo.environment
    var dir: String { env["GATE_DIR"] ?? "/tmp/sa-gate" }
    var leg: String { env["GATE_LEG"] ?? "?" }
    var flags: [String] { (env["GATE_FLAGS"] ?? "").split(separator: " ").map(String.init).filter { !$0.isEmpty } }
    var shotN = 0

    /// the words whose first appearance the walk waits for (the app's own strings, copied verbatim)
    static let watch: [[String]] = [
        ["welcome", "Endless Torah."], ["email", "One email. No password."], ["checkEmail", "Check your email"],
        ["codeWrong", "That code is not right."], ["name", "What should we call you?"], ["rabbis", "o do you want to hear from?"],
        ["seder", "How much Torah a day?"], ["building", "Building your feed"], ["back", "Good to have you back"],
        ["tip1", "Swipe up for the next clip."], ["tip2", "Hold the right side to play faster."], ["tip3", "Tap Save to keep a clip."],
        ["allset", "You’re all set"], ["ask", "Want a reminder tomorrow?"], ["counts", "Today counts."],
        ["photos", "Saved to Photos"], ["offline", "You’re offline"], ["couldnt", "Couldn’t connect"],
        ["shellWall", "needs a connection for your first open"], ["parsha", "Parashat "],
        ["googleFail", "Google sign-in didn’t go through"], ["appleFail", "Apple sign-in didn’t go through"],
        ["myTorah", "Tap Save on any clip to keep it here."], ["milestone", "days of Torah in a row"],
        // THE SHABBAT LOCK’S SCREEN (2026-11-07)
        ["rest", "Scroll Anytime is resting."],
    ]
    static var watchJSON: String {
        String(data: (try? JSONSerialization.data(withJSONObject: watch)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: the record

    func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        let o: [String: Any] = ["name": name, "pass": pass, "detail": String(detail.prefix(1400)), "leg": leg]
        if let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) { print("SA-GATE-CHECK \(s)") }
    }

    func mark(_ what: String, _ detail: String = "") {
        print("SA-GATE-MARK \(Int(now()))\t\(what)\t\(detail.replacingOccurrences(of: "\n", with: " ").prefix(600))")
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shotN += 1
        a.name = String(format: "%02d %@", shotN, name)
        a.lifetime = .keepAlways
        add(a)
    }

    func state() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: "\(dir)/state.json"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o
    }

    func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    /// the first clip's first moving frame (its [load] line) or a <video> seen playing, whichever came first; 0 = not yet
    func firstPlay() -> Double {
        let s = state()
        return [num(s["firstLoadAt"]), num(s["firstPlayingAt"])].compactMap { $0 }.filter { $0 > 0 }.min() ?? 0
    }
    /// when the app's own code started (the shell's launch moment): the test runner's launch takes up to a minute on a
    /// fresh install before the app exists at all, and that is the harness, never the app
    func appStart(_ fallback: Double) -> Double { num(state()["launchAt"]) ?? fallback }
    func seen(_ k: String) -> Double? { num((state()["seen"] as? [String: Any])?[k]) }
    func route() -> String { state()["route"] as? String ?? "" }
    func loads() -> Int { Int(num(state()["loads"]) ?? 0) }
    func streakText() -> String { state()["streak"] as? String ?? "" }

    @discardableResult
    func waitFor(_ timeout: TimeInterval, every: TimeInterval = 0.2, _ ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ok() { return true }
            Thread.sleep(forTimeInterval: every)
        } while Date() < deadline
        return ok()
    }

    func waitSeen(_ k: String, _ timeout: TimeInterval) -> Double? {
        var t: Double?
        waitFor(timeout) { t = seen(k); return t != nil }
        return t
    }

    func waitRoute(_ timeout: TimeInterval, _ want: (String) -> Bool) -> String {
        var r = ""
        waitFor(timeout) { r = route(); return want(r) }
        return r
    }

    // MARK: the app

    /// the launch: the record's state is cleared first (its events stay), the moment before is marked
    @discardableResult
    func launch(_ extra: [String] = []) -> (XCUIApplication, Double) {
        try? FileManager.default.removeItem(atPath: "\(dir)/state.json")
        let app = XCUIApplication(bundleIdentifier: Self.appId)
        let proxy = (env["GATE_PROXY"] ?? "").isEmpty ? [] : ["-saGateProxy", env["GATE_PROXY"]!]
        app.launchArguments = ["-saGate", "-saGateDir", dir, "-saGateWatch", Self.watchJSON] + proxy + flags + extra
        let t = now()
        mark("launch", leg)
        app.launch()
        return (app, t)
    }

    /// an element by its accessibility label (exact, or how it starts), the first one a finger could hit
    func find(_ app: XCUIApplication, _ label: String, begins: Bool = false, type: XCUIElement.ElementType = .any, timeout: TimeInterval = 15) -> XCUIElement? {
        let pred = begins ? NSPredicate(format: "label BEGINSWITH %@", label) : NSPredicate(format: "label == %@", label)
        let q = (type == .any ? app.descendants(matching: .any) : app.descendants(matching: type)).matching(pred)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let first = q.firstMatch
            if first.exists {
                if first.isHittable { return first }
                if let e = q.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        return nil
    }

    @discardableResult
    func tap(_ app: XCUIApplication, _ label: String, begins: Bool = false, type: XCUIElement.ElementType = .any, timeout: TimeInterval = 15) -> Bool {
        guard let e = find(app, label, begins: begins, type: type, timeout: timeout) else {
            mark("not-found", label)
            return false
        }
        e.tap()
        return true
    }

    func point(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    func swipeUp(_ app: XCUIApplication) {
        point(app, 0.42, 0.78).press(forDuration: 0.02, thenDragTo: point(app, 0.42, 0.2), withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// a tap at an element's centre, read ONCE: the feed's accessibility tree is slow to query again
    func tapAt(_ app: XCUIApplication, _ frame: CGRect) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    /// the walk must never meet an offline page while it is online
    func noWall(_ where_: String) {
        let s = state()
        let wall = (num(s["wall"]) ?? 0) > 0 || (s["seen"] as? [String: Any])?["offline"] != nil || (s["seen"] as? [String: Any])?["shellWall"] != nil
        check("the offline wall never appears while online", !wall, wall ? "an offline page showed (\(where_))" : "none (\(where_))")
    }

    /// the page's OWN requests reach the build being judged: its /version, read by the watcher at document start.
    /// curl's check through the proxy said "pinned" on 11-03 while every one of the app's connections went around it.
    func pinCheck() {
        let want = env["GATE_SHA"] ?? ""
        guard !want.isEmpty else { return }
        var got = ""
        waitFor(30) { got = state()["build"] as? String ?? ""; return !got.isEmpty }
        check("the app's own requests reach the build being judged", got == want,
              got.isEmpty ? "the page never read its /version (30 s)" : got == want ? "the page's /version answers \(want.prefix(8))" : "the page's /version answers \(got.prefix(8)), not \(want.prefix(8))")
    }

    func signedInFeed(_ app: XCUIApplication, _ name: String, _ t0: Double) {
        pinCheck()
        // signed in = the feed plays and the onboarding's welcome never comes
        let playing = waitFor(90) { firstPlay() > 0 }
        let welcome = seen("welcome")
        let at = firstPlay()
        shot("\(leg)-feed")
        check(name, playing && welcome == nil, playing ? (welcome == nil ? "the feed played \(Int(at - appStart(t0))) ms after the app started, no sign-in screen" : "the sign-in screen came back") : "the feed never played (90 s); route \(route())")
    }

    // MARK: THE LEGS

    /// keychain reset, app deleted and installed: everything a new person does
    func testNewPerson() throws {
        let email = env["GATE_EMAIL"] ?? ""
        let code = env["GATE_CODE"] ?? ""
        let (app, t0) = launch()

        // 1 · the first screen
        let welcome = waitSeen("welcome", 120)
        shot("first-open")
        let start = appStart(t0)
        let firstMs = welcome.map { Int($0 - start) } ?? -1
        mark("first-screen", "\(firstMs)\t\(Int(start - t0))")
        check("a fresh install shows the first screen in under 4 s", welcome != nil && firstMs < 4000, welcome != nil ? "the welcome \(firstMs) ms after the app started (the test runner took \(Int(start - t0)) ms to start it)" : "no welcome in 120 s (route \(route()))")
        noWall("first open")
        pinCheck()

        // 2 · Google: the system sheet opens at Google, and closing it comes back to the app
        googleHandoff(app)
        // 3 · Apple
        appleHandoff(app)

        // 4 · email, through the real email step
        var signedIn = false
        dismissAlerts(app)
        if email.isEmpty || code.isEmpty {
            check("sign in with email", false, "this build has no gate address to sign in with (the run's marker named none)")
        } else if tap(app, "Continue with email", timeout: 20) {
            let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "you@example.com")).firstMatch
            if !field.waitForExistence(timeout: 15) {
                // a tap that landed on something over the button: the alerts go, and the button once more
                dismissAlerts(app)
                tap(app, "Continue with email", timeout: 10)
            }
            if field.waitForExistence(timeout: 20) {
                field.tap()
                field.typeText(email)
                keyboardTipOut()
                shot("email")
                tap(app, "Email me a sign-in link", timeout: 10)
                if waitSeen("checkEmail", 30) != nil {
                    let otp = app.textFields["Six-digit code"]
                    if otp.waitForExistence(timeout: 10) { otp.tap() }
                    app.typeText(code)
                    shot("code")
                    let onward = waitFor(40) { seen("name") != nil || seen("rabbis") != nil || seen("seder") != nil || seen("building") != nil || seen("back") != nil || seen("codeWrong") != nil }
                    signedIn = onward && seen("codeWrong") == nil
                    check("sign in with email", signedIn, signedIn ? "the code was accepted" : seen("codeWrong") != nil ? "the code was refused" : "nothing after the code (40 s)")
                } else {
                    shot("email-not-sent")
                    check("sign in with email", false, "the code step never came (the send failed?)")
                }
            } else {
                check("sign in with email", false, "no email field")
            }
        } else {
            check("sign in with email", false, "no Continue with email button")
        }

        // 5 · the rest of the onboarding: name → rabbis → seder → the feed
        if signedIn {
            if waitSeen("name", 8) != nil {
                let name = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "First name")).firstMatch
                if name.waitForExistence(timeout: 8) { name.tap(); name.typeText("Gate") }
                keyboardTipOut()
                shot("name")
                // the page's own button, by its whole label: iOS's keyboard tip has a "Continue" of its own (run 4
                // tapped that one, and the name step never moved)
                if !tap(app, "Continue, Gate", type: .button, timeout: 8) { tap(app, "Continue, ", begins: true, type: .button, timeout: 4) }
                if waitFor(6, { seen("rabbis") != nil || seen("seder") != nil || seen("building") != nil }) == false {
                    keyboardTipOut()
                    tap(app, "Continue, ", begins: true, type: .button, timeout: 6)
                }
            }
            if waitSeen("rabbis", 10) != nil {
                shot("rabbis")
                tap(app, "Skip for now", timeout: 8)
            }
            var sederTaps = 0
            if waitSeen("seder", 10) != nil {
                shot("seder")
                // A DROPPED TAP IS TAPPED AGAIN, AND SAID (2026-11-06): deploy8's walk tapped "No limit" once, the step never
                // moved, and the walk swiped eighty times on the seder card while every later check read "no feed"
                repeat {
                    sederTaps += 1
                    tap(app, "No limit", begins: true, timeout: 8)
                } while waitSeen("building", 8) == nil && seen("back") == nil && sederTaps < 3
            }
            let building = waitSeen("building", 15)
            shot("building")
            if building == nil && seen("back") == nil {
                check("the onboarding ends on the playing feed", false, "the seder step never moved (\(sederTaps) taps on No limit); route \(route())")
                noWall("onboarding")
                return
            }
            if sederTaps > 1 { mark("seder-taps", "\(sederTaps)") }
        }
        let feedUp = waitFor(60) { firstPlay() > 0 }
        shot("feed")
        check("the onboarding ends on the playing feed", feedUp, feedUp ? "route \(route())" : "no clip played within 60 s of the onboarding (route \(route()))")
        guard feedUp else { noWall("onboarding"); return }

        // 6 · THE THREE TIPS: swipe, hold the right side, tap Save
        let tip1 = waitSeen("tip1", 25)
        shot("tip-1")
        if tip1 != nil { swipeUp(app) }
        let tip2 = waitSeen("tip2", 15)
        shot("tip-2")
        // THE HOLD ON A PLAYING CLIP (deploy20, 2026-11-08): 2x lands only once a clip moves (rateToApply), and the lesson
        // counts half a second of 2x. Deploy20's walk held the right side while the clip under tip 2 still spun (the
        // shot: a spinner; the record: playing 0 for 3.6 s from the hold) — the hold taught nothing, tip 2 stayed, and
        // the one swipe after it was not enough for tip 3. A person holds a clip they can see playing, and holds again
        // when the tip is still there: the walk waits for a playing clip, and tries once more if tip 3 does not follow.
        if tip2 != nil {
            for attempt in 1...2 {
                let playing = waitFor(12) { (num(state()["playing"]) ?? 0) == 1 }
                mark("tip2-hold", "\(attempt)\t\(playing ? "playing" : "not playing")")
                // CLEAR OF THE RAIL (deploy23, 2026-11-08): at (0.82, 0.5) the press sat on the edge of the rabbi's avatar — a
                // control, so no 2x and the tips ended for good (TipsLayer: anything else ends them). The 2x zone is x > 0.6.
                point(app, 0.75, 0.35).press(forDuration: 1.3)
                Thread.sleep(forTimeInterval: 0.6)
                swipeUp(app)
                if waitSeen("tip3", attempt == 1 ? 8 : 15) != nil { break }
            }
        }
        let tip3 = waitSeen("tip3", 2)
        shot("tip-3")
        if tip3 != nil {
            if let save = find(app, "Save", timeout: 10) { save.tap() }
        }
        let allSet = waitSeen("allset", 10)
        shot("tips-done")
        // what the app itself recorded of the tips (window.__saTips → the watcher's "tips" event): why they ended
        let tipsRec = state()["tips"] as? [String: Any]
        let tipsEnded = tipsRec?["ended"] as? String ?? ""
        let tipsNote = (tip3 == nil || allSet == nil) && !tipsEnded.isEmpty ? " · the app ended the tips: \(tipsEnded)" : ""
        check("the three onboarding tips show", tip1 != nil && tip2 != nil && tip3 != nil, "tip 1 \(tip1 != nil ? "shown" : "MISSING"), tip 2 \(tip2 != nil ? "shown" : "MISSING"), tip 3 \(tip3 != nil ? "shown" : "MISSING"), all set \(allSet != nil ? "shown" : "not seen")\(tipsNote)")
        Thread.sleep(forTimeInterval: 1.5)

        // 7 · SIXTY CLIPS: a flick each (2.4 s: a quick look, never a counted watch)
        let before = loads()
        mark("scroll-start", "\(before)")
        var stuck = 0
        var i = 0
        while loads() - before < 60 && i < 80 {
            i += 1
            let n0 = loads()
            swipeUp(app)
            // THE RUNNER'S SAMPLE (2026-11-06): on GitHub's 2-core VM nothing paints inside the flick (59 of 60 clips were
            // left at ~4.5 s with readyState 0 on 00c775d1), so every tenth clip is given GATE_SAMPLE_DWELL_S to move —
            // scripts/gate/run.mjs judges those against the runner's ceiling; the rest stay the 2.4 s flick
            let dwell = Double(env["GATE_SAMPLE_DWELL_S"] ?? "") ?? 0
            // a sampled clip is given the dwell to MOVE, then flicked like the rest: waiting longer would be watching, and
            // two minutes of watching inside the sixty made today count before the counting clip (the ask check's order)
            // …its OWN line: a clip left unmoved before it writes "[load] left", which once ended the wait at the swipe and
            // left the sampled clip at ~3 s (deploy10's two "never moved (left at 3086 ms)")
            if dwell > 0 && i % 10 == 1 {
                // A MOMENT OVER THE FEED IS CLOSED FIRST (deploy22, 2026-11-08): the clips play now, so the sixty's
                // flicks and dwells pass the No-limit minute and TODAY COUNTS inside the sixty; the 7-day milestone
                // ("One week.") opened at that clip end and the next sampled dwell (clip 61) waited 20 s under it
                if let moment = find(app, "Keep going", type: .button, timeout: 1) {
                    mark("moment-closed", "sample \(i)")
                    moment.tap()
                    Thread.sleep(forTimeInterval: 1.0)
                }
                // THE SAMPLE IS MARKED (deploy17, 2026-11-07): since the app passes a clip with no frame at 5 s by itself,
                // one swipe can leave several "[load]" lines (61 in 44 swipes), so every tenth LINE was not the clip the
                // walk dwelt on. The judge reads the dwell from this mark: how long the person waited for a moving picture
                mark("sample", "\(i)\t\(n0)")
                let moved = waitFor(dwell) { loads() > n0 && !((state()["lastLoad"] as? String ?? "").contains(" left ")) }
                mark("sample-end", "\(i)\t\(moved ? "moved" : "none")\t\(loads())")
                Thread.sleep(forTimeInterval: 1.0)
            } else { Thread.sleep(forTimeInterval: 2.4) }
            if loads() == n0 { stuck += 1 } else { stuck = 0 }
            if i == 1 || i == 30 || i == 60 { shot("clip-\(i)") }
            if stuck >= 4 {
                shot("scroll-stuck-\(i)")
                mark("scroll-stuck", "at swipe \(i), route \(route())")
                // something is over the feed (a sheet, a Moment): close it the way a person would
                for l in ["Not now", "Keep going", "Close", "Done", "Dismiss"] where tap(app, l, timeout: 1) {
                    mark("moment-closed", "stuck at swipe \(i): \(l)") // the ask check reads when the Moment went (scripts/gate/run.mjs)
                    break
                }
                stuck = 0
            }
        }
        mark("scroll-end", "\(loads())")
        let scrolled = loads() - before
        check("sixty clips scroll", scrolled >= 60, "\(scrolled) clips started or were left in \(i) swipes")
        let askEarly = seen("ask")
        noWall("sixty clips")

        // 8 · THE COUNTING CLIP: watch one clip a minute (it loops), leave it — today counts, then the ask
        mark("count-start", streakText())
        Thread.sleep(forTimeInterval: 66)
        swipeUp(app)
        mark("count-left", streakText())
        let ignited = waitFor(25) { streakText().contains("today counts") }
        mark("counted", streakText())
        var ask = waitSeen("ask", 20)
        // THE ASK'S OWN WINDOW (run 202611081037, 2026-11-08): when today counts at THIS clip and a milestone Moment
        // takes its end ("One week."), the app puts the ask at the first clip end 90 s later (lib/moments.ts), and the
        // leg's remaining steps (Save, the end) have no clip end in that window — the record read "no reminder ask" for
        // a build that would have asked. So the walk gives it the window: the Moment closed as a person closes it, the
        // clip playing on, one swipe at 91 s after the milestone (a clip end), and the ask waited for there.
        if ask == nil, let milestone = seen("milestone") {
            if let moment = find(app, "Keep going", type: .button, timeout: 2) {
                mark("moment-closed", "count")
                moment.tap()
            }
            let wait = (milestone + 91_000 - now()) / 1000
            if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 120)) }
            swipeUp(app)
            mark("ask-swipe", "\(Int((now() - milestone) / 1000)) s after the milestone")
            ask = waitSeen("ask", 25)
        }
        shot("ask")
        // the verdicts on the streak and the ask are the record's: scripts/gate/run.mjs reads the pill and the ask in
        // the order they came (today may have counted during the sixty, and then the ask came then)
        mark("ask-seen", "\(Int(ask ?? 0))\t\(Int(askEarly ?? 0))\t\(ignited)")
        mark("streak", streakText())
        tap(app, "Not now", timeout: 8)
        Thread.sleep(forTimeInterval: 1.2)

        // 9 · SAVE · SAVE TO PHOTOS · WHATSAPP · MY TORAH
        var savedOK = false
        closeSheets(app)
        if find(app, "Unsave", timeout: 3) != nil {
            // the clip in view is saved already (the third tip's Save): the next one is saved here
            swipeUp(app)
            Thread.sleep(forTimeInterval: 3)
        }
        var saveTaps = 0
        if let save = find(app, "Save", timeout: 10) {
            save.tap(); saveTaps = 1
            savedOK = find(app, "Unsave", timeout: 8) != nil
            // a person taps again; the record says so (a dropped first tap is in the detail, never silent)
            if !savedOK, let again = find(app, "Save", timeout: 3) {
                again.tap(); saveTaps = 2
                savedOK = find(app, "Unsave", timeout: 8) != nil
            }
        }
        shot("saved")
        check("Save", savedOK, savedOK ? (saveTaps == 2 ? "the rail says Unsave — after a SECOND tap (the first was dropped)" : "the rail says Unsave") : "the rail never said Unsave (\(saveTaps) taps)")
        mark("saved-at", "\(Int(now()))")
        // 9b-12 · Save to Photos, WhatsApp, My Torah, the navigation, Parsha and VoiceOver walk on the second runner
        // (testSignedInTour, since deploy16): the job's 45 minutes cannot hold them after the sixty
        noWall("the walk")
    }

    /// THE SIGNED-IN TOUR, on a runner of its own (deploy15/16, 2026-11-06): the new person's account (the one the first
    /// runner onboarded and saved a clip with) signs in on a fresh install through the real email step, is welcomed back
    /// to the feed, and walks what a signed-in person does after the sixty: Save to Photos, WhatsApp, My Torah (the saved
    /// clip listed), the four navigation sequences, Parsha, VoiceOver on the rail. What needs the NEW install (the first
    /// screen, the onboarding, the tips, the sixty, the counting clip, Save) stays in testNewPerson.
    func testSignedInTour() throws {
        let email = env["GATE_EMAIL"] ?? ""
        let code = env["GATE_CODE"] ?? ""
        // the ghost probe rides this leg: the watcher times three clip starts with no touch, then one touch
        let (app, t0) = launch(["-saGateGhostProbe"])
        guard !email.isEmpty, !code.isEmpty else {
            check("the tour signs in to the feed", false, "this run's marker named no gate address")
            return
        }
        guard waitSeen("welcome", 120) != nil else {
            shot("tour-no-welcome")
            check("the tour signs in to the feed", false, "no welcome in 120 s (route \(route()))")
            noWall("tour first open")
            return
        }
        pinCheck()
        dismissAlerts(app)
        var accepted = false
        if tap(app, "Continue with email", timeout: 20) {
            let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "you@example.com")).firstMatch
            if !field.waitForExistence(timeout: 15) {
                dismissAlerts(app)
                tap(app, "Continue with email", timeout: 10)
            }
            if field.waitForExistence(timeout: 20) {
                field.tap()
                field.typeText(email)
                keyboardTipOut()
                tap(app, "Email me a sign-in link", timeout: 10)
                if waitSeen("checkEmail", 30) != nil {
                    let otp = app.textFields["Six-digit code"]
                    if otp.waitForExistence(timeout: 10) { otp.tap() }
                    app.typeText(code)
                    accepted = waitFor(40) { firstPlay() > 0 || seen("back") != nil || seen("building") != nil || seen("name") != nil || seen("rabbis") != nil || seen("seder") != nil || seen("codeWrong") != nil } && seen("codeWrong") == nil
                }
            }
        }
        // a returning person goes straight back to the feed; if any onboarding step shows anyway, it is passed through
        if accepted && firstPlay() == 0 {
            if waitSeen("rabbis", 6) != nil { tap(app, "Skip for now", timeout: 8) }
            if waitSeen("seder", 6) != nil { tap(app, "No limit", begins: true, timeout: 8) }
        }
        let feedUp = waitFor(60) { firstPlay() > 0 }
        shot("tour-feed")
        check("the tour signs in to the feed", accepted && feedUp, !accepted ? "the email step did not take the code (route \(route()))" : feedUp ? "the feed played \(Int(firstPlay() - appStart(t0))) ms after the app started" : "no clip played within 60 s of the sign-in (route \(route()))")
        guard feedUp else { noWall("tour"); return }
        ghostProbe(app)
        Thread.sleep(forTimeInterval: 2)
        closeSheets(app)

        // 9b · SAVE TO PHOTOS · WHATSAPP · MY TORAH
        if let more = find(app, "More options", type: .button, timeout: 10) {
            more.tap()
            if tap(app, "Save to Photos", timeout: 10) {
                let saw = waitSeen("photos", 150)
                shot("photos")
                check("Save to Photos", saw != nil, saw != nil ? "“Saved to Photos”" : "no “Saved to Photos” in 150 s")
                // A SHEET THAT STAYED IS CLOSED AS A PERSON CLOSES IT (deploy22, 2026-11-08): the save ran past the walk's
                // 150 s and the More sheet stood over the rail and the tab bar, so WhatsApp, My Torah, the navigation and
                // Parsha each failed on the sheet, not on themselves. The More sheet has no Done: it is dragged down.
                if saw == nil { closeMoreSheet(app) }
            } else {
                shot("photos-row")
                check("Save to Photos", false, "the More sheet had no Save to Photos row")
            }
        } else {
            check("Save to Photos", false, "no More options button")
        }
        Thread.sleep(forTimeInterval: 2)
        closeSheets(app)
        whatsApp(app)
        closeSheets(app)
        myTorah(app)

        // 10 · THE FOUR NAVIGATION SEQUENCES (B-006: the on-screen Back, one step toward the tab's root)
        navigation(app)

        // 11 · PARSHA
        parsha(app)

        // 12 · VOICEOVER READS THE RAIL
        rail(app)
        noWall("the tour")
    }

    /// THE GHOST (the owner, 2026-11-07, check 5): the rail under 40 % within 300 ms of play on three consecutive clips, and back
    /// above 95 % within 200 ms of a touch. The watcher (UITestHooks.gateScript) times both from OUTSIDE the app's code, on the
    /// rail's own Save button (its opacity times every ancestor's); the page's gate hook (__saGateAdvance, the path a clip's end
    /// takes) starts the next clips with no touch at all. Starts the interface was held up for (a strip, a touch) do not count.
    func ghostProbe(_ app: XCUIApplication) {
        // each of the three advanced clips gets 30 s to start on the runner (run 202611081347, 2026-11-08: a VM whose feed
        // first played 120 s after launch gave the probe one start in three 10 s waits — a reading of the VM, not the ghost)
        let done = waitFor(130) { (state()["ghostProbe"] as? [String: Any]) != nil }
        let plays = (state()["ghostPlays"] as? [[String: Any]]) ?? []
        let free = plays.filter { (($0["held"] as? String) ?? "").isEmpty }
        let three = Array(free.suffix(3))
        let ns = three.map { Int(num($0["n"]) ?? -1) }
        let consecutive = ns.count == 3 && ns[1] == ns[0] + 1 && ns[2] == ns[1] + 1
        let ms = three.map { Int(num($0["ms"]) ?? -1) }
        let ok = three.count == 3 && consecutive && ms.allSatisfy { $0 >= 0 && $0 <= 300 }
        shot("ghost-ghosted")
        let rail = three.map { "\(num($0["o0"]) ?? -1)→\(num($0["o"]) ?? -1)" }.joined(separator: ", ")
        check("the rail ghosts under 40 % within 300 ms of play, three clips in a row", ok,
              done ? "starts \(ns.map { String($0) }.joined(separator: ", ")): \(ms.map { "\($0) ms" }.joined(separator: ", ")) (the rail \(rail)); \(plays.count) starts seen, \(plays.count - free.count) held" : "the probe never finished (75 s): \(plays.count) starts seen")
        // one touch on the left of the video (a tap there pauses it: the interface comes back either way)
        let before = ((state()["ghostTouches"] as? [[String: Any]]) ?? []).count
        point(app, 0.3, 0.5).tap()
        var touch: [String: Any]? = nil
        waitFor(10) {
            let t = (state()["ghostTouches"] as? [[String: Any]]) ?? []
            if t.count > before { touch = t[before] }
            return touch != nil
        }
        let tms = Int(num(touch?["ms"]) ?? -1)
        shot("ghost-restored")
        check("a touch brings the rail back above 95 % within 200 ms", touch != nil && tms >= 0 && tms <= 200,
              touch == nil ? "no reading in 10 s (the rail was not ghosted at the press)" : "\(tms) ms (the rail \(num(touch?["o0"]) ?? -1) → \(num(touch?["o"]) ?? -1))")
        // the tap paused it: play it again, and the walk goes on
        Thread.sleep(forTimeInterval: 0.8)
        point(app, 0.3, 0.5).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// THE SHABBAT LOCK'S SIMULATOR TEST (the owner, 2026-11-07, proof (b)): the clock set to twenty weekday moments and ten
    /// Shabbat ones across the seven cities — the app's own case runner (?lockCases=) sets each moment, and the server answers as
    /// of it, without a reload — and the screen must be on the page exactly on the Shabbat ones. These moments are
    /// shared/src/lockCases.ts's: worker/test/lockCases.test.ts holds this copy to it, and every expectation to hebcal. Then a
    /// cold open on a Shabbat moment: the screen, and nothing behind it.
    static let lockCases: [(Double, String, Bool)] = [
        (1794625200000, "brooklyn", true), // 2026-11-13T22:00 Friday night
        (1794675600000, "deal", true), // 2026-11-14T12:00 Shabbat noon
        (1795237200000, "los-angeles", true), // 2026-11-20T21:00 Friday night
        (1795298400000, "miami", true), // 2026-11-21T17:00 Shabbat afternoon — over in Brooklyn by now, not in Miami
        (1795870800000, "london", true), // 2026-11-28T13:00 Shabbat afternoon
        (1796414400000, "jerusalem", true), // 2026-12-04T22:00 Friday night
        (1796461200000, "tel-aviv", true), // 2026-12-05T11:00 Shabbat morning
        (1797084000000, "brooklyn", true), // 2026-12-12T09:00 Shabbat Chanukah morning
        (1797721200000, "los-angeles", true), // 2026-12-19T15:00 Shabbat afternoon, shortest days
        (1806130800000, "jerusalem", true), // 2027-03-27T10:00 the Shabbat after Israel springs forward
        (1794601800000, "brooklyn", false), // 2026-11-13T15:30 Friday afternoon, before candle lighting
        (1794697200000, "brooklyn", false), // 2026-11-14T18:00 Saturday night, after havdalah
        (1794837600000, "deal", false), // 2026-11-16T09:00 Monday morning
        (1794963600000, "brooklyn", false), // 2026-11-17T20:00 Tuesday night
        (1795024800000, "miami", false), // 2026-11-18T13:00 Wednesday
        (1795208400000, "miami", false), // 2026-11-20T16:00 Friday, an hour before candle lighting
        (1795370400000, "los-angeles", false), // 2026-11-22T10:00 Sunday morning
        (1795719600000, "tel-aviv", false), // 2026-11-26T21:00 Thursday night
        (1795788000000, "london", false), // 2026-11-27T14:00 Friday afternoon, before candle lighting
        (1795894200000, "london", false), // 2026-11-28T19:30 Saturday night, after havdalah
        (1796491800000, "jerusalem", false), // 2026-12-05T19:30 Saturday night, after havdalah
        (1796623200000, "tel-aviv", false), // 2026-12-07T08:00 Monday morning
        (1796857200000, "deal", false), // 2026-12-09T18:00 Wednesday evening, Chanukah
        (1797624000000, "los-angeles", false), // 2026-12-18T12:00 Friday noon
        (1798777800000, "brooklyn", false), // 2026-12-31T23:30 Thursday, the last night of the year
        (1799038800000, "jerusalem", false), // 2027-01-04T07:00 Monday morning
        (1805009400000, "brooklyn", false), // 2027-03-14T03:30 the night the US springs forward (a Sunday)
        (1806051600000, "tel-aviv", false), // 2027-03-26T12:00 the Friday Israel springs forward, before candle lighting
        (1806224400000, "london", false), // 2027-03-28T10:00 the Sunday Britain springs forward
        (1825565400000, "miami", false), // 2027-11-07T01:30 the night the US falls back (a Sunday)
    ]

    /// a phone IN that city: the zone it says to the server (the window is held to the phone's own calendar)
    static func lockZone(_ city: String) -> String {
        switch city {
        case "los-angeles": return "America/Los_Angeles"
        case "london": return "Europe/London"
        case "jerusalem", "tel-aviv": return "Asia/Jerusalem"
        default: return "America/New_York"
        }
    }

    func testShabbatLock() throws {
        let list = Self.lockCases.map { [$0.0, $0.1, Self.lockZone($0.1)] as [Any] }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        let b64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let (app, _) = launch(["-saStartURL", "https://scrollanytime.com/?lockCases=\(b64)"])
        pinCheck()
        var results: [[String: Any]] = []
        let finished = waitFor(420, every: 1) {
            results = (state()["lockCases"] as? [[String: Any]]) ?? []
            return !results.isEmpty
        }
        shot("lock-cases-end")
        if !finished || results.count != Self.lockCases.count {
            check("Shabbat lock: the screen appears on all ten Shabbat moments", false, "the case runner never finished (\(results.count) of \(Self.lockCases.count) in 420 s; route \(route()))")
            check("Shabbat lock: the screen appears on none of the twenty weekday moments", false, "the case runner never finished")
        } else {
            var shabbatOk = 0
            var weekdayOk = 0
            var wrong: [String] = []
            for (i, c) in Self.lockCases.enumerated() {
                let r = results[i]
                let locked = (r["locked"] as? Bool) ?? false
                let screen = r["screen"] as? String
                let place = r["place"] as? String ?? ""
                let words = screen.map { ($0.hasPrefix("Shabbat Shalom") || $0.hasPrefix("Chag Sameach")) && $0.contains("Scroll Anytime is resting.") && $0.contains("Back ") } ?? false
                let onTop = (r["onTop"] as? Bool) ?? false
                let ok = c.2 ? (locked && words && onTop && place == c.1) : (!locked && screen == nil && !onTop && place == c.1)
                if ok {
                    if c.2 { shabbatOk += 1 } else { weekdayOk += 1 }
                } else {
                    wrong.append("\(c.1) \(Int(c.0)): locked \(locked), screen \(screen ?? "none"), place \(place)")
                }
            }
            let tail = wrong.isEmpty ? "" : " · wrong: " + wrong.prefix(4).joined(separator: " · ")
            check("Shabbat lock: the screen appears on all ten Shabbat moments", shabbatOk == 10, "\(shabbatOk)/10\(tail)")
            check("Shabbat lock: the screen appears on none of the twenty weekday moments", weekdayOk == 20, "\(weekdayOk)/20\(tail)")
        }
        app.terminate()
        // a cold open on a Shabbat moment: the screen and nothing else
        let fri = Self.lockCases[0]
        let (app2, _) = launch(["-saStartURL", "https://scrollanytime.com/?lockAt=\(Int(fri.0))&lockCity=\(fri.1)&lockTz=\(Self.lockZone(fri.1))&lockNoExempt=1"])
        let rest = waitSeen("rest", 60)
        Thread.sleep(forTimeInterval: 3)
        shot("lock-shabbat")
        let played = firstPlay() > 0
        check("Shabbat lock: a cold open on Shabbat shows the screen and nothing else", rest != nil && !played && seen("welcome") == nil,
              rest == nil ? "no screen in 60 s (route \(route()))" : played ? "a clip played behind it" : seen("welcome") != nil ? "the welcome came up behind it" : "the screen, no clip, no onboarding")
        app2.terminate()
    }

    /// the app relaunched: still signed in, and no tip again
    func testRelaunch() throws {
        let (app, t0) = launch()
        signedInFeed(app, "still signed in after a relaunch", t0)
        Thread.sleep(forTimeInterval: 10)
        swipeUp(app)
        Thread.sleep(forTimeInterval: 6)
        let again = ["tip1", "tip2", "tip3"].filter { seen($0) != nil }
        shot("relaunch-no-tips")
        check("the tips never show again", again.isEmpty, again.isEmpty ? "16 s on the feed after a relaunch: no tip" : "shown again: \(again.joined(separator: ", "))")
        noWall("relaunch")
    }

    /// app deleted and installed, the Keychain kept: a fresh install reaches the feed signed in
    func testFreshInstallReturning() throws {
        let (app, t0) = launch()
        signedInFeed(app, "still signed in after a fresh install", t0)
        let at = firstPlay()
        let start = appStart(t0)
        let ms = at > 0 ? Int(at - start) : -1
        mark("fresh-feed", "\(ms)\t\(Int(start - t0))")
        check("a fresh install reaches the feed in under 4 s", at > 0 && ms < 4000, at > 0 ? "the first clip moved \(ms) ms after the app started (the test runner took \(Int(start - t0)) ms to start it)" : "no clip played")
        noWall("fresh install")
    }

    /// the runner's clock moved 48 hours ahead
    func testAfter48Hours() throws {
        let (app, t0) = launch()
        signedInFeed(app, "still signed in 48 hours later", t0)
        noWall("48 hours later")
    }

    /// the whole web data store wiped at launch (-saUITestWipeWebData)
    func testStorageWiped() throws {
        let (app, t0) = launch()
        signedInFeed(app, "still signed in after a storage wipe", t0)
        noWall("storage wipe")
    }

    /// Dynamic Type at its largest: no label clipped on the four tabs
    func testDynamicTypeXXXL() throws {
        let (app, _) = launch()
        _ = waitFor(90) { firstPlay() > 0 }
        var clipped: [String] = []
        for tab in ["Feed", "My Torah", "Rabbis", "Profile"] {
            if tab != "Feed" { tap(app, tab, type: .button, timeout: 10); Thread.sleep(forTimeInterval: 2.5) }
            shot("xxxl-\(tab)")
            do {
                try app.performAccessibilityAudit(for: [.textClipped]) { issue in
                    clipped.append("\(tab): \(issue.element?.label ?? "?") — \(issue.compactDescription)")
                    return true
                }
            } catch {
                clipped.append("\(tab): the audit failed (\(error.localizedDescription))")
            }
        }
        check("Dynamic Type xxxLarge clips no label", clipped.isEmpty, clipped.isEmpty ? "Feed, My Torah, Rabbis, Profile: no clipped text" : clipped.prefix(12).joined(separator: " · "))
    }

    /// iOS's first-use keyboard tip ("Speed up your typing by sliding your finger…") sits over the page with a
    /// "Continue" of its own the first time a fresh Simulator shows a keyboard: it goes before any page tap
    func keyboardTipOut() {
        let app = XCUIApplication(bundleIdentifier: Self.appId)
        let tip = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Speed up your typing'")).firstMatch
        guard tip.waitForExistence(timeout: 1.5) else { return }
        mark("keyboard-tip", "dismissed")
        let below = tip.frame.maxY
        if let b = app.buttons.matching(NSPredicate(format: "label == 'Continue'")).allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable && $0.frame.minY >= below }) {
            b.tap()
        } else {
            app.buttons["Continue"].firstMatch.tap()
        }
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// any system alert over the app (iOS's Apple Account answer, a permission prompt) closed the way a person would
    func dismissAlerts(_ app: XCUIApplication) {
        for _ in 0..<4 {
            var closed = false
            for target in [springboard, app] where target.alerts.firstMatch.exists {
                let alert = target.alerts.firstMatch
                for l in ["Close", "Cancel", "Not Now", "OK", "Don’t Allow", "Don't Allow"] where alert.buttons[l].exists {
                    mark("alert-closed", "\(alert.label) → \(l)")
                    alert.buttons[l].tap()
                    closed = true
                    break
                }
                if closed { break }
            }
            if !closed { return }
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    /// the More sheet (its "Copy link" row on show) dragged down by its handle, twice at most
    func closeMoreSheet(_ app: XCUIApplication) {
        for _ in 0..<2 {
            guard let row = find(app, "Copy link", type: .button, timeout: 2), row.isHittable else { return }
            mark("sheet-dragged", "more")
            point(app, 0.5, 0.2).press(forDuration: 0.1, thenDragTo: point(app, 0.5, 0.97))
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    /// a sheet or Moment a step left open would hide every later step: closed the way a person closes it
    func closeSheets(_ app: XCUIApplication) {
        dismissAlerts(app)
        for _ in 0..<3 {
            var closed = false
            // "Keep going" closes a Moment (the milestone's: deploy22's sixty counted the day and "One week." stood
            // over the feed for a minute, under the walk's swipes and a sampled dwell)
            for l in ["Done", "Close", "Not now", "Keep going", "Dismiss", "Cancel"] {
                let b = app.buttons.matching(NSPredicate(format: "label == %@", l)).firstMatch
                if b.exists && b.isHittable { b.tap(); closed = true; Thread.sleep(forTimeInterval: 0.8); break }
            }
            if !closed { return }
        }
    }

    // MARK: the walk's parts

    func googleHandoff(_ app: XCUIApplication) {
        guard tap(app, "Continue with Google", timeout: 15) else {
            check("Google sign-in opens Google and comes back", false, "no Continue with Google button on the welcome")
            return
        }
        var steps: [String] = []
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 12) {
            steps.append("iOS asked: \(alert.label)")
            shot("google-ask")
            for l in ["Continue", "Allow"] where alert.buttons[l].exists { alert.buttons[l].tap(); break }
        }
        let svc = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let google = NSPredicate(format: "label CONTAINS[c] 'google' OR value CONTAINS[c] 'google'")
        let reached = waitFor(30, every: 1) { svc.descendants(matching: .any).matching(google).firstMatch.exists || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'accounts.google.com'")).firstMatch.exists }
        steps.append(reached ? "Google's page was on screen" : "Google's page never showed")
        shot("google-sheet")
        var closed = false
        for target in [svc, app] {
            for l in ["Cancel", "Close", "Done"] where target.buttons[l].exists { target.buttons[l].tap(); closed = true; break }
            if closed { break }
        }
        if !closed { app.activate() }
        let back = app.wait(for: .runningForeground, timeout: 10) && waitFor(15) { seen("googleFail") != nil || find(app, "Continue with email", timeout: 1) != nil }
        shot("google-back")
        steps.append(back ? "back in the app" : "the app did not come back")
        check("Google sign-in opens Google and comes back", reached && back, steps.joined(separator: "; "))
    }

    func appleHandoff(_ app: XCUIApplication) {
        guard tap(app, "Sign in with Apple", timeout: 8) else {
            check("Apple sign-in opens Apple's sheet and comes back", false, "no Sign in with Apple button on the welcome")
            return
        }
        // iOS's own answer can take its time on a slow runner (run 202611031017: it came after 4 s, was never closed, and
        // sat over the welcome for the rest of the walk): watched for up to 20 s
        let apple = NSPredicate(format: "label CONTAINS[c] 'Apple Account' OR label CONTAINS[c] 'Apple ID' OR label CONTAINS[c] 'iCloud' OR label CONTAINS[c] 'Sign in with Apple' OR label CONTAINS[c] 'Sign In with Apple'")
        var sheet = ""
        waitFor(20, every: 0.5) {
            if springboard.alerts.firstMatch.exists { sheet = "iOS: \(springboard.alerts.firstMatch.label)" }
            else if app.alerts.firstMatch.exists { sheet = "iOS: \(app.alerts.firstMatch.label)" }
            else if let e = springboard.descendants(matching: .any).matching(apple).allElementsBoundByIndex.first(where: { $0.exists }) { sheet = "iOS: \(e.label)" }
            else if app.sheets.firstMatch.exists { sheet = "a system sheet over the app" }
            return !sheet.isEmpty
        }
        shot("apple-sheet")
        dismissAlerts(app)
        if app.state != .runningForeground { app.activate() }
        let back = waitFor(15) { !springboard.alerts.firstMatch.exists && !app.alerts.firstMatch.exists && find(app, "Continue with email", timeout: 1) != nil }
        shot("apple-back")
        check("Apple sign-in opens Apple's sheet and comes back", !sheet.isEmpty && back, "\(sheet.isEmpty ? "no Apple sheet was seen" : sheet); \(back ? "back in the app" : "the app did not come back")")
    }

    func whatsApp(_ app: XCUIApplication) {
        guard let w = find(app, "Send to WhatsApp", begins: true, type: .button, timeout: 10) else {
            check("WhatsApp share", false, "no WhatsApp button on the rail")
            return
        }
        w.tap()
        // no WhatsApp on a Simulator: the shell opens wa.me in Safari, with the clip's link in it
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let opened = safari.wait(for: .runningForeground, timeout: 20)
        var url = ""
        if opened {
            Thread.sleep(forTimeInterval: 3)
            url = safari.textFields.firstMatch.exists ? String(describing: safari.textFields.firstMatch.value ?? "") : ""
            if url.isEmpty, let b = safari.buttons.matching(NSPredicate(format: "label CONTAINS 'wa.me' OR value CONTAINS 'wa.me' OR label CONTAINS 'whatsapp'")).allElementsBoundByIndex.first { url = b.label }
        }
        shot("whatsapp")
        mark("whatsapp", url)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 1.5)
        check("WhatsApp share", opened, opened ? "WhatsApp's send page opened (\(url.isEmpty ? "Safari, wa.me" : url))" : "nothing opened")
    }

    func myTorah(_ app: XCUIApplication) {
        guard tap(app, "My Torah", type: .button, timeout: 10) else {
            check("the saved clip appears in My Torah", false, "no My Torah tab")
            return
        }
        Thread.sleep(forTimeInterval: 3)
        // A MOMENT THAT CAME AFTER THE TAP IS CLOSED, AS A PERSON CLOSES IT (deploy21, 2026-11-08): the run began on a
        // New York Shabbat and crossed midnight into Sunday, so the tour's clip COUNTED and its clip end opened the
        // reminder ask ("Day 12. ... Want a reminder tomorrow?") over My Torah; the walk read the Moment as the page and
        // every later step lost the tab bar under it. "Not now", then the tab again.
        if find(app, "Not now", type: .button, timeout: 1) != nil {
            mark("moment-closed", "my-torah")
            closeSheets(app)
            tap(app, "My Torah", type: .button, timeout: 8)
            Thread.sleep(forTimeInterval: 3)
        }
        shot("my-torah")
        // the Saved section's tiles: each is a button named by the clip's title (or its rabbi)
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Saved'")).firstMatch
        var tiles: [String] = []
        if saved.waitForExistence(timeout: 10) {
            let below = saved.frame.maxY
            tiles = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.frame.minY > below && $0.frame.minY < below + 420 && !$0.label.isEmpty }.map { $0.label }.prefix(8).map { $0 }
        }
        mark("my-torah", tiles.joined(separator: " | "))
        check("the saved clip appears in My Torah", !tiles.isEmpty && seen("myTorah") == nil, tiles.isEmpty ? "My Torah shows no saved clip" : "Saved: \(tiles.prefix(3).joined(separator: " | "))")
        tap(app, "Feed", type: .button, timeout: 8)
        Thread.sleep(forTimeInterval: 2)
    }

    /// the tab bar's four buttons, read once
    func tabs(_ app: XCUIApplication) -> [String: CGRect] {
        // a Moment or sheet that opened at a clip's end covers the tab bar: closed first, as a person would
        closeSheets(app)
        var out: [String: CGRect] = [:]
        for t in ["Feed", "My Torah", "Rabbis", "Profile"] {
            if let e = find(app, t, type: .button, timeout: 8) { out[t] = e.frame }
        }
        return out
    }

    func navStep(_ seq: String, _ step: String, _ want: @escaping (String) -> Bool, _ wantWords: String, _ results: inout [String], _ ok: inout Bool) {
        let got = waitRoute(6) { want($0) }
        let pass = want(got)
        if !pass { ok = false }
        results.append("\(seq) \(step) → \(got.isEmpty ? "?" : got)\(pass ? "" : " (want \(wantWords))")")
        mark("nav", "\(seq) \(step) \(got)")
    }

    func backOnScreen(_ app: XCUIApplication) -> Bool {
        if let b = find(app, "Back", type: .button, timeout: 8) { b.tap(); Thread.sleep(forTimeInterval: 1.2); return true }
        return false
    }

    func openFirstRabbiCard(_ app: XCUIApplication) -> Bool {
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".+, [0-9]+ clips?$"))
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if let e = card.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { e.tap(); Thread.sleep(forTimeInterval: 1.5); return true }
            Thread.sleep(forTimeInterval: 0.6)
        } while Date() < deadline
        return false
    }

    /// "Try again" taps the rabbi page needed, named in the check's detail (never hidden)
    var pageRetries: [String] = []
    func openFirstClipTile(_ app: XCUIApplication) -> Bool {
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".+, [0-9]+:[0-9]{2}$"))
        // 30 s on the runner: the rabbi page's tiles come late on the VM (nav G found none in 15 s, nav A took 9 s)
        let deadline = Date().addingTimeInterval(30)
        // A REQUEST THE VM DROPPED IS TRIED AGAIN, ONCE, AS A PERSON WOULD (deploy20, 2026-11-08): Rabbi Ariel Mizrahi's
        // page answered "Couldn't load this rabbi." with its Try again (the app's own state for a failed request; the
        // route is unchanged in that build and live answered it in 0.26 s) and the walk waited 30 s for tiles that
        // could not come. One tap on Try again; a second failure still fails the check.
        var retried = false
        repeat {
            if !retried, let again = app.buttons.matching(NSPredicate(format: "label == 'Try again'")).allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                retried = true
                pageRetries.append(route())
                mark("page-retry", route())
                again.tap()
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }
            if let e = tile.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                e.tap()
                // a tile tap the page dropped (deploy9: the route stayed on the rabbi) is tapped once more
                if !waitFor(4, { route().contains("/watch") }), e.exists, e.isHittable { e.tap() }
                Thread.sleep(forTimeInterval: 1.5)
                return true
            }
            Thread.sleep(forTimeInterval: 0.6)
        } while Date() < deadline
        return false
    }

    /// the rabbi's name on the clip in view: the rail's avatar is a button named by the rabbi
    func openRabbiFromClip(_ app: XCUIApplication) -> Bool {
        let rail = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable && $0.frame.minX > app.frame.width * 0.72 }
        let skip: Set<String> = ["Save", "Unsave", "More options", "More"]
        if let avatar = rail.first(where: { !skip.contains($0.label) && !$0.label.hasPrefix("Send to WhatsApp") && !$0.label.hasPrefix("Tap to send") && !$0.label.hasPrefix("Follow ") && !$0.label.isEmpty }) {
            avatar.tap()
            Thread.sleep(forTimeInterval: 1.5)
            return true
        }
        return false
    }

    func navigation(_ app: XCUIApplication) {
        let t = tabs(app)
        guard let rabbisTab = t["Rabbis"], let feedTab = t["Feed"] else {
            check("Rabbis → rabbi → clip → Back ×3 lands on Feed", false, "the tab bar was not found")
            return
        }
        let isFeed: (String) -> Bool = { $0 == "/" || $0.hasPrefix("/?") }
        let isRabbis: (String) -> Bool = { $0 == "/rabbis" }
        let isRabbi: (String) -> Bool = { $0.hasPrefix("/rabbi/") && !$0.contains("/watch") }
        let isWatch: (String) -> Bool = { $0.hasPrefix("/rabbi/") && $0.contains("/watch") }

        // A · Rabbis → a rabbi → a clip → Back → Back → Back
        var r: [String] = []
        var ok = true
        tapAt(app, rabbisTab); navStep("A", "Rabbis tab", isRabbis, "/rabbis", &r, &ok)
        if openFirstRabbiCard(app) { navStep("A", "a rabbi", isRabbi, "/rabbi/<slug>", &r, &ok) } else { ok = false; r.append("A no rabbi card") }
        if openFirstClipTile(app) { navStep("A", "a clip", isWatch, "the clip", &r, &ok) } else { ok = false; r.append("A no clip tile") }
        shot("nav-A-clip")
        if backOnScreen(app) { navStep("A", "Back 1", isRabbi, "the rabbi", &r, &ok) } else { ok = false; r.append("A no Back 1") }
        if backOnScreen(app) { navStep("A", "Back 2", isRabbis, "Rabbis", &r, &ok) } else { ok = false; r.append("A no Back 2") }
        if backOnScreen(app) { navStep("A", "Back 3", isFeed, "the Feed", &r, &ok) } else if isRabbis(route()) {
            // a tab's ROOT has no Back of its own (B-006, shared/src/navStack.ts: the on-screen Back is one step toward the
            // root; from the root the tab bar is the way, and the system Back goes to the Feed tab) — the stack is right
            r.append("A the Rabbis root: no Back (a tab's root)")
        } else {
            ok = false; r.append("A no Back, and not on the Rabbis root: \(route())")
        }
        shot("nav-A-end")
        if !pageRetries.isEmpty { r.append("the rabbi page said it could not load, Try again tapped once (\(pageRetries.joined(separator: ", ")))"); pageRetries = [] }
        check("Rabbis → rabbi → clip → Back ×3 lands on Feed", ok, r.joined(separator: " · "))
        if !isFeed(route()) { tapAt(app, feedTab); Thread.sleep(forTimeInterval: 1.5) }

        // B · Feed → the rabbi's name on the clip → a clip → Back → Back
        r = []; ok = true
        if openRabbiFromClip(app) { navStep("B", "the rabbi's name", isRabbi, "/rabbi/<slug>", &r, &ok) } else { ok = false; r.append("B no rabbi on the clip") }
        if openFirstClipTile(app) { navStep("B", "a clip", isWatch, "the clip", &r, &ok) } else { ok = false; r.append("B no clip tile") }
        if backOnScreen(app) { navStep("B", "Back 1", isRabbi, "the rabbi", &r, &ok) } else { ok = false; r.append("B no Back 1") }
        if backOnScreen(app) { navStep("B", "Back 2", isFeed, "the Feed", &r, &ok) } else { ok = false; r.append("B no Back 2") }
        shot("nav-B-end")
        if !pageRetries.isEmpty { r.append("the rabbi page said it could not load, Try again tapped once (\(pageRetries.joined(separator: ", ")))"); pageRetries = [] }
        check("Feed → rabbi → clip → Back ×2 lands on Feed", ok, r.joined(separator: " · "))
        if !isFeed(route()) { tapAt(app, feedTab); Thread.sleep(forTimeInterval: 1.5) }

        // E · Rabbis → a rabbi → Feed tab → Rabbis tab (the rabbi kept) → Rabbis tab again (its root)
        r = []; ok = true
        tapAt(app, rabbisTab); navStep("E", "Rabbis tab", isRabbis, "/rabbis", &r, &ok)
        if openFirstRabbiCard(app) { navStep("E", "a rabbi", isRabbi, "/rabbi/<slug>", &r, &ok) } else { ok = false; r.append("E no rabbi card") }
        tapAt(app, feedTab); navStep("E", "Feed tab", isFeed, "the Feed", &r, &ok)
        tapAt(app, rabbisTab); navStep("E", "Rabbis tab again: the rabbi kept", isRabbi, "the rabbi", &r, &ok)
        tapAt(app, rabbisTab); navStep("E", "Rabbis tab on it: its root", isRabbis, "/rabbis", &r, &ok)
        shot("nav-E-end")
        check("Rabbis keeps its place across tabs and resets on a second tap", ok, r.joined(separator: " · "))

        // G · Rabbis → a rabbi → a clip → the rabbi's name on it → Back → Back (never the clip again)
        r = []; ok = true
        if openFirstRabbiCard(app) { navStep("G", "a rabbi", isRabbi, "/rabbi/<slug>", &r, &ok) } else { ok = false; r.append("G no rabbi card") }
        if openFirstClipTile(app) { navStep("G", "a clip", isWatch, "the clip", &r, &ok) } else { ok = false; r.append("G no clip tile") }
        if openRabbiFromClip(app) { navStep("G", "the name on the clip", isRabbi, "the rabbi", &r, &ok) } else { ok = false; r.append("G no rabbi on the clip") }
        if backOnScreen(app) { navStep("G", "Back 1: not the clip again", isRabbis, "Rabbis", &r, &ok) } else { ok = false; r.append("G no Back 1") }
        if backOnScreen(app) { navStep("G", "Back 2", isFeed, "the Feed", &r, &ok) } else if isRabbis(route()) {
            r.append("G the Rabbis root: no Back (a tab's root)") // B-006: a tab root has no Back of its own
        } else { ok = false; r.append("G no Back 2, and not on the Rabbis root: \(route())") }
        shot("nav-G-end")
        if !pageRetries.isEmpty { r.append("the rabbi page said it could not load, Try again tapped once (\(pageRetries.joined(separator: ", ")))"); pageRetries = [] }
        check("rabbi → clip → its rabbi → Back never returns to the clip", ok, r.joined(separator: " · "))
        if !isFeed(route()) { tapAt(app, feedTab); Thread.sleep(forTimeInterval: 1.5) }
    }

    func parsha(_ app: XCUIApplication) {
        closeSheets(app)
        guard tap(app, "Parsha", timeout: 10) else {
            check("Parsha shows this week's parsha with at least 3 clips", false, "no Parsha tab")
            return
        }
        let note = waitSeen("parsha", 20)
        var label = ""
        if let e = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Parashat '")).allElementsBoundByIndex.first(where: { $0.exists }) { label = e.label }
        shot("parsha")
        let n0 = loads()
        for _ in 1...3 { swipeUp(app); Thread.sleep(forTimeInterval: 3) }
        let played = loads() - n0
        mark("parsha", "\(label)\t\(played + 1)")
        shot("parsha-3")
        // the week's name is checked against the server's (scripts/gate/run.mjs): here, that it says one and plays
        check("Parsha shows this week's parsha with at least 3 clips", note != nil && played >= 2, "\(label.isEmpty ? (note != nil ? "a Parashat line" : "no Parashat line") : label); \(played + 1) clips played")
        tap(app, "For you", timeout: 8)
        Thread.sleep(forTimeInterval: 2)
    }

    func rail(_ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 1)
        let w = app.frame.width
        closeSheets(app)
        let kinds: [XCUIElement.ElementType] = [.button, .toggle, .switch, .link]
        let rail = app.descendants(matching: .any).allElementsBoundByIndex.filter { kinds.contains($0.elementType) && $0.exists && $0.isHittable && $0.frame.minX > w * 0.72 && $0.frame.minY > app.frame.height * 0.3 }
        let labels = rail.map { $0.label }
        let hasSave = labels.contains { $0 == "Save" || $0 == "Unsave" }
        let hasMore = labels.contains("More options")
        let hasWA = labels.contains { $0.hasPrefix("Send to WhatsApp") || $0.hasPrefix("Tap to send") }
        let hasName = labels.contains { !$0.isEmpty && !["Save", "Unsave", "More options"].contains($0) && !$0.hasPrefix("Send to WhatsApp") && !$0.hasPrefix("Follow ") }
        let unnamed = rail.filter { $0.label.trimmingCharacters(in: .whitespaces).isEmpty }.count
        var issues: [String] = []
        do {
            try app.performAccessibilityAudit(for: [.sufficientElementDescription]) { issue in
                if let f = issue.element?.frame, f.minX > w * 0.72 { issues.append("\(issue.element?.label ?? "?"): \(issue.compactDescription)") }
                return true
            }
        } catch {
            issues.append("the audit failed: \(error.localizedDescription)")
        }
        shot("rail")
        let ok = hasSave && hasMore && hasWA && hasName && unnamed == 0 && issues.isEmpty
        check("VoiceOver reads the rail", ok, "the rail reads: \(labels.joined(separator: " · "))\(unnamed > 0 ? "; \(unnamed) unnamed" : "")\(issues.isEmpty ? "" : "; audit: \(issues.prefix(6).joined(separator: " · "))")")
    }

    // MARK: notch — the Rabbis search header and the status bar (the owner, 2026-11-04)

    /// "On the Rabbis tab, scroll to the bottom and assert the search bar's top edge is at or below the status bar on an
    /// iPhone 15 Pro and an iPhone SE, with a screenshot of each." gate-walk.sh runs this once on each of those two
    /// Simulators. It is a layout check, not a person's first open: the page runs as a guest the test mints itself (the
    /// suites' storage flags, -saUITest; deleted after), opened straight on /rabbis, every request still through the pin.
    func testRabbisHeaderNotch() throws {
        // gate-walk.sh names its Simulators "gate-notch-<device>"
        let dev = (env["SIMULATOR_DEVICE_NAME"] ?? "?").replacingOccurrences(of: "gate-notch-", with: "")
        let model = env["SIMULATOR_MODEL_IDENTIFIER"] ?? "?"
        // the status bar's height on each device (its safe-area inset, points): the Dynamic Island phones 59 (16 Pro: 62),
        // the Home-button SE 20
        let insets: [String: Double] = ["iPhone16,1": 59, "iPhone16,2": 59, "iPhone15,4": 59, "iPhone15,5": 59, "iPhone17,1": 62, "iPhone17,2": 62,
                                        "iPhone17,3": 59, "iPhone17,4": 59, "iPhone14,6": 20, "iPhone12,8": 20]
        let statusBar = insets[model] ?? (dev.contains("SE") ? 20 : 59)
        let label = "\(dev)"
        var token: String?
        defer { if let token { _ = try? notchHTTP("DELETE", "/me", token: token) } }
        let (ms, minted) = try notchHTTP("POST", "/auth/guest", body: Data("{}".utf8))
        guard (200..<300).contains(ms), let o = (try? JSONSerialization.jsonObject(with: minted)) as? [String: Any],
              let t = o["token"] as? String, let user = o["user"],
              let ud = try? JSONSerialization.data(withJSONObject: user) else {
            check("\(label): the Rabbis search bar stays below the status bar", false, "the test's guest could not be minted (\(ms))")
            return
        }
        token = t
        let (app, _) = launch(["-saUITest", "-saUITestToken", t, "-saUITestUser", String(decoding: ud, as: UTF8.self),
                               "-saStartURL", "https://scrollanytime.com/rabbis?app=ios"])
        mark("notch", "\(dev) \(model) status bar \(Int(statusBar)) pt")
        let pill = app.buttons.matching(NSPredicate(format: "label == %@", "Search rabbis, topics, words")).firstMatch
        // A REQUEST THE VM DROPPED IS TRIED AGAIN, ONCE, AS A PERSON WOULD (deploy21, 2026-11-08): the iPhone 15 Pro's
        // page answered "Couldn't load the rabbis." with its Retry (the app's own state for a failed request) while the
        // proxy waited 107 s for the first byte of the wall's previews; live answered the same requests in 0.12 s. One tap
        // on Retry, named in the check's detail; a second failure still fails.
        var retriedNote = ""
        let pillUp = waitFor(90, every: 1) {
            if pill.exists { return true }
            if retriedNote.isEmpty, let again = app.buttons.matching(NSPredicate(format: "label == 'Retry' OR label == 'Try again'")).allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                retriedNote = " · the page said it could not load the rabbis, Retry tapped once"
                mark("page-retry", "/rabbis")
                again.tap()
            }
            return false
        }
        guard pillUp else {
            shot("notch-\(dev)-no-wall")
            check("\(label): the Rabbis search bar stays below the status bar", false, "the Rabbis page never showed its search bar in 90 s")
            return
        }
        Thread.sleep(forTimeInterval: 2)
        let top0 = pill.frame.minY
        shot("notch \(dev) top")
        // to the bottom: swipe until the last row of the page ("Don't see your rabbi? Ask for him.") is on screen, then
        // twice more so the list rests against its end
        let last = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "see your rabbi")).firstMatch
        // on screen by its frame: web content keeps every element in the tree, and the floating tab bar can make a row
        // read as not hittable
        let screenH = app.frame.height
        let onScreen = { () -> Bool in last.exists && last.frame.minY >= 0 && last.frame.maxY <= screenH && last.frame.height > 0 }
        // the search bar is read after EVERY swipe on the way down, not only at the end: the bug the owner saw is in the
        // middle of the scroll (the old build's pill slid under the clock and a bar faded in only once it had left)
        var swipes = 0
        var lowest = top0
        var lowestAt = 0
        let sample = { (i: Int) in
            let y = pill.exists ? pill.frame.minY : -999
            if y < lowest { lowest = y; lowestAt = i }
        }
        while swipes < 60 && !onScreen() {
            app.swipeUp()
            swipes += 1
            sample(swipes)
        }
        let reached = onScreen()
        for i in 0..<2 { app.swipeUp(velocity: .fast); sample(swipes + i + 1) }
        Thread.sleep(forTimeInterval: 2)
        let f = pill.frame
        sample(swipes + 3)
        shot("notch \(dev) bottom")
        let below = f.minY >= statusBar - 0.5 && lowest >= statusBar - 0.5
        let still = abs(f.minY - top0) <= 1
        let numbers = "status bar \(Int(statusBar)) pt (\(model)); the search bar's top edge at \(String(format: "%.1f", f.minY)) pt at the bottom of the list (\(String(format: "%.1f", top0)) at the top, lowest \(String(format: "%.1f", lowest)) after swipe \(lowestAt)), \(swipes + 2) swipes\(retriedNote)"
        check("\(label): the Rabbis search bar stays below the status bar", reached && below,
              reached ? numbers : "the bottom of the list was never reached in \(swipes) swipes; \(numbers)")
        check("\(label): the Rabbis search bar never moves on scroll", reached && still, numbers)
    }

    func notchHTTP(_ method: String, _ path: String, token: String? = nil, body: Data? = nil) throws -> (Int, Data) {
        var last: Error?
        // a freshly booted Simulator can fail TLS (-1200) for its first minute or two: keep asking
        for attempt in 0..<8 {
            if attempt > 0 { Thread.sleep(forTimeInterval: attempt < 3 ? 3 : 12) }
            var req = URLRequest(url: URL(string: "https://scrollanytime.com" + path)!)
            req.httpMethod = method
            req.timeoutInterval = 30
            // the shell's marker: Ops files this guest under Test suite, never as a person
            req.setValue("ScrollAnytime-XCUITest SAUITest", forHTTPHeaderField: "User-Agent")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let sem = DispatchSemaphore(value: 0)
            var result: (Int, Data)?
            URLSession.shared.dataTask(with: req) { data, response, error in
                if let error { last = error } else { result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
                sem.signal()
            }.resume()
            if sem.wait(timeout: .now() + 40) == .timedOut { last = URLError(.timedOut); continue }
            if let result, result.0 < 500 { return result }
        }
        throw last ?? URLError(.badServerResponse)
    }
}
