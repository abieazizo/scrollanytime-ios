// Words on a screenshot, WITH their boxes (Apple's Vision) — for the onboarding audit (2026-11-08).
// ocr.swift answers with the centre of a whole LINE; the welcome's "Terms" and "Privacy Policy" are two words
// inside one line, so this one asks Vision for the box of the words themselves.
//
//   ocrw shot.png                         every line, top to bottom, as JSON [{text,x0,y0,x1,y1}] (fractions, top-left origin)
//   ocrw shot.png --word "Terms"          the centre of those words in the first line holding them: "0.412 0.903"
//   ocrw shot.png --line "Terms of Use"   the box of the first line that IS that text: "x0 y0 x1 y1"
//   --fast                                Vision's fast pass (the walk's polling)
//   exit 3 = not on screen
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
func opt(_ k: String) -> String? {
    if let i = args.firstIndex(of: k), i + 1 < args.count { return args[i + 1] }
    return nil
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = args.contains("--fast") ? .fast : .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do { try handler.perform([request]) } catch {
    FileHandle.standardError.write("vision failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

struct Line { let text: String; let box: CGRect; let cand: VNRecognizedText }
var lines: [Line] = []
for o in request.results ?? [] {
    if let c = o.topCandidates(1).first { lines.append(Line(text: c.string, box: o.boundingBox, cand: c)) }
}
lines.sort { $0.box.maxY > $1.box.maxY }   // top of the screen first

// Vision's boxes are fractions with the origin at the BOTTOM-left
func tl(_ r: CGRect) -> (Double, Double, Double, Double) {
    (Double(r.minX), Double(1 - r.maxY), Double(r.maxX), Double(1 - r.minY))
}

if let want = opt("--word") {
    let w = want.lowercased()
    for l in lines {
        let low = l.text.lowercased()
        guard let r = low.range(of: w) else { continue }
        let off = low.distance(from: low.startIndex, to: r.lowerBound)
        if low.count == l.text.count,
           let start = l.text.index(l.text.startIndex, offsetBy: off, limitedBy: l.text.endIndex),
           let end = l.text.index(start, offsetBy: want.count, limitedBy: l.text.endIndex),
           let sub = try? l.cand.boundingBox(for: start..<end) {
            let b = tl(sub.boundingBox)
            print(String(format: "%.4f %.4f", (b.0 + b.2) / 2, (b.1 + b.3) / 2))
        } else {
            let b = tl(l.box)
            print(String(format: "%.4f %.4f", (b.0 + b.2) / 2, (b.1 + b.3) / 2))
        }
        exit(0)
    }
    exit(3)
}

if let want = opt("--line") {
    let w = want.lowercased().trimmingCharacters(in: .whitespaces)
    for l in lines where l.text.lowercased().trimmingCharacters(in: .whitespaces) == w {
        let b = tl(l.box)
        print(String(format: "%.4f %.4f %.4f %.4f", b.0, b.1, b.2, b.3))
        exit(0)
    }
    exit(3)
}

var out: [[String: Any]] = []
for l in lines {
    let b = tl(l.box)
    out.append(["text": l.text, "x0": b.0, "y0": b.1, "x1": b.2, "y1": b.3])
}
let data = try! JSONSerialization.data(withJSONObject: out, options: [])
print(String(data: data, encoding: .utf8)!)
