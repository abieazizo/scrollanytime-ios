import UIKit
import WebKit
import Photos
import AVFoundation

/// SAVE TO PHOTOS (the owner's spec of 2026-10-14) — the web app's `saveToPhotos` message handler.
/// app/src/lib/nativeSave.ts is the other side of this contract:
///
///   JS → shell   { action: "save", id, url, name }   download the clip's file, ask for add-only Photos
///                                                    access (never the whole library), write the video
///                                                    into the camera roll, delete the temporary copy
///                { action: "openSettings" }          this app's page in iOS Settings, where its Photos
///                                                    switch is
///   shell → JS   sa-photos  { id, phase: "progress", received, total }
///                           { id, phase: "saving" }                       the bytes are in, Photos writes
///                           { id, phase: "done", ok: true, duration }
///                           { id, phase: "done", ok: false, error }       denied · network · unsupported ·
///                                                                         disk_full · failed
///
/// Why native: a web page inside WKWebView cannot write to Photos at all, and a host app without
/// NSPhotoLibraryAddUsageDescription gets a share sheet with no "Save Video" in it (the owner's report).
/// With the key in Info.plist iOS can ask — once — and "Save Video" also returns to the share sheet.
///
/// Before the page's first script runs `window.__saShell.photos` is 1 (WebView.swift), so the page calls
/// this instead of the share sheet; an older shell has neither and the page falls back.
final class SaveToPhotos: NSObject, URLSessionDownloadDelegate {
    static let shared = SaveToPhotos()

    private struct Job {
        let id: String
        var sentAt: Date
        var total: Int64
        var checkedSpace: Bool
        /// the error this job already decided on (disk space), so the cancellation is not read as a network failure
        var decided: String?
    }

