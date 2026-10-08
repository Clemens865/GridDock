import AppKit

/// A saved arrangement: which app/window goes into which cell(s) of a grid.
struct ProjectLayout: Codable {
    struct Item: Codable {
        var cells: [Int]
        var bundleID: String
        var appName: String
        /// Optional substring the window title must contain (e.g. a project name in a browser or editor).
        var titleContains: String?
        /// Terminal.app only: open a new window and `cd` into this folder.
        var terminalDirectory: String?
        /// Terminal.app only: command to run after `cd` (e.g. "claude").
        var terminalCommand: String?
    }
    var name: String
    var gridName: String
    var items: [Item]
}

final class ProjectLayoutStore {
    static let shared = ProjectLayoutStore()
    static let terminalBundleID = "com.apple.Terminal"

    private(set) var layouts: [ProjectLayout] = []

    var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GridDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layouts.json")
    }

    private init() { reload() }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL) else { layouts = []; return }
        layouts = (try? JSONDecoder().decode([ProjectLayout].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(layouts).write(to: fileURL)
    }

    func delete(named name: String) {
        layouts.removeAll { $0.name == name }
        persist()
    }

    // MARK: Save

    /// Captures what is currently in each cell on the screen under the mouse.
    func saveCurrent(named name: String) {
        let gm = GridManager.shared
        let screen = ScreenGeometry.screen(containingAX: ScreenGeometry.mouseAX)
        let occupancy = gm.occupancy(on: screen)
        let terminalDirs = TerminalBridge.directoriesByWindowTitle()

        var items: [ProjectLayout.Item] = []
        for cell in occupancy.keys.sorted() {
            // Front-most window wins if several share a cell.
            guard let w = occupancy[cell]?.first, let bid = w.bundleID else { continue }
            var item = ProjectLayout.Item(cells: [cell], bundleID: bid, appName: w.appName)
            if bid == Self.terminalBundleID {
                item.terminalDirectory = terminalDirs.first { w.title.contains($0.key) || $0.key.contains(w.title) }?.value
            } else if !w.title.isEmpty, AX.windows(of: w.app!).count > 1 {
                item.titleContains = w.title   // only needed to tell several windows of one app apart
            }
            items.append(item)
        }
        layouts.removeAll { $0.name == name }
        layouts.append(ProjectLayout(name: name, gridName: gm.layout.name, items: items))
        persist()
    }

    // MARK: Restore

    @MainActor
    func restore(_ project: ProjectLayout) async {
        let gm = GridManager.shared
        if let grid = GridLayout.resolve(project.gridName) { gm.layout = grid }
        let screen = ScreenGeometry.screen(containingAX: ScreenGeometry.mouseAX)
        var used: [AXWindow] = []

        for item in project.items {
            var window: AXWindow?
            if item.bundleID == Self.terminalBundleID, let dir = item.terminalDirectory {
                window = await TerminalBridge.openWindow(in: dir, command: item.terminalCommand)
            } else {
                window = await findOrLaunch(item, excluding: used)
            }
            guard let w = window else { continue }
            used.append(w)
            gm.place(w, inCells: item.cells, on: screen)
        }
    }

    @MainActor
    private func findOrLaunch(_ item: ProjectLayout.Item, excluding used: [AXWindow]) async -> AXWindow? {
        func candidate() -> AXWindow? {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID)
            let wins = apps.flatMap { AX.windows(of: $0) }.filter { w in !used.contains { $0.isSame(w) } }
            if let t = item.titleContains, let match = wins.first(where: { $0.title.contains(t) }) { return match }
            return wins.first
        }
        if let w = candidate() { return w }

        // Launch (or re-open, which asks a running app without windows to create one).
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<30 {   // wait up to ~6 s for a window
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let w = candidate() { return w }
        }
        return nil
    }
}
