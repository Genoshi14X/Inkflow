import Foundation
import CoreGraphics

@main struct Tests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAILED: \(label)") }; checks += 1
        }
        let full = Box(x:0,y:0,width:1,height:1)
        let lines = [
            OCRLine(text:"HELLO",confidence:1,box:Box(x:0.7,y:0.1,width:0.15,height:0.02)),
            OCRLine(text:"WORLD",confidence:1,box:Box(x:0.7,y:0.125,width:0.15,height:0.02)),
            OCRLine(text:"LEFT",confidence:1,box:Box(x:0.1,y:0.1,width:0.15,height:0.02))]
        let blocks = ReadingOrder.blocks(lines,panels:[full])
        expect(blocks.count == 2,"group whole balloons, not mixed rows")
        expect(blocks.first?.text == "HELLO WORLD","right balloon first and lines top down")
        expect(ReadingOrder.join(["BREAK-","FAST?"]) == "BREAKFAST?","line-end hyphen")
        expect(ReadingOrder.normalize("ОН...") == "OH...","Latin lookalikes")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("InkflowTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:tmp) }
        for f in ["10.JPG","2.jpeg","01.png","ignore.txt"] { try Data().write(to:tmp.appendingPathComponent(f)) }
        let names = try ProjectFiles.images(in:tmp).map(\.lastPathComponent)
        expect(names == ["01.png","2.jpeg","10.JPG"],"natural ordering and mixed extensions")
        var chapter = try ProjectFiles.load(tmp)
        chapter.pages[0].scanned = true; chapter.pages[0].blocks = blocks
        chapter.pages[0].blocks[0].included = false
        chapter.pages[0].blocks[1].text = "EDITED"
        try ProjectFiles.save(chapter,to:tmp)
        let loaded = try ProjectFiles.load(tmp)
        expect(loaded.pages[0].blocks[1].text == "EDITED","edits survive reopening")
        expect(!loaded.pages[0].blocks[0].included,"excluded state survives reopening")
        let txt = ProjectFiles.transcript(loaded)
        expect(txt.contains("EDITED") && !txt.contains("HELLO WORLD"),"export excludes hidden blocks")
        expect(txt.contains("не проверены") && txt.contains("не распознана"),"export marks unchecked and unscanned pages")
        try Data("changed".utf8).write(to:tmp.appendingPathComponent("01.png"))
        let changed = try ProjectFiles.load(tmp)
        expect(changed.pages[0].blocks[1].text == "EDITED" && changed.pages[0].error != nil,"changed source preserves edits and warns")
        // Synthetic asymmetric panel layout: full top, two right panels, tall left bottom.
        let w = 600, h = 900
        let ctx = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray:1,alpha:1);ctx.fill(CGRect(x:0,y:0,width:w,height:h))
        ctx.setFillColor(gray:0,alpha:1)
        // CoreGraphics uses bottom-left coordinates here.
        ctx.fill(CGRect(x:0,y:520,width:600,height:380))
        ctx.fill(CGRect(x:0,y:0,width:350,height:500))
        ctx.fill(CGRect(x:370,y:270,width:230,height:230))
        ctx.fill(CGRect(x:370,y:0,width:230,height:250))
        let panels = PanelDetector.detect(ctx.makeImage()!)
        expect(panels.count == 4,"asymmetric panel count")
        expect(panels[0].cy < 0.5 && panels[1].cx > 0.5 && panels[2].cx > 0.5 && panels[3].cx < 0.5,"top, right top, right bottom, left tall")
        let sampleFolder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("samples")
        guard ProcessInfo.processInfo.environment["INKFLOW_PRIVATE_SAMPLES"] == "1" else {
            print("PASS: \(checks) checks (private sample OCR skipped; opt in with INKFLOW_PRIVATE_SAMPLES=1)")
            return
        }
        var results: [ScanPage] = []
        for url in try ProjectFiles.images(in:sampleFolder) {
            let p = try Scanner.scan(url); results.append(p)
            expect(p.scanned && !p.blocks.isEmpty,"real sample recognized: \(p.file)")
            print("\(p.file): \(p.panels.count) panels, \(p.blocks.count) blocks")
            for (i,b) in p.blocks.enumerated() { print("  \(i+1) [P\(b.panel+1)] \(b.text)") }
        }
        let region = try Scanner.scan(sampleFolder.appendingPathComponent("01.png"),region:Box(x:0.82,y:0.04,width:0.16,height:0.1))
        expect(region.blocks.map(\.text).joined().contains("MOM"),"crop recognizes target balloon")
        expect(!region.blocks.map(\.text).joined().contains("MASSAGE"),"crop excludes other balloon")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(results).write(to:URL(fileURLWithPath:"output/automatic.json"))
        print("PASS: \(checks) checks")
    }
}
