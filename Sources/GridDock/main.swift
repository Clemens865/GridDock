import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x2", accessibilityDescription: "GridDock")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Log.trimIfLarge()
        // Never wait more than half a second on an app that doesn't answer (default is 6 s).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        Hotkeys.shared.registerDefaults { DashboardWindow.shared.show() }

        // Menu-bar badge: how many Claude sessions are waiting for you.
        NotificationCenter.default.addObserver(forName: .claudeSessionsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                let n = SessionMonitor.shared.waitingCount
                self?.statusItem.length = n > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
                self?.statusItem.button?.title = n > 0 ? " \(n)" : ""
                self?.statusItem.button?.contentTintColor = n > 0 ? .systemOrange : nil
            }
        }

        if AX.isTrusted {
            startMonitors()
        } else {
            AX.requestTrust()
            // Global mouse monitoring only works once Accessibility is granted — wait for it.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard AX.isTrusted else { return }
                    self?.trustTimer?.invalidate()
                    self?.startMonitors()
                }
            }
        }
    }

    private func startMonitors() {
        DragSnap.shared.start()
        PageManager.shared.startSwipeMonitor()
        PageManager.shared.restore()     // pages from last run; stray parked windows come back
        PageManager.shared.startFollowFocus()
        SessionMonitor.shared.start()
        if AutoArrange.shared.enabled { AutoArrange.shared.startWatching() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PageManager.shared.save()
        PageManager.shared.unparkAll(resetPages: false)   // never leave windows off-screen; pages are restored next launch
    }

    // Rebuilt every time the menu opens, so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if AutoArrange.stageManagerOn {
            menu.addItem(item("⚠︎ Stage Manager is on — it hides windows from the grid…") { _ = AutoArrange.checkStageManager() })
            menu.addItem(.separator())
        }
        if !AX.isTrusted {
            menu.addItem(item("⚠︎ Grant Accessibility access…") { AX.requestTrust() })
            menu.addItem(.separator())
        }

        menu.addItem(item("Show Grid  (⌃⌥G)") { OverlayController.shared.showPicker() })
        menu.addItem(item("Overview  (⌃⌥D)") { DashboardWindow.shared.show() })
        menu.addItem(item("Keyboard shortcuts  (⌃⌥H)") { ShortcutSheet.shared.toggle() })
        menu.addItem(.separator())

        let grids = NSMenu()
        for preset in GridLayout.presets {
            let mi = item(preset.name) { GridManager.shared.layout = preset }
            mi.state = preset == GridManager.shared.layout ? .on : .off
            grids.addItem(mi)
        }
        let current = GridManager.shared.layout
        if !GridLayout.presets.contains(current) {
            let mi = item(current.name) {}
            mi.state = .on
            grids.addItem(mi)
        }
        grids.addItem(.separator())
        grids.addItem(item("Custom grid…") { [weak self] in self?.promptCustomGrid() })
        menu.addItem(submenu("Grid: \(current.name)", grids))
        menu.addItem(item("Tile all windows  (⌃⌥T)") { PageManager.shared.tileAll() })
        let auto = AutoArrange.shared
        menu.addItem(item("Arrange everything  (⌃⌥A)") { auto.arrangeEverything() })
        menu.addItem(item("Arrange by project  (⌃⌥P)") { auto.arrangeEverything(byProject: true) })
        let mode = item("Auto-arrange mode") {
            auto.enabled.toggle()
            if auto.enabled { auto.arrangeEverything() }
        }
        mode.state = auto.enabled ? .on : .off
        menu.addItem(mode)
        let perPage = NSMenu()
        for n in [4, 6, 8, 9, 12] {
            let mi = item("\(n) windows") { auto.perPage = n }
            mi.state = n == auto.perPage ? .on : .off
            perPage.addItem(mi)
        }
        menu.addItem(submenu("Windows per page: \(auto.perPage)", perPage))

        let pm = PageManager.shared
        let pagesMenu = NSMenu()
        for i in 0..<pm.pageCount {
            let mi = item("\(pm.title(of: i))  (\(pm.windowCount(of: i)) windows)") { pm.go(to: i) }
            mi.state = i == pm.current ? .on : .off
            pagesMenu.addItem(mi)
        }
        pagesMenu.addItem(.separator())
        pagesMenu.addItem(item("New page  (⌃⌥N)") { pm.newPage() })
        pagesMenu.addItem(item("Previous / next:  ⌃⌥← →  or  ⌥ + two-finger swipe") {})
        pagesMenu.addItem(item("Send window to page:  ⌃⌥⇧← →") {})
        pagesMenu.addItem(.separator())
        pagesMenu.addItem(item("Bring all parked windows back") { pm.unparkAll() })
        menu.addItem(submenu("Pages: \(pm.title(of: pm.current)) (\(pm.current + 1)/\(pm.pageCount))", pagesMenu))

        let projects = NSMenu()
        let store = ProjectLayoutStore.shared
        store.reload()
        for p in store.layouts {
            projects.addItem(item("Restore “\(p.name)”") { Task { await store.restore(p) } })
        }
        if !store.layouts.isEmpty { projects.addItem(.separator()) }
        projects.addItem(item("Save current arrangement…") { [weak self] in self?.promptSave() })
        if !store.layouts.isEmpty {
            let del = NSMenu()
            for p in store.layouts { del.addItem(item(p.name) { store.delete(named: p.name) }) }
            projects.addItem(submenu("Delete", del))
        }
        projects.addItem(item("Edit layouts file…") { NSWorkspace.shared.open(store.fileURL) })
        menu.addItem(submenu("Projects", projects))
        let claude = NSMenu()
        let sm = SessionMonitor.shared
        if !ClaudeHooks.isInstalled {
            claude.addItem(item("Install Claude Code hooks…") { ClaudeHooks.promptInstall() })
        } else if sm.sessions.isEmpty {
            claude.addItem(item("No active sessions yet (they appear from their next prompt)") {})
        }
        for s in sm.sessions {
            let mark = s.state == .waiting ? "🟠" : s.state == .working ? "🔵" : "🟢"
            let label = s.state == .waiting ? "needs you" : s.state == .working ? "working" : "done"
            claude.addItem(item("\(mark)  \(s.project) — \(label)") {
                guard let w = sm.window(for: s) else { return }
                if let i = PageManager.shared.pageIndex(of: w), i != PageManager.shared.current {
                    PageManager.shared.go(to: i, focus: w)
                } else { w.focus() }
            })
        }
        claude.addItem(.separator())
        claude.addItem(item("Jump to next waiting  (⌃⌥W)") { sm.jumpToWaiting() })
        let frames = item("Show coloured frames") { StatusBorders.shared.enabled.toggle() }
        frames.state = StatusBorders.shared.enabled ? .on : .off
        claude.addItem(frames)
        let waitingN = sm.waitingCount
        menu.addItem(submenu(waitingN > 0 ? "Claude sessions — \(waitingN) need you" : "Claude sessions (\(sm.sessions.count))", claude))

        let desk = NSMenu()
        let desktops = Spaces.desktops()
        if Spaces.isAvailable && !desktops.isEmpty {
            for n in 1...desktops.count {
                let mi = item("Desktop \(n)") { Spaces.homeNumber = n }
                mi.state = n == Spaces.homeNumber ? .on : .off
                desk.addItem(mi)
            }
            desk.addItem(.separator())
        }
        let pull = item("Bring windows from other desktops & fullscreen") { Spaces.pullEnabled.toggle() }
        pull.state = Spaces.pullEnabled ? .on : .off
        desk.addItem(pull)
        if SpacePull.directShortcut(toDesktop: Spaces.homeNumber) == nil {
            desk.addItem(item("Tip: turn on “Switch to Desktop \(Spaces.homeNumber)” for faster moves…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
            })
        }
        menu.addItem(submenu("Grid lives on: Desktop \(Spaces.homeNumber)", desk))
        menu.addItem(.separator())

        let snap = item("Show grid when dragging a window (otherwise hold ⌥)") { DragSnap.shared.snapOnEveryDrag.toggle() }
        snap.state = DragSnap.shared.snapOnEveryDrag ? .on : .off
        menu.addItem(snap)

        let login = item("Launch at login") {
            let svc = SMAppService.mainApp
            if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit GridDock") { NSApp.terminate(nil) })
    }

    private func promptCustomGrid() {
        let alert = NSAlert()
        alert.messageText = "Custom grid"
        alert.informativeText = "Columns × rows, e.g. 5x3 (up to 12 × 12)."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "5x3"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let layout = GridLayout.resolve(field.stringValue) else { return }
        GridManager.shared.layout = layout
    }

    private func promptSave() {
        let alert = NSAlert()
        alert.messageText = "Save arrangement"
        alert.informativeText = "Saves which app sits in which cell (on the screen under the mouse). Terminal windows remember their folder."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Project name, e.g. Atelier"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        ProjectLayoutStore.shared.saveCurrent(named: name)
    }

    // MARK: Menu helpers

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction(action)
        mi.target = target
        mi.representedObject = target   // keeps the target alive
        return mi
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = sub
        return mi
    }
}

final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
