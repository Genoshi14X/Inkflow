import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MangaModel: ObservableObject {
    @Published var chapter: Chapter? = nil
    @Published var folder: URL? = nil
    @Published var selectedPage: String? = nil
    @Published var selectedBlock: UUID? = nil
    @Published var busy = false
    @Published var status = "Выберите папку с PNG, JPG или JPEG."
    @Published var message: String? = nil
    @Published var adding = false
    @Published var textEditing = false
    @Published var selectedTextLayer: UUID? = nil
    @Published var healing = false
    @Published var healingMethod = "texture"
    @Published var brushDiameter = 40.0
    @Published var showPanels = false
    @Published var zoom = 1.0
    @Published var autoCleanAfterExport = UserDefaults.standard.object(forKey:"autoCleanAfterTXT") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCleanAfterExport,forKey:"autoCleanAfterTXT") }
    }
    @Published var exportMode: ExportMode = .original
    @Published var showBrowserTranslation = false
    @Published private(set) var browserTranslation: BrowserTranslation? = nil
    @Published private(set) var browserTranslationProblem: String? = nil
    @Published var browserTranslationPreview: TranslationImportPlan? = nil
    @Published var pendingTranslationImport: TranslationImportPlan? = nil
    @Published private(set) var cleaningSkippedPages: [String] = []
    var importTXTName = ""
    var importMapName = ""
    private var browserSourcePasteboardChange: Int?
    @Published var undoHistory: [Chapter] = []
    private var healingJob: HealingJob?
    private var cleaningJob: HealingJob?
    private var upscaleJob: UpscaleJob?
    private var stopRequested = false
    private var unsaved = false
    var pageIndex: Int? { chapter?.pages.firstIndex(where: { $0.file == selectedPage }) }
    var page: ScanPage? { guard let i = pageIndex else { return nil }; return chapter?.pages[i] }
    var imageURL: URL? { guard let f = folder, let p = page else { return nil }; return f.appendingPathComponent(p.imagePath) }

    func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Открыть главу"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard !busy, save() else { return }
        do {
            let loaded = try ProjectFiles.load(url)
            guard !loaded.pages.isEmpty else { message = "В папке нет PNG, JPG или JPEG. Выберите папку со страницами главы."; return }
            chapter = loaded; folder = url; selectedPage = loaded.pages.first?.file
            pendingTranslationImport = nil
            closeBrowserTranslation()
            cleaningSkippedPages = []
            selectedTextLayer = nil; textEditing = false
            selectedBlock = nil; undoHistory = []; adding = false; healing = false; zoom = 1
            status = "\(loaded.pages.count) стр. · \(loaded.pages.filter(\.scanned).count) распознано · локальная обработка"
            unsaved = false
        } catch { message = "Не удалось открыть главу. \(error.localizedDescription) Сохранённый проект не изменён." }
    }
    @discardableResult func save() -> Bool {
        guard unsaved, let c = chapter, let f = folder else { return true }
        do { try ProjectFiles.save(c,to:f); unsaved = false; return true }
        catch { message = "Не удалось сохранить правки в папке главы. Проверьте права доступа и свободное место. \(error.localizedDescription)"; return false }
    }
    func edit(_ action: (inout ScanPage) -> Void) {
        guard !busy, let i = pageIndex, var c = chapter else { return }
        undoHistory.append(c); if undoHistory.count > 80 { undoHistory.removeFirst() }
        action(&c.pages[i]); TranslationAnchors.ensure(in:&c.pages[i]); c.pages[i].reviewed = false; c.pages[i].translationReviewed = false
        chapter = c; unsaved = true
        if save() { status = "Правки сохранены в папке главы" }
    }
    var layer: TextLayer? { page?.textLayers?.first(where: { $0.id == selectedTextLayer }) }
    var workingSize: CGSize {
        if let url = imageURL, let size = UpscaleJob.dimensions(url) { return CGSize(width:size.0,height:size.1) }
        return CGSize(width:1,height:1)
    }
    private func editTextLayers(_ action: (inout [TextLayer]) -> Void) {
        guard !busy, let i = pageIndex, var c = chapter else { return }
        var layers = c.pages[i].textLayers ?? []
        action(&layers)
        undoHistory.append(c); if undoHistory.count > 80 { undoHistory.removeFirst() }
        c.pages[i].textLayers = layers
        chapter = c; unsaved = true; if save() { status = "Текстовые слои сохранены" }
    }
    func updateTextLayer(_ id: UUID, _ action: (inout TextLayer) -> Void) {
        guard let index = page?.textLayers?.firstIndex(where: { $0.id == id }) else { return }
        editTextLayers {
            action(&$0[index])
            if $0[index].sourceBlockID != nil { $0[index].anchorEdited = true }
        }
    }
    func addTextLayer() {
        guard !busy, imageURL != nil else { return }
        var new = TextLayer()
        if let block = page?.blocks.first(where: { $0.id == selectedBlock }) {
            if let existing = page?.textLayers?.first(where:{ $0.sourceBlockID == block.id }) {
                if existing.text.isEmpty, let translation = block.translation?.text, !translation.isEmpty {
                    updateTextLayer(existing.id) { $0.text = translation }
                }
                selectedTextLayer = existing.id; textEditing = true; healing = false; adding = false
                return
            }
            new.sourceBlockID = block.id; new.anchorEdited = true
            new.box = block.box
            new.text = block.translation?.text ?? "Новый текст"
        }
        editTextLayers { $0.append(new) }
        selectedTextLayer = new.id; textEditing = true; healing = false; adding = false
    }
    func deleteTextLayer() {
        guard let id = selectedTextLayer else { return }
        editTextLayers { $0.removeAll(where: { $0.id == id }) }
        selectedTextLayer = page?.textLayers?.last?.id
    }
    func reorderTextLayer(by offset: Int) {
        guard let id = selectedTextLayer, let layers = page?.textLayers,
              let index = layers.firstIndex(where: { $0.id == id }), layers.indices.contains(index+offset) else { return }
        editTextLayers { $0.swapAt(index,index+offset) }
    }
    @discardableResult func prepareTranslationLayers() -> Bool {
        guard !busy, var updated = chapter else { return false }
        var changed = false
        for i in updated.pages.indices {
            if TranslationAnchors.ensure(in:&updated.pages[i]) { changed = true }
        }
        if changed {
            if let previous = chapter { undoHistory.append(previous); if undoHistory.count > 80 { undoHistory.removeFirst() } }
            chapter = updated; unsaved = true
        }
        return save()
    }
    func sourceCaption(for layer: TextLayer) -> String? {
        guard let id = layer.sourceBlockID, let page,
              let block = page.blocks.first(where:{ $0.id == id }) else { return nil }
        if let index = page.blocks.filter(\.included).firstIndex(where:{ $0.id == id }) {
            return String(format:"[%02d] ",index+1) + block.text
        }
        return "Исключена из TXT: " + block.text
    }
    func layerTitle(_ layer: TextLayer) -> String {
        if !layer.text.isEmpty { return layer.text.replacingOccurrences(of:"\n",with:" ") }
        return sourceCaption(for:layer).map { "Место перевода " + $0 } ?? "Пустой слой"
    }
    func exportTXT(to url: URL, cleaningPython: URL? = nil, cleaningScript: URL? = nil) throws {
        guard prepareTranslationLayers(), let chapter, let folder else {
            throw ScanError.missingAnchor
        }
        let mapURL = TextExportMap.url(for:url)
        let protected = [folder.appendingPathComponent(ProjectFiles.saveName)] + chapter.pages.flatMap {
            [folder.appendingPathComponent($0.file),folder.appendingPathComponent($0.imagePath)]
        }
        let normalized = Set(protected.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        guard !normalized.contains(url.standardizedFileURL.resolvingSymlinksInPath()),
              !normalized.contains(mapURL.standardizedFileURL.resolvingSymlinksInPath()) else {
            throw UpscaleFailure("Выберите другое имя, чтобы сохранить проект и рабочие изображения.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let map = try encoder.encode(TextExportMap(chapter:chapter,mode:exportMode))
        // Keep the existing TXT format; the sidecar preserves its numbering-to-ID mapping.
        let text = Data(ProjectFiles.transcript(chapter,mode:exportMode).utf8)
        let previousMap = FileManager.default.fileExists(atPath:mapURL.path) ? try Data(contentsOf:mapURL) : nil
        try map.write(to:mapURL,options:.atomic)
        do { try text.write(to:url,options:.atomic) }
        catch {
            if let previousMap { try? previousMap.write(to:mapURL,options:.atomic) }
            else { try? FileManager.default.removeItem(at:mapURL) }
            throw error
        }
        if autoCleanAfterExport { cleanDetectedText(afterTXTExport:true,python:cleaningPython,script:cleaningScript) }
    }
    func translationImportPlan(txt: URL, map: URL) throws -> TranslationImportPlan {
        guard !busy, let chapter else { throw TranslationImportError("Откройте главу и дождитесь завершения обработки.") }
        let document = try TranslationDocument.read(txt)
        let mapping: TextExportMap
        do { mapping = try JSONDecoder().decode(TextExportMap.self,from:Data(contentsOf:map)) }
        catch { throw TranslationImportError("Не удалось прочитать карту экспорта. Выберите исходный файл .inkflow-map.json. \(error.localizedDescription)") }
        return try TranslationImporter.plan(document:document,map:mapping,chapter:chapter)
    }
    func beginTranslationImport() {
        guard !busy, chapter != nil, save() else { return }
        let txtPanel = NSOpenPanel(); txtPanel.allowedContentTypes = [.plainText]
        txtPanel.allowsMultipleSelection = false; txtPanel.prompt = "Выбрать перевод"
        txtPanel.message = "Выберите переведённый TXT с заголовками страниц и номерами реплик."
        txtPanel.directoryURL = folder
        guard txtPanel.runModal() == .OK, let txt = txtPanel.url else { return }
        do { _ = try TranslationDocument.read(txt) }
        catch { message = error.localizedDescription; return }
        let mapPanel = NSOpenPanel(); mapPanel.allowedContentTypes = [.json]
        mapPanel.allowsMultipleSelection = false; mapPanel.prompt = "Выбрать карту"
        mapPanel.message = "Выберите .inkflow-map.json от исходного TXT-экспорта. Например, для 155_ru.txt нужна карта исходного 155.txt."
        mapPanel.directoryURL = txt.deletingLastPathComponent()
        do {
            let exact = TextExportMap.url(for:txt)
            // Reusing the same basename is unambiguous; otherwise ask for the original map.
            let map: URL
            if FileManager.default.fileExists(atPath:exact.path) { map = exact }
            else {
                guard mapPanel.runModal() == .OK, let chosen = mapPanel.url else { return }
                map = chosen
            }
            do {
                pendingTranslationImport = try translationImportPlan(txt:txt,map:map)
                importTXTName = txt.lastPathComponent; importMapName = map.lastPathComponent
            } catch {
                // A same-named map may belong to an earlier export; allow choosing another.
                guard map == exact else { throw error }
                mapPanel.message = error.localizedDescription + "\nВыберите другую исходную карту экспорта."
                guard mapPanel.runModal() == .OK, let chosen = mapPanel.url else { return }
                pendingTranslationImport = try translationImportPlan(txt:txt,map:chosen)
                importTXTName = txt.lastPathComponent; importMapName = chosen.lastPathComponent
            }
        } catch { message = error.localizedDescription }
    }
    private func fittedBrowserTranslation(_ plan: TranslationImportPlan, chapter: Chapter, folder: URL,
                                          policy: TranslationImportPolicy, fontName: String) throws
        -> (Chapter, [TranslationImportPlan.Item], Set<UUID>) {
        guard TextRenderer.supportsRussian(fontName) else {
            throw TranslationImportError("Этот шрифт недоступен или не поддерживает все русские буквы. Выберите другой шрифт.")
        }
        var (updated,items) = try TranslationImporter.applying(plan,to:chapter,policy:policy,allowPartial:false,
            fontName:fontName,translationModel:"yandex-browser")
        var sizes: [Int: CGSize] = [:], overflow = Set<UUID>()
        for item in items {
            let pageIndex = item.pageIndex
            let page = updated.pages[pageIndex]
            let size: CGSize
            if let cached = sizes[pageIndex] { size = cached }
            else {
                guard let dimensions = UpscaleJob.dimensions(folder.appendingPathComponent(page.imagePath)),
                      dimensions.0 > 0, dimensions.1 > 0 else {
                    throw TranslationImportError("Не удалось открыть рабочее изображение \(page.file). Проверьте, что файл на месте.")
                }
                size = CGSize(width:dimensions.0,height:dimensions.1)
                sizes[pageIndex] = size
            }
            guard let index = page.textLayers?.firstIndex(where:{ $0.id == item.layerID }) else { throw ScanError.missingAnchor }
            if !TextRenderer.fitTranslation(&updated.pages[pageIndex].textLayers![index],size:size) {
                overflow.insert(item.blockID)
            }
        }
        updated.browserTranslationFont = fontName
        return (updated,items,overflow)
    }
    func browserTranslationOverflow(_ plan: TranslationImportPlan, policy: TranslationImportPolicy, fontName: String) throws -> Set<UUID> {
        guard !busy, let chapter, let folder else { throw ScanError.missingAnchor }
        return try fittedBrowserTranslation(plan,chapter:chapter,folder:folder,policy:policy,fontName:fontName).2
    }
    @discardableResult func commitTranslationImport(_ plan: TranslationImportPlan, policy: TranslationImportPolicy, allowPartial: Bool,
                                                     fontName: String? = nil, fitBrowserText: Bool = false) throws -> Int {
        guard !busy, let previous = chapter, let folder, save() else {
            throw TranslationImportError(message ?? "Не удалось подготовить проект к импорту.")
        }
        let updated: Chapter, items: [TranslationImportPlan.Item], overflow: Set<UUID>
        if fitBrowserText {
            guard let fontName else { throw TranslationImportError("Выберите шрифт для перевода.") }
            (updated,items,overflow) = try fittedBrowserTranslation(plan,chapter:previous,folder:folder,policy:policy,fontName:fontName)
        } else {
            if let fontName, NSFont(name:fontName,size:12) == nil { throw TranslationImportError("Выбранный шрифт недоступен. Выберите установленный шрифт.") }
            (updated,items) = try TranslationImporter.applying(plan,to:previous,policy:policy,allowPartial:allowPartial,fontName:fontName)
            overflow = []
        }
        guard !items.isEmpty else { return 0 }
        // Publish and record undo only after the whole updated project is saved successfully.
        try ProjectFiles.save(updated,to:folder)
        undoHistory.append(previous); if undoHistory.count > 80 { undoHistory.removeFirst() }
        chapter = updated; unsaved = false
        let selected = items.first(where:{ overflow.contains($0.blockID) }) ?? items[0]
        selectedPage = selected.key.page
        selectedBlock = nil; healing = false; adding = false; textEditing = true
        selectedTextLayer = selected.layerID
        if fitBrowserText {
            status = "Добавлено реплик: \(items.count)." + (overflow.isEmpty ? "" : " Проверьте рамки у \(overflow.count) реплик, которые не поместились.")
        } else { status = "Импортировано реплик: \(items.count). Проверьте расположение и размер текста." }
        return items.count
    }
    func finishTranslationImport(_ plan: TranslationImportPlan, policy: TranslationImportPolicy, allowPartial: Bool, fontName: String? = nil) {
        do {
            try commitTranslationImport(plan,policy:policy,allowPartial:allowPartial,fontName:fontName)
            pendingTranslationImport = nil
        } catch {
            pendingTranslationImport = nil
            message = "Не удалось импортировать перевод. \(error.localizedDescription)"
        }
    }
    func exportPagePNG(to output: URL) throws {
        guard let input = imageURL, let page else { throw UpscaleFailure("Выберите страницу для экспорта.") }
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        let protected = chapter?.pages.flatMap { [$0.file,$0.imagePath] }.map { folder!.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath() } ?? []
        guard !protected.contains(destination) else { throw UpscaleFailure("Выберите другое имя, чтобы сохранить исходник и рабочие изображения.") }
        try TextRenderer.export(image:input,layers:page.textLayers ?? [],to:output)
    }
    private(set) var lastBatchExportURL: URL?
    func saveAllPages(to output: URL, reveal: Bool = false) {
        guard !busy, let chapter, let folder, save() else { return }
        busy = true; stopRequested = false; lastBatchExportURL = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let run = try PageExportRun(chapter:chapter,source:folder,output:output)
                for index in chapter.pages.indices {
                    await Task.yield()
                    if stopRequested { status = "Сохранение остановлено. Готовая папка не создана."; return }
                    status = "Сохранение PNG: \(index+1) из \(chapter.pages.count)…"
                    try run.exportPage(index)
                }
                await Task.yield()
                if stopRequested { status = "Сохранение остановлено. Готовая папка не создана."; return }
                let destination = try run.complete()
                lastBatchExportURL = destination
                status = "Сохранено страниц: \(chapter.pages.count). Папка: \(destination.lastPathComponent)"
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } catch { message = error.localizedDescription; status = "Не удалось сохранить все страницы." }
        }
    }
    func chooseAllPNGExport() {
        guard !busy, chapter != nil, save() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Сохранить страницы"
        panel.message = "Выберите папку. Inkflow создаст внутри новую папку со всеми страницами PNG и видимыми текстовыми слоями."
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { saveAllPages(to:url,reveal:true) }
    }
    func choosePNGExport() {
        guard !busy, let page, save() else { return }
        guard let folder else { return }
        let exports = folder.appendingPathComponent("exports",isDirectory:true)
        do { try FileManager.default.createDirectory(at:exports,withIntermediateDirectories:true) }
        catch { message = "Не удалось создать папку для PNG. \(error.localizedDescription)"; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = page.file + "_lettered.png"
        panel.directoryURL = exports
        if panel.runModal() == .OK, let url = panel.url {
            do { try exportPagePNG(to:url); status = "PNG с текстом сохранён: \(url.lastPathComponent)" }
            catch { message = error.localizedDescription }
        }
    }
    func textBinding(_ id: UUID, translated: Bool = false) -> Binding<String> {
        // Read the live model, not a BlockCard's captured value. TextEditor can
        // read this binding again after a write, before SwiftUI rebuilds the card.
        Binding(get: {
            guard let block = self.page?.blocks.first(where: { $0.id == id }) else { return "" }
            return translated ? block.translation?.text ?? "" : block.text
        }, set: { value in
            if translated { self.translationText(id, value:value) }
            else { self.text(id, value:value) }
        })
    }
    func text(_ id: UUID, value: String) { edit { p in if let i = p.blocks.firstIndex(where: { $0.id == id }) { p.blocks[i].text = value } } }
    func include(_ id: UUID, value: Bool) { edit { p in if let i = p.blocks.firstIndex(where: { $0.id == id }) { p.blocks[i].included = value } } }
    func move(_ id: UUID, by delta: Int) {
        edit { p in
            guard let i = p.blocks.firstIndex(where: { $0.id == id }), p.blocks.indices.contains(i+delta) else { return }
            p.blocks.swapAt(i,i+delta)
        }
    }
    func merge(_ id: UUID) {
        edit { p in
            guard let i = p.blocks.firstIndex(where: { $0.id == id }), i+1 < p.blocks.count else { return }
            let next = p.blocks.remove(at:i+1)
            p.blocks[i].text += " " + next.text
            p.blocks[i].original += "\n" + next.original
            p.blocks[i].ocrLines = (p.blocks[i].ocrLines ?? [p.blocks[i].box]) + (next.ocrLines ?? [next.box])
            p.blocks[i].box = p.blocks[i].box.union(next.box)
            if let translation = next.translation {
                if p.blocks[i].translation != nil { p.blocks[i].translation?.text += " " + translation.text }
                else { p.blocks[i].translation = translation }
            }
            if !next.warning.isEmpty { p.blocks[i].warning += " " + next.warning }
        }
    }
    func delete(_ id: UUID) { edit { $0.blocks.removeAll { $0.id == id } }; selectedBlock = nil }
    func undo() {
        guard !busy, var c = undoHistory.popLast() else { return }
        // Keep the browser draft and preferred face independently of page edits.
        c.browserTranslation = chapter?.browserTranslation
        c.browserTranslationFont = chapter?.browserTranslationFont
        if chapter?.pages.map(\.imagePath) != c.pages.map(\.imagePath)
            || chapter?.pages.map(\.autoCleanSignature) != c.pages.map(\.autoCleanSignature) {
            cleaningSkippedPages = []
        }
        chapter = c; unsaved = true; _ = save(); status = "Последняя правка отменена"
    }
    func markReviewed() {
        guard !busy, let i = pageIndex, var c = chapter, c.pages[i].scanned else { return }
        undoHistory.append(c); c.pages[i].reviewed.toggle(); chapter = c; unsaved = true; _ = save()
    }
    func stop() {
        if let job = cleaningJob {
            stopRequested = true
            if job.process.isRunning { job.process.terminate() }
            status = "Остановка очистки текста…"
            return
        }
        if let job = healingJob {
            stopRequested = true
            if job.process.isRunning { job.process.terminate() }
            status = "Остановка восстановления фона…"
            return
        }
        if let job = upscaleJob {
            stopRequested = true
            if job.process.isRunning { job.process.terminate() }
            status = "Остановка апскейла…"
            return
        }
        stopRequested = true; status = "Остановка после текущей страницы…" }
    func upscale() {
        guard !busy, chapter != nil, folder != nil, save() else { return }
        let defaults = UserDefaults.standard
        var repository = defaults.string(forKey: "nunifRepository").map { URL(fileURLWithPath: $0) }
        if repository == nil {
            let candidate = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/nunif")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("waifu2x/cli.py").path) { repository = candidate }
        }
        if repository == nil || !FileManager.default.fileExists(atPath: repository!.appendingPathComponent("waifu2x/cli.py").path) {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.message = "Выберите папку nunif с модулем waifu2x."; panel.prompt = "Выбрать nunif"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            repository = url
        }
        guard let repository, FileManager.default.fileExists(atPath: repository.appendingPathComponent("waifu2x/cli.py").path) else {
            message = "В выбранной папке нет waifu2x/cli.py."; return
        }
        var python = defaults.string(forKey: "nunifPython").map { URL(fileURLWithPath: $0) }
        if python == nil || !FileManager.default.isExecutableFile(atPath: python!.path) {
            python = [".venv/bin/python", "venv/bin/python"].map { repository.appendingPathComponent($0) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        if python == nil {
            let panel = NSOpenPanel(); panel.message = "Выберите Python окружения, в котором установлен nunif."; panel.prompt = "Выбрать Python"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            python = url
        }
        guard let python else { return }
        defaults.set(repository.path, forKey: "nunifRepository"); defaults.set(python.path, forKey: "nunifPython")
        upscaleAll(repository: repository, python: python)
    }

    func upscaleAll(repository: URL, python: URL) {
        guard !busy, let source = chapter, let folder, !source.pages.isEmpty, save() else { return }
        let run = "upscaled/" + UUID().uuidString
        busy = true; adding = false; stopRequested = false
        Task {
            var completed = 0
            defer { upscaleJob = nil; busy = false }
            for (index, page) in source.pages.enumerated() {
                if stopRequested { break }
                let relative = run + "/" + page.file + "_x2.png"
                let output = folder.appendingPathComponent(relative)
                let input = folder.appendingPathComponent(page.imagePath)
                status = "Апскейл ×2: \(index + 1) из \(source.pages.count) · \(page.file)"
                do {
                    let job = try UpscaleJob(repository: repository, python: python, input: input, output: output)
                    try job.process.run(); upscaleJob = job
                    let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                        do { try job.finish(); return nil } catch { return error.localizedDescription }
                    }.value
                    upscaleJob = nil
                    if stopRequested { break }
                    if let failure { throw UpscaleFailure(failure) }
                    guard var updated = chapter, let i = updated.pages.firstIndex(where: { $0.file == page.file }),
                          let size = UpscaleJob.dimensions(output) else { throw UpscaleFailure("Не удалось открыть результат апскейла.") }
                    updated.pages[i].imageFile = relative
                    updated.pages[i].width = size.0; updated.pages[i].height = size.1
                    updated.pages[i].fingerprint = ProjectFiles.fingerprint(output)
                    updated.pages[i].reviewed = false; updated.pages[i].translationReviewed = false
                    updated.pages[i].error = nil
                    // Commit the new working image before exposing it in the UI.
                    try ProjectFiles.save(updated, to: folder)
                    chapter = updated; unsaved = false; completed += 1
                    undoHistory = []
                } catch {
                    status = "Апскейл прерван: готово \(completed) из \(source.pages.count)."
                    message = "Не удалось обработать \(page.file). \(error.localizedDescription)"
                    return
                }
            }
            status = stopRequested
                ? "Апскейл остановлен: готово \(completed) из \(source.pages.count)."
                : "Апскейл ×2 завершён: \(completed) изображений. Можно продолжать работу."
        }
    }
    func stopUpscaleOnExit() {
        if let job = upscaleJob, job.process.isRunning { job.process.terminate() }
        if let job = healingJob, job.process.isRunning { job.process.terminate() }
        if let job = cleaningJob, job.process.isRunning { job.process.terminate() }
    }

    func startTextCleaning() { cleanDetectedText() }

    func cleanDetectedText(afterTXTExport: Bool = false, python overridePython: URL? = nil, script overrideScript: URL? = nil) {
        guard !busy, let source = chapter, let folder, save() else { return }
        let prefix = afterTXTExport ? "TXT и карта сохранены. " : ""
        let eligible = source.pages.indices.filter { source.pages[$0].scanned && source.pages[$0].blocks.contains { $0.included && !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } }
        let pending = eligible.filter { index in
            let page = source.pages[index]
            let actual = ProjectFiles.fingerprint(folder.appendingPathComponent(page.imagePath))
            return page.autoCleanSignature != (try? TextCleaningConfiguration(page:page).signature(imageFingerprint:actual))
        }
        guard !pending.isEmpty else {
            status = prefix + (eligible.isEmpty ? "Нет распознанных областей для очистки." : "Эти области уже обработаны.")
            return
        }
        let stored = UserDefaults.standard.string(forKey:"nunifPython").map { URL(fileURLWithPath:$0) }
        let candidates = [overridePython, stored,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/nunif/.venv/bin/python"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/nunif/venv/bin/python")]
        guard let python = candidates.compactMap({ $0 }).first(where:{ FileManager.default.isExecutableFile(atPath:$0.path) }),
              let script = overrideScript ?? Bundle.main.url(forResource:"clean-text",withExtension:"py") else {
            status = prefix + "Очистка не запущена."
            message = prefix + "Для очистки нужен Python с OpenCV и Pillow, выбранный для nunif, и обновлённая сборка Inkflow."
            return
        }
        let run = "cleaned/" + UUID().uuidString
        let directory = folder.appendingPathComponent(run,isDirectory:true)
        busy = true; stopRequested = false; adding = false
        status = prefix + "Подготовка очистки текста…"
        Task {
            var published = false
            defer {
                cleaningJob = nil; busy = false
                if !published { try? FileManager.default.removeItem(at:directory) }
            }
            var updated = source
            var totalSmooth = 0, totalTexture = 0, totalSkipped = 0, changedPages = 0
            var skippedPages: [String] = []
            do {
                for (number,index) in pending.enumerated() {
                    if stopRequested { status = prefix + "Очистка остановлена. Рабочие изображения не изменились."; return }
                    let page = source.pages[index]
                    let input = folder.appendingPathComponent(page.imagePath)
                    // OCR geometry must still describe this working image.
                    guard page.error == nil, page.fingerprint == ProjectFiles.fingerprint(input) else {
                        throw UpscaleFailure("Страница \(page.file) изменилась или недоступна. Проверьте её перед очисткой.")
                    }
                    let config = TextCleaningConfiguration(page:page)
                    let relative = run + "/" + String(format:"%04d.png",index+1)
                    let output = folder.appendingPathComponent(relative)
                    status = "Очистка текста: \(number+1) из \(pending.count) · \(page.file)"
                    let job = try HealingJob(python:python,script:script,input:input,output:output,configuration:JSONEncoder().encode(config))
                    try job.process.run(); cleaningJob = job
                    let failure = await Task.detached(priority:.userInitiated) { () -> String? in
                        do { try job.finish(); return nil } catch { return error.localizedDescription }
                    }.value
                    cleaningJob = nil
                    if stopRequested { status = prefix + "Очистка остановлена. Рабочие изображения не изменились."; return }
                    if let failure { throw UpscaleFailure("\(page.file): \(failure)") }
                    guard let data = job.reportData else { throw UpscaleFailure("Не получен отчёт очистки \(page.file).") }
                    let report = try JSONDecoder().decode(TextCleaningReport.self,from:data)
                    totalSmooth += report.smooth; totalTexture += report.texture; totalSkipped += report.skipped
                    if report.skipped > 0 { skippedPages.append("\(page.file) · \(report.skipped)") }
                    if report.changedPixels > 0 {
                        updated.pages[index].imageFile = relative
                        updated.pages[index].fingerprint = ProjectFiles.fingerprint(output)
                        updated.pages[index].error = nil
                        changedPages += 1
                    } else { try FileManager.default.removeItem(at:output) }
                    updated.pages[index].autoCleanSignature = try config.signature(imageFingerprint:updated.pages[index].fingerprint)
                }
                // No page is exposed until the complete chapter and all files are ready.
                try ProjectFiles.save(updated,to:folder)
                undoHistory.append(source); if undoHistory.count > 80 { undoHistory.removeFirst() }
                chapter = updated; unsaved = false
                cleaningSkippedPages = skippedPages
                published = changedPages > 0
                status = prefix + "Очищено страниц: \(changedPages). Обработано областей: \(totalSmooth+totalTexture), пропущено: \(totalSkipped)."
            } catch {
                status = prefix + "Очистка не завершена. Рабочие изображения не изменились."
                message = prefix + error.localizedDescription
            }
        }
    }

    func heal(_ points: [BrushPoint], python overridePython: URL? = nil, script overrideScript: URL? = nil) {
        guard !busy, let page, let input = imageURL, let folder, !points.isEmpty, save() else { return }
        let stored = UserDefaults.standard.string(forKey: "nunifPython").map { URL(fileURLWithPath: $0) }
        let candidates = [overridePython, stored,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/nunif/.venv/bin/python"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/nunif/venv/bin/python")]
        guard let python = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            message = "Не найден Python для кисти. Настройте nunif через кнопку апскейла и повторите мазок."; return
        }
        guard let script = overrideScript ?? Bundle.main.url(forResource: "heal-image", withExtension: "py") else {
            message = "Не найден инструмент восстановления фона. Пересоберите Inkflow."; return
        }
        let relative = "edited/" + UUID().uuidString + ".png"
        let output = folder.appendingPathComponent(relative)
        do {
            let job = try HealingJob(python: python, script: script, input: input, output: output,
                stroke: BrushStroke(diameter: brushDiameter, points: points, method:healingMethod))
            try job.process.run(); healingJob = job; busy = true; stopRequested = false
            status = "Восстановление фона…"
            Task {
                defer { healingJob = nil; busy = false }
                let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                    do { try job.finish(); return nil } catch { return error.localizedDescription }
                }.value
                if stopRequested { status = "Восстановление фона остановлено."; return }
                if let failure { message = failure; status = "Фон не восстановлен."; return }
                guard var updated = chapter, let i = updated.pages.firstIndex(where: { $0.file == page.file }) else { return }
                updated.pages[i].imageFile = relative
                updated.pages[i].fingerprint = ProjectFiles.fingerprint(output)
                if let size = UpscaleJob.dimensions(output) { updated.pages[i].width = size.0; updated.pages[i].height = size.1 }
                updated.pages[i].reviewed = false; updated.pages[i].error = nil
                do {
                    try ProjectFiles.save(updated, to: folder)
                    if let previous = chapter { undoHistory.append(previous); if undoHistory.count > 80 { undoHistory.removeFirst() } }
                    chapter = updated; unsaved = false
                    status = "Фон восстановлен. Мазок сохранён; его можно отменить."
                } catch { message = "Не удалось сохранить мазок. \(error.localizedDescription)" }
            }
        } catch { message = "Не удалось запустить кисть. \(error.localizedDescription)" }
    }

    func scanAll() {
        guard !busy, let c = chapter, let f = folder else { return }
        // Never overwrite existing blocks or manual work through batch recognition.
        let files = c.pages.filter { !$0.scanned }.map(\.file)
        guard !files.isEmpty else { guard prepareTranslationLayers() else { return }; status = "Страницы уже распознаны. Места перевода подготовлены во вкладке «Текст на странице»."; return }
        busy = true; stopRequested = false; adding = false
        Task {
            for (n,file) in files.enumerated() {
                if stopRequested { break }
                status = "Распознавание \(n+1) из \(files.count): \(file)"
                guard let sourcePage = chapter?.pages.first(where: { $0.file == file }) else { continue }
                let url = f.appendingPathComponent(sourcePage.imagePath)
                do {
                    var result = try await Task.detached(priority:.userInitiated) { try Scanner.scan(url) }.value
                    result.file = file; result.imageFile = sourcePage.imageFile; result.textLayers = sourcePage.textLayers
                    TranslationAnchors.ensure(in:&result)
                    if let i = chapter?.pages.firstIndex(where: { $0.file == file }) { chapter?.pages[i] = result; unsaved = true }
                } catch {
                    if let i = chapter?.pages.firstIndex(where: { $0.file == file }) { chapter?.pages[i].error = error.localizedDescription; unsaved = true }
                }
                if !save() { break }
            }
            busy = false
            let failed = chapter?.pages.filter { $0.error != nil }.count ?? 0
            status = stopRequested ? "Обработка остановлена. Результаты сохранены." : "Распознавание завершено. Места перевода подготовлены. Проверьте порядок и текст.\(failed > 0 ? " Страниц с ошибками: \(failed)." : "")"
        }
    }
    func addRegion(_ box: Box) {
        guard !busy, let url = imageURL, let file = page?.file else { return }
        busy = true; adding = false; status = "Распознавание выделенного облачка…"
        Task {
            let result = await Task.detached(priority:.userInitiated) { try? Scanner.scan(url,region:box) }.value
            busy = false
            let text = result.map { ReadingOrder.join($0.blocks.map(\.text)) } ?? ""
            let block = TextBlock(text:text, original:result?.blocks.map(\.original).joined(separator:"\n") ?? "", box:box, warning:text.isEmpty ? "Текст не распознан. Введите реплику вручную." : "Проверьте место новой реплики в последовательности.")
            if var c = chapter, let i = c.pages.firstIndex(where: { $0.file == file }) {
                undoHistory.append(c)
                c.pages[i].blocks.append(block)
                TranslationAnchors.ensure(in:&c.pages[i])
                c.pages[i].translationReviewed = false
                c.pages[i].reviewed = false
                chapter = c; unsaved = true
                if save() { status = "Облачко добавлено на страницу \(file). Проверьте порядок реплик." }
                if selectedPage == file { selectedBlock = block.id }
            }
        }
    }
    func translationText(_ id: UUID, value: String) {
        guard !busy, let i = pageIndex, var c = chapter,
              let b = c.pages[i].blocks.firstIndex(where: { $0.id == id }) else { return }
        undoHistory.append(c); if undoHistory.count > 80 { undoHistory.removeFirst() }
        let previous = c.pages[i].blocks[b].translation
        c.pages[i].blocks[b].translation = TranslationRecord(text:value,
            source:previous?.source ?? c.pages[i].blocks[b].text,
            context:previous?.context ?? ProjectFiles.translationContext(c.pages[i],glossary:c.glossary),
            model:previous?.model ?? "manual")
        c.pages[i].translationReviewed = false
        chapter = c; unsaved = true; if save() { status = "Перевод сохранён" }
    }
    func markTranslationReviewed() {
        guard !busy, let i = pageIndex, var c = chapter else { return }
        let included = c.pages[i].blocks.filter(\.included)
        guard !included.isEmpty, included.allSatisfy({ !($0.translation?.text.trimmingCharacters(in:.whitespacesAndNewlines) ?? "").isEmpty }) else {
            message = "Сначала заполните перевод всех включённых реплик страницы."; return
        }
        undoHistory.append(c)
        let context = ProjectFiles.translationContext(c.pages[i],glossary:c.glossary)
        for j in c.pages[i].blocks.indices where c.pages[i].blocks[j].included {
            let source = c.pages[i].blocks[j].text
            c.pages[i].blocks[j].translation?.source = source
            c.pages[i].blocks[j].translation?.context = context
        }
        c.pages[i].translationReviewed = true; chapter = c; unsaved = true; _ = save()
    }
    func beginBrowserTranslation() {
        guard !busy, chapter != nil, prepareTranslationLayers(), let chapter else { return }
        do {
            browserTranslation = try BrowserTranslation(chapter:chapter)
            browserTranslationProblem = nil
        } catch {
            browserTranslation = nil
            browserTranslationProblem = error.localizedDescription
        }
        browserSourcePasteboardChange = nil
        showBrowserTranslation = true
    }
    func closeBrowserTranslation() {
        showBrowserTranslation = false
        browserTranslation = nil
        browserTranslationProblem = nil
        browserTranslationPreview = nil
        browserSourcePasteboardChange = nil
    }
    func copyAndOpenYandex(part: Int) throws {
        guard let parts = browserTranslation?.parts, parts.indices.contains(part) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(parts[part].source,forType:.string) else {
            throw TranslationImportError("Не удалось скопировать оригинал. Попробуйте ещё раз.")
        }
        browserSourcePasteboardChange = pasteboard.changeCount
        guard NSWorkspace.shared.open(URL(string:"https://translate.yandex.ru/?source_lang=en&target_lang=ru")!) else {
            throw TranslationImportError("Оригинал скопирован. Откройте translate.yandex.ru и вставьте его в левое поле.")
        }
    }
    func browserResultFromPasteboard() throws -> String {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != browserSourcePasteboardChange,
              let text = pasteboard.string(forType:.string), !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw TranslationImportError("Скопируйте русский результат из правого поля Яндекса.")
        }
        return text
    }
    func acceptBrowserResult(_ text: String, for part: Int) throws {
        try browserTranslation?.accept(text,for:part)
    }
    func clearBrowserResult(for part: Int) {
        browserTranslation?.clearResult(for:part)
    }
    func reviewBrowserTranslation() throws {
        guard !busy, let chapter, let browserTranslation else { return }
        browserTranslationPreview = try browserTranslation.plan(for:chapter)
    }
    func setBrowserTranslation(_ text: String) {
        guard chapter != nil else { return }
        chapter?.browserTranslation = text; unsaved = true; _ = save()
    }
    func appendBrowserTranslation() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "В буфере обмена нет текста. Скопируйте русский перевод в браузере."; return
        }
        let previous = chapter?.browserTranslation ?? ""
        setBrowserTranslation(previous + (previous.isEmpty ? "" : "\n\n") + text)
    }
    func exportBrowserTranslation() {
        guard let c = chapter, let text = c.browserTranslation,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, save() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = c.name + "_ru.txt"; panel.directoryURL = folder
        panel.prompt = "Сохранить RU TXT"
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8); status = "Сохранено: \(url.lastPathComponent)" }
            catch { message = "Не удалось сохранить перевод. \(error.localizedDescription)" }
        }
    }
    func export() {
        guard !busy, let c = chapter, save() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = c.name + (exportMode == .original ? "" : exportMode == .translated ? "_ru_blocks" : "_en-ru") + ".txt"; panel.directoryURL = folder
        panel.prompt = "Сохранить TXT"
        if panel.runModal() == .OK, let url = panel.url {
            do { try exportTXT(to:url); if !autoCleanAfterExport { status = "TXT и карта мест перевода сохранены: \(url.lastPathComponent)" } }
            catch { message = "Не удалось сохранить TXT. \(error.localizedDescription)" }
        }
    }
}
