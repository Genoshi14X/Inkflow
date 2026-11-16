import Foundation

// Publish the complete chapter only after every page has been rendered successfully.
final class PageExportRun {
    let chapter: Chapter
    let source: URL
    let staging: URL
    let destination: URL
    private var saved = Set<Int>()
    private var finished = false
    init(chapter: Chapter, source: URL, output: URL) throws {
        guard !chapter.pages.isEmpty else { throw UpscaleFailure("В главе нет страниц для сохранения.") }
        self.chapter = chapter; self.source = source
        let token = UUID().uuidString
        staging = output.appendingPathComponent(".inkflow-export-" + token,isDirectory:true)
        destination = output.appendingPathComponent("Inkflow_PNG_" + token,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
    }
    deinit { if !finished { try? FileManager.default.removeItem(at:staging) } }
    func exportPage(_ index: Int) throws {
        guard !finished, chapter.pages.indices.contains(index) else { throw UpscaleFailure("Некорректная страница экспорта.") }
        let page = chapter.pages[index]
        let name = String(format:"%04d_",index+1) + URL(fileURLWithPath:page.file).lastPathComponent + "_lettered.png"
        do {
            try TextRenderer.export(image:source.appendingPathComponent(page.imagePath),layers:page.textLayers ?? [],to:staging.appendingPathComponent(name))
            saved.insert(index)
        } catch { throw UpscaleFailure("Не удалось сохранить \(page.file): \(error.localizedDescription)") }
    }
    func complete() throws -> URL {
        guard !finished, saved.count == chapter.pages.count else { throw UpscaleFailure("Сохранены не все страницы главы.") }
        try FileManager.default.moveItem(at:staging,to:destination)
        finished = true
        return destination
    }
}
