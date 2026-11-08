import Foundation

@main struct BrowserTranslationTests {
    static func main() throws {
        let samples = ["", "Hello", String(repeating:"Line of dialogue.\n\n",count:2000), String(repeating:"A",count:21000), String(repeating:"😀 Привет!\n",count:4000)]
        for text in samples {
            let parts = BrowserTranslation.chunks(text)
            precondition(parts.joined() == text, "Chunking must not lose characters")
            precondition(parts.allSatisfy { !$0.isEmpty && $0.utf16.count <= 9500 })
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let chapter = Chapter(name:"155",pages:[],browserTranslation:"Русский черновик\nС правками")
        try ProjectFiles.save(chapter,to:folder)
        let loaded = try ProjectFiles.load(folder)
        precondition(loaded.browserTranslation == chapter.browserTranslation)
        let old = try JSONDecoder().decode(Chapter.self,from:Data(#"{"version":1,"name":"155","pages":[]}"#.utf8))
        precondition(old.browserTranslation == nil)
        print("Browser translation: lossless chunking, size limits, draft persistence and compatibility passed")
    }
}
