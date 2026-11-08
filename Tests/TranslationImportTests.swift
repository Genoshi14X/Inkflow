import Foundation

@main struct TranslationImportTests {
    @MainActor static func main() throws {
        func rejected(_ action: () throws -> Void) {
            do { try action(); fatalError("Invalid translation must be rejected") } catch {}
        }
        let basic = "\u{feff}Глава 155\r\n=== Страница 01.png ===\r\n[Порядок и текст не проверены]\r\n[01]\r\nПривет!\r\n\r\nВторая строка.\r\n[02] До встречи.\r\n"
        let parsed = try TranslationDocument.parse(basic)
        precondition(parsed.entries.count == 2 && parsed.entries[0].text == "Привет!\n\nВторая строка.")
        precondition(parsed.entries[1].key.number == 2 && parsed.entries[1].text == "До встречи.")
        let bilingual = try TranslationDocument.parse("=== Page 01.png ===\n[01]\nEN: Hello\nRU: Привет\nПродолжение\n[Перевод не проверен]\n")
        precondition(bilingual.entries[0].text == "Привет\nПродолжение")
        for text in ["", "No structured translation", "[01]\nПривет", "=== Страница 01.png ===\n[00]\nТекст",
                     "=== Страница 01.png ===\n[01]\n[Нет перевода]", "=== Страница 01.png ===\n[01]\nA\n[1]\nB",
                     "=== Страница 01.png ===\n[01]\nA\n=== Страница 01.png ===\n[02]\nB",
                     "=== Страница 01.png ===\n[01]\nEN: Hello", "=== Страница 01.png ===\n[01]\nТекст\n=== bad header ===",
                     "=== Страница 01.png ===\n[01]\nТекст\n[02"] {
            rejected { _ = try TranslationDocument.parse(text) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Inkflow import ' " + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let image = folder.appendingPathComponent("01.png")
        try Data("untouched pixels".utf8).write(to:image)
        let textFile = folder.appendingPathComponent("155_ru.txt")
        try Data(basic.utf8).write(to:textFile)
        precondition(tryRead(textFile) == 2)
        let utf16 = folder.appendingPathComponent("utf16.txt")
        try (Data([0xff,0xfe]) + basic.replacingOccurrences(of:"\u{feff}",with:"").data(using:.utf16LittleEndian)!).write(to:utf16)
        precondition(tryRead(utf16) == 2)
        let a = TextBlock(text:"HELLO",original:"HELLO",box:Box(x:0.6,y:0.1,width:0.2,height:0.1))
        let b = TextBlock(text:"BYE",original:"BYE",box:Box(x:0.1,y:0.5,width:0.3,height:0.2))
        var page = ScanPage(file:"01.png",width:1000,height:1500,blocks:[a,b],scanned:true,reviewed:true,
            fingerprint:ProjectFiles.fingerprint(image))
        TranslationAnchors.ensure(in:&page)
        var original = Chapter(name:"155",pages:[page],browserTranslation:"Keep browser draft")
        let map = try TextExportMap(chapter:original,mode:.original)
        let mapFile = folder.appendingPathComponent("155.inkflow-map.json")
        try JSONEncoder().encode(map).write(to:mapFile)
        // A later reorder and manual layout must not move the imported translation to another bubble.
        original.pages[0].blocks.swapAt(0,1)
        original.pages[0].textLayers![0].box.x = 0.55
        original.pages[0].textLayers![0].bold = true
        original.pages[0].textLayers![0].fontName = "Helvetica-Bold"
        original.pages[0].textLayers![0].anchorEdited = true
        try ProjectFiles.save(original,to:folder)
        let model = MangaModel(); model.open(folder)
        let before = model.chapter!
        let plan = try model.translationImportPlan(txt:textFile,map:mapFile)
        precondition(plan.missing.isEmpty && plan.conflicts == 0 && plan.pageCount == 1)
        precondition(model.chapter!.pages[0].textLayers == before.pages[0].textLayers,"Preview must not mutate anything")
        let count = try model.commitTranslationImport(plan,policy:.keepExisting,allowPartial:false)
        precondition(count == 2)
        let first = model.page!.textLayers!.first { $0.sourceBlockID == a.id }!
        precondition(first.text == "Привет!\n\nВторая строка." && first.box.x == 0.55 && first.bold == true && first.fontName == "Helvetica-Bold")
        precondition(model.page!.blocks.first { $0.id == b.id }!.translation?.text == "До встречи.")
        precondition(model.chapter!.browserTranslation == "Keep browser draft" && model.page!.reviewed)
        let stored = try ProjectFiles.load(folder)
        precondition(stored.pages[0].textLayers == model.page!.textLayers)
        let history = model.undoHistory.count
        let again = try model.commitTranslationImport(plan,policy:.keepExisting,allowPartial:false)
        precondition(again == 0 && model.undoHistory.count == history,"Repeated import must be idempotent")
        model.undo(); precondition(model.page!.textLayers == before.pages[0].textLayers && model.page!.blocks.allSatisfy { $0.translation == nil })
        let imageAfter = try Data(contentsOf:image); precondition(imageAfter == Data("untouched pixels".utf8))
        // Missing entries need explicit confirmation and never empty the absent layer.
        let partialDocument = try TranslationDocument.parse("=== Страница 01.png ===\n[02]\nПока!")
        let partial = try TranslationImporter.plan(document:partialDocument,map:map,chapter:before)
        precondition(partial.missing.count == 1)
        rejected { _ = try TranslationImporter.applying(partial,to:before,policy:.keepExisting,allowPartial:false) }
        let (partiallyUpdated,partialItems) = try TranslationImporter.applying(partial,to:before,policy:.keepExisting,allowPartial:true)
        precondition(partialItems.count == 1 && partiallyUpdated.pages[0].textLayers!.first { $0.sourceBlockID == a.id }!.text.isEmpty)
        // Existing text in either the layer or OCR translation is preserved unless replacement is chosen.
        var conflictChapter = before
        conflictChapter.pages[0].textLayers![0].text = "Ручная версия"
        let conflicting = try TranslationImporter.plan(document:parsed,map:map,chapter:conflictChapter)
        precondition(conflicting.conflicts == 1)
        let (kept,keptItems) = try TranslationImporter.applying(conflicting,to:conflictChapter,policy:.keepExisting,allowPartial:false)
        precondition(keptItems.count == 1 && kept.pages[0].textLayers![0].text == "Ручная версия")
        let (replaced,replacedItems) = try TranslationImporter.applying(conflicting,to:conflictChapter,policy:.replaceExisting,allowPartial:false)
        precondition(replacedItems.count == 2 && replaced.pages[0].textLayers![0].text == parsed.entries[0].text)
        conflictChapter.pages[0].textLayers![0].text = ""
        conflictChapter.pages[0].blocks[1].translation = TranslationRecord(text:"Другой перевод OCR",source:a.text,context:"",model:"manual")
        let ruConflict = try TranslationImporter.plan(document:parsed,map:map,chapter:conflictChapter)
        precondition(ruConflict.conflicts == 1 && ruConflict.items[0].previous.contains("Другой перевод OCR"))
        // Recreate a removed layer from exported geometry, but keep any currently linked replacement.
        var removed = before
        removed.pages[0].textLayers = []
        let missingLayer = try TranslationImporter.plan(document:parsed,map:map,chapter:removed)
        let (restored,_) = try TranslationImporter.applying(missingLayer,to:removed,policy:.keepExisting,allowPartial:false)
        precondition(restored.pages[0].textLayers![0].id == map.entries[0].layerID && restored.pages[0].textLayers![0].box == map.entries[0].box)
        removed.pages[0].textLayers = [TranslationAnchors.make(for:a,page:page)]
        removed.pages[0].textLayers![0].box.x = 0.42
        let replacement = try TranslationImporter.plan(document:parsed,map:map,chapter:removed)
        precondition(replacement.items[0].layerID == removed.pages[0].textLayers![0].id && replacement.items[0].newLayer == nil)
        // Stale/foreign maps and malformed files cannot modify the project.
        var foreign = map; foreign.entries[0].blockID = UUID()
        rejected { _ = try TranslationImporter.plan(document:parsed,map:foreign,chapter:before) }
        var duplicate = map; duplicate.entries.append(duplicate.entries[0])
        rejected { _ = try TranslationImporter.plan(document:parsed,map:duplicate,chapter:before) }
        var version = map; version.version = 99
        rejected { _ = try TranslationImporter.plan(document:parsed,map:version,chapter:before) }
        let unknown = try TranslationDocument.parse("=== Страница 01.png ===\n[99]\nТекст")
        rejected { _ = try TranslationImporter.plan(document:unknown,map:map,chapter:before) }
        var deleted = before; deleted.pages[0].blocks.removeAll { $0.id == a.id }
        rejected { _ = try TranslationImporter.applying(plan,to:deleted,policy:.replaceExisting,allowPartial:false) }
        // Save failure must not publish imported text or append undo history.
        let stateEncoder = JSONEncoder(); stateEncoder.outputFormatting = [.sortedKeys]
        let currentModelData = try stateEncoder.encode(model.chapter!)
        let historyBeforeFailure = model.undoHistory.count
        let saveURL = folder.appendingPathComponent(ProjectFiles.saveName)
        try FileManager.default.removeItem(at:saveURL)
        try FileManager.default.createDirectory(at:saveURL,withIntermediateDirectories:true)
        rejected { _ = try model.commitTranslationImport(plan,policy:.replaceExisting,allowPartial:false) }
        let afterFailure = try stateEncoder.encode(model.chapter!)
        precondition(currentModelData == afterFailure,"Failed import must not change any project field")
        precondition(model.page!.textLayers == before.pages[0].textLayers && model.undoHistory.count == historyBeforeFailure)
        print("PASS: TXT parser, UTF-8/16, mapping after reorder, preview, import, styles, conflicts, partial files, undo, persistence, idempotence, stale maps and save failure")
    }
    static func tryRead(_ url: URL) -> Int { (try! TranslationDocument.read(url)).entries.count }
}