    /// taskIdentifier → job; touched only on `queue`
    private var jobs: [Int: Job] = [:]
    private let queue = DispatchQueue(label: "com.scrollanytime.save-to-photos")
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30 // no byte for 30 s: the link is gone, say so
        config.timeoutIntervalForResource = 15 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let ops = OperationQueue()
        ops.maxConcurrentOperationCount = 1
        ops.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: ops)
    }()

    // MARK: the page's messages

    static func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "save":
            let id = (body["id"] as? String) ?? ""
            guard let raw = body["url"] as? String, let url = URL(string: raw), isOurs(url) else {
                // only the app's own files: the page is ours, but the shell checks anyway
                done(id, error: "failed")
                return
            }
            shared.save(id: id, url: url)
        case "openSettings":
            openSettings()
        default:
            break
        }
    }

    /// https on the app's own origin — the files are served from scrollanytime.com/video/…
    static func isOurs(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedOrigins.contains(host)
    }

    /// Settings → Scroll Anytime: the Photos row is there once the app has asked (Add Photos Only)
    static func openSettings() {
        DispatchQueue.main.async {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    // MARK: events to the page

    static func emit(_ detail: [String: Any]) {
        NotifyBridge.emit("sa-photos", detail)
    }

    static func done(_ id: String, error: String) {
        emit(["id": id, "phase": "done", "ok": false, "error": error])
        log("save \(id) failed: \(error)")
    }

    static func log(_ line: String) {
        NSLog("SA-PHOTOS %@", line)
    }

    // MARK: one save

    /// Ask first, download second: a "Don't Allow" costs the person no data, and the prompt comes up the
    /// moment they tap rather than after the file has arrived.
    func save(id: String, url: URL) {
        Self.log("save \(id) asked for \(url.path)")
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
                Self.log("save \(id): the person answered \(granted.rawValue)")
                self.proceed(id: id, url: url, status: granted)
            }
        } else {
            proceed(id: id, url: url, status: status)
        }
    }

    private func proceed(id: String, url: URL, status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            queue.async {
                let task = self.session.downloadTask(with: url)
                self.jobs[task.taskIdentifier] = Job(id: id, sentAt: .distantPast, total: 0, checkedSpace: false, decided: nil)
                task.resume()
            }
        default:
            // denied or restricted: the page shows "Allow Scroll Anytime to save to Photos" + Open Settings
            Self.done(id, error: "denied")
        }
    }

    // MARK: URLSessionDownloadDelegate (on `queue`)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard var job = jobs[downloadTask.taskIdentifier] else { return }
        let total = max(0, totalBytesExpectedToWrite)
        if !job.checkedSpace, total > 0 {
            job.checkedSpace = true
            // the temporary copy and Photos' own copy both need the room
            if let free = Self.freeBytes(), free < total * 2 + 50_000_000 {
                job.decided = "disk_full"
                jobs[downloadTask.taskIdentifier] = job
                downloadTask.cancel()
                return
            }
        }
        job.total = total
        let now = Date()
        // ten times a second is plenty for a ring; the last bytes always get through below
        if now.timeIntervalSince(job.sentAt) >= 0.1 {
            job.sentAt = now
            Self.emit(["id": job.id, "phase": "progress", "received": totalBytesWritten, "total": total])
        }
        jobs[downloadTask.taskIdentifier] = job
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard var job = jobs[downloadTask.taskIdentifier] else { return }
        let http = downloadTask.response as? HTTPURLResponse
        guard let http, http.statusCode == 200 else {
            job.decided = "network"
            jobs[downloadTask.taskIdentifier] = job
            Self.log("save \(job.id): HTTP \(http?.statusCode ?? -1)")
            return
        }
        // the file lives only until this method returns: move it now, under a name Photos can read
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sa-save-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.moveItem(at: location, to: file)
        } catch {
            job.decided = Self.isOutOfSpace(error) ? "disk_full" : "failed"
            jobs[downloadTask.taskIdentifier] = job
            return
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        Self.emit(["id": job.id, "phase": "progress", "received": size, "total": max(size, job.total)])
        job.decided = "saving"
        jobs[downloadTask.taskIdentifier] = job
        let id = job.id
        Self.emit(["id": id, "phase": "saving"])
        guard type.hasPrefix("video/mp4") || type.hasPrefix("video/quicktime") else {
            try? FileManager.default.removeItem(at: file)
            Self.log("save \(id): served as \(type)")
            Self.done(id, error: "unsupported")
            return
        }
        Self.writeToPhotos(id: id, file: file)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { return }
        if job.decided == "saving" { return } // Photos has it from here
        if let decided = job.decided {
            Self.done(job.id, error: decided)
            return
        }
        if let error {
            Self.log("save \(job.id): \(error.localizedDescription)")
            Self.done(job.id, error: Self.isOutOfSpace(error) ? "disk_full" : "network")
        }
    }

    // MARK: Photos

    /// Photos takes the file, the temporary copy goes, the page hears how it went. The success haptic is
    /// played here, at the moment Photos says yes — the same moment the page draws its checkmark.
    private static func writeToPhotos(id: String, file: URL) {
        // what the file is, measured — the page's report and the XCUITest's log both carry it
        let duration = CMTimeGetSeconds(AVURLAsset(url: file).duration)
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(file.path) else {
            try? FileManager.default.removeItem(at: file)
            log("save \(id): Photos cannot play this file")
            done(id, error: "unsupported")
            return
        }
        var placeholder: String?
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            placeholder = request?.placeholderForCreatedAsset?.localIdentifier
        }) { ok, error in
            try? FileManager.default.removeItem(at: file)
            if ok {
                log("save \(id) saved: asset \(placeholder ?? "?"), \(String(format: "%.2f", duration)) s")
                DispatchQueue.main.async {
                    let haptic = UINotificationFeedbackGenerator()
                    haptic.prepare()
                    haptic.notificationOccurred(.success)
                }
                emit(["id": id, "phase": "done", "ok": true, "duration": duration.isFinite ? duration : 0])
                return
            }
            log("save \(id): Photos refused — \(error.map { "\(($0 as NSError).domain) \(($0 as NSError).code) \($0.localizedDescription)" } ?? "no error")")
            done(id, error: photosError(error))
        }
    }

    private static func photosError(_ error: Error?) -> String {
        guard let error else { return "failed" }
        if isOutOfSpace(error) { return "disk_full" }
        if let e = error as? PHPhotosError {
            switch e.code {
            case .accessUserDenied, .accessRestricted: return "denied"
            case .notEnoughSpace: return "disk_full"
            case .invalidResource: return "unsupported"
            default: return "failed"
            }
        }
        return "failed"
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
        if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
        if let under = e.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(under) }
        return false
    }

    private static func freeBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// THE XCUITEST'S HOOKS (2026-10-14) — dormant unless the app is launched with -saUITest, which only a
