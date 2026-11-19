import Foundation

@main struct BrowserTranslationTests {
    static func main() throws {
        try checkExchange()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let chapter = Chapter(name:"155",pages:[],browserTranslation:"Русский черновик\nС правками",browserTranslationFont:"Helvetica")
        try ProjectFiles.save(chapter,to:folder)
        let loaded = try ProjectFiles.load(folder)
        precondition(loaded.browserTranslation == chapter.browserTranslation)
        precondition(loaded.browserTranslationFont == chapter.browserTranslationFont)
        let old = try JSONDecoder().decode(Chapter.self,from:Data(#"{"version":1,"name":"155","pages":[]}"#.utf8))
        precondition(old.browserTranslation == nil && old.browserTranslationFont == nil)
        print("PASS: browser part limits, paired markers, malformed or foreign results, ID mapping, replacement, draft and font compatibility")
    }

    static func checkExchange() throws {
        let box = Box(x:0.1,y:0.1,width:0.3,height:0.2)
        let a = TextBlock(text:"Hello! Where are you going?",original:"Hello!",box:box)
        let b = TextBlock(text:"I am going to the station.",original:"I'm going",box:box)
        let c = TextBlock(text:"OK! 😀",original:"OK!",box:box)
        let blank = TextBlock(text:" ",original:" ",box:box)
        let excluded = TextBlock(text:"Boom!",original:"BOOM",box:box,included:false)
        var page = ScanPage(file:"01.png",blocks:[a,blank,b,excluded],scanned:true)
        var second = ScanPage(file:"02.png",blocks:[c],scanned:true)
        TranslationAnchors.ensure(in:&page); TranslationAnchors.ensure(in:&second)
        var chapter = Chapter(name:"155",pages:[page,second])
        var session = try BrowserTranslation(chapter:chapter,limit:122)
        precondition(session.parts.count == 2 && session.map.entries.map(\.blockID) == [a.id,b.id,c.id])
        precondition(session.map.entries.map(\.number) == [1,3,1])
        precondition(session.parts.allSatisfy { $0.source.utf16.count <= 122 })
        let first = session.parts[0].source.replacingOccurrences(of:a.text,with:"Привет! Куда ты идёшь?")
        let other = session.parts[1].source.replacingOccurrences(of:b.text,with:"Я иду на станцию.")
            .replacingOccurrences(of:c.text,with:"Хорошо! 😀")
        func rejected(_ action: () throws -> Void) {
            do { try action(); fatalError("Expected invalid browser translation to be rejected") } catch {}
        }
        rejected { try session.accept(other,for:0) }
        rejected { try session.accept(first + "\n" + first,for:0) }
        rejected { try session.accept(first.components(separatedBy:"\n").dropLast().joined(separator:"\n"),for:0) }
        rejected { try session.accept(first.replacingOccurrences(of:"Привет! Куда ты идёшь?",with:""),for:0) }
        let foreign = try BrowserTranslation(chapter:chapter,limit:122)
        rejected { try session.accept(foreign.parts[0].source,for:0) }
        try session.accept(other,for:1)
        rejected { _ = try session.plan(for:chapter) }
        try session.accept(first.replacingOccurrences(of:"[[",with:"[ [ "),for:0)
        try session.accept(first.replacingOccurrences(of:"Куда ты идёшь?",with:"Куда путь держишь?"),for:0)
        chapter.pages[0].blocks.swapAt(0,2)
        let plan = try session.plan(for:chapter)
        precondition(plan.items.map(\.blockID) == [a.id,b.id,c.id])
        precondition(plan.items.map(\.text) == ["Привет! Куда путь держишь?","Я иду на станцию.","Хорошо! 😀"])
        chapter.pages[0].blocks.removeAll { $0.id == b.id }
        rejected { _ = try session.plan(for:chapter) }
        session.clearResult(for:0)
        precondition(session.completedParts == 1)

        let long = TextBlock(text:String(repeating:"Keep all words. 😀 ",count:15),original:"Long",box:box)
        var largePage = ScanPage(file:"03.png",blocks:(0..<60).map { _ in
            TextBlock(text:long.text,original:long.original,box:box)
        },scanned:true)
        TranslationAnchors.ensure(in:&largePage)
        chapter.pages = [largePage]
        let large = try BrowserTranslation(chapter:chapter)
        precondition(large.parts.count > 1 && large.parts.allSatisfy { $0.source.utf16.count <= 9500 })
        precondition(large.parts.flatMap { $0.source.components(separatedBy:"\n") }.filter { $0 == long.text.trimmingCharacters(in:.whitespaces) }.count == 60)
        rejected { _ = try BrowserTranslation(chapter:chapter,limit:20) }
    }
}
