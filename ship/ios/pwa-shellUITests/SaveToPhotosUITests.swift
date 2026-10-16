import XCTest
import Photos
import AVFoundation

/// SAVE TO PHOTOS, PROVED (the owner's spec of 2026-10-14, Part 4). The real shell, on the Simulator,
/// against the live site: open a feed clip, tap More → "Save to Photos", and read the photo library
/// afterwards. Three paths, one per test, each started by ship/ios/uitest-photos.sh with the app's Photos
/// permission set beforehand (`simctl privacy`):
///
///   testFirstTimePermission   never asked → iOS asks once (add-only) → Allow → "Saved to Photos" →
///                             one new video in the library, as long as the file
///   testAlreadyGranted        granted → no prompt → a second tap while it saves changes nothing → one
///                             new video, as long as the file
///   testDenied                denied → no prompt, no video → "Allow Scroll Anytime to save to Photos"
///                             with Open Settings, which opens Settings
///
/// The test picks the clip through the API the app uses (a guest of its own, deleted afterwards), and
/// measures the file a save of that clip downloads (`GET /clips/:id/photos`) itself — "the right
/// duration" is that file's, read independently of the app.
final class SaveToPhotosUITests: XCTestCase {
    static let origin = "https://scrollanytime.com"
    static let appId = "com.scrollanytime.app"
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private var token: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // the test's guest leaves with the test (the app signed in as it)
        if let token { _ = try? http("DELETE", "/me", token: token) }
    }

    // MARK: the three paths

    func testFirstTimePermission() throws {
        let pick = try pickClip()
        let before = try libraryVideos()
        let app = try openMoreSheet(pick)
        tapSaveToPhotos(app)
        // iOS asks once, add-only. Its words name Photos; its yes is "Allow" (or "OK" on some releases).
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "iOS did not ask for Photos access on the first save")
        note("the system asked: \(alert.label) — buttons: \(alert.buttons.allElementsBoundByIndex.map { $0.label })")
        attach("first-time-prompt")
        XCTAssertTrue(alert.label.localizedCaseInsensitiveContains("photo"), "the prompt is not about Photos: \(alert.label)")
        let allow = ["Allow", "OK", "Allow Access"].lazy.map { alert.buttons[$0] }.first { $0.exists }
        XCTAssertNotNil(allow, "no Allow button on the prompt")
        allow?.tap()
        try expectSaved(app, before: before, pick: pick, name: "first-time")
    }

    func testAlreadyGranted() throws {
        let pick = try pickClip()
        let before = try libraryVideos()
        let app = try openMoreSheet(pick)
        // two taps 0.15 s apart: the second lands while the first is still downloading (a save needs the
        // file first), and must do nothing — one video, not two. (Waiting to SEE "Saving to Photos…"
        // first raced a 3-second save: run 38645674476's late tap started a second, legitimate save.)
        Thread.sleep(forTimeInterval: 0.8)
        // a fixed point on the screen, read once: an element-bound coordinate looks the row up again by its
        // label at every press, and after the first press the row reads "Saving to Photos…" (run 38654180561)
        let frame = saveRow(app).frame
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        point.press(forDuration: 0.15)
        point.press(forDuration: 0.15)
        note("tapped Save to Photos twice, the second while the first was saving")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2), "iOS asked although access was already granted")
        try expectSaved(app, before: before, pick: pick, name: "granted")
    }

    func testDenied() throws {
        let pick = try pickClip()
        let before = try libraryVideos()
        let app = try openMoreSheet(pick)
        tapSaveToPhotos(app)
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 3), "iOS asked although access was denied — it only ever asks once")
        let sheet = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Allow Scroll Anytime to save to Photos'")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "the Settings sheet did not appear after a denied save")
        attach("denied-sheet")
        let open = app.descendants(matching: .button).matching(NSPredicate(format: "label == 'Open Settings'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the sheet has no Open Settings button")
        open.press(forDuration: 0.15)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "Open Settings did not open Settings")
        attach("denied-settings")
        let after = try libraryVideos()
        XCTAssertEqual(after.count, before.count, "a video reached the library although access was denied")
        settings.terminate()
    }

    // MARK: the app

    private func openMoreSheet(_ pick: Pick) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.appId)
        app.launchArguments = ["-saUITest", "-saUITestToken", pick.token, "-saUITestUser", pick.userJSON, "-saStartURL", "\(Self.origin)/?app=ios&start=\(pick.clipId)"]
        app.launch()
        // the feed is up when its More button is there and on screen
        let more = app.descendants(matching: .button).matching(NSPredicate(format: "label == 'More options'"))
        let deadline = Date().addingTimeInterval(120)
        var target: XCUIElement?
        while Date() < deadline, target == nil {
            target = more.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            if target == nil { Thread.sleep(forTimeInterval: 1) }
        }
        guard target != nil else {
            attach("feed")
            XCTFail("the feed never showed a More button (120 s)")
            throw NoFeed()
        }
        // the first page settles (posters, the first clip's playback, the rail's own entrance) before a
        // person's thumb would land; a tap during that can miss the sheet
        Thread.sleep(forTimeInterval: 3)
        attach("feed")
        let row = saveRow(app)
        var found = false
        // the More button of the clip on screen now, found once: XCTest's element queries are slow on this
        // page (run 38651769742: 20 s between retries), and the lockup idles again 8 s after a touch
        guard let button = more.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) else {
            XCTFail("the More button left the screen")
            throw NoFeed()
        }
        note("More options at \(button.frame)")
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: button.frame.midX, dy: button.frame.midY))
        // after 8 s of watching, the first touch fades the clip's lockup back in, and WebKit drops the click
        // of a tap that ends while content is appearing (run 38642097942's recording; the web fix is
        // 7a33bfd). So, as a thumb does on its way to the rail: a touch on the clip wakes the lockup, and
        // the press on More comes 0.6 s later, after the fade — with no query in between, because a query
        // here can take longer than the 8 s the lockup stays awake (run 38651769742: 20 s per retry).
        let wakePoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
        for attempt in 1...3 where !found {
            wakePoint.press(forDuration: 0.1)
            Thread.sleep(forTimeInterval: 0.6)
            point.press(forDuration: 0.2)
            found = row.waitForExistence(timeout: 3)
            if !found { note("the sheet did not open on press \(attempt)") }
        }
        attach("more-sheet")
        if !found {
            // say what the sheet holds instead — a site without the Save to Photos page shows "Download"
            let labels = app.descendants(matching: .button).allElementsBoundByIndex.prefix(40).map { $0.label }.filter { !$0.isEmpty }
            note("the More sheet's buttons: \(labels)")
        }
        XCTAssertTrue(found, "the More sheet has no \"Save to Photos\" row")
        return app
    }

    private func saveRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .button).matching(NSPredicate(format: "label == 'Save to Photos'")).firstMatch
    }

    private func tapSaveToPhotos(_ app: XCUIApplication) {
        // the sheet settles on a spring; give it its moment, then a person's tap
        Thread.sleep(forTimeInterval: 0.8)
        saveRow(app).press(forDuration: 0.15)
        note("tapped Save to Photos")
    }

    /// "Saved to Photos" on the row, then in the toast — and exactly one new video in the library, the
    /// length of the file a save of this clip downloads
    private func expectSaved(_ app: XCUIApplication, before: [Video], pick: Pick, name: String) throws {
        // "Saved to Photos" is on screen ~3 s, often less than one snapshot of this page takes: the shell
        // keeps a record of each time the page showed it (UITestHooks.saw), and that record stays
        let saw = app.descendants(matching: .any).matching(identifier: "sa-uitest-saw").firstMatch
        XCTAssertTrue(saw.waitForExistence(timeout: 240), "\"Saved to Photos\" never appeared")
        note("the app said it: \(saw.label)")
        attach("\(name)-saved")
        var after = try libraryVideos()
        let until = Date().addingTimeInterval(20)
        while after.count <= before.count, Date() < until {
            Thread.sleep(forTimeInterval: 1)
            after = try libraryVideos()
        }
        let known = Set(before.map { $0.id })
        let added = after.filter { !known.contains($0.id) }
        note("library videos: \(before.count) before, \(after.count) after — new: \(added.map { "\($0.id) \(String(format: "%.2f", $0.duration)) s" })")
        XCTAssertEqual(added.count, 1, "expected exactly one new video in the library")
        guard let video = added.first else { return }
        XCTAssertEqual(video.duration, pick.fileDuration, accuracy: 0.25, "the saved video's length is not the file's (\(pick.fileDuration) s)")
        XCTAssertEqual(video.duration, pick.dbDuration, accuracy: 1.5, "the saved video's length is not the clip's (\(pick.dbDuration) s)")
    }

    // MARK: the library
    //
    // Two ways to read the Simulator's photo library, the first that works: PhotoKit, when the runner holds
    // read access (uitest-photos.sh grants it with simctl before the run, but xcodebuild reinstalls the runner
    // and a reinstall forgets); else the library's own originals on disk — a Simulator's processes can read
    // its data folder, and Photos keeps every original under Media/DCIM. Either way a video's length is
    // measured, not assumed.

    struct Video { let id: String; let duration: Double }
    struct NoLibrary: Error {}
    struct NoFeed: Error {}

    private func libraryVideos() throws -> [Video] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized {
            let assets = PHAsset.fetchAssets(with: .video, options: nil)
            var out: [Video] = []
            assets.enumerateObjects { asset, _, _ in out.append(Video(id: asset.localIdentifier, duration: asset.duration)) }
            note("library read through PhotoKit: \(out.count) video(s)")
            return out
        }
        if let onDisk = libraryOriginals() {
            note("library read from the Simulator's Media/DCIM (PhotoKit status \(status.rawValue)): \(onDisk.count) video(s)")
            return onDisk
        }
        // a skip would exit 0 and read as a pass: no library, no proof — fail
        XCTFail("the photo library could not be read: PhotoKit status \(status.rawValue), no Simulator data folder")
        throw NoLibrary()
    }

    /// every video original Photos holds, from the Simulator's own data folder
    private func libraryOriginals() -> [Video]? {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] else { return nil }
        let dcim = URL(fileURLWithPath: root).appendingPathComponent("Media/DCIM", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dcim.path) else { return [] }
        var out: [Video] = []
        let files = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()) else { continue }
            let seconds = CMTimeGetSeconds(AVURLAsset(url: file).duration)
            out.append(Video(id: file.path.replacingOccurrences(of: root, with: ""), duration: seconds.isFinite ? seconds : 0))
        }
        return out
    }

    // MARK: the clip, through the API

    struct Pick { let token: String; let userJSON: String; let clipId: String; let fileDuration: Double; let dbDuration: Double }

    private func pickClip() throws -> Pick {
        let (status, data) = try http("POST", "/auth/guest", body: Data("{}".utf8))
        XCTAssertTrue((200..<300).contains(status), "guest mint answered \(status)")
        let minted = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let token = try XCTUnwrap(minted["token"] as? String)
        self.token = token
        let userData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(minted["user"]))
        let userJSON = String(decoding: userData, as: UTF8.self)
        let (fs, feed) = try http("GET", "/feed?scope=all", token: token)
        XCTAssertEqual(fs, 200, "the feed answered \(fs)")
        let items = try XCTUnwrap((try JSONSerialization.jsonObject(with: feed) as? [String: Any])?["items"] as? [[String: Any]])
        // the shortest real clip on the page: the smallest download, so the test measures the save, not the link
        let candidates = items.compactMap { i -> (String, Double, String?)? in
            guard let id = i["id"] as? String, let d = i["duration_seconds"] as? Double, d >= 8 else { return nil }
            return (id, d, (i["wm_url"] as? String) ?? (i["video_url"] as? String))
        }.sorted { $0.1 < $1.1 }
        let (clipId, dbDuration, itemFile) = try XCTUnwrap(candidates.first, "no clip on the first feed page")
        // the file a save of this clip gets — the same answer the app gets: GET /clips/:id/photos, and the
        // item's own file where that answers nothing (app/src/feed/download.ts fileFor)
        let (ps, photos) = try http("GET", "/clips/\(clipId)/photos")
        // a site without the route answers its app shell (HTML, 200): not an answer — the item's own file
        let plan = ps == 200 ? ((try? JSONSerialization.jsonObject(with: photos)) as? [String: Any]) : nil
        let fileURL = try XCTUnwrap(((plan?["url"] as? String) ?? itemFile).flatMap(URL.init(string:)), "no file for clip \(clipId)")
        let fileDuration = try measure(fileURL)
        note("clip \(clipId): \(String(format: "%.2f", dbDuration)) s in the library, file \(fileURL.lastPathComponent) \(String(format: "%.2f", fileDuration)) s (/photos \(ps): \(plan?["state"] ?? "-"))")
        return Pick(token: token, userJSON: userJSON, clipId: clipId, fileDuration: fileDuration, dbDuration: dbDuration)
    }

    private func measure(_ url: URL) throws -> Double {
        let sem = DispatchSemaphore(value: 0)
        var local: URL?
        var failure: Error?
        URLSession.shared.downloadTask(with: url) { tmp, _, error in
            if let tmp {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString).mp4")
                do { try FileManager.default.moveItem(at: tmp, to: dest); local = dest } catch { failure = error }
            }
            failure = failure ?? error
            sem.signal()
        }.resume()
        XCTAssertEqual(sem.wait(timeout: .now() + 180), .success, "the clip's file did not download in 3 minutes")
        if let failure { throw failure }
        let file = try XCTUnwrap(local)
        defer { try? FileManager.default.removeItem(at: file) }
        let seconds = CMTimeGetSeconds(AVURLAsset(url: file).duration)
        XCTAssertTrue(seconds.isFinite && seconds > 0, "the file has no length")
        return seconds
    }

    private func http(_ method: String, _ path: String, token: String? = nil, body: Data? = nil) throws -> (Int, Data) {
        var last: Error?
        // a freshly booted Simulator can fail TLS (-1200) for its first minute or two: keep asking, patiently
        for attempt in 0..<9 {
            if attempt > 0 {
                note("\(method) \(path): \(last.map { ($0 as NSError).code } ?? 0) — trying again (\(attempt))")
                Thread.sleep(forTimeInterval: attempt < 3 ? 3 : 15)
            }
            var req = URLRequest(url: URL(string: Self.origin + path)!)
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
            if sem.wait(timeout: .now() + 45) == .timedOut { last = URLError(.timedOut); continue }
            if let result, result.0 < 500 { return result }
        }
        throw last ?? URLError(.badServerResponse)
    }

    // MARK: the record

    private func note(_ line: String) {
        print("SA-UITEST \(name): \(line)")
    }

    private func attach(_ label: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = label
        shot.lifetime = .keepAlways
        add(shot)
    }
}
