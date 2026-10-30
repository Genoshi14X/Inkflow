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
    private var stopRequested = false
    private var unsaved = false
    var pageIndex: Int? { chapter?.pages.firstIndex(where: { $0.file == selectedPage }) }
    var page: ScanPage? { guard let i = pageIndex else { return nil }; return chapter?.pages[i] }
    var imageURL: URL? { guard let f = folder, let p = page else { return nil }; return f.appendingPathComponent(p.file) }

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
            selectedBlock = nil; undoHistory = []; adding = false; zoom = 1
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
    func stop() { stopRequested = true; status = "Остановка после текущей страницы…" }
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
                let url = f.appendingPathComponent(file)
                do {
                    let result = try await Task.detached(priority:.userInitiated) { try Scanner.scan(url) }.value
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
