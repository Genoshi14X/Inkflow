import Foundation

@main struct TranslationAnchorTests {
    @MainActor static func main() throws {
        let a = TextBlock(text:"FIRST",original:"FIRST",box:Box(x:0.6,y:0.1,width:0.2,height:0.1))
        let b = TextBlock(text:"SECOND",original:"SECOND",box:Box(x:0.1,y:0.4,width:0.3,height:0.15))
        var excluded = TextBlock(text:"SFX",original:"SFX",box:Box(x:0.2,y:0.8,width:0.1,height:0.1))
        excluded.included = false
        let manual = TextLayer(text:"Existing manual translation",bold:true)
        var page = ScanPage(file:"01.png",width:1000,height:1500,textLayers:[manual],blocks:[a,b,excluded],scanned:true,reviewed:true)
        precondition(TranslationAnchors.ensure(in:&page))
        precondition(page.textLayers!.count == 3 && page.textLayers![0] == manual)
        for block in [a,b] {
            let layer = page.textLayers!.first { $0.sourceBlockID == block.id }!
            precondition(layer.text.isEmpty && layer.box == block.box && layer.fontScale > 0)
        }
        let originalIDs = page.textLayers!.map(\.id)
        precondition(!TranslationAnchors.ensure(in:&page))
        precondition(page.textLayers!.map(\.id) == originalIDs)
        var chapter = Chapter(name:"155",pages:[page])
        let firstMap = try TextExportMap(chapter:chapter,mode:.original)
        precondition(firstMap.entries.map(\.blockID) == [a.id,b.id] && firstMap.mode == "original")
        page.blocks.swapAt(0,1)
        precondition(!TranslationAnchors.ensure(in:&page))
        chapter.pages[0] = page
        let reorderedMap = try TextExportMap(chapter:chapter,mode:.original)
        precondition(reorderedMap.entries.map(\.blockID) == [b.id,a.id])
        precondition(firstMap.entries[0].blockID == a.id && reorderedMap.entries[1].layerID == firstMap.entries[0].layerID)
        // Manual movement, formatting and text must not be replaced by source geometry.
        let aIndex = page.textLayers!.firstIndex { $0.sourceBlockID == a.id }!
        page.textLayers![aIndex].anchorEdited = true
        page.textLayers![aIndex].box.x = 0.55; page.textLayers![aIndex].bold = true
        page.blocks[1].box = Box(x:0.2,y:0.2,width:0.6,height:0.6)
        TranslationAnchors.ensure(in:&page)
        precondition(page.textLayers![aIndex].box.x == 0.55 && page.textLayers![aIndex].bold == true)
        // An untouched layer follows a source frame; filled layers survive source deletion.
        page.blocks[0].box.width = 0.4
        TranslationAnchors.ensure(in:&page)
        let bIndex = page.textLayers!.firstIndex { $0.sourceBlockID == b.id }!
        precondition(page.textLayers![bIndex].box.width == 0.4)
        page.textLayers![bIndex].text = "Перевод"
        page.blocks.removeAll { $0.id == b.id }
        TranslationAnchors.ensure(in:&page)
        precondition(page.textLayers!.contains { $0.text == "Перевод" && $0.sourceBlockID == nil })
        var blank = ScanPage(file:"blank.png",blocks:[a],scanned:true)
        TranslationAnchors.ensure(in:&blank); blank.blocks[0].included = false
        TranslationAnchors.ensure(in:&blank); precondition(blank.textLayers!.isEmpty)
        blank.blocks[0].included = true; TranslationAnchors.ensure(in:&blank)
        blank.blocks.removeAll(); TranslationAnchors.ensure(in:&blank); precondition(blank.textLayers!.isEmpty)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Inkflow anchors ' " + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        // ProjectFiles only enumerates file extensions; this test does not need OCR pixels.
        try Data("original image bytes".utf8).write(to:folder.appendingPathComponent("01.png"))
        let input = folder.appendingPathComponent("01.png")
        var legacy = ScanPage(file:"01.png",width:1000,height:1500,blocks:[a,b,excluded],scanned:true,reviewed:true,
            fingerprint:ProjectFiles.fingerprint(input))
        legacy.translationReviewed = true
        try ProjectFiles.save(Chapter(name:"155",pages:[legacy],browserTranslation:"Черновик"),to:folder)
        let previousAutoCleanPreference = UserDefaults.standard.object(forKey:"autoCleanAfterTXT")
        defer { UserDefaults.standard.set(previousAutoCleanPreference,forKey:"autoCleanAfterTXT") }
        let model = MangaModel(); model.autoCleanAfterExport = false; model.open(folder)
        let expectedTXT = ProjectFiles.transcript(model.chapter!)
        let output = folder.appendingPathComponent("155.txt")
        try model.exportTXT(to:output)
        let actualTXT = try String(contentsOf:output,encoding:.utf8)
        precondition(expectedTXT == actualTXT,"TXT format must stay compatible")
        let mapURL = TextExportMap.url(for:output)
        let map = try JSONDecoder().decode(TextExportMap.self,from:Data(contentsOf:mapURL))
        precondition(map.entries.count == 2 && map.entries[0].number == 1 && map.entries[1].number == 2)
        let restored = try ProjectFiles.load(folder)
        precondition(restored.pages[0].textLayers!.count == 2 && restored.pages[0].reviewed && restored.pages[0].translationReviewed == true)
        precondition(restored.browserTranslation == "Черновик")
        precondition(restored.pages[0].textLayers!.allSatisfy { $0.text.isEmpty })
        let savedIDs = model.page!.textLayers!.map(\.id)
        try model.exportTXT(to:output); precondition(model.page!.textLayers!.map(\.id) == savedIDs)
        model.move(a.id,by:1)
        precondition(model.page!.textLayers!.map(\.id) == savedIDs)
        let secondOutput = folder.appendingPathComponent("reordered.txt")
        try model.exportTXT(to:secondOutput)
        let unchangedMap = try JSONDecoder().decode(TextExportMap.self,from:Data(contentsOf:mapURL))
        precondition(unchangedMap.entries[0].blockID == a.id)
        // Adding from a selected OCR block opens its existing anchor rather than duplicating it.
        model.selectedBlock = a.id; let count = model.page!.textLayers!.count
        model.addTextLayer(); precondition(model.page!.textLayers!.count == count && model.layer!.sourceBlockID == a.id)
        model.updateTextLayer(model.selectedTextLayer!) { $0.box.x = 0.5; $0.bold = true }
        precondition(model.layer!.anchorEdited == true)
        let layout = model.layer!
        precondition(model.prepareTranslationLayers()); precondition(model.layer! == layout)
        // If writing the TXT fails, its previous sidecar must remain intact.
        let bad = folder.appendingPathComponent("blocked.txt")
        try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:true)
        let previousMap = Data("old mapping".utf8)
        let badMap = TextExportMap.url(for:bad); try previousMap.write(to:badMap)
        do { try model.exportTXT(to:bad); fatalError("Directory cannot be a TXT file") } catch {}
        let rolledBack = try Data(contentsOf:badMap); precondition(rolledBack == previousMap)
        let original = try Data(contentsOf:input)
        do { try model.exportTXT(to:input); fatalError("Must protect images") } catch {}
        let preserved = try Data(contentsOf:input); precondition(preserved == original)
        print("PASS: OCR anchors, stable IDs, no duplicates, geometry, manual preservation, exclusions, TXT mapping, persistence and failed exports")
    }
}
