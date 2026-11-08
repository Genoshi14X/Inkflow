import Foundation
import CoreGraphics
import ImageIO

@main struct UpscaleTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Inkflow upscale 'test " + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        func image(_ url: URL, size: Int) {
            let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:size,height:size))
            context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:size/4,y:size/4,width:size/2,height:size/2))
            let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(destination,context.makeImage()!,nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        let input = folder.appendingPathComponent("source ' page.png")
        let doubled = folder.appendingPathComponent("double.png")
        image(input,size:64); image(doubled,size:128)
        let executable = folder.appendingPathComponent("fake-python")
        func fake(_ body: String) throws {
            try ("#!/bin/zsh\nset -eu\n" + body).write(to:executable,atomically:true,encoding:.utf8)
            try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        }
        // Input/output paths with quotes/spaces must pass intact, and outputs must be validated.
        try fake("cp -- double.png \"$6\"\n")
        let output = folder.appendingPathComponent("output/result.png")
        var job = try UpscaleJob(repository:folder,python:executable,input:input,output:output)
        try job.process.run(); try job.finish()
        precondition(fm.fileExists(atPath:output.path))
        job = try UpscaleJob(repository:folder,python:executable,input:input,output:output)
        try job.process.run()
        do { try job.finish(); fatalError("Must not overwrite") } catch {}
        try fake("cp -- \"$4\" \"$6\"\n")
        job = try UpscaleJob(repository:folder,python:executable,input:input,output:folder.appendingPathComponent("bad.png"))
        try job.process.run()
        do { try job.finish(); fatalError("Must reject wrong dimensions") } catch {}
        try fake("echo 'missing dependency' >&2\nexit 1\n")
        job = try UpscaleJob(repository:folder,python:executable,input:input,output:folder.appendingPathComponent("failed.png"))
        try job.process.run()
        do { try job.finish(); fatalError("Must report failure") } catch { precondition(error.localizedDescription.contains("missing dependency")) }
        let chapterFolder = folder.appendingPathComponent("chapter")
        try fm.createDirectory(at:chapterFolder,withIntermediateDirectories:true)
        try fm.copyItem(at:input,to:chapterFolder.appendingPathComponent("1.png"))
        try fm.copyItem(at:input,to:chapterFolder.appendingPathComponent("1.jpg"))
        var chapter = try ProjectFiles.load(chapterFolder)
        let block = TextBlock(text:"Manual edit",original:"OCR",box:Box(x:0.1,y:0.1,width:0.2,height:0.1))
        chapter.pages[0].textLayers = [TextLayer(text:"Типографика")]
        chapter.pages[0].blocks = [block]; chapter.pages[0].scanned = true
        chapter.pages[0].reviewed = true; chapter.browserTranslation = "Русский черновик"
        try ProjectFiles.save(chapter,to:chapterFolder)
        try fake("cp -- double.png \"$6\"\n")
        let model = MangaModel(); model.open(chapterFolder)
        let selected = model.selectedPage
        model.upscaleAll(repository:folder,python:executable)
        while model.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(model.message == nil, model.message ?? "")
        precondition(model.selectedPage == selected && model.chapter!.pages.count == 2)
        precondition(model.chapter!.pages.allSatisfy { $0.imageFile != nil && $0.width == 128 && $0.height == 128 })
        precondition(Set(model.chapter!.pages.map(\.imagePath)).count == 2)
        precondition(model.page!.blocks[0].text == "Manual edit" && !model.page!.reviewed)
        precondition(model.chapter!.browserTranslation == "Русский черновик")
        precondition(model.page!.textLayers?.first?.text == "Типографика" && model.page!.textLayers?.first?.fontScale == 0.04)
        let reopened = MangaModel(); reopened.open(chapterFolder)
        precondition(reopened.imageURL == model.imageURL)
        precondition(reopened.chapter!.pages.allSatisfy { $0.error == nil })
        reopened.scanAll()
        while reopened.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(reopened.chapter!.pages.allSatisfy { $0.scanned && $0.width == 128 && $0.imageFile != nil })
        precondition(reopened.chapter!.pages.map(\.file) == chapter.pages.map(\.file))
        // Fail the second page: the completed first page must remain saved and active.
        let partial = folder.appendingPathComponent("partial")
        try fm.createDirectory(at:partial,withIntermediateDirectories:true)
        try fm.copyItem(at:input,to:partial.appendingPathComponent("1.png"))
        try fm.copyItem(at:input,to:partial.appendingPathComponent("2.png"))
        try fake("if [[ \"$4\" == */2.png ]]; then echo failure >&2; exit 1; fi\ncp -- double.png \"$6\"\n")
        let interrupted = MangaModel(); interrupted.open(partial)
        interrupted.upscaleAll(repository:folder,python:executable)
        while interrupted.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(interrupted.message != nil)
        let savedPartial = try ProjectFiles.load(partial)
        precondition(savedPartial.pages[0].imageFile != nil && savedPartial.pages[1].imageFile == nil)
        precondition(savedPartial.pages.allSatisfy { $0.error == nil })
        try fake("exec /bin/sleep 30\n")
        let cancelled = MangaModel(); cancelled.open(partial)
        let beforeCancel = cancelled.chapter!.pages.map(\.imagePath)
        cancelled.upscaleAll(repository:folder,python:executable)
        try await Task.sleep(nanoseconds:100_000_000)
        cancelled.stop()
        while cancelled.busy { try await Task.sleep(nanoseconds:20_000_000) }
        precondition(cancelled.message == nil && cancelled.chapter!.pages.map(\.imagePath) == beforeCancel)
        print("PASS: whole-folder replacement, mixed filenames, edits, reopen, OCR on active images and partial failure")
        if let path = ProcessInfo.processInfo.environment["INKFLOW_NUNIF"] {
            let repository = URL(fileURLWithPath:path)
            job = try UpscaleJob(repository:repository,python:repository.appendingPathComponent("venv/bin/python"),input:input,output:folder.appendingPathComponent("real/result.png"))
            try job.process.run(); try job.finish()
            let realFolder = folder.appendingPathComponent("real batch")
            try fm.createDirectory(at:realFolder,withIntermediateDirectories:true)
            for name in ["01.png", "02.jpg"] { try fm.copyItem(at:input,to:realFolder.appendingPathComponent(name)) }
            let realModel = MangaModel(); realModel.open(realFolder)
            realModel.upscaleAll(repository:repository,python:repository.appendingPathComponent("venv/bin/python"))
            while realModel.busy { try await Task.sleep(nanoseconds:20_000_000) }
            precondition(realModel.message == nil, realModel.message ?? "")
            precondition(realModel.chapter!.pages.allSatisfy { $0.width == 128 && $0.imageFile != nil })
            print("PASS: real nunif CLI and batch, 64×64 → 128×128 PNG")
        }
        print("PASS: upscale paths, output validation, overwrite protection and process errors")
    }
}
