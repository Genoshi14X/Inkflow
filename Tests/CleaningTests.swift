import Foundation
import CoreGraphics
import ImageIO

@main struct CleaningTests {
    @MainActor static func main() async throws {
        guard let pythonPath = ProcessInfo.processInfo.environment["INKFLOW_HEALING_PYTHON"] else {
            print("SKIP: automatic cleaning integration (set INKFLOW_HEALING_PYTHON)"); return
        }
        let fm = FileManager.default, defaults = UserDefaults.standard
        let oldPreference = defaults.object(forKey:"autoCleanAfterTXT")
        defer { defaults.set(oldPreference,forKey:"autoCleanAfterTXT") }
        let folder = fm.temporaryDirectory.appendingPathComponent("Inkflow cleaning ' " + UUID().uuidString)
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:folder) }
        let image = folder.appendingPathComponent("01.png")
        let context = CGContext(data:nil,width:200,height:160,bitsPerComponent:8,bytesPerRow:800,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:200,height:160))
        context.setFillColor(CGColor(gray:0,alpha:1))
        context.fill(CGRect(x:65,y:70,width:10,height:25)); context.fill(CGRect(x:95,y:70,width:10,height:25))
        context.fill(CGRect(x:10,y:10,width:10,height:10))
        let dest = CGImageDestinationCreateWithURL(image as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(dest,context.makeImage()!,nil); precondition(CGImageDestinationFinalize(dest))
        try fm.copyItem(at:image,to:folder.appendingPathComponent("02.png"))
        try fm.createDirectory(at:folder.appendingPathComponent("edited"),withIntermediateDirectories:true)
        try fm.copyItem(at:image,to:folder.appendingPathComponent("edited/working.png"))
        let originalData = try Data(contentsOf:image)
        var chapter = try ProjectFiles.load(folder)
        for i in chapter.pages.indices {
            chapter.pages[i].scanned = true
            let box = Box(x:0.25,y:0.375,width:0.5,height:0.25)
            chapter.pages[i].blocks = [TextBlock(text:"HI",original:"HI",box:box,
                translation:TranslationRecord(text:"ПРИВЕТ",source:"HI",context:"",model:"manual"),ocrLines:[box]),
                TextBlock(text:"EXCLUDED",original:"EXCLUDED",box:Box(x:0.04,y:0.85,width:0.08,height:0.1),included:false)]
            chapter.pages[i].textLayers = [TextLayer(text:"ПЕРЕВОД",rotation:15,outline:TextOutline())]
        }
        chapter.pages[0].imageFile = "edited/working.png"
        chapter.pages[0].fingerprint = ProjectFiles.fingerprint(folder.appendingPathComponent("edited/working.png"))
        let blank = Box(x:0.04,y:0.05,width:0.1,height:0.1)
        chapter.pages[1].blocks.append(TextBlock(text:"Blank",original:"Blank",box:blank,ocrLines:[blank]))
        chapter.browserTranslation = "Не менять черновик"
        try ProjectFiles.save(chapter,to:folder)
        let model = MangaModel(); model.autoCleanAfterExport = true; model.open(folder)
        let python = URL(fileURLWithPath:pythonPath)
        let script = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("scripts/clean-text.py")
        let txt = folder.appendingPathComponent("translation.txt")
        // A failed export must never launch cleanup.
        do { try model.exportTXT(to:folder,cleaningPython:python,cleaningScript:script); fatalError("Export must fail") } catch {}
        precondition(!model.busy && model.page!.imagePath == "edited/working.png")
        try model.exportTXT(to:txt,cleaningPython:python,cleaningScript:script)
        precondition(model.busy && fm.fileExists(atPath:txt.path) && fm.fileExists(atPath:TextExportMap.url(for:txt).path))
        model.selectedPage = "02.png"
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(model.message == nil,model.message ?? "")
        precondition(model.chapter!.pages.allSatisfy { $0.imageFile?.hasPrefix("cleaned/") == true && $0.autoCleanSignature != nil })
        precondition(model.cleaningSkippedPages == ["02.png · 1"])
        precondition(model.chapter!.pages[0].textLayers?.first?.rotation == 15)
        precondition(model.chapter!.pages[0].blocks[0].translation?.text == "ПРИВЕТ" && model.chapter!.browserTranslation == "Не менять черновик")
        let newPaths = model.chapter!.pages.map(\.imagePath)
        let history = model.undoHistory.count
        try model.exportTXT(to:txt,cleaningPython:python,cleaningScript:script)
        precondition(!model.busy && model.chapter!.pages.map(\.imagePath) == newPaths && model.undoHistory.count == history,"Identical export must not clean twice")
        let reopened = MangaModel(); reopened.open(folder)
        precondition(reopened.chapter!.pages.map(\.imagePath) == newPaths)
        let sourceAfter = try Data(contentsOf:image); precondition(sourceAfter == originalData)
        let workingAfter = try Data(contentsOf:folder.appendingPathComponent("edited/working.png")); precondition(workingAfter == originalData)
        model.undo()
        precondition(model.chapter!.pages[0].imagePath == "edited/working.png" && model.chapter!.pages[1].imageFile == nil)
        precondition(model.chapter!.pages.allSatisfy { $0.autoCleanSignature == nil })
        // A later page failure must roll back already generated pages too.
        let savedSecond = try Data(contentsOf:folder.appendingPathComponent("02.png"))
        try fm.removeItem(at:folder.appendingPathComponent("02.png"))
        model.message = nil
        try model.exportTXT(to:txt,cleaningPython:python,cleaningScript:script)
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(model.message != nil && model.chapter!.pages[0].imagePath == "edited/working.png")
        let retainedRuns = try fm.contentsOfDirectory(atPath:folder.appendingPathComponent("cleaned").path)
        precondition(retainedRuns.count == 1,"Only the previously completed run should remain")
        try savedSecond.write(to:folder.appendingPathComponent("02.png"))
        // Restore the fingerprint to match the new copy; the old source was intentionally removed.
        model.chapter!.pages[1].fingerprint = ProjectFiles.fingerprint(folder.appendingPathComponent("02.png"))
        model.message = nil
        let slow = folder.appendingPathComponent("slow.py")
        try "import time\ntime.sleep(10)\n".write(to:slow,atomically:true,encoding:.utf8)
        try model.exportTXT(to:txt,cleaningPython:python,cleaningScript:slow)
        try await Task.sleep(nanoseconds:100_000_000)
        model.stop()
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(model.message == nil && model.chapter!.pages[0].imagePath == "edited/working.png")
        precondition(model.status.contains("остановлена"))
        // Project persistence failure cannot expose generated images.
        try model.exportTXT(to:txt,cleaningPython:python,cleaningScript:script)
        let project = folder.appendingPathComponent(ProjectFiles.saveName)
        let savedProject = try Data(contentsOf:project)
        try fm.removeItem(at:project); try fm.createDirectory(at:project,withIntermediateDirectories:false)
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(model.message != nil && model.chapter!.pages[0].imagePath == "edited/working.png")
        try fm.removeItem(at:project); try savedProject.write(to:project)
        precondition(fm.fileExists(atPath:txt.path))
        try fm.removeItem(at:txt); try fm.removeItem(at:TextExportMap.url(for:txt))
        model.message = nil
        model.cleanDetectedText(python:python,script:script)
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(model.message == nil && model.chapter!.pages.allSatisfy { $0.imageFile?.hasPrefix("cleaned/") == true })
        precondition(!model.status.contains("TXT") && !fm.fileExists(atPath:txt.path) && !fm.fileExists(atPath:TextExportMap.url(for:txt).path))
        precondition(model.cleaningSkippedPages == ["02.png · 1"])
        print("PASS: manual and post-export cleanup, skipped pages, failed export gating, active image, chapter atomicity, repeat/export/reopen, OCR/translation/layers preservation, source protection, one-step undo, page failure, cancellation and save failure")
    }
}
