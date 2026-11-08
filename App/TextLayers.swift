import AppKit
import SwiftUI
import ImageIO

// Shared AppKit typography for the on-screen layer and full-resolution PNG export.
enum TextRenderer {
    static func rect(_ layer: TextLayer, size: CGSize) -> CGRect {
        CGRect(x:layer.box.x*size.width,y:layer.box.y*size.height,
               width:layer.box.width*size.width,height:layer.box.height*size.height)
    }
    struct FontStyle {
        var font: NSFont
        var bold: Bool
        var italic: Bool
        var syntheticBold: Bool
        var syntheticItalic: Bool
        var cannotRemoveTrait: Bool
    }
    static func fontStyle(_ layer: TextLayer, width: Double) -> FontStyle {
        let manager = NSFontManager.shared
        var font = NSFont(name:layer.fontName,size:max(1,layer.fontScale*width)) ?? NSFont.systemFont(ofSize:max(1,layer.fontScale*width))
        let baseTraits = manager.traits(of:font)
        let bold = layer.bold ?? baseTraits.contains(.boldFontMask)
        let italic = layer.italic ?? baseTraits.contains(.italicFontMask)
        // Remove unwanted traits first; then choose real faces for the requested combination.
        if !bold && manager.traits(of:font).contains(.boldFontMask) { font = manager.convert(font,toNotHaveTrait:.boldFontMask) }
        if !italic && manager.traits(of:font).contains(.italicFontMask) { font = manager.convert(font,toNotHaveTrait:.italicFontMask) }
        if bold && !manager.traits(of:font).contains(.boldFontMask) { font = manager.convert(font,toHaveTrait:.boldFontMask) }
        if italic && !manager.traits(of:font).contains(.italicFontMask) { font = manager.convert(font,toHaveTrait:.italicFontMask) }
        let traits = manager.traits(of:font)
        return FontStyle(font:font,bold:bold,italic:italic,
            syntheticBold:bold && !traits.contains(.boldFontMask),
            syntheticItalic:italic && !traits.contains(.italicFontMask),
            cannotRemoveTrait:(!bold && traits.contains(.boldFontMask)) || (!italic && traits.contains(.italicFontMask)))
    }
    static func horizontalScale(_ layer: TextLayer) -> Double { max(0.5,min(2,layer.widthScale ?? 1)) }
    static func attributed(_ layer: TextLayer, width: Double) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = layer.alignment == .left ? .left : layer.alignment == .right ? .right : .center
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = max(0,layer.lineSpacing*width)
        let face = fontStyle(layer,width:width)
        var attributes: [NSAttributedString.Key:Any] = [
            .font:face.font,
            .foregroundColor:NSColor(srgbRed:layer.red,green:layer.green,blue:layer.blue,alpha:1),
            .paragraphStyle:style,.kern:layer.letterSpacing*width]
        if face.syntheticBold { attributes[.strokeWidth] = -2.5 }
        if face.syntheticItalic { attributes[.obliqueness] = 0.2 }
        if layer.underline == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if layer.strikethrough == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string:layer.uppercase == true ? layer.text.uppercased() : layer.text,attributes:attributes)
    }
    static func textHeight(_ layer: TextLayer, size: CGSize) -> Double {
        attributed(layer,width:size.width).boundingRect(with:CGSize(width:max(1,layer.box.width*size.width/horizontalScale(layer)),height:CGFloat.greatestFiniteMagnitude),
            options:[.usesLineFragmentOrigin,.usesFontLeading]).height * layer.heightScale
    }
    static func draw(_ layer: TextLayer, size: CGSize) {
        guard layer.visible, let context = NSGraphicsContext.current?.cgContext else { return }
        let box = rect(layer,size:size)
        let factor = max(0.1,layer.heightScale)
        let horizontal = horizontalScale(layer)
        let layoutWidth = max(1,box.width/horizontal)
        let text = attributed(layer,width:size.width)
        let measured = text.boundingRect(with:CGSize(width:layoutWidth,height:CGFloat.greatestFiniteMagnitude),
            options:[.usesLineFragmentOrigin,.usesFontLeading])
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to:box)
        context.translateBy(x:box.minX,y:box.minY)
        context.scaleBy(x:horizontal,y:factor)
        let height = box.height/factor
        let y = layer.verticallyCentered ? max(0,(height-measured.height)/2) : 0
        text.draw(with:CGRect(x:0,y:y,width:layoutWidth,height:max(height,measured.height)),
            options:[.usesLineFragmentOrigin,.usesFontLeading])
    }
    static func export(image: URL, layers: [TextLayer], to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(image as CFURL,nil),
              let background = CGImageSourceCreateImageAtIndex(source,0,nil),
              let context = CGContext(data:nil,width:background.width,height:background.height,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw UpscaleFailure("Не удалось открыть рабочее изображение для экспорта.")
        }
        let size = CGSize(width:background.width,height:background.height)
        context.draw(background,in:CGRect(origin:.zero,size:size))
        context.translateBy(x:0,y:size.height); context.scaleBy(x:1,y:-1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
        for layer in layers { draw(layer,size:size) }
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw UpscaleFailure("Не удалось собрать изображение.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else {
            throw UpscaleFailure("Не удалось создать PNG.")
        }
        CGImageDestinationAddImage(destination,result,nil)
        guard CGImageDestinationFinalize(destination) else { throw UpscaleFailure("Не удалось записать PNG.") }
        try (data as Data).write(to:output,options:.atomic)
    }
}