/// test runner (xcodebuild, simctl) can pass: an App Store install never receives launch arguments. With
/// it the page starts the way the automated suites start it — zerem.suite and the one-time flags, so no
/// sign-in step, card or coach stands between the feed and the More sheet — signed in as the guest the
/// test minted (-saUITestToken / -saUITestUser; the test deletes that guest afterwards), with " SAUITest"
/// on the user-agent so Ops files it under Test suite, never as a person, and -saStartURL opens the clip
/// the test chose (our origin only). ship/ios/pwa-shellUITests/SaveToPhotosUITests.swift drives it.
enum UITestHooks {
    static var on: Bool { ProcessInfo.processInfo.arguments.contains("-saUITest") }

    private static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// the clip the test opens on: https, our origin, nothing else
    static var startURL: URL? {
        guard on, let raw = value("-saStartURL"), let url = URL(string: raw), SaveToPhotos.isOurs(url) else { return nil }
        return url
    }

    /// the page's storage before its first script, as the suites set it (scripts/perf/perf.mjs)
    static func documentStartScript() -> String? {
        guard on else { return nil }
        var setup: [String: String] = ["zerem.suite": "1"]
        for k in ["zerem.onboarded", "zerem.landing.seen", "zerem.card.rabbis", "zerem.ask.account", "zerem.ask.goal", "zerem.ask.notify", "zerem.coach.swipe", "zerem.coach.doubletap", "zerem.coach.speed", "zerem.intro.done", "zerem.dlcard.seen"] {
            setup[k] = "1"
        }
        if let token = value("-saUITestToken"), let user = value("-saUITestUser") {
            setup["zerem.token"] = token
            setup["zerem.user"] = user
        }
        guard let data = try? JSONSerialization.data(withJSONObject: setup, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "(function(){try{var s=\(json);for(var k in s){localStorage.setItem(k,s[k]);}sessionStorage.setItem('zerem.soundprompt','1');}catch(e){}})();" + sawScript
    }

    /// "Saved to Photos" is on screen for about three seconds (the row's checkmark, then the toast), and one
    /// accessibility snapshot of the feed can take longer than that — the test missed it (run 38655601404)
    /// although the save had worked. So, under the test only, the page's own words are watched as they
    /// appear and each appearance is posted to the shell, which keeps it where the test can read it at any
    /// time (`saw`). It records what the page put on screen; it changes nothing the page does.
    private static let sawScript = """
    (function(){var last=0;function hit(){var now=Date.now();if(now-last<1500)return;last=now;try{window.webkit.messageHandlers.sa.postMessage('uitest-saw:Saved to Photos')}catch(e){}}
    function has(n){var t=n&&n.textContent;return !!t&&t.indexOf('Saved to Photos')!==-1}
    new MutationObserver(function(ms){for(var i=0;i<ms.length;i++){var m=ms[i];if(m.type==='characterData'){if(has(m.target)){hit();return}continue}
    for(var j=0;j<m.addedNodes.length;j++){if(has(m.addedNodes[j])){hit();return}}}}).observe(document,{childList:true,subtree:true,characterData:true});})();
    """

    private static var sawCount = 0
    private static weak var sawLabel: UILabel?

    /// the page put "Saved to Photos" on screen: count it on a native label the test reads
    static func saw(_ text: String) {
        guard on else { return }
        DispatchQueue.main.async {
            sawCount += 1
            let label: UILabel
            if let existing = sawLabel {
                label = existing
            } else {
                guard let window = PWAShell.webView?.window else { return }
                label = UILabel(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
                label.alpha = 0.05
                label.isAccessibilityElement = true
                label.accessibilityIdentifier = "sa-uitest-saw"
                window.addSubview(label)
                sawLabel = label
            }
            label.accessibilityLabel = "SA-UITEST saw \(text) \(sawCount)"
            SaveToPhotos.log("the page said \"\(text)\" (\(sawCount))")
        }
    }
}
