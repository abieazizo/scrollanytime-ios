// Read the words on a screenshot with Apple's own text recognition (Vision), one line per line of
// text. The sign-in walk (walk-signin.sh) needs to know what Google's page SAYS, and that page lives
// in another process (the system sign-in sheet, or a web view) that idb's accessibility dump does
// not reach — nor does it reach the web page's own buttons. The screenshot always does.
//
//   swift ship/demo/ocr.swift shot.png                      every line of text
//   swift ship/demo/ocr.swift shot.png --find "Continue with Google" [--exact]
//        the centre of the first line that contains (or, --exact, is) the phrase, as fractions of
//        the screen from the top-left: "0.512 0.871" — exit 3 when it is not on screen
import AppKit
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count > 1,
      let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("no readable image\n".data(using: .utf8)!)
    exit(1)
}
var find: String? = nil
if let i = args.firstIndex(of: "--find"), i + 1 < args.count { find = args[i + 1].lowercased() }
let exact = args.contains("--exact")

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
do {
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
} catch {
    FileHandle.standardError.write("vision failed: \(error)\n".data(using: .utf8)!)
    exit(2)
}
for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let text = candidate.string
    guard let want = find else {
        print(text)
        continue
    }
    let line = text.lowercased().trimmingCharacters(in: .whitespaces)
    let hit = exact ? line == want : line.contains(want)
    if !hit { continue }
    // the phrase's own box when Vision can give it, else the whole line's; Vision's origin is the
    // bottom-left, the screen's the top-left
    var box = observation.boundingBox
    if !exact, let r = line.range(of: want) {
        let lo = line.distance(from: line.startIndex, to: r.lowerBound)
        let hi = line.distance(from: line.startIndex, to: r.upperBound)
        let s = text.index(text.startIndex, offsetBy: lo)
        let e = text.index(text.startIndex, offsetBy: hi)
        if let sub = try? candidate.boundingBox(for: s..<e) { box = sub.boundingBox }
    }
    print(String(format: "%.4f %.4f", box.midX, 1 - box.midY))
    exit(0)
}
exit(find == nil ? 0 : 3)
