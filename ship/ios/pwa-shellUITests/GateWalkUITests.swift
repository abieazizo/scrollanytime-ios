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
        ["myTorah", "Tap Save on any clip to keep it here."],
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
        app.launchArguments = ["-saGate", "-saGateDir", dir, "-saGateWatch", Self.watchJSON] + flags + extra
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

    func signedInFeed(_ app: XCUIApplication, _ name: String, _ t0: Double) {
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

        // 2 · Google: the system sheet opens at Google, and closing it comes back to the app
        googleHandoff(app)
        // 3 · Apple
        appleHandoff(app)

        // 4 · email, through the real email step
        var signedIn = false
        if email.isEmpty || code.isEmpty {
            check("sign in with email", false, "this build has no gate address to sign in with (the run's marker named none)")
        } else if tap(app, "Continue with email", timeout: 20) {
            let field = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "you@example.com")).firstMatch
            if field.waitForExistence(timeout: 15) {
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
            if waitSeen("seder", 10) != nil {
                shot("seder")
                tap(app, "No limit", begins: true, timeout: 8)
            }
            _ = waitSeen("building", 15)
            shot("building")
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
        if tip2 != nil { point(app, 0.82, 0.5).press(forDuration: 1.3) }
        if tip2 != nil { Thread.sleep(forTimeInterval: 0.6); swipeUp(app) }
        let tip3 = waitSeen("tip3", 15)
        shot("tip-3")
        if tip3 != nil {
            if let save = find(app, "Save", timeout: 10) { save.tap() }
        }
        let allSet = waitSeen("allset", 10)
        shot("tips-done")
        check("the three onboarding tips show", tip1 != nil && tip2 != nil && tip3 != nil, "tip 1 \(tip1 != nil ? "shown" : "MISSING"), tip 2 \(tip2 != nil ? "shown" : "MISSING"), tip 3 \(tip3 != nil ? "shown" : "MISSING"), all set \(allSet != nil ? "shown" : "not seen")")
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
            Thread.sleep(forTimeInterval: 2.4)
            if loads() == n0 { stuck += 1 } else { stuck = 0 }
            if i == 1 || i == 30 || i == 60 { shot("clip-\(i)") }
            if stuck >= 4 {
                shot("scroll-stuck-\(i)")
                mark("scroll-stuck", "at swipe \(i), route \(route())")
                // something is over the feed (a sheet, a Moment): close it the way a person would
                for l in ["Not now", "Close", "Done", "Dismiss"] where tap(app, l, timeout: 1) { break }
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
        let ask = waitSeen("ask", 20)
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
        if let save = find(app, "Save", timeout: 10) {
            save.tap()
            savedOK = find(app, "Unsave", timeout: 8) != nil
        }
        shot("saved")
        check("Save", savedOK, savedOK ? "the rail says Unsave" : "the rail never said Unsave")
        mark("saved-at", "\(Int(now()))")
        if let more = find(app, "More options", type: .button, timeout: 10) {
            more.tap()
            if tap(app, "Save to Photos", timeout: 10) {
                let saw = waitSeen("photos", 150)
                shot("photos")
                check("Save to Photos", saw != nil, saw != nil ? "“Saved to Photos”" : "no “Saved to Photos” in 150 s")
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
        noWall("the walk")
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

    /// a sheet or Moment a step left open would hide every later step: closed the way a person closes it
    func closeSheets(_ app: XCUIApplication) {
        for _ in 0..<3 {
            var closed = false
            for l in ["Done", "Close", "Not now", "Dismiss", "Cancel"] {
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
        Thread.sleep(forTimeInterval: 4)
        shot("apple-sheet")
        let apple = NSPredicate(format: "label CONTAINS[c] 'Apple Account' OR label CONTAINS[c] 'Apple ID' OR label CONTAINS[c] 'iCloud' OR label CONTAINS[c] 'Sign in with Apple' OR label CONTAINS[c] 'Sign In with Apple'")
        var sheet = ""
        if springboard.alerts.firstMatch.exists { sheet = "iOS: \(springboard.alerts.firstMatch.label)" }
        else if let e = springboard.descendants(matching: .any).matching(apple).allElementsBoundByIndex.first(where: { $0.exists }) { sheet = "iOS: \(e.label)" }
        else if app.sheets.firstMatch.exists || app.alerts.firstMatch.exists { sheet = "a system sheet over the app" }
        var closed = false
        for target in [springboard, app] {
            for l in ["Cancel", "Close", "Not Now", "OK"] where target.buttons[l].exists { target.buttons[l].tap(); closed = true; break }
            if closed { break }
        }
        if !closed { app.activate() }
        let back = waitFor(15) { seen("appleFail") != nil || find(app, "Continue with email", timeout: 1) != nil }
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

    func openFirstClipTile(_ app: XCUIApplication) -> Bool {
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".+, [0-9]+:[0-9]{2}$"))
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if let e = tile.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { e.tap(); Thread.sleep(forTimeInterval: 1.5); return true }
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
        if backOnScreen(app) { navStep("A", "Back 3", isFeed, "the Feed", &r, &ok) } else {
            // the Rabbis root has no Back of its own on some builds: the system Back (edge) is off in the shell
            ok = false; r.append("A no Back on the Rabbis root")
        }
        shot("nav-A-end")
        check("Rabbis → rabbi → clip → Back ×3 lands on Feed", ok, r.joined(separator: " · "))
        if !isFeed(route()) { tapAt(app, feedTab); Thread.sleep(forTimeInterval: 1.5) }

        // B · Feed → the rabbi's name on the clip → a clip → Back → Back
        r = []; ok = true
        if openRabbiFromClip(app) { navStep("B", "the rabbi's name", isRabbi, "/rabbi/<slug>", &r, &ok) } else { ok = false; r.append("B no rabbi on the clip") }
        if openFirstClipTile(app) { navStep("B", "a clip", isWatch, "the clip", &r, &ok) } else { ok = false; r.append("B no clip tile") }
        if backOnScreen(app) { navStep("B", "Back 1", isRabbi, "the rabbi", &r, &ok) } else { ok = false; r.append("B no Back 1") }
        if backOnScreen(app) { navStep("B", "Back 2", isFeed, "the Feed", &r, &ok) } else { ok = false; r.append("B no Back 2") }
        shot("nav-B-end")
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
        if backOnScreen(app) { navStep("G", "Back 2", isFeed, "the Feed", &r, &ok) } else { ok = false; r.append("G no Back 2") }
        shot("nav-G-end")
        check("rabbi → clip → its rabbi → Back never returns to the clip", ok, r.joined(separator: " · "))
        if !isFeed(route()) { tapAt(app, feedTab); Thread.sleep(forTimeInterval: 1.5) }
    }

    func parsha(_ app: XCUIApplication) {
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
}
