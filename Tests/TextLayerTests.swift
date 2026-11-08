import Foundation
import AppKit
import CoreGraphics
import ImageIO

@main struct TextLayerTests {
    @MainActor static func main() async throws {
        var legacyFace = TextLayer(text:"Исходный текст",fontName:"Helvetica-Bold")
        let legacyData = try JSONEncoder().encode(legacyFace)
        precondition(!String(decoding:legacyData,as:UTF8.self).contains("widthScale"))
        let decodedLegacy = try JSONDecoder().decode(TextLayer.self,from:legacyData)
        precondition(decodedLegacy.bold == nil && decodedLegacy.italic == nil && TextRenderer.horizontalScale(decodedLegacy) == 1)
        precondition(TextRenderer.fontStyle(decodedLegacy,width:600).font.fontName == "Helvetica-Bold")
        legacyFace.bold = false
        precondition(!NSFontManager.shared.traits(of:TextRenderer.fontStyle(legacyFace,width:600).font).contains(.boldFontMask))
        var styled = TextLayer(text:"Привет, мир!",bold:true,italic:true,underline:true,strikethrough:true,uppercase:true,widthScale:1.3)
        let styledText = TextRenderer.attributed(styled,width:600)
        precondition(styledText.string == "ПРИВЕТ, МИР!" && styled.text == "Привет, мир!")
        let attrs = styledText.attributes(at:0,effectiveRange:nil)
        let styledFont = attrs[.font] as! NSFont
        precondition(NSFontManager.shared.traits(of:styledFont).contains([.boldFontMask,.italicFontMask]))
        precondition(attrs[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        precondition(attrs[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        precondition(attrs[.strokeWidth] == nil && attrs[.obliqueness] == nil)
        // Decorative fonts may not provide italic/bold faces: fallback attributes must be explicit.
        let decorative = NSFontManager.shared.availableFonts.first { name in
            let sample = TextLayer(fontName:name,bold:true,italic:true)
            let face = TextRenderer.fontStyle(sample,width:600)
            return face.syntheticBold || face.syntheticItalic
        }
        if let decorative {
            let sample = TextLayer(fontName:decorative,bold:true,italic:true)
            let face = TextRenderer.fontStyle(sample,width:600)
            let attributes = TextRenderer.attributed(sample,width:600).attributes(at:0,effectiveRange:nil)
            if face.syntheticBold { precondition(attributes[.strokeWidth] as? Double == -2.5) }
            if face.syntheticItalic { precondition(attributes[.obliqueness] as? Double == 0.2) }
        }
        styled.bold = false; styled.italic = false; styled.uppercase = false
        styled.underline = false; styled.strikethrough = false
        let plainAttrs = TextRenderer.attributed(styled,width:600).attributes(at:0,effectiveRange:nil)
        precondition(plainAttrs[.underlineStyle] == nil && plainAttrs[.strikethroughStyle] == nil)
        precondition(TextRenderer.attributed(styled,width:600).string == styled.text)
        let initial = Box(x:0.2,y:0.3,width:0.4,height:0.2)
        let minimum = CGSize(width:0.02,height:0.02)
        let moved = TextBoxGeometry.changed(initial,delta:CGSize(width:0.1,height:-0.1),handle:nil,minimum:minimum)
        precondition(abs(moved.x-0.3) < 0.000001 && abs(moved.y-0.2) < 0.000001)
        precondition(moved.width == initial.width && moved.height == initial.height)
        let corner = TextBoxGeometry.changed(initial,delta:CGSize(width:-0.1,height:-0.1),handle:.topLeft,minimum:minimum)
        precondition(abs(corner.right-initial.right) < 0.000001 && abs(corner.bottom-initial.bottom) < 0.000001)
        precondition(abs(corner.width-0.5) < 0.000001 && abs(corner.height-0.3) < 0.000001)
        for handle in TextHandle.allCases {
            for delta in [CGSize(width:10,height:10),CGSize(width:-10,height:-10)] {
                let box = TextBoxGeometry.changed(initial,delta:delta,handle:handle,minimum:minimum)
                precondition(box.x >= 0 && box.y >= 0 && box.right <= 1.000001 && box.bottom <= 1.000001)
                precondition(box.width >= 0.019999 && box.height >= 0.019999)
            }
        }
        let resized = TextBoxGeometry.changed(initial,delta:CGSize(width:-0.15,height:0.1),handle:.bottomRight,minimum:minimum)
        var wide = TextLayer(text:"A line of text that must wrap when its frame narrows")
        wide.box = initial
        var narrow = wide; narrow.box = resized
        precondition(TextRenderer.textHeight(narrow,size:CGSize(width:1000,height:1000)) > TextRenderer.textHeight(wide,size:CGSize(width:1000,height:1000)))
        _ = NSApplication.shared
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:600,height:800),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let canvas = TextCanvasView(frame:CGRect(x:0,y:0,width:600,height:800))
        window.contentView = canvas
        var nativeLayer = TextLayer(); nativeLayer.box = initial
        canvas.layers = [nativeLayer]; canvas.selectedID = nativeLayer.id; canvas.editable = true
        var commits: [Box] = []
        canvas.commit = { _,box in commits.append(box) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,
                windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:200,y:300)))
        for x in [210.0, 250.0, 240.0, 260.0] {
            canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:x,y:340)))
        }
        precondition(commits.isEmpty,"Mouse movement must not save the project")
        canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:260,y:340)))
        precondition(commits.count == 1)
        precondition(abs(commits[0].x-0.3) < 0.000001 && abs(commits[0].y-0.35) < 0.000001,"Movement must use stable page coordinates, not accumulate intermediate deltas")
        nativeLayer.box = commits[0]; canvas.layers = [nativeLayer]
        let bottomRight = TextRenderer.rect(nativeLayer,size:canvas.bounds.size).origin
        let cornerPoint = CGPoint(x:bottomRight.x+nativeLayer.box.width*600,y:bottomRight.y+nativeLayer.box.height*800)
        canvas.mouseDown(with:mouse(.leftMouseDown,cornerPoint))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:cornerPoint.x-60,y:cornerPoint.y+40)))
        precondition(commits.count == 1)
        canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:cornerPoint.x-60,y:cornerPoint.y+40)))
        precondition(commits.count == 2 && abs(commits[1].width-0.3) < 0.000001 && abs(commits[1].height-0.25) < 0.000001)
        window.close()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Inkflow text ' " + UUID().uuidString)
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:folder) }
        let input = folder.appendingPathComponent("01.png")
        let ctx = CGContext(data:nil,width:600,height:800,bitsPerComponent:8,bytesPerRow:2400,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:1,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:600,height:800))
        ctx.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1)); ctx.fill(CGRect(x:0,y:760,width:20,height:40))
        let destination = CGImageDestinationCreateWithURL(input as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,ctx.makeImage()!,nil); precondition(CGImageDestinationFinalize(destination))
        var chapter = try ProjectFiles.load(folder)
        let block = TextBlock(text:"ORIGINAL",original:"OCR",box:Box(x:0.2,y:0.1,width:0.6,height:0.3),
            translation:TranslationRecord(text:"Привет, мир!\nВторая строка",source:"ORIGINAL",context:"",model:"manual"))
        chapter.pages[0].reviewed = true; chapter.pages[0].translationReviewed = true
        chapter.pages[0].blocks = [block]; chapter.browserTranslation = "Черновик"
        try ProjectFiles.save(chapter,to:folder)
        let old = try JSONDecoder().decode(ScanPage.self,from:JSONEncoder().encode(chapter.pages[0]))
        precondition(old.textLayers == nil)
        let model = MangaModel(); model.open(folder); model.selectedBlock = block.id
        model.addTextLayer()
        let id = model.selectedTextLayer!
        precondition(model.page!.reviewed && model.page!.translationReviewed == true)
        precondition(model.layer!.text == block.translation!.text && model.layer!.box == block.box)
        model.updateTextLayer(id) {
            $0.fontScale = 40/600; $0.heightScale = 1.2; $0.lineSpacing = 6/600
            $0.letterSpacing = 1/600; $0.alignment = .center
        }
        model.updateTextLayer(id) {
            $0.bold = true; $0.italic = true; $0.underline = true; $0.strikethrough = true
            $0.uppercase = true; $0.widthScale = 1.1
        }
        model.undo(); precondition(model.layer!.bold == nil && model.layer!.widthScale == nil)
        model.updateTextLayer(id) {
            $0.bold = true; $0.italic = true; $0.underline = true; $0.strikethrough = true
            $0.uppercase = true; $0.widthScale = 1.1
        }
        let reopened = MangaModel(); reopened.open(folder)
        precondition(reopened.page!.textLayers!.count == 1)
        let saved = reopened.page!.textLayers![0]
        precondition(saved.fontScale == model.layer!.fontScale && saved.heightScale == 1.2)
        precondition(saved.bold == true && saved.italic == true && saved.underline == true && saved.strikethrough == true)
        precondition(saved.uppercase == true && saved.widthScale == 1.1)
        precondition(saved.fontName == "Helvetica" && saved.text == block.translation!.text)
        precondition(model.chapter!.browserTranslation == "Черновик" && model.page!.blocks[0].text == "ORIGINAL")
        let output = folder.appendingPathComponent("out.png")
        try model.exportPagePNG(to:output)
        let original = try pixels(input), rendered = try pixels(output)
        precondition(original.count == rendered.count)
        var changed = 0
        for y in 0..<800 {
            for x in 0..<600 {
                let i = (y*600+x)*4
                if Array(original[i..<i+4]) != Array(rendered[i..<i+4]) {
                    precondition(y >= 80 && y < 320 && x >= 120 && x < 480,"Text must stay within top-origin layer rectangle")
                    changed += 1
                }
            }
        }
        precondition(changed > 500,"PNG must contain visible Cyrillic text")
        let sourceBefore = try Data(contentsOf:input)
        do { try model.exportPagePNG(to:input); fatalError("Must protect working image") } catch {}
        let sourceAfter = try Data(contentsOf:input); precondition(sourceBefore == sourceAfter)
        model.updateTextLayer(id) { $0.visible = false }
        try model.exportPagePNG(to:output)
        let hidden = try pixels(output); precondition(hidden == original)
        model.undo(); precondition(model.layer!.visible)
        model.selectedBlock = nil // A free layer; selecting OCR now reuses its anchor.
        model.addTextLayer(); let second = model.selectedTextLayer!
        model.reorderTextLayer(by:-1); precondition(model.page!.textLayers!.first!.id == second)
        model.deleteTextLayer(); precondition(model.page!.textLayers!.count == 1)
        model.undo(); precondition(model.page!.textLayers!.count == 2)
        // OCR must not discard text layers on an unscanned page.
        let layerIDs = model.page!.textLayers!.map(\.id)
        model.scanAll()
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(Set(layerIDs).isSubset(of:Set(model.page!.textLayers!.map(\.id))))
        precondition(model.page!.blocks.filter(\.included).allSatisfy { block in model.page!.textLayers!.contains { $0.sourceBlockID == block.id } })
        print("PASS: text layers, translation insertion, persistence, typography, Cyrillic PNG, top-origin clipping, hidden layers, overwrite protection, undo, ordering and OCR preservation")
    }
    static func pixels(_ url: URL) throws -> [UInt8] {
        let source = CGImageSourceCreateWithURL(url as CFURL,nil)!
        let image = CGImageSourceCreateImageAtIndex(source,0,nil)!
        precondition(image.width == 600 && image.height == 800)
        var bytes = [UInt8](repeating:0,count:600*800*4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data:buffer.baseAddress,width:600,height:800,bitsPerComponent:8,bytesPerRow:2400,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image,in:CGRect(x:0,y:0,width:600,height:800))
        }
        return bytes
    }
}
