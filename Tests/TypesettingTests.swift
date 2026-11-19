import AppKit
import SwiftUI
import ImageIO

@main struct TypesettingTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Inkflow-typesetting-" + UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let image = root.appendingPathComponent("01.png")
        let ctx = CGContext(data:nil,width:600,height:800,bitsPerComponent:8,bytesPerRow:2400,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:0.5,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:600,height:800))
        let dest = CGImageDestinationCreateWithURL(image as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(dest,ctx.makeImage()!,nil); precondition(CGImageDestinationFinalize(dest))
        let before = try Data(contentsOf:image)
        var layer = TextLayer(text:"INKFLOW",box:Box(x:0.2,y:0.4,width:0.6,height:0.15),fontScale:0.08,red:1,green:1,blue:1)
        layer.rotation = 90; layer.outline = TextOutline(widthScale:0.006)
        let decoded = try JSONDecoder().decode(TextLayer.self,from:JSONEncoder().encode(layer))
        precondition(decoded == layer)
        let size = CGSize(width:600,height:800)
        let originalPoint = CGPoint(x:120,y:320)
        let rotated = TextRenderer.point(originalPoint,layer:layer,size:size)
        let back = TextRenderer.point(rotated,layer:layer,size:size,inverse:true)
        precondition(hypot(back.x-originalPoint.x,back.y-originalPoint.y) < 0.001)
        precondition(TextRenderer.contains(CGPoint(x:300,y:240),layer:layer,size:size))
        precondition(!TextRenderer.contains(CGPoint(x:130,y:380),layer:layer,size:size))
        let output = root.appendingPathComponent("render.png")
        try TextRenderer.export(image:image,layers:[layer],to:output)
        func pixels(_ url: URL) -> [UInt8] {
            let im = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
            var bytes = [UInt8](repeating:0,count:600*800*4)
            bytes.withUnsafeMutableBytes { buffer in
                let c = CGContext(data:buffer.baseAddress,width:600,height:800,bitsPerComponent:8,bytesPerRow:2400,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(im,in:CGRect(x:0,y:0,width:600,height:800))
            }
            return bytes
        }
        let rendered = pixels(output)
        let dark = stride(from:0,to:rendered.count,by:4).filter { rendered[$0] < 40 }.count
        let white = stride(from:0,to:rendered.count,by:4).filter { rendered[$0] > 240 }.count
        precondition(dark > 500 && white > 500,"Outline and fill must both render")
        var noOutline = layer; noOutline.outline = nil
        let plain = root.appendingPathComponent("plain.png")
        try TextRenderer.export(image:image,layers:[noOutline],to:plain)
        precondition(pixels(plain) != rendered)
        // Rotation uses a native drag, previews locally and commits only once on release.
        let window = NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let canvas = TextCanvasView(frame:CGRect(origin:.zero,size:size)); window.contentView = canvas
        layer.rotation = nil; canvas.layers = [layer]; canvas.selectedID = layer.id; canvas.editable = true
        var angles: [Double] = []
        canvas.commitRotation = { _,angle in angles.append(angle) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        canvas.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:300,y:294)))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:386,y:380)))
        precondition(angles.isEmpty)
        canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:386,y:380)))
        precondition(angles.count == 1 && abs(angles[0]-90) < 0.001)
        layer.rotation = 45; canvas.layers = [layer]
        let rectangle = TextRenderer.rect(layer,size:size)
        let corner = TextRenderer.point(CGPoint(x:rectangle.maxX,y:rectangle.maxY),layer:layer,size:size)
        let fixed = TextRenderer.point(CGPoint(x:rectangle.minX,y:rectangle.minY),layer:layer,size:size)
        var resized: Box?
        canvas.commit = { _,box in resized = box }
        canvas.mouseDown(with:mouse(.leftMouseDown,corner))
        canvas.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:corner.x+40,y:corner.y+40)))
        precondition(resized != nil && resized!.width > layer.box.width)
        var changed = layer; changed.box = resized!
        let newRect = TextRenderer.rect(changed,size:size)
        let fixedAfter = TextRenderer.point(CGPoint(x:newRect.minX,y:newRect.minY),layer:changed,size:size)
        precondition(hypot(fixed.x-fixedAfter.x,fixed.y-fixedAfter.y) < 0.001,"Rotated resize must preserve the opposite corner")
        window.close()
        // Field-editor keyboard increments and clamping use the current typed value.
        var number = 10.0
        let numeric = NumericTextField(value:Binding(get:{ number },set:{ number = $0 }),range:0...12,label:"Размер")
        let coordinator = numeric.makeCoordinator(), field = NSTextField(), editor = NSTextView()
        editor.string = "11"
        precondition(coordinator.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveUp(_:))))
        precondition(number == 12 && editor.string == "12")
        _ = coordinator.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveUp(_:)))
        precondition(number == 12)
        _ = coordinator.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveDown(_:)))
        precondition(number == 11)
        var chapter = try ProjectFiles.load(root)
        chapter.pages = [chapter.pages.first!]
        chapter.pages[0].textLayers = [decoded]
        var second = chapter.pages[0]; second.file = "01.jpg"; second.imageFile = "01.png"
        chapter.pages.append(second)
        let run = try PageExportRun(chapter:chapter,source:root,output:root)
        try run.exportPage(0)
        do { _ = try run.complete(); fatalError("Cannot publish incomplete chapter") } catch {}
        try run.exportPage(1)
        let final = try run.complete()
        let names = try fm.contentsOfDirectory(atPath:final.path).sorted()
        precondition(names == ["0001_01.png_lettered.png","0002_01.jpg_lettered.png"])
        precondition(pixels(final.appendingPathComponent(names[0])) == rendered,"Batch and single-page output must match")
        let missing = root.appendingPathComponent("missing")
        var staging: URL!
        do {
            let failed = try PageExportRun(chapter:chapter,source:missing,output:root); staging = failed.staging
            do { try failed.exportPage(0); fatalError("Missing input must fail") } catch {}
        }
        precondition(!fm.fileExists(atPath:staging.path))
        try ProjectFiles.save(chapter,to:root)
        let model = MangaModel(); model.open(root)
        model.saveAllPages(to:root)
        while model.busy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(model.lastBatchExportURL != nil && model.message == nil)
        model.saveAllPages(to:root); model.stop()
        while model.busy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(model.lastBatchExportURL == nil)
        let after = try Data(contentsOf:image); precondition(before == after)
        try checkBrowserTranslation(in:root,image:image,size:size,pixels:pixels)
        print("PASS: rotation gesture, outline/fill raster, legacy/persisted styling, keyboard increments, complete batch export, single/batch equivalence, failure cleanup, cancellation and source protection")
    }

    @MainActor static func checkBrowserTranslation(in folder: URL, image: URL, size: CGSize, pixels: (URL) -> [UInt8]) throws {
        let a = TextBlock(text:"EN first",original:"EN first",box:Box(x:0.1,y:0.1,width:0.25,height:0.1))
        let b = TextBlock(text:"EN second",original:"EN second",box:Box(x:0.6,y:0.3,width:0.08,height:0.025))
        let c = TextBlock(text:"EN third",original:"EN third",box:Box(x:0.4,y:0.7,width:0.3,height:0.15))
        var page = ScanPage(file:image.lastPathComponent,width:Int(size.width),height:Int(size.height),blocks:[a,b,c],scanned:true,
                            fingerprint:ProjectFiles.fingerprint(image))
        TranslationAnchors.ensure(in:&page)
        page.textLayers![0].outline = TextOutline(widthScale:0.001)
        page.textLayers![0].widthScale = 1.1
        page.textLayers![0].lineSpacing = 0.002
        page.textLayers![2].text = "Ручной перевод"
        let original = Chapter(name:folder.lastPathComponent,pages:[page],browserTranslation:"Старый черновик")
        try ProjectFiles.save(original,to:folder)
        let model = MangaModel(); model.open(folder); model.beginBrowserTranslation()
        let english = model.browserTranslation!.parts[0].source
        let first = "Привет! Куда ты идёшь? Я давно тебя ищу."
        let long = String(repeating:"Длинная реплика с буквой ё. ",count:10).trimmingCharacters(in:.whitespaces)
        try model.acceptBrowserResult(english.replacingOccurrences(of:a.text,with:first)
            .replacingOccurrences(of:b.text,with:long).replacingOccurrences(of:c.text,with:"Новый перевод"),for:0)
        model.move(a.id,by:1)
        try model.reviewBrowserTranslation()
        let plan = model.browserTranslationPreview!
        precondition(plan.conflicts == 1)
        let font = "Helvetica-Oblique"
        let overflow = try model.browserTranslationOverflow(plan,policy:.keepExisting,fontName:font)
        precondition(overflow == [b.id])
        precondition(model.page!.textLayers == page.textLayers)
        let count = try model.commitTranslationImport(plan,policy:.keepExisting,allowPartial:false,fontName:font,fitBrowserText:true)
        precondition(count == 2 && model.selectedTextLayer == page.textLayers![1].id)
        let fitted = model.page!.textLayers![0], tooLong = model.page!.textLayers![1]
        precondition(fitted.box == page.textLayers![0].box && fitted.outline == page.textLayers![0].outline)
        precondition(fitted.fontName == font && fitted.text == first && fitted.fontScale < page.textLayers![0].fontScale)
        precondition(TextRenderer.fits(fitted,size:size) && !TextRenderer.fits(tooLong,size:size))
        precondition(tooLong.text == long && abs(tooLong.fontScale*size.width-12) < 0.001)
        var narrow = fitted
        narrow.box.width = 0.005
        narrow.text = "Ш"
        precondition(!TextRenderer.fitTranslation(&narrow,size:size),"A glyph wider than the frame must be flagged")
        precondition(model.page!.textLayers![2] == page.textLayers![2])
        precondition(model.page!.blocks.first { $0.id == a.id }?.translation?.text == first)
        let output = folder.appendingPathComponent("browser-render.png")
        try TextRenderer.export(image:image,layers:[fitted],to:output)
        let rendered = pixels(output)
        let background = pixels(image)
        let textBox = TextRenderer.rect(fitted,size:size).insetBy(dx:-3,dy:-3)
        var changed = 0
        for index in stride(from:0,to:rendered.count,by:4) where rendered[index] != background[index] {
            let position = index/4
            let p = CGPoint(x:position % Int(size.width),y:position/Int(size.width))
            precondition(textBox.contains(p),"Fitted glyph pixels must stay in the frame")
            changed += 1
        }
        precondition(changed > 100)
        let reopened = try ProjectFiles.load(folder)
        precondition(reopened.browserTranslationFont == font && reopened.browserTranslation == original.browserTranslation)
        precondition(reopened.pages.first { $0.file == page.file }?.textLayers == model.page!.textLayers)
        let again = try model.commitTranslationImport(plan,policy:.keepExisting,allowPartial:false,fontName:font,fitBrowserText:true)
        precondition(again == 0)
        model.undo()
        precondition(model.page!.textLayers == page.textLayers && model.page!.blocks.allSatisfy { $0.translation == nil })
        precondition(model.chapter?.browserTranslationFont == font)
        model.closeBrowserTranslation()
        precondition(model.browserTranslation == nil && model.browserTranslationPreview == nil)
        print("PASS: browser output to stable layers, Cyrillic fit, overflow, raster bounds, conflict, one-step undo and reopen")
    }
}
