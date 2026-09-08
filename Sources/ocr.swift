import Foundation
import Vision
import ImageIO

struct Line: Codable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
struct Page: Codable {
    let file: String
    let width: Int
    let height: Int
    let seconds: Double
    let lines: [Line]
}
let paths = Array(CommandLine.arguments.dropFirst())
if paths.isEmpty {
    fputs("Usage: ocr image.png [image.jpg ...] > raw.json\n", stderr)
    exit(1)
}
var pages: [Page] = []
for path in paths {
    do {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "Inkflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(path)"])
        }
        let start = Date()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            return Line(text: candidate.string, confidence: candidate.confidence,
                        x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
        let elapsed = Date().timeIntervalSince(start)
        pages.append(Page(file: url.lastPathComponent, width: image.width, height: image.height, seconds: elapsed, lines: lines))
        fputs("\(url.lastPathComponent): \(lines.count) lines, \(String(format: "%.2f", elapsed)) s\n", stderr)
    } catch {
        fputs("\(path): \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(pages))
