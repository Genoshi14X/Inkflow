import SwiftUI
import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: MangaModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, !model.save() { return .terminateCancel }
        model?.stopUpscaleOnExit()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct InkflowApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = MangaModel()
    var body: some Scene {
        WindowGroup("Inkflow") {
            MainView(model:model)
                .frame(minWidth:1060,minHeight:700)
                .onAppear {
                    delegate.model = model
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps:true)
                    if model.chapter == nil, CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--folder" {
                        model.open(URL(fileURLWithPath:CommandLine.arguments[2]))
                    }
                }
        }
        .defaultSize(width:1320,height:880)
        .commands {
            CommandGroup(replacing:.newItem) { Button("Открыть папку…", action:model.chooseFolder).keyboardShortcut("o").disabled(model.busy) }
            CommandGroup(replacing:.saveItem) {
                Button("Сохранить правки") { _ = model.save() }.keyboardShortcut("s")
                Button("Экспорт TXT…",action:model.export).keyboardShortcut("e").disabled(model.chapter == nil || model.busy)
            }
            CommandGroup(after:.undoRedo) { Button("Отменить правку Inkflow",action:model.undo).keyboardShortcut("z",modifiers:[.command,.shift]).disabled(model.undoHistory.isEmpty || model.busy) }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: MangaModel
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                Image(nsImage:NSImage(named:NSImage.Name("AppIcon")) ?? NSImage())
                    .resizable().frame(width:40,height:40)
                VStack(alignment:.leading) {
                    Text(model.chapter?.name ?? "Inkflow").font(.headline)
                    Text("OCR локально · перевод в браузере").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Открыть папку…",action:model.chooseFolder).disabled(model.busy)
                if model.busy { Button("Остановить",action:model.stop) }
                else { Button("Распознать главу") { model.scanAll() }.disabled(model.chapter == nil).buttonStyle(.borderedProminent) }
                Button("Яндекс Переводчик…", action:model.beginBrowserTranslation)
                    .disabled(model.chapter == nil || model.busy)
                Picker("TXT",selection:$model.exportMode) {
                    ForEach(ExportMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.frame(width:145).disabled(model.busy)
                Button("Экспорт TXT…",action:model.export).disabled(model.chapter == nil || model.busy)
            }.padding(16)
            Divider()
            if model.chapter != nil {
                HSplitView {
                    sidebar.frame(minWidth:140,idealWidth:165,maxWidth:220)
                    PageView(model:model).frame(minWidth:400)
                    inspector.frame(minWidth:360,idealWidth:400,maxWidth:540)
                }
            } else {
                VStack(spacing:20) {
                    Image(systemName:"doc.text.image").font(.system(size:60)).foregroundStyle(.blue)
                    Text("Текст главы — по порядку реплик").font(.title2.bold())
                    Text("Откройте папку со страницами, распознайте главу\nи проверьте номера облачков перед экспортом.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Выбрать папку",action:model.chooseFolder).buttonStyle(.borderedProminent)
                    Text("PNG · JPG · JPEG").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).lineLimit(2)
                Spacer()
                if let c = model.chapter { Text("Проверено: \(c.pages.filter(\.reviewed).count) / \(c.pages.count)").font(.caption).foregroundStyle(.secondary) }
            }.padding(10)
        }
        .alert("Не удалось завершить действие",isPresented:Binding(get:{ model.message != nil },set:{ if !$0 { model.message = nil } })) {
            Button("Закрыть",role:.cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(isPresented:$model.showBrowserTranslation) {
            VStack(alignment:.leading,spacing:14) {
                Text("Перевод главы в Яндексе").font(.title2.bold())
                Text("1. Скопируйте оригинал и вставьте его в левое поле браузера: ⌘V. Яндекс переведёт текст онлайн с английского на русский.").foregroundStyle(.secondary)
                HStack {
                    Picker("Часть", selection:$model.browserPart) {
                        ForEach(Array(model.browserParts.indices), id: \.self) { i in
                            Text("\(i + 1) из \(model.browserParts.count)").tag(i)
                        }
                    }.frame(width:170)
                    Button("Скопировать EN и открыть Яндекс", action:model.copyAndOpenYandex)
                }
                Text("Для длинной главы переводите части по очереди. Перед вставкой новой части очистите левое поле Яндекса.").font(.caption).foregroundStyle(.secondary)
                Text("2. Скопируйте русский результат в браузере и добавьте его сюда. Здесь можно исправить текст перед сохранением.")
                Button("Добавить перевод из буфера", action:model.appendBrowserTranslation)
                TextEditor(text:Binding(get:{ model.chapter?.browserTranslation ?? "" },set:{ model.setBrowserTranslation($0) }))
                    .font(.body).frame(height:260).border(Color.secondary.opacity(0.3))
                Text("Черновик сохраняется с главой. После правок оригинала обновите перевод вручную; к отдельным облачкам он не привязан.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Закрыть") { model.showBrowserTranslation = false }
                    Spacer()
                    Button("Сохранить RU TXT…", action:model.exportBrowserTranslation)
                        .disabled((model.chapter?.browserTranslation ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width:650)
        }
        .onChange(of:model.selectedPage) { _ in model.selectedBlock = nil; model.adding = false; model.healing = false; model.selectedTextLayer = nil }
    }
    var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            Text("СТРАНИЦЫ").font(.caption.bold()).foregroundStyle(.secondary).padding(14)
            List(selection:$model.selectedPage) {
                ForEach(model.chapter?.pages ?? []) { p in
                    HStack {
                        Image(systemName:p.error != nil ? "exclamationmark.triangle" : p.reviewed ? "checkmark.circle.fill" : p.scanned ? "doc.text" : "photo")
                            .foregroundStyle(p.error != nil ? Color.orange : p.reviewed ? Color.green : Color.secondary)
                        VStack(alignment:.leading) {
                            Text(p.file).lineLimit(1)
                            Text(p.scanned ? "\(p.blocks.filter(\.included).count) реплик" : "Не распознана").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical,4).tag(p.file)
                }
            }.listStyle(.sidebar)
        }
    }
    var inspector: some View {
        VStack(spacing:0) {
            Picker("Панель",selection:$model.textEditing) {
                Text("Реплики").tag(false)
                Text("Текст на странице").tag(true)
            }.pickerStyle(.segmented).padding(12)
            if model.textEditing { TextLayerInspector(model:model) }
            else { ocrInspector }
        }
        .onChange(of:model.textEditing) { active in
            if active { model.healing = false; model.adding = false; model.selectedBlock = nil }
            else { model.selectedTextLayer = nil }
        }
    }
    var ocrInspector: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Реплики").font(.title3.bold()); Spacer()
                Button { model.undo() } label: { Image(systemName:"arrow.uturn.backward") }.help("Отменить последнюю правку").disabled(model.undoHistory.isEmpty || model.busy)
            }.padding(.horizontal,14).padding(.top,14)
            Text("Проверьте последовательность. Стрелки меняют порядок, галочка включает реплику в TXT.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal,14)
            if let p = model.page {
                if let error = p.error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal,14) }
                if !p.scanned {
                    Button("Распознать страницу") { model.scanAll(onlyCurrent:true) }.padding(14).disabled(model.busy)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing:10) {
                            ForEach(Array(p.blocks.enumerated()),id:\.element.id) { index,block in
                                BlockCard(model:model,block:block,index:index,total:p.blocks.count).id(block.id)
                            }
                            if p.scanned && p.blocks.isEmpty { Text("Текст не найден. Выделите облачко на странице, чтобы добавить реплику.").foregroundStyle(.secondary).padding() }
                        }.padding(12)
                    }
                    .onChange(of:model.selectedBlock) { id in if let id { withAnimation { proxy.scrollTo(id,anchor:.center) } } }
                }
                Button { model.markReviewed() } label: {
                    Label(p.reviewed ? "Страница проверена" : "Отметить как проверенную",systemImage:p.reviewed ? "checkmark.circle.fill" : "checkmark.circle")
                        .frame(maxWidth:.infinity)
                }.disabled(model.busy || !p.scanned).padding(.horizontal,12)
                if p.blocks.contains(where:{ $0.translation != nil }) {
                    Button(p.translationReviewed == true ? "Перевод проверен" : "Отметить перевод как проверенный") { model.markTranslationReviewed() }
                        .frame(maxWidth:.infinity).disabled(model.busy).padding(.horizontal,12)
                }
                Spacer().frame(height:4)
            } else { Spacer() }
        }.background(Color(nsColor:.controlBackgroundColor))
    }
}

