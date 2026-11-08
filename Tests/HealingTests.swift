import Foundation
import CoreGraphics
import ImageIO

@main struct HealingTests {
    @MainActor static func main() async throws {
        guard let pythonPath = ProcessInfo.processInfo.environment["INKFLOW_HEALING_PYTHON"] else {
            print("SKIP: healing integration (set INKFLOW_HEALING_PYTHON to Python with OpenCV)"); return
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Inkflow healing ' " + UUID().uuidString)
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:folder) }
        let input = folder.appendingPathComponent("01.png")
        let context = CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:512,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:128,height:128))
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:60,y:60,width:8,height:8))
        let destination = CGImageDestinationCreateWithURL(input as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil); precondition(CGImageDestinationFinalize(destination))
        try fm.copyItem(at:input,to:folder.appendingPathComponent("02.png"))
        let originalData = try Data(contentsOf:input)
        var chapter = try ProjectFiles.load(folder)
        chapter.pages[0].scanned = true
        chapter.pages[0].textLayers = [TextLayer(text:"Текст поверх ретуши")]
        chapter.pages[0].blocks = [TextBlock(text:"KEEP TEXT",original:"OCR",box:Box(x:0.4,y:0.4,width:0.2,height:0.2),
            translation:TranslationRecord(text:"ПЕРЕВОД",source:"KEEP TEXT",context:"",model:"manual"))]
        chapter.browserTranslation = "Черновик перевода"
        try ProjectFiles.save(chapter,to:folder)
        let python = URL(fileURLWithPath:pythonPath)
        let script = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("scripts/heal-image.py")
        let model = MangaModel(); model.open(folder)
        model.brushDiameter = 24
        let points = [BrushPoint(x:0.5,y:0.5)]
        model.heal(points,python:python,script:script)
        model.selectedPage = "02.png" // Completion must still update the original page.
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(model.message == nil, model.message ?? "")
        let edited = model.chapter!.pages[0]
        precondition(edited.imageFile?.hasPrefix("edited/") == true && model.chapter!.pages[1].imageFile == nil)
        precondition(edited.textLayers?.first?.text == "Текст поверх ретуши")
        precondition(edited.blocks[0].text == "KEEP TEXT" && edited.blocks[0].translation?.text == "ПЕРЕВОД")
        precondition(model.chapter!.browserTranslation == "Черновик перевода")
        let unchanged = try Data(contentsOf:input)
        precondition(unchanged == originalData)
        let changed = try Data(contentsOf:folder.appendingPathComponent(edited.imagePath))
        precondition(changed != originalData)
        let reopened = MangaModel(); reopened.open(folder)
        precondition(reopened.page!.imagePath == edited.imagePath && reopened.page!.error == nil)
        model.undo()
        precondition(model.chapter!.pages[0].imageFile == nil)
        let undone = try ProjectFiles.load(folder)
        precondition(undone.pages[0].imageFile == nil)
        // Failures and absent scripts must not replace a working image or add undo history.
        let historyCount = model.undoHistory.count
        model.heal(points,python:python,script:folder.appendingPathComponent("missing.py"))
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(model.message != nil && model.chapter!.pages[1].imageFile == nil)
        precondition(model.undoHistory.count == historyCount)
        print("PASS: healing process, working image, text/translation preservation, page switching, undo, reopen and failure")
    }
}
