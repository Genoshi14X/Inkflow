import Foundation
import CryptoKit

struct TextCleaningConfiguration: Codable, Sendable {
    struct Region: Codable, Sendable {
        let box: Box
        let lines: [Box]
        let lineCount: Int
    }
    let regions: [Region]
    init(page: ScanPage) {
        regions = page.blocks.filter { $0.included && !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.map { block in
            Region(box:block.box,lines:(block.ocrLines ?? []).filter { line in
                line.x >= block.box.x-0.000001 && line.y >= block.box.y-0.000001 && line.right <= block.box.right+0.000001 && line.bottom <= block.box.bottom+0.000001
            },lineCount:max(1,block.original.split(separator:"\n").count))
        }
    }
    func signature(imageFingerprint: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        data.append(Data(imageFingerprint.utf8))
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
}
struct TextCleaningReport: Codable, Sendable {
    var smooth: Int
    var texture: Int
    var skipped: Int
    var changedPixels: Int
}