struct BlockCard: View {
    @ObservedObject var model: MangaModel
    let block: TextBlock
    let index: Int
    let total: Int
    @State private var showOriginal = false
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Button { model.selectedBlock = block.id } label: { Text(String(format:"%02d",index+1)).font(.headline.monospacedDigit()) }.buttonStyle(.plain)
                Toggle("В TXT",isOn:Binding(get:{ block.included },set:{ model.include(block.id,value:$0) })).font(.caption).toggleStyle(.checkbox)
                Spacer()
                Button { model.move(block.id,by:-1) } label: { Image(systemName:"arrow.up") }.disabled(index==0).help("Раньше")
                Button { model.move(block.id,by:1) } label: { Image(systemName:"arrow.down") }.disabled(index==total-1).help("Позже")
                Menu {
                    Button("Объединить со следующей") { model.merge(block.id) }.disabled(index==total-1)
                    Button(showOriginal ? "Скрыть исходный OCR" : "Показать исходный OCR") { showOriginal.toggle() }
                    Button("Удалить блок") { model.delete(block.id) }
                } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).frame(width:24)
            }
            TextEditor(text:model.textBinding(block.id))
                .font(.system(size:14)).frame(minHeight:64,idealHeight:CGFloat(min(155,max(64,block.text.count/35*20+28)))).scrollContentBackground(.hidden)
            if model.exportMode != .original || block.translation != nil {
                Text("РУССКИЙ ПЕРЕВОД · ЧЕРНОВИК").font(.caption2.bold()).foregroundStyle(.secondary)
                TextEditor(text:model.textBinding(block.id,translated:true))
                    .font(.system(size:14)).frame(height:85).scrollContentBackground(.hidden)
                if let ru = block.translation, let page = model.page,
                   ru.source != block.text || ru.context != ProjectFiles.translationContext(page,glossary:model.chapter?.glossary) {
                    Text("Оригинал, порядок или словарь изменились — проверьте перевод.").font(.caption2).foregroundStyle(.orange)
                }
            }
            if !block.warning.isEmpty { Label(block.warning,systemImage:"exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
            if showOriginal { Text(block.original).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius:10).fill(Color(nsColor:.textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius:10).stroke(model.selectedBlock==block.id ? Color.blue : Color.gray.opacity(0.2),lineWidth:model.selectedBlock==block.id ? 2 : 1))
        .opacity(block.included ? 1 : 0.55)
        .disabled(model.busy)
    }
}

