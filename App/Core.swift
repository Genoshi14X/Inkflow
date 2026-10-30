import Foundation
import Vision
import ImageIO
import CoreGraphics

struct Box: Codable, Equatable, Sendable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var right: Double { x + width }; var bottom: Double { y + height }
    var cx: Double { x + width / 2 }; var cy: Double { y + height / 2 }
    func union(_ b: Box) -> Box {
        Box(x: min(x,b.x), y: min(y,b.y), width: max(right,b.right)-min(x,b.x), height: max(bottom,b.bottom)-min(y,b.y))
    }
    func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px <= right && py >= y && py <= bottom }
}
struct OCRLine: Codable, Sendable {
    var text: String; var confidence: Float; var box: Box
}
struct TranslationRecord: Codable, Sendable {
    var text: String
    var source: String
    var context: String
    var model: String
}
enum ExportMode: String, CaseIterable, Identifiable {
    case original = "Оригинал"
    case translated = "Перевод"
    case bilingual = "EN + RU"
    var id: String { rawValue }
}
struct TextBlock: Codable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var original: String
    var box: Box
    var included = true
    var warning: String = ""
    var panel: Int = 0
    var translation: TranslationRecord? = nil
}
struct ScanPage: Codable, Identifiable, Sendable {
    var id: String { file }
    var file: String
    var width: Int = 0
    var height: Int = 0
    var blocks: [TextBlock] = []
    var panels: [Box] = []
    var scanned = false
    var reviewed = false
    var error: String? = nil
    var fingerprint: String = ""
    var translationReviewed: Bool? = nil
}
struct Chapter: Codable, Sendable {
    var version = 2
    var name: String
    var pages: [ScanPage]
    var glossary: String? = nil
    var browserTranslation: String? = nil
}

enum ScanError: LocalizedError {
    case unreadable(String)
    case incompatible
    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Не удалось прочитать изображение \(name). Проверьте, открывается ли оно в Просмотре."
        case .incompatible: return "Этот проект создан другой версией Inkflow. Откройте его в совместимой версии приложения."
        }
    }
}

