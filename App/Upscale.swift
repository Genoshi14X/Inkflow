import Foundation
import ImageIO

struct UpscaleFailure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

// Use argument arrays, never shell interpolation: image paths may contain spaces.
final class UpscaleJob: @unchecked Sendable {
    let process = Process()
    let input: URL
    let output: URL
    private let temporary: URL
    private let log: URL
    private let result: URL
    private let logHandle: FileHandle

    init(repository: URL, python: URL, input: URL, output: URL) throws {
        self.input = input; self.output = output
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("InkflowUpscale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        result = temporary.appendingPathComponent("result.png")
        log = temporary.appendingPathComponent("process.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: log)
        process.executableURL = python
        process.currentDirectoryURL = repository
        process.arguments = ["-m", "waifu2x.cli", "-i", input.path, "-o", result.path,
                             "--method", "scale2x", "--noise-level", "1", "--format", "png"]
        process.standardOutput = logHandle; process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
    }
    deinit { try? logHandle.close(); try? FileManager.default.removeItem(at: temporary) }

    func finish() throws {
        process.waitUntilExit()
        try? logHandle.close()
        guard process.terminationStatus == 0 else {
            let handle = try? FileHandle(forReadingFrom: log)
            let size = (try? handle?.seekToEnd()) ?? 0
            try? handle?.seek(toOffset: size > 4000 ? size - 4000 : 0)
            let detail = String(decoding: (try? handle?.readToEnd()) ?? Data(), as: UTF8.self)
            try? handle?.close()
            throw UpscaleFailure("nunif завершился с ошибкой. Проверьте Python, зависимости и модели.\n" + detail)
        }
        guard let original = Self.dimensions(input), let scaled = Self.dimensions(result),
              scaled.0 == original.0 * 2, scaled.1 == original.1 * 2 else {
            throw UpscaleFailure("nunif не создал изображение с увеличением ×2.")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        // moveItem refuses to overwrite an existing result.
        try FileManager.default.moveItem(at: result, to: output)
    }

    static func dimensions(_ url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}
