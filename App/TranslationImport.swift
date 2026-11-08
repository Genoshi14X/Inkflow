import Foundation

struct TranslationImportError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct TranslationKey: Hashable {
    let page: String
    let number: Int
    var label: String { page + String(format:" [%02d]",number) }
}
struct TranslationDocument {
    struct Entry {
        let key: TranslationKey
        let text: String
    }
    let entries: [Entry]

    static func read(_ url: URL) throws -> TranslationDocument {
        let data = try Data(contentsOf:url)
        let text: String?
        if data.starts(with:[0xff,0xfe]) { text = String(data:data.dropFirst(2),encoding:.utf16LittleEndian) }
        else if data.starts(with:[0xfe,0xff]) { text = String(data:data.dropFirst(2),encoding:.utf16BigEndian) }
        else { text = String(data:data,encoding:.utf8) }
        guard let text else { throw TranslationImportError("Не удалось прочитать TXT. Сохраните файл в UTF-8 или UTF-16 с BOM и повторите импорт.") }
        return try parse(text)
    }
    static func parse(_ text: String) throws -> TranslationDocument {
        let pagePattern = try NSRegularExpression(pattern:#"^===\s*(?:Страница|Page)\s+(.+?)\s*===$"#,options:[.caseInsensitive])
        let numberPattern = try NSRegularExpression(pattern:#"^\[([0-9]+)\](?:\s*(.*))?$"#)
        let annotations: Set<String> = ["[Порядок и текст не проверены]","[Страница не распознана]","[Нет перевода]","[Перевод не проверен]","[Оригинал, порядок или словарь изменились — проверьте перевод]"]
        var entries: [Entry] = [], pages = Set<String>(), keys = Set<TranslationKey>()
        var page: String?, key: TranslationKey?, body: [String] = []
        func finish() throws {
            guard let current = key else { return }
            var lines = body
            while lines.first?.trimmingCharacters(in:.whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in:.whitespaces).isEmpty == true { lines.removeLast() }
            if lines.first?.trimmingCharacters(in:.whitespaces).uppercased().hasPrefix("EN:") == true {
                guard let ru = lines.firstIndex(where:{ $0.trimmingCharacters(in:.whitespaces).uppercased().hasPrefix("RU:") }) else {
                    throw TranslationImportError("Нет RU-перевода для \(current.label). Замените оригинал переводом или заполните строку RU:.")
                }
                lines = Array(lines[ru...])
            }
            if let first = lines.first, first.trimmingCharacters(in:.whitespaces).uppercased().hasPrefix("RU:") {
                lines[0] = String(first.trimmingCharacters(in:.whitespaces).dropFirst(3)).trimmingCharacters(in:.whitespaces)
            }
            let value = lines.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.isEmpty else { throw TranslationImportError("Пустой перевод для \(current.label). Заполните реплику или удалите её номер из файла для частичного импорта.") }
            entries.append(Entry(key:current,text:value))
        }
        let normalized = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
            .trimmingCharacters(in:CharacterSet(charactersIn:"\u{feff}"))
        for (i,line) in normalized.components(separatedBy:"\n").enumerated() {
            let trimmed = line.trimmingCharacters(in:.whitespaces)
            let range = NSRange(trimmed.startIndex...,in:trimmed)
            if let match = pagePattern.firstMatch(in:trimmed,range:range), let capture = Range(match.range(at:1),in:trimmed) {
                try finish(); key = nil; body = []
                let name = String(trimmed[capture]).trimmingCharacters(in:.whitespaces)
                guard pages.insert(name).inserted else { throw TranslationImportError("Повторный заголовок страницы \(name), строка \(i+1). Объедините её реплики в один раздел.") }
                page = name
            } else if let match = numberPattern.firstMatch(in:trimmed,range:range), let capture = Range(match.range(at:1),in:trimmed) {
                try finish()
                guard let page else { throw TranslationImportError("Перед репликой в строке \(i+1) нужен заголовок: === Страница 01.png ===.") }
                guard let number = Int(trimmed[capture]), number > 0 else { throw TranslationImportError("Некорректный номер реплики в строке \(i+1).") }
                let next = TranslationKey(page:page,number:number)
                guard keys.insert(next).inserted else { throw TranslationImportError("Повторный номер \(next.label), строка \(i+1). Каждый номер на странице должен встречаться один раз.") }
                key = next; body = []
                if let content = Range(match.range(at:2),in:trimmed), !trimmed[content].isEmpty { body.append(String(trimmed[content])) }
            } else if trimmed.hasPrefix("===") || trimmed.range(of:#"^\[[0-9]+\s*$"#,options:.regularExpression) != nil {
                throw TranslationImportError("Некорректный заголовок или номер в строке \(i+1). Используйте === Страница 01.png === и [01].")
            } else if annotations.contains(trimmed) { continue }
            else if key != nil { body.append(line) }
            else if trimmed.isEmpty { continue }
            else if page == nil && (trimmed.hasPrefix("Глава ") || trimmed.hasPrefix("Chapter ")) { continue }
            else { throw TranslationImportError("Не удалось разобрать строку \(i+1): \(trimmed.prefix(80)). Сохраните заголовки страниц и номера [01], [02] из экспорта.") }
        }
        try finish()
        guard !entries.isEmpty else { throw TranslationImportError("В TXT нет переведённых реплик. Сохраните заголовки страниц, номера и текст перевода.") }
        return TranslationDocument(entries:entries)
    }
}

enum TranslationImportPolicy: String, CaseIterable {
    case keepExisting = "Сохранить заполненный текст"
    case replaceExisting = "Заменить текст переводом из файла"
}

struct TranslationImportPlan: Identifiable {
    struct Item: Identifiable {
        var id: UUID { blockID }
        let key: TranslationKey
        let pageIndex: Int
        let blockID: UUID
        let layerID: UUID
        let text: String
        let previous: String
        let conflict: Bool
        let unchanged: Bool
        let sourceChanged: Bool
        let hidden: Bool
        let newLayer: TextLayer?
    }
    let id = UUID()
    let document: TranslationDocument
    let map: TextExportMap
    let items: [Item]
    let missing: [TranslationKey]
    var pageCount: Int { Set(items.map { $0.key.page }).count }
    var conflicts: Int { items.filter(\.conflict).count }
    func applicable(_ policy: TranslationImportPolicy) -> [Item] {
        items.filter { !$0.unchanged && (policy == .replaceExisting || !$0.conflict) }
    }
}

enum TranslationImporter {
    static func plan(document: TranslationDocument, map: TextExportMap, chapter: Chapter) throws -> TranslationImportPlan {
        guard map.version == 1, ["original","translated","bilingual"].contains(map.mode), !map.entries.isEmpty else {
            throw TranslationImportError("Неподдерживаемая или пустая карта экспорта. Выберите .inkflow-map.json от исходного TXT.")
        }
        guard !document.entries.isEmpty, Set(document.entries.map(\.key)).count == document.entries.count,
              document.entries.allSatisfy({ !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else {
            throw TranslationImportError("В переводе есть пустые или повторные реплики.")
        }
        var mapping: [TranslationKey:TextExportMap.Entry] = [:]
        var blockIDs = Set<UUID>(), layerIDs = Set<UUID>()
        for entry in map.entries {
            let key = TranslationKey(page:entry.page,number:entry.number)
            let values = [entry.box.x,entry.box.y,entry.box.width,entry.box.height]
            guard entry.number > 0, !entry.page.isEmpty, mapping[key] == nil,
                  blockIDs.insert(entry.blockID).inserted, layerIDs.insert(entry.layerID).inserted,
                  values.allSatisfy(\.isFinite), entry.box.x >= 0, entry.box.y >= 0,
                  entry.box.width > 0, entry.box.height > 0, entry.box.right <= 1.000001, entry.box.bottom <= 1.000001 else {
                throw TranslationImportError("Карта экспорта содержит повторные или некорректные привязки. Выберите исходную карту без ручных изменений.")
            }
            mapping[key] = entry
        }
        let pagesByName = Dictionary(grouping:chapter.pages.indices,by:{ chapter.pages[$0].file })
        var items: [TranslationImportPlan.Item] = []
        for entry in document.entries {
            guard let anchor = mapping[entry.key] else { throw TranslationImportError("Для \(entry.key.label) нет привязки в карте. Проверьте имя страницы, номер и выбранную карту.") }
            guard let pageIndices = pagesByName[entry.key.page], pageIndices.count == 1 else {
                throw TranslationImportError("Страница \(entry.key.page) не найдена в открытой главе. Откройте исходный проект для этого экспорта.")
            }
            let p = pageIndices[0], page = chapter.pages[p]
            let blocks = page.blocks.filter { $0.id == anchor.blockID }
            guard blocks.count == 1, let block = blocks.first, block.included, page.scanned else {
                throw TranslationImportError("Исходная реплика \(entry.key.label) удалена, исключена или относится к другому проекту. Сверьте перевод с актуальным экспортом.")
            }
            let layers = page.textLayers ?? []
            let exact = layers.filter { $0.id == anchor.layerID }
            let linked = layers.filter { $0.sourceBlockID == anchor.blockID }
            guard exact.count <= 1, linked.count <= 1,
                  exact.first == nil || exact.first?.sourceBlockID == anchor.blockID else {
                throw TranslationImportError("Неоднозначная связь текстового слоя для \(entry.key.label). Проверьте проект перед импортом.")
            }
            var target = exact.first ?? linked.first
            var newLayer: TextLayer?
            if target == nil {
                guard !chapter.pages.contains(where:{ $0.textLayers?.contains(where:{ $0.id == anchor.layerID }) == true }) else {
                    throw TranslationImportError("ID слоя \(entry.key.label) уже используется в другом месте проекта.")
                }
                var created = TranslationAnchors.make(for:block,page:page)
                created.id = anchor.layerID; created.box = anchor.box
                target = created; newLayer = created
            }
            let layer = target!
            let oldText = layer.text.trimmingCharacters(in:.whitespacesAndNewlines)
            let oldRU = block.translation?.text.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            let conflict = (!oldText.isEmpty && oldText != entry.text) || (!oldRU.isEmpty && oldRU != entry.text)
            let context = ProjectFiles.translationContext(page,glossary:chapter.glossary)
            let unchanged = newLayer == nil && layer.text == entry.text && block.translation?.text == entry.text
                && block.translation?.source == block.text && block.translation?.context == context
            var previous: [String] = []
            if !oldText.isEmpty && oldText != entry.text { previous.append("Слой: " + layer.text) }
            if !oldRU.isEmpty && oldRU != entry.text { previous.append("Перевод OCR: " + oldRU) }
            items.append(.init(key:entry.key,pageIndex:p,blockID:block.id,layerID:layer.id,text:entry.text,
                previous:previous.joined(separator:"\n"),conflict:conflict,unchanged:unchanged,
                sourceChanged:block.text != anchor.source,hidden:!layer.visible,newLayer:newLayer))
        }
        let imported = Set(document.entries.map(\.key))
        let missing = map.entries.map { TranslationKey(page:$0.page,number:$0.number) }.filter { !imported.contains($0) }
        return TranslationImportPlan(document:document,map:map,items:items,missing:missing)
    }
    static func applying(_ original: TranslationImportPlan, to chapter: Chapter, policy: TranslationImportPolicy, allowPartial: Bool) throws -> (Chapter, [TranslationImportPlan.Item]) {
        // Resolve IDs again so a stale preview can never write to a different layer.
        let plan = try self.plan(document:original.document,map:original.map,chapter:chapter)
        guard plan.missing.isEmpty || allowPartial else { throw TranslationImportError("В TXT отсутствует часть реплик. Подтвердите частичный импорт в окне проверки.") }
        var updated = chapter
        let items = plan.applicable(policy)
        for item in items {
            let p = item.pageIndex
            if let newLayer = item.newLayer {
                if updated.pages[p].textLayers == nil { updated.pages[p].textLayers = [] }
                updated.pages[p].textLayers?.append(newLayer)
            }
            guard let l = updated.pages[p].textLayers?.firstIndex(where:{ $0.id == item.layerID }),
                  let b = updated.pages[p].blocks.firstIndex(where:{ $0.id == item.blockID }) else { throw ScanError.missingAnchor }
            updated.pages[p].textLayers![l].text = item.text
            updated.pages[p].textLayers![l].anchorEdited = true
            let context = ProjectFiles.translationContext(updated.pages[p],glossary:updated.glossary)
            updated.pages[p].blocks[b].translation = TranslationRecord(text:item.text,source:updated.pages[p].blocks[b].text,context:context,model:"imported-txt")
            updated.pages[p].translationReviewed = false
        }
        return (updated,items)
    }
}