struct PageView: View {
    @ObservedObject var model: MangaModel
    @State private var dragStart: CGPoint? = nil
    @State private var dragEnd: CGPoint? = nil
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Button(model.adding ? "Отменить выделение" : "Добавить облачко") { model.adding.toggle(); model.healing = false; model.textEditing = false }.disabled(model.busy || model.page?.scanned != true)
                Button("Апскейл папки ×2", action:model.upscale).disabled(model.busy || model.chapter == nil)
                Toggle("Панели",isOn:$model.showPanels).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button { model.zoom = max(1,model.zoom-0.25) } label: { Image(systemName:"minus.magnifyingglass") }
                Text("\(Int(model.zoom*100))%").font(.caption.monospacedDigit()).frame(width:40)
                Button { model.zoom = min(3,model.zoom+0.25) } label: { Image(systemName:"plus.magnifyingglass") }
            }.padding(10)
            HStack(spacing:10) {
                Button(model.healing ? "Завершить ретушь" : "Кисть восстановления") {
                    model.healing.toggle(); model.adding = false; model.textEditing = false; model.selectedBlock = nil
                }.disabled(model.busy || model.imageURL == nil)
                if !model.healing {
                    Button("Добавить текст",action:model.addTextLayer).disabled(model.busy || model.imageURL == nil)
                }
                if model.healing {
                    Text("Размер").font(.caption)
                    Slider(value:$model.brushDiameter,in:4...240,step:2).frame(minWidth:65,maxWidth:150)
                    Text("\(Int(model.brushDiameter)) px").font(.caption.monospacedDigit()).frame(width:48)
                    Button { model.undo() } label: { Image(systemName:"arrow.uturn.backward") }
                        .help("Отменить мазок или последнюю правку").disabled(model.busy || model.undoHistory.isEmpty)
                }
                Spacer(minLength:0)
                Button {
                    if let url = model.imageURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: { Image(systemName:"folder") }.help("Показать рабочее изображение в Finder")
                    .disabled(model.imageURL == nil)
            }.padding(.horizontal,10).padding(.bottom,8)
            if model.healing {
                Picker("Восстановление",selection:$model.healingMethod) {
                    Text("Сохранять текстуру").tag("texture")
                    Text("Сглаживать").tag("smooth")
                }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
                    .padding(.horizontal,10).padding(.bottom,8)
            }
            if model.healing {
                Text("Закрасьте текст целиком, захватив немного фона. Отпустите мышь, чтобы восстановить участок.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal,10).padding(.bottom,8)
            }
            if model.adding { Text("Обведите одно облачко мышью. Новая реплика появится в конце списка.").font(.caption).foregroundStyle(.blue).padding(.bottom,8) }
            GeometryReader { geo in
                if let url = model.imageURL, let nsImage = NSImage(contentsOf:url) {
                    let width = max(200,geo.size.width-24)*model.zoom
                    let height = width * nsImage.size.height / max(1,nsImage.size.width)
                    ScrollView([.horizontal,.vertical]) {
                        ZStack(alignment:.topLeading) {
                            Image(nsImage:nsImage).resizable().frame(width:width,height:height)
                            if model.showPanels && !model.healing && !model.textEditing {
                                ForEach(Array((model.page?.panels ?? []).enumerated()),id:\.offset) { i,box in
                                    Rectangle().stroke(Color.green.opacity(0.8),style:StrokeStyle(lineWidth:2,dash:[6,4]))
                                        .overlay(alignment:.bottomLeading) { Text("П\(i+1)").font(.caption2).padding(3).background(.green).foregroundStyle(.white) }
                                        .frame(width:box.width*width,height:box.height*height).offset(x:box.x*width,y:box.y*height).allowsHitTesting(false)
                                }
                            }
                            ForEach(Array((model.page?.blocks ?? []).enumerated()),id:\.element.id) { i,b in
                                let color = !b.included ? Color.gray : model.selectedBlock==b.id ? Color.orange : Color.blue
                                Rectangle().stroke(color,lineWidth:model.selectedBlock==b.id ? 3 : 1.5)
                                    .background(color.opacity(0.07))
                                    .overlay(alignment:.topLeading) { Text("\(i+1)").font(.system(size:12,weight:.bold)).padding(3).background(color).foregroundStyle(.white).offset(y:-19) }
                                    .frame(width:max(14,b.box.width*width),height:max(14,b.box.height*height))
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectedBlock = b.id }
                                    .offset(x:b.box.x*width,y:b.box.y*height)
                                    .allowsHitTesting(!model.adding && !model.healing && !model.textEditing)
                                    .opacity(model.healing || model.textEditing ? 0 : 1)
                            }
                            TextLayersCanvas(model:model).frame(width:width,height:height).id(model.page?.file)
                            if model.healing {
                                HealingCanvas(diameter:model.brushDiameter * width / Double(UpscaleJob.dimensions(url)?.0 ?? 1),
                                    canvasSize:CGSize(width:width,height:height)) { points in model.heal(points) }
                                    .frame(width:width,height:height).id(url.path)
                                    .allowsHitTesting(!model.busy)
                            }
                            if model.adding {
                                Color.clear.contentShape(Rectangle()).frame(width:width,height:height)
                                    .gesture(DragGesture(minimumDistance:3).onChanged { value in dragStart = value.startLocation; dragEnd = value.location }.onEnded { value in
                                        let x = max(0,min(value.startLocation.x,value.location.x))/width
                                        let y = max(0,min(value.startLocation.y,value.location.y))/height
                                        let r = min(width,max(value.startLocation.x,value.location.x))/width
                                        let b = min(height,max(value.startLocation.y,value.location.y))/height
                                        dragStart = nil; dragEnd = nil
                                        if r-x > 0.01 && b-y > 0.006 { model.addRegion(Box(x:x,y:y,width:r-x,height:b-y)) }
                                    })
                            }
                            if let a = dragStart, let b = dragEnd {
                                Rectangle().fill(Color.orange.opacity(0.15)).border(Color.orange,width:2)
                                    .frame(width:abs(b.x-a.x),height:abs(b.y-a.y)).offset(x:min(a.x,b.x),y:min(a.y,b.y)).allowsHitTesting(false)
                            }
                        }.frame(width:width,height:height).padding(12)
                    }
                } else { Text("Не удалось показать изображение.").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
            }
        }.background(Color(nsColor:.underPageBackgroundColor))
    }
}