enum ProjectFiles {
    static let saveName = ".mangascan.json"
    static func images(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted {
                let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                return order == .orderedSame ? $0.lastPathComponent < $1.lastPathComponent : order == .orderedAscending
            }
    }
    static func fingerprint(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(v?.fileSize ?? 0):\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    static func load(_ folder: URL) throws -> Chapter {
        let urls = try images(in: folder)
        let save = folder.appendingPathComponent(saveName)
        var previous: [String: ScanPage] = [:]
        var browserTranslation: String? = nil
        var glossary: String? = nil
        if FileManager.default.fileExists(atPath: save.path) {
            let old = try JSONDecoder().decode(Chapter.self, from: Data(contentsOf: save))
            guard [1,2].contains(old.version) else { throw ScanError.incompatible }
            browserTranslation = old.browserTranslation
            glossary = old.glossary
            previous = Dictionary(old.pages.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return Chapter(name: folder.lastPathComponent, pages: urls.map { url in
            let key = fingerprint(url)
            if var old = previous[url.lastPathComponent] {
                if old.fingerprint != key {
                    // Preserve edits; changed sources must never silently erase them.
                    old.error = "Файл изображения изменился. Сохранённые реплики оставлены; проверьте их по новой странице."
                    old.reviewed = false
                }
                return old
            }
            return ScanPage(file: url.lastPathComponent, fingerprint: key)
        }, glossary: glossary, browserTranslation: browserTranslation)
    }
    static func save(_ chapter: Chapter, to folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(chapter).write(to: folder.appendingPathComponent(saveName), options: .atomic)
    }
    static func translationContext(_ page: ScanPage, glossary: String?) -> String {
        let content = [glossary ?? ""] + page.blocks.filter(\.included).flatMap { [$0.id.uuidString, $0.text] }
        return String(data:try! JSONEncoder().encode(content),encoding:.utf8)!
    }
    static func transcript(_ chapter: Chapter, mode: ExportMode = .original) -> String {
        var parts = ["Глава \(chapter.name)"]
        for page in chapter.pages {
            parts.append("\n=== Страница \(page.file) ===\n")
            if !page.scanned { parts.append("[Страница не распознана]"); continue }
            if !page.reviewed { parts.append("[Порядок и текст не проверены]\n") }
            for (i, block) in page.blocks.filter({ $0.included }).enumerated() {
                var text = String(format: "[%02d]", i + 1) + "\n"
                if mode != .translated { text += (mode == .bilingual ? "EN: " : "") + block.text + "\n" }
                if mode != .original {
                    if let ru = block.translation, !ru.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        text += (mode == .bilingual ? "RU: " : "") + ru.text + "\n"
                        if ru.source != block.text || ru.context != translationContext(page,glossary:chapter.glossary) { text += "[Оригинал, порядок или словарь изменились — проверьте перевод]\n" }
                        else if page.translationReviewed != true { text += "[Перевод не проверен]\n" }
                    } else { text += "[Нет перевода]\n" }
                }
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n") + "\n"
    }
}

// Whitespace segmentation is a geometric heuristic, not a learned manga detector.
// Recursively split full-width gutters before full-height ones. Vertical cuts read RTL.
enum PanelDetector {
    static func detect(_ image: CGImage) -> [Box] {
        let w = min(640, image.width), h = max(1, image.height * w / image.width)
        var pixels = [UInt8](repeating: 255, count: w*h)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard success else { return [Box(x: 0,y: 0,width: 1,height: 1)] }
        struct Region { var x: Int; var y: Int; var w: Int; var h: Int }
        func darkRatio(_ r: Region, horizontal: Bool, at p: Int) -> Double {
            let count = horizontal ? r.w : r.h
            var dark = 0
            for k in 0..<count {
                let x = horizontal ? r.x+k : r.x+p
                let y = horizontal ? r.y+p : r.y+k
                if pixels[y*w+x] < 215 { dark += 1 }
            }
            return Double(dark)/Double(max(1,count))
        }
        func cut(_ r: Region, horizontal: Bool) -> Int? {
            let length = horizontal ? r.h : r.w
            let margin = max(horizontal ? h/12 : w/12, Int(Double(length)*0.13))
            guard length > margin*2+4 else { return nil }
            let ratios = (0..<length).map { darkRatio(r,horizontal: horizontal,at: $0) }
            var candidates: [(Int,Int)] = []; var start: Int? = nil
            for p in margin..<(length-margin) {
                if ratios[p] < 0.025 { if start == nil { start = p } }
                else if let s = start { if p-s >= 3 { candidates.append((s,p)) }; start = nil }
            }
            if let s = start, length-margin-s >= 3 { candidates.append((s,length-margin)) }
            // A real gutter is bordered by panel ink, not merely a large empty balloon.
            candidates = candidates.filter { s,e in
                let radius = max(5, length/35)
                let before = ratios[max(0,s-radius)..<s].max() ?? 0
                let after = ratios[e..<min(length,e+radius)].max() ?? 0
                return before > 0.18 && after > 0.18
            }
            guard let best = candidates.max(by: { ($0.1-$0.0) < ($1.1-$1.0) }) else { return nil }
            return (best.0+best.1)/2
        }
        func recurse(_ r: Region, depth: Int) -> [Box] {
            if depth < 6 {
                if let c = cut(r,horizontal: true) {
                    return recurse(Region(x:r.x,y:r.y,w:r.w,h:c),depth:depth+1) + recurse(Region(x:r.x,y:r.y+c,w:r.w,h:r.h-c),depth:depth+1)
                }
                if let c = cut(r,horizontal: false) {
                    return recurse(Region(x:r.x+c,y:r.y,w:r.w-c,h:r.h),depth:depth+1) + recurse(Region(x:r.x,y:r.y,w:c,h:r.h),depth:depth+1)
                }
            }
            return [Box(x: Double(r.x)/Double(w), y: Double(r.y)/Double(h), width: Double(r.w)/Double(w), height: Double(r.h)/Double(h))]
        }
        return recurse(Region(x:0,y:0,w:w,h:h),depth:0)
    }
}

enum ReadingOrder {
    static func panelIndex(_ box: Box, panels: [Box]) -> Int {
        panels.firstIndex(where: { $0.contains(box.cx,box.cy) }) ?? 0
    }
    static func normalize(_ text: String) -> String {
        let map: [Character: Character] = ["А":"A", "В":"B", "Е":"E", "К":"K", "М":"M", "Н":"H", "О":"O", "Р":"P", "С":"C", "Т":"T", "Х":"X", "а":"a", "е":"e", "о":"o", "р":"p", "с":"c", "х":"x", "н":"H"]
        return String(text.map { map[$0] ?? $0 })
    }
    static func join(_ texts: [String]) -> String {
        var result = ""
        for t in texts {
            let next = t.trimmingCharacters(in:.whitespacesAndNewlines)
            if result.hasSuffix("-"), let first = next.first, first.isLetter {
                result.removeLast(); result += next
            } else { result += (result.isEmpty ? "" : " ") + next }
        }
        return result
    }
    static func blocks(_ lines: [OCRLine], panels: [Box]) -> [TextBlock] {
        var groups: [[OCRLine]] = []
        let ordered = lines.sorted { $0.box.y < $1.box.y }
        for line in ordered {
            var best: Int? = nil; var bestScore = Double.infinity
            for (i,g) in groups.enumerated() {
                guard let last = g.last else { continue }
                let a = last.box, b = line.box
                guard panelIndex(a,panels:panels) == panelIndex(b,panels:panels) else { continue }
                let gap = b.y-a.bottom
                let overlap = min(a.right,b.right)-max(a.x,b.x)
                let center = abs(a.cx-b.cx)
                guard gap > -min(a.height,b.height)*0.4,
                      gap < max(a.height,b.height)*0.95,
                      overlap > min(a.width,b.width)*0.35,
                      center < max(a.width,b.width)*0.38+0.006,
                      max(a.height,b.height) < min(a.height,b.height)*2.1 else { continue }
                let score = max(0,gap)+center
                if score < bestScore { best = i; bestScore = score }
            }
            if let i = best { groups[i].append(line) } else { groups.append([line]) }
        }
        let blocks = groups.map { g -> TextBlock in
            let box = g.dropFirst().reduce(g[0].box) { $0.union($1.box) }
            let original = g.map(\.text).joined(separator:"\n")
            let text = join(g.map { normalize($0.text) })
            var issues: [String] = []
            if normalize(original) != original { issues.append("Заменены похожие кириллические буквы. Сверьте с изображением.") }
            if g.contains(where: { $0.confidence < 0.5 }) { issues.append("Низкая уверенность распознавания.") }
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            if letters < 2 || Double(letters) / Double(max(1,text.filter { !$0.isWhitespace }.count)) < 0.55 || text.range(of:"[^\\x00-\\x7F]",options:.regularExpression) != nil { issues.append("Возможна ошибка или звуковой эффект.") }
            return TextBlock(text:text,original:original,box:box,warning:issues.joined(separator:" "),panel:panelIndex(box,panels:panels))
        }
        return sort(blocks)
    }
    static func sort(_ blocks: [TextBlock]) -> [TextBlock] {
        var result: [TextBlock] = []
        for panel in Set(blocks.map(\.panel)).sorted() {
            var remaining = blocks.filter { $0.panel == panel }.sorted { $0.box.y < $1.box.y }
            while let first = remaining.first {
                // Group blocks starting on roughly the same row; read those right to left.
                let tolerance = min(0.055, max(0.018,first.box.height*0.45))
                let row = remaining.filter { $0.box.y <= first.box.y+tolerance }.sorted { $0.box.cx > $1.box.cx }
                let ids = Set(row.map(\.id)); result += row
                remaining.removeAll { ids.contains($0.id) }
            }
        }
        return result
    }
}

enum Scanner {
    static func scan(_ url: URL, region: Box? = nil) throws -> ScanPage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw ScanError.unreadable(url.lastPathComponent) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.006
        if let r = region { request.regionOfInterest = CGRect(x:r.x,y:1-r.bottom,width:r.width,height:r.height) }
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        let lines = (request.results ?? []).compactMap { obs -> OCRLine? in
            guard let c = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return OCRLine(text:c.string,confidence:c.confidence,box:Box(x:b.minX,y:1-b.maxY,width:b.width,height:b.height))
        }
        let panels = PanelDetector.detect(image)
        return ScanPage(file:url.lastPathComponent,width:image.width,height:image.height,blocks:ReadingOrder.blocks(lines,panels:panels),panels:panels,scanned:true,fingerprint:ProjectFiles.fingerprint(url))
    }
}

// Preserve every character while keeping browser input below its 10,000-character limit.
enum BrowserTranslation {
    static func chunks(_ text: String, limit: Int = 9500) -> [String] {
        precondition(limit >= 2)
        var result: [String] = [], current = ""
        var units = 0
        for character in text {
            let next = String(character)
            if units + next.utf16.count > limit && !current.isEmpty {
                // Prefer a paragraph/line boundary so replicas usually stay together.
                if let boundary = current.lastIndex(of: "\n"), current.distance(from: current.startIndex, to: boundary) > current.count / 2 {
                    let after = current.index(after: boundary)
                    result.append(String(current[..<after])); current = String(current[after...])
                } else { result.append(current); current = "" }
                units = current.utf16.count
            }
            current += next; units += next.utf16.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
