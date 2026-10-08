import AppKit
import SwiftUI

struct WinInfo: Identifiable {
    let id = UUID()
    let window: AXWindow
    let appName: String
    let title: String
    let icon: NSImage?
}

struct CellInfo: Identifiable {
    var id: Int { index }
    let index: Int
    let rect: CGRect
    let windows: [WinInfo]
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var cells: [CellInfo] = []
    @Published var unplaced: [WinInfo] = []
    @Published var layoutName = GridManager.shared.layout.name
    @Published var projects: [String] = []
    @Published var pageCounts: [Int] = []
    @Published var currentPage = 0

    func refresh() {
        let gm = GridManager.shared
        let screen = gm.screen(for: nil)
        let occupancy = gm.occupancy(on: screen)
        func info(_ w: AXWindow) -> WinInfo {
            WinInfo(window: w, appName: w.appName, title: w.title, icon: w.app?.icon)
        }
        cells = gm.layout.cells.enumerated().map { i, r in
            CellInfo(index: i, rect: r, windows: (occupancy[i] ?? []).map(info))
        }
        let placed = occupancy.values.flatMap { $0 }
        // Includes fullscreen windows and windows on other Spaces ("Place in…" pulls fullscreen ones back).
        unplaced = AX.allWindows().filter { w in
            guard let f = w.frame, !ScreenGeometry.isParked(f) else { return false }
            return !placed.contains { $0.isSame(w) }
        }.map(info)
        let pm = PageManager.shared
        pageCounts = (0..<pm.pageCount).map { pm.windowCount(of: $0) }
        currentPage = pm.current
        layoutName = gm.layout.name
        projects = ProjectLayoutStore.shared.layouts.map(\.name)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Grid", selection: Binding(
                    get: { model.layoutName },
                    set: { name in
                        if let l = GridLayout.presets.first(where: { $0.name == name }) { GridManager.shared.layout = l }
                        model.refresh()
                    })) {
                    ForEach(GridLayout.presets, id: \.name) { Text($0.name).tag($0.name) }
                }
                .frame(width: 200)
                Spacer()
                if !model.projects.isEmpty {
                    Menu("Restore project") {
                        ForEach(model.projects, id: \.self) { name in
                            Button(name) {
                                guard let p = ProjectLayoutStore.shared.layouts.first(where: { $0.name == name }) else { return }
                                Task { await ProjectLayoutStore.shared.restore(p); model.refresh() }
                            }
                        }
                    }
                    .frame(width: 160)
                }
                Button("Tile all") { PageManager.shared.tileAll(); refreshSoon() }
                Button("Refresh") { model.refresh() }
            }

            HStack(spacing: 6) {
                Button { PageManager.shared.previous(); refreshSoon() } label: { Image(systemName: "chevron.left") }
                ForEach(Array(model.pageCounts.enumerated()), id: \.offset) { i, count in
                    Button("Page \(i + 1) · \(count)") { PageManager.shared.go(to: i); refreshSoon() }
                        .buttonStyle(.bordered)
                        .tint(i == model.currentPage ? .accentColor : .secondary)
                }
                Button { PageManager.shared.next(); refreshSoon() } label: { Image(systemName: "chevron.right") }
                Button("+ New page") { PageManager.shared.newPage(); refreshSoon() }
                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(model.cells) { cell in
                        CellView(cell: cell, refresh: model.refresh)
                            .frame(width: cell.rect.width * geo.size.width - 6,
                                   height: cell.rect.height * geo.size.height - 6)
                            .offset(x: cell.rect.minX * geo.size.width + 3,
                                    y: cell.rect.minY * geo.size.height + 3)
                    }
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)

            if !model.unplaced.isEmpty {
                Text("Not in the grid").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.unplaced) { w in
                            HStack {
                                WindowRow(info: w)
                                Spacer()
                                Menu("Place in…") {
                                    ForEach(model.cells) { c in
                                        Button("Cell \(c.index + 1)") {
                                            GridManager.shared.place(w.window, inCells: [c.index])
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.refresh() }
                                        }
                                    }
                                }
                                .frame(width: 100)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { model.refresh() }
        .onReceive(timer) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .gridLayoutChanged)) { _ in model.refresh() }
    }
}

extension DashboardView {
    /// Window moves take a moment to land; refresh after they settle.
    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.refresh() }
    }
}

struct CellView: View {
    let cell: CellInfo
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(cell.index + 1)").font(.caption.bold()).foregroundStyle(.secondary)
            if cell.windows.isEmpty {
                Spacer()
                Text("empty").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(cell.windows) { w in
                    Button { w.window.focus() } label: { WindowRow(info: w) }
                        .buttonStyle(.plain)
                        .help("Click to focus")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(cell.windows.isEmpty ? 0.03 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
    }
}

struct WindowRow: View {
    let info: WinInfo
    var body: some View {
        HStack(spacing: 8) {
            if let icon = info.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
            VStack(alignment: .leading, spacing: 1) {
                Text(info.appName).font(.callout.bold()).lineLimit(1)
                if !info.title.isEmpty {
                    Text(info.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

@MainActor
final class DashboardWindow {
    static let shared = DashboardWindow()
    private var window: NSWindow?
    private let model = DashboardModel()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 620),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "GridDock Overview"
            w.contentView = NSHostingView(rootView: DashboardView(model: model))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
