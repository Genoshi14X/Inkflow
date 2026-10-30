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
    @Published var exportMode: ExportMode = .original
    @Published var showBrowserTranslation = false
    @Published var browserPart = 0
    var browserParts: [String] {
        guard let chapter else { return [] }
        return BrowserTranslation.chunks(ProjectFiles.transcript(chapter, mode: .original))
    }
    @Published var undoHistory: [Chapter] = []
    private var healingJob: HealingJob?
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
        action(&c.pages[i]); c.pages[i].reviewed = false; c.pages[i].translationReviewed = false
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
        editTextLayers { action(&$0[index]) }
    }
    func addTextLayer() {
        guard !busy, imageURL != nil else { return }
        var new = TextLayer()
        if let block = page?.blocks.first(where: { $0.id == selectedBlock }) {
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
    func exportPagePNG(to output: URL) throws {
        guard let input = imageURL, let page else { throw UpscaleFailure("Выберите страницу для экспорта.") }
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        let protected = chapter?.pages.flatMap { [$0.file,$0.imagePath] }.map { folder!.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath() } ?? []
        guard !protected.contains(destination) else { throw UpscaleFailure("Выберите другое имя, чтобы сохранить исходник и рабочие изображения.") }
        try TextRenderer.export(image:input,layers:page.textLayers ?? [],to:output)
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
        // Browser drafts are edited independently of page undo history.
        c.browserTranslation = chapter?.browserTranslation
        chapter = c; unsaved = true; _ = save(); status = "Последняя правка отменена"
    }
    func markReviewed() {
        guard !busy, let i = pageIndex, var c = chapter, c.pages[i].scanned else { return }
        undoHistory.append(c); c.pages[i].reviewed.toggle(); chapter = c; unsaved = true; _ = save()
    }
    func stop() {
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

    func scanAll(onlyCurrent: Bool = false) {
        guard !busy, let c = chapter, let f = folder else { return }
        // Never overwrite existing blocks or manual work through batch recognition.
        let files = c.pages.filter { !$0.scanned && (!onlyCurrent || $0.file == selectedPage) }.map(\.file)
        guard !files.isEmpty else { status = "Страницы уже распознаны. Можно проверить и отредактировать реплики."; return }
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
                    if let i = chapter?.pages.firstIndex(where: { $0.file == file }) { chapter?.pages[i] = result; unsaved = true }
                } catch {
                    if let i = chapter?.pages.firstIndex(where: { $0.file == file }) { chapter?.pages[i].error = error.localizedDescription; unsaved = true }
                }
                if !save() { break }
            }
            busy = false
            let failed = chapter?.pages.filter { $0.error != nil }.count ?? 0
            status = stopRequested ? "Обработка остановлена. Результаты сохранены." : "Распознавание завершено. Проверьте порядок и текст.\(failed > 0 ? " Страниц с ошибками: \(failed)." : "")"
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
        guard !busy, let c = chapter, save() else { return }
        guard c.pages.contains(where: { $0.scanned && $0.blocks.contains(where: { $0.included }) }) else {
            message = "Сначала распознайте страницы главы."; return
        }
        browserPart = 0; showBrowserTranslation = true
    }
    func copyAndOpenYandex() {
        let parts = browserParts
        guard parts.indices.contains(browserPart) else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(parts[browserPart], forType: .string) else {
            message = "Не удалось скопировать текст. Попробуйте ещё раз."; return
        }
        if NSWorkspace.shared.open(URL(string:"https://translate.yandex.ru/?source_lang=en&target_lang=ru")!) {
            status = "Английский текст скопирован. Вставьте его в Яндекс Переводчик: ⌘V."
        } else { message = "Текст скопирован, но браузер не открылся. Откройте translate.yandex.ru и вставьте текст: ⌘V." }
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
            do { try ProjectFiles.transcript(c,mode:exportMode).write(to:url,atomically:true,encoding:.utf8); status = "Сохранено: \(url.lastPathComponent)" }
            catch { message = "Не удалось сохранить TXT. \(error.localizedDescription)" }
        }
    }
}
