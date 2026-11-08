import Foundation

struct BrushPoint: Codable, Sendable {
    let x: Double
    let y: Double
}
struct BrushStroke: Codable, Sendable {
    let diameter: Double
    let points: [BrushPoint]
    var method = "texture"
}

final class HealingJob: @unchecked Sendable {
    let process = Process()
    private let temporary: URL
    private let log: URL
    private let result: URL
    private let handle: FileHandle
    private let input: URL
    private let output: URL

    init(python: URL, script: URL, input: URL, output: URL, stroke: BrushStroke) throws {
        self.input = input; self.output = output
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("InkflowHealing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        log = temporary.appendingPathComponent("process.log")
        result = temporary.appendingPathComponent("result.png")
        let mask = temporary.appendingPathComponent("stroke.json")
        try JSONEncoder().encode(stroke).write(to: mask)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        handle = try FileHandle(forWritingTo: log)
        process.currentDirectoryURL = input.deletingLastPathComponent()
        process.executableURL = python
        process.arguments = [script.path, input.path, result.path, mask.path]
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
    }
    deinit { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }

    func finish() throws {
        process.waitUntilExit(); try? handle.close()
        guard process.terminationStatus == 0 else {
            let reader = try? FileHandle(forReadingFrom: log)
            let length = (try? reader?.seekToEnd()) ?? 0
            try? reader?.seek(toOffset: length > 3000 ? length - 3000 : 0)
            let detail = String(decoding: (try? reader?.readToEnd()) ?? Data(), as: UTF8.self)
            try? reader?.close()
            throw UpscaleFailure("Не удалось восстановить фон. " + detail)
        }
        guard let before = UpscaleJob.dimensions(input), let after = UpscaleJob.dimensions(result),
              before.0 == after.0, before.1 == after.1 else {
            throw UpscaleFailure("Размер изображения изменился при восстановлении фона.")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: result, to: output)
    }
}
