import Foundation
import CoreGraphics
import CoreText
import ImageIO

@main struct ModelTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InkflowModel-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        // Synthetic fixture: no copyrighted pages or private files required.
        let ctx = CGContext(data:nil,width:1200,height:1800,bitsPerComponent:8,bytesPerRow:4800,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:1,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:1200,height:1800))
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString,20,nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray:0,alpha:1)]
        for (text,x,y) in [("WHERE'S MOM?",1000.0,1610.0),("HELLO FRIEND",100.0,1400.0),("ANOTHER BUBBLE",100.0,1100.0)] {
            ctx.textPosition = CGPoint(x:x,y:y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attrs)),ctx)
        }
        let imageURL = folder.appendingPathComponent("01.png")
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,ctx.makeImage()!,nil)
        precondition(CGImageDestinationFinalize(destination))
        var chapter = try ProjectFiles.load(folder)
        chapter.pages[0] = try Scanner.scan(folder.appendingPathComponent("01.png"))
        try ProjectFiles.save(chapter,to:folder)
        let model = MangaModel(); model.open(folder)
        let id = model.page!.blocks[0].id
        model.text(id,value:"EDIT TEST")
        precondition(model.page!.blocks[0].text == "EDIT TEST")
        model.move(id,by:1)
        precondition(model.page!.blocks[1].id == id)
        model.include(id,value:false)
        precondition(!model.page!.blocks[1].included)
        model.undo(); precondition(model.page!.blocks[1].included)
        let count = model.page!.blocks.count
        model.merge(id); precondition(model.page!.blocks.count == count-1)
        model.undo(); precondition(model.page!.blocks.count == count)
        model.delete(id); precondition(!model.page!.blocks.contains { $0.id == id })
        model.undo(); precondition(model.page!.blocks.contains { $0.id == id })
        model.markReviewed(); precondition(model.page!.reviewed)
        let reopened = MangaModel(); reopened.open(folder)
        precondition(reopened.page!.reviewed)
        precondition(reopened.page!.blocks[1].text == "EDIT TEST")
        let before = reopened.page!.blocks.map(\.text)
        reopened.scanAll()
        precondition(reopened.page!.blocks.map(\.text) == before && !reopened.busy)
        reopened.addRegion(Box(x:0.82,y:0.04,width:0.16,height:0.1))
        while reopened.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(reopened.page!.blocks.count == count+1)
        precondition(reopened.page!.blocks.last!.text.contains("MOM"))
        precondition(!reopened.page!.reviewed)
        reopened.undo(); precondition(reopened.page!.blocks.count == count)
        let saved = try ProjectFiles.load(folder)
        precondition(saved.pages[0].blocks.count == count)
        print("PASS: model edit, reorder, include, merge, delete, undo, review, reopen, rescan preservation, crop OCR, persistence")
    }
}
