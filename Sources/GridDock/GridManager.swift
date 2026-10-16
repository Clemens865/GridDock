import AppKit

extension Notification.Name {
    static let gridLayoutChanged = Notification.Name("GridDock.layoutChanged")
}

/// Holds the active grid and places windows into its cells.
final class GridManager {
    static let shared = GridManager()

    private let layoutKey = "activeLayoutName"

    var layout: GridLayout {
        didSet {
            UserDefaults.standard.set(layout.name, forKey: layoutKey)
            NotificationCenter.default.post(name: .gridLayoutChanged, object: nil)
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: layoutKey)
        layout = saved.flatMap(GridLayout.resolve) ?? GridLayout.presets[2]
    }

    func cycleLayout() {
        let all = GridLayout.presets
        let i = all.firstIndex(of: layout) ?? 0
        layout = all[(i + 1) % all.count]
    }

    /// Screen a window is on (by its center), falling back to the mouse's screen.
    func screen(for window: AXWindow?) -> NSScreen {
        if let f = window?.frame { return ScreenGeometry.screen(containingAX: CGPoint(x: f.midX, y: f.midY)) }
        return ScreenGeometry.screen(containingAX: ScreenGeometry.mouseAX)
    }

    func frame(ofCell index: Int, on screen: NSScreen) -> CGRect? {
        guard layout.cells.indices.contains(index) else { return nil }
        return ScreenGeometry.frame(for: layout.cells[index], on: screen)
    }

    /// Frame spanning several cells (their bounding box).
    func frame(spanning indices: [Int], on screen: NSScreen) -> CGRect? {
        let cells = indices.filter { layout.cells.indices.contains($0) }.map { layout.cells[$0] }
        guard let first = cells.first else { return nil }
        let union = cells.dropFirst().reduce(first) { $0.union($1) }
        return ScreenGeometry.frame(for: union, on: screen)
    }

    func place(_ window: AXWindow, inCells indices: [Int], on screen: NSScreen? = nil) {
        let scr = screen ?? self.screen(for: window)
        guard let f = frame(spanning: indices, on: scr) else { return }
        if window.isFullscreen {
            // A fullscreen window sits on its own Space: leave fullscreen first, then place it.
            window.exitFullscreen { self.place(window, inCells: indices, on: scr) }
            return
        }
        if Spaces.needsPull(window) {
            // The window lives on another desktop: carry it over to the grid desktop first.
            Task { @MainActor in
                if !(await SpacePull.pullToHome(window)) {
                    PageHUD.shared.flash(message: "Couldn't bring the window to Desktop \(Spaces.homeNumber) — is “Move left/right a space” on in Keyboard Shortcuts?")
                }
                self.setFrame(window, f)
                window.focus()
            }
            return
        }
        setFrame(window, f)
    }

    private func setFrame(_ window: AXWindow, _ f: CGRect) {
        window.setFrame(f)
        // Some apps (Electron, Java) apply the first move only partially — retry once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let now = window.frame, abs(now.minX - f.minX) > 2 || abs(now.minY - f.minY) > 2 {
                window.setFrame(f)
            }
        }
    }

    func placeFocused(inCell index: Int) {
        guard let w = AX.focusedWindow() else { NSSound.beep(); return }
        place(w, inCells: [index])
        GapFill.shared.fill(dropped: w, into: [index])
    }

    /// Cell index whose rect contains the AX point on the given screen.
    func cellIndex(atAX p: CGPoint, on screen: NSScreen) -> Int? {
        layout.cells.indices.first { ScreenGeometry.frame(for: layout.cells[$0], on: screen).insetBy(dx: -ScreenGeometry.gap, dy: -ScreenGeometry.gap).contains(p) }
    }

    /// Which windows currently occupy each cell of the active layout (matched by window center), per screen.
    func occupancy(on screen: NSScreen) -> [Int: [AXWindow]] {
        var result: [Int: [AXWindow]] = [:]
        for w in AX.visibleWindows() {
            guard let f = w.frame else { continue }
            let center = CGPoint(x: f.midX, y: f.midY)
            guard ScreenGeometry.flip(screen.frame).contains(center),
                  let i = cellIndex(atAX: center, on: screen) else { continue }
            result[i, default: []].append(w)
        }
        return result
    }
}