// The stroke lives in image coordinates, independent of scroll position and zoom.
struct HealingCanvas: View {
    let diameter: Double
    let canvasSize: CGSize
    let apply: ([BrushPoint]) -> Void
    @State private var points: [CGPoint] = []
    @State private var hover: CGPoint? = nil

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x:max(0,min(canvasSize.width,point.x)),y:max(0,min(canvasSize.height,point.y)))
    }
    var body: some View {
        ZStack(alignment:.topLeading) {
            Color.clear
            Path { path in
                if points.count == 1, let p = points.first {
                    path.addEllipse(in:CGRect(x:p.x-diameter/2,y:p.y-diameter/2,width:diameter,height:diameter))
                } else if let first = points.first {
                    path.move(to:first)
                    for point in points.dropFirst() { path.addLine(to:point) }
                }
            }
            .stroke(Color.pink.opacity(0.55),style:StrokeStyle(lineWidth:points.count == 1 ? 1 : diameter,lineCap:.round,lineJoin:.round))
            if let hover {
                Circle().stroke(Color.white,lineWidth:2).overlay(Circle().stroke(Color.black,lineWidth:1))
                    .frame(width:diameter,height:diameter).position(hover)
            }
        }
        .clipped().contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase { case .active(let location): hover = clamped(location); case .ended: hover = nil }
        }
        .gesture(DragGesture(minimumDistance:0).onChanged { value in
            let p = clamped(value.location)
            if points.isEmpty { points.append(clamped(value.startLocation)) }
            if points.last != p { points.append(p) }
            hover = p
        }.onEnded { value in
            if points.isEmpty { points = [clamped(value.location)] }
            let stroke = points.map { BrushPoint(x:$0.x/canvasSize.width,y:$0.y/canvasSize.height) }
            points = []; apply(stroke)
        })
    }
}