enum TextHandle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x:movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
                y:movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY)
    }
}

enum TextBoxGeometry {
    // Delta always comes from the original mouse-down point in page coordinates.
    static func changed(_ box: Box, delta: CGSize, handle: TextHandle?, minimum: CGSize) -> Box {
        guard let handle else {
            return Box(x:max(0,min(1-box.width,box.x+delta.width)),
                       y:max(0,min(1-box.height,box.y+delta.height)),width:box.width,height:box.height)
        }
        var left = box.x, top = box.y, right = box.right, bottom = box.bottom
        let minW = min(box.width,minimum.width), minH = min(box.height,minimum.height)
        if handle.movesLeft { left = max(0,min(right-minW,left+delta.width)) }
        if handle.movesRight { right = min(1,max(left+minW,right+delta.width)) }
        if handle.movesTop { top = max(0,min(bottom-minH,top+delta.height)) }
        if handle.movesBottom { bottom = min(1,max(top+minH,bottom+delta.height)) }
        return Box(x:left,y:top,width:right-left,height:bottom-top)
    }
}

// One stationary native surface avoids the feedback caused by dragging an offset SwiftUI view.
final class TextCanvasView: NSView {
    var layers: [TextLayer] = []
    var selectedID: UUID?
    var editable = false
    var anchorNumbers: [UUID:Int] = [:]
    var select: (UUID) -> Void = { _ in }
    var commit: (UUID, Box) -> Void = { _,_ in }
    private struct Drag {
        var id: UUID
        var origin: CGPoint
        var original: Box
        var box: Box
        var handle: TextHandle?
    }
    private var drag: Drag?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func effective(_ layer: TextLayer) -> TextLayer {
        var value = layer
        if let drag, drag.id == value.id { value.box = drag.box }
        return value
    }
    private func handle(at point: CGPoint) -> TextHandle? {
        guard let layer = layers.first(where:{ $0.id == selectedID && $0.visible }) else { return nil }
        let rect = TextRenderer.rect(effective(layer),size:bounds.size)
        return TextHandle.allCases.first { handle in
            let p = handle.point(in:rect)
            return CGRect(x:p.x-8,y:p.y-8,width:16,height:16).contains(point)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard editable, !isHidden else { return nil }
        let local = convert(point,from:superview)
        guard bounds.contains(local) else { return nil }
        if handle(at:local) != nil { return self }
        return layers.reversed().contains { $0.visible && TextRenderer.rect($0,size:bounds.size).contains(local) } ? self : nil
    }
    override func draw(_ dirtyRect: NSRect) {
        for layer in layers where layer.visible {
            TextRenderer.draw(effective(layer),size:bounds.size)
        }
        if editable {
            for layer in layers where layer.visible && layer.text.isEmpty && layer.sourceBlockID != nil {
                let rect = TextRenderer.rect(effective(layer),size:bounds.size)
                NSColor.systemPurple.withAlphaComponent(0.5).setStroke()
                let outline = NSBezierPath(rect:rect); outline.lineWidth = 1
                outline.setLineDash([4,3],count:2,phase:0); outline.stroke()
                if let id = layer.sourceBlockID, let number = anchorNumbers[id] {
                    NSAttributedString(string:String(format:"[%02d]",number),attributes:[.font:NSFont.systemFont(ofSize:11),
                        .foregroundColor:NSColor.systemPurple]).draw(at:CGPoint(x:rect.minX+3,y:rect.minY+2))
                }
            }
        }
        if editable, let selected = layers.first(where:{ $0.id == selectedID && $0.visible }) {
            let rect = TextRenderer.rect(effective(selected),size:bounds.size)
            NSColor.systemPurple.setStroke()
            let outline = NSBezierPath(rect:rect); outline.lineWidth = 1; outline.stroke()
            for handle in TextHandle.allCases {
                let p = handle.point(in:rect)
                let square = NSBezierPath(rect:CGRect(x:p.x-4,y:p.y-4,width:8,height:8))
                NSColor.white.setFill(); square.fill(); NSColor.systemPurple.setStroke(); square.stroke()
            }
        }
    }
    override func resetCursorRects() {
        guard editable else { return }
        for layer in layers where layer.visible {
            addCursorRect(TextRenderer.rect(layer,size:bounds.size),cursor:.openHand)
        }
        if let selected = layers.first(where:{ $0.id == selectedID && $0.visible }) {
            let rect = TextRenderer.rect(selected,size:bounds.size)
            for handle in TextHandle.allCases {
                let p = handle.point(in:rect)
                let cursor: NSCursor = handle == .left || handle == .right ? .resizeLeftRight
                    : handle == .top || handle == .bottom ? .resizeUpDown : .crosshair
                addCursorRect(CGRect(x:p.x-8,y:p.y-8,width:16,height:16),cursor:cursor)
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        let point = convert(event.locationInWindow,from:nil)
        let resize = handle(at:point)
        let selected = resize != nil ? layers.first(where:{ $0.id == selectedID })
            : layers.reversed().first(where:{ $0.visible && TextRenderer.rect($0,size:bounds.size).contains(point) })
        guard let selected else { return }
        drag = Drag(id:selected.id,origin:point,original:selected.box,box:selected.box,handle:resize)
        selectedID = selected.id; select(selected.id)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        updateDrag(event)
    }
    private func updateDrag(_ event: NSEvent) {
        guard var value = drag, editable else { return }
        let point = convert(event.locationInWindow,from:nil)
        let delta = CGSize(width:(point.x-value.origin.x)/max(1,bounds.width),height:(point.y-value.origin.y)/max(1,bounds.height))
        value.box = TextBoxGeometry.changed(value.original,delta:delta,handle:value.handle,
            minimum:CGSize(width:12/max(1,bounds.width),height:12/max(1,bounds.height)))
        drag = value
        if value.handle == nil { NSCursor.closedHand.set() }
        // Only the native view redraws during dragging; no project writes or image reloads.
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        updateDrag(event)
        guard let value = drag else { return }
        drag = nil
        if value.box != value.original { commit(value.id,value.box) }
        needsDisplay = true
        window?.invalidateCursorRects(for:self)
    }
    func cancelDrag() { drag = nil }
}

struct TextLayersCanvas: NSViewRepresentable {
    @ObservedObject var model: MangaModel
    func makeNSView(context: Context) -> TextCanvasView { TextCanvasView() }
    func updateNSView(_ view: TextCanvasView, context: Context) {
        view.layers = model.page?.textLayers ?? []
        view.anchorNumbers = Dictionary((model.page?.blocks.filter(\.included) ?? []).enumerated().map { ($0.element.id,$0.offset+1) },uniquingKeysWith:{ first,_ in first })
        view.selectedID = model.selectedTextLayer
        view.editable = model.textEditing && !model.busy && !model.healing && !model.adding
        if !view.editable { view.cancelDrag() }
        view.select = { id in if model.selectedTextLayer != id { model.selectedTextLayer = id } }
        view.commit = { id,box in model.updateTextLayer(id) { $0.box = box } }
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for:view)
    }
}

struct TextLayerInspector: View {
    @ObservedObject var model: MangaModel
    @State private var choosingFont = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("Текстовые слои").font(.headline)
                    Spacer()
                    Button { model.undo() } label: { Image(systemName:"arrow.uturn.backward") }
                        .help("Отменить последнюю правку").disabled(model.undoHistory.isEmpty)
                    Button("Добавить",action:model.addTextLayer)
                }
                Button("Импорт перевода TXT…",action:model.beginTranslationImport)
                    .disabled(model.chapter == nil)
                if let layers = model.page?.textLayers, !layers.isEmpty {
                    if layers.contains(where:{ $0.sourceBlockID != nil && $0.text.isEmpty }) {
                        Text("Пунктирные рамки — места перевода из OCR. Их номера совпадают с TXT; пустые рамки не видны в PNG.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing:4) {
                        ForEach(layers.reversed()) { layer in
                            Button { model.selectedTextLayer = layer.id } label: {
                                HStack {
                                    Image(systemName:layer.visible ? "textformat" : "eye.slash")
                                    Text(model.layerTitle(layer)).lineLimit(1)
                                    Spacer()
                                }.padding(6).contentShape(Rectangle()).background(model.selectedTextLayer == layer.id ? Color.purple.opacity(0.12) : Color.clear)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if let layer = model.layer {
                    if let source = model.sourceCaption(for:layer) {
                        Text("Реплика " + source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if layer.text.isEmpty { Text("Место перевода сохранено. Введите текст в поле ниже.").font(.caption).foregroundStyle(.secondary) }
                    }
                    TextEditor(text:Binding(get:{ model.layer?.text ?? "" },set:{ value in model.updateTextLayer(layer.id) { $0.text = value } }))
                        .font(.body).frame(height:110).border(Color.secondary.opacity(0.25))
                    HStack {
                        Text("Шрифт").frame(width:105,alignment:.leading)
                        Button(TextRenderer.fontStyle(layer,width:model.workingSize.width).font.displayName ?? layer.fontName) { choosingFont = true }
                            .lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    if NSFont(name:layer.fontName,size:14) == nil {
                        Text("Шрифт недоступен. Выберите установленный шрифт; пока используется системный.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    let face = TextRenderer.fontStyle(layer,width:model.workingSize.width)
                    HStack(spacing:6) {
                        styleToggle("B",label:"Жирный",key: \.bold,fallback:face.bold)
                        styleToggle("I",label:"Курсив",key: \.italic,fallback:face.italic)
                        styleToggle("U",label:"Подчёркнутый",key: \.underline)
                        styleToggle("S",label:"Зачёркнутый",key: \.strikethrough)
                        styleToggle("TT",label:"Все прописные",key: \.uppercase)
                        Spacer(minLength:0)
                    }
                    Text("Форматирование применяется ко всему слою.").font(.caption).foregroundStyle(.secondary)
                    if face.syntheticBold || face.syntheticItalic {
                        Text("У шрифта нет нужного начертания. Используется искусственная жирность или наклон.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if face.cannotRemoveTrait {
                        Text("У шрифта нет обычного начертания. Чтобы убрать жирность или курсив, выберите другое начертание в списке шрифтов.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    number("Размер, px",key: \.fontScale,multiplier:model.workingSize.width,range:1...1000)
                    HStack {
                        Text("Ширина букв, %").frame(width:145,alignment:.leading)
                        TextField("Ширина букв, %",value:Binding(get:{ (model.layer?.widthScale ?? 1)*100 },set:{ value in
                            guard value.isFinite, let id = model.selectedTextLayer else { return }
                            model.updateTextLayer(id) { $0.widthScale = max(50,min(200,value))/100 }
                        }),format:.number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder)
                    }
                    number("Высота букв, %",key: \.heightScale,multiplier:100,range:50...200)
                    number("Межстрочный, px",key: \.lineSpacing,multiplier:model.workingSize.width,range:0...500)
                    number("Межбуквенный, px",key: \.letterSpacing,multiplier:model.workingSize.width,range:-30...100)
                    Picker("Выравнивание",selection:Binding(get:{ model.layer?.alignment ?? .center },set:{ value in model.updateTextLayer(layer.id) { $0.alignment = value } })) {
                        ForEach(TextAlignment.allCases,id:\.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("По центру блока по высоте",isOn:Binding(get:{ model.layer?.verticallyCentered ?? true },set:{ value in model.updateTextLayer(layer.id) { $0.verticallyCentered = value } }))
                    ColorPicker("Цвет текста",selection:Binding(get:{ Color(.sRGB,red:layer.red,green:layer.green,blue:layer.blue) },set:{ color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        model.updateTextLayer(layer.id) { $0.red = rgb.redComponent; $0.green = rgb.greenComponent; $0.blue = rgb.blueComponent }
                    }),supportsOpacity:false)
                    Divider()
                    Text("Положение и размер блока").font(.subheadline.bold())
                    number("X, px",key: \.box.x,multiplier:model.workingSize.width,range:0...model.workingSize.width)
                    number("Y, px",key: \.box.y,multiplier:model.workingSize.height,range:0...model.workingSize.height)
                    number("Ширина, px",key: \.box.width,multiplier:model.workingSize.width,range:1...model.workingSize.width)
                    number("Высота, px",key: \.box.height,multiplier:model.workingSize.height,range:1...model.workingSize.height)
                    if TextRenderer.textHeight(layer,size:model.workingSize) > layer.box.height*model.workingSize.height+1 {
                        Text("Текст не помещается по высоте. Увеличьте блок или уменьшите шрифт.").font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Показывать слой",isOn:Binding(get:{ model.layer?.visible ?? true },set:{ value in model.updateTextLayer(layer.id) { $0.visible = value } }))
                    HStack {
                        Button("Ниже") { model.reorderTextLayer(by:-1) }
                        Button("Выше") { model.reorderTextLayer(by:1) }
                        Spacer()
                        Button("Удалить",action:model.deleteTextLayer)
                    }
                } else {
                    Text("Добавьте слой или выберите его в списке. Текст можно перемещать мышью по странице.")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Button("Экспорт страницы в PNG…",action:model.choosePNGExport).buttonStyle(.borderedProminent)
                Text("Слои сохраняются с главой. PNG содержит изображение и видимые слои без рамок редактирования.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }.disabled(model.busy)
        .sheet(isPresented:$choosingFont) {
            FontChooser(current:model.layer.map { TextRenderer.fontStyle($0,width:model.workingSize.width).font.fontName } ?? "Helvetica") { name in
                if let id = model.selectedTextLayer { model.updateTextLayer(id) { $0.fontName = name; $0.bold = nil; $0.italic = nil } }
                choosingFont = false
            }
        }
    }
    private func styleToggle(_ title: String, label: String, key: WritableKeyPath<TextLayer,Bool?>, fallback: Bool = false) -> some View {
        Toggle(isOn:Binding(get:{ model.layer?[keyPath:key] ?? fallback },set:{ value in
            if let id = model.selectedTextLayer { model.updateTextLayer(id) { $0[keyPath:key] = value } }
        })) {
            Text(title).font(title == "I" ? .system(size:13,weight:.semibold).italic() : .system(size:13,weight:.semibold))
                .underline(title == "U").strikethrough(title == "S").frame(minWidth:18)
        }.toggleStyle(.button).tint(.purple).help(label).accessibilityLabel(label)
    }
    private func number(_ title: String, key: WritableKeyPath<TextLayer,Double>, multiplier: Double, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width:145,alignment:.leading)
            TextField(title,value:Binding(get:{ (model.layer ?? TextLayer())[keyPath:key]*multiplier },set:{ value in
                guard value.isFinite, let id = model.selectedTextLayer else { return }
                model.updateTextLayer(id) {
                    $0[keyPath:key] = max(range.lowerBound,min(range.upperBound,value))/max(1,multiplier)
                    $0.box.width = min(1,max(0.001,$0.box.width)); $0.box.height = min(1,max(0.001,$0.box.height))
                    $0.box.x = min(1-$0.box.width,max(0,$0.box.x)); $0.box.y = min(1-$0.box.height,max(0,$0.box.y))
                }
            }),format:.number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder)
        }
    }
}

private struct FontChooser: View {
    let current: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var fonts: [String] = []
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Системные шрифты").font(.title2.bold())
            TextField("Найти шрифт",text:$query).textFieldStyle(.roundedBorder)
            List(fonts.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) },id:\.self) { name in
                Button { choose(name) } label: {
                    HStack {
                        Text(NSFont(name:name,size:14)?.displayName ?? name)
                        Spacer()
                        if name == current { Image(systemName:"checkmark") }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,3).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Button("Закрыть") { dismiss() }
        }.padding(20).frame(width:460,height:480)
        .onAppear { fonts = NSFontManager.shared.availableFonts.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }
}


struct TranslationImportPreview: View {
    @ObservedObject var model: MangaModel
    let plan: TranslationImportPlan
    @State private var policy: TranslationImportPolicy = .keepExisting
    @State private var allowPartial = false
    private var count: Int { plan.applicable(policy).count }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Импорт перевода").font(.title2.bold())
            Text("TXT: \(model.importTXTName)\nКарта: \(model.importMapName)").font(.caption).foregroundStyle(.secondary)
            Text("Реплик в файле: \(plan.items.count). Страниц: \(plan.pageCount). Будет обновлено: \(count).")
            if plan.conflicts > 0 {
                Text("Реплик с другим текстом в слоях или переводах OCR: \(plan.conflicts).").foregroundStyle(.orange)
                Picker("Заполненный текст",selection:$policy) {
                    ForEach(TranslationImportPolicy.allCases,id:\.self) { Text($0.rawValue).tag($0) }
                }
            }
            if !plan.missing.isEmpty {
                Text("В TXT отсутствует реплик: \(plan.missing.count). Их слои останутся без изменений.").foregroundStyle(.orange)
                Text(plan.missing.prefix(12).map(\.label).joined(separator:", ") + (plan.missing.count > 12 ? "…" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Импортировать неполный перевод",isOn:$allowPartial)
            }
            if plan.items.contains(where: \.sourceChanged) {
                Text("После экспорта часть исходных реплик была исправлена. Сверьте их перевод; привязка сохраняется по ID.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if plan.items.contains(where: \.hidden) {
                Text("Некоторые слои скрыты. Их видимость сохранится; включите её в панели слоя, чтобы увидеть перевод.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    ForEach(plan.items) { item in
                        VStack(alignment:.leading,spacing:4) {
                            HStack {
                                Text(item.key.label).font(.caption.bold())
                                Spacer()
                                if item.unchanged { Text("Уже добавлено").font(.caption).foregroundStyle(.secondary) }
                                else if item.conflict && policy == .keepExisting { Text("Сохранится прежний текст").font(.caption).foregroundStyle(.orange) }
                            }
                            if item.conflict { Text("Сейчас: " + item.previous).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                            Text(item.text).font(.body).textSelection(.enabled)
                        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                            .background(Color.secondary.opacity(0.07)).cornerRadius(8)
                    }
                }
            }.frame(minHeight:160,maxHeight:300)
            Text("Положение, шрифт и оформление слоёв сохранятся. Перевод также появится у реплик OCR. Весь импорт можно отменить одной правкой.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Отмена") { model.pendingTranslationImport = nil }
                Spacer()
                Button("Импортировать: \(count)") { model.finishTranslationImport(plan,policy:policy,allowPartial:allowPartial) }
                    .disabled(count == 0 || (!plan.missing.isEmpty && !allowPartial))
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width:650)
    }
}
