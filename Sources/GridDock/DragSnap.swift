import AppKit

/// Watches window drags system-wide. While a window is dragged (with ⌥ held, unless
/// "snap on every drag" is on), the grid appears; releasing over a cell places the window there.
final class DragSnap {
    static let shared = DragSnap()

    private let alwaysKey = "snapOnEveryDrag"
    var snapOnEveryDrag: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysKey) }
    }

    /// Set while GridDock itself drags a window (desktop pull), so that drag isn't snapped.
    var suspended = false

    private var monitors: [Any] = []
    private var candidate: AXWindow?
    private var isMoving = false
    private var active = false
    private var currentCell: Int?
    private var currentScreen: NSScreen?

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseDown() }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in self?.mouseDragged(e) }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() }
        monitors = [down, drag, up].compactMap { $0 }
    }

    private func mouseDown() {
        reset()
    }

    private func mouseDragged(_ e: NSEvent) {
        if suspended { return }
        let wantsSnap = snapOnEveryDrag || e.modifierFlags.contains(.option)
        if !wantsSnap {
            if active { OverlayController.shared.hide(); active = false }
            return
        }
        let p = ScreenGeometry.mouseAX
        if !isMoving {
            // Look up the window only once a snap-drag is actually happening (not on every click).
            // A title-bar drag has the cursor near the window's top edge; resizes and in-window drags don't.
            guard let w = AX.window(at: p), let f = w.frame, p.y - f.minY < 44 else { return }
            candidate = w
            isMoving = true
        }
        if !active { OverlayController.shared.showDrag(); active = true }
        let screen = ScreenGeometry.screen(containingAX: p)
        let cell = GridManager.shared.cellIndex(atAX: p, on: screen)
        if cell != currentCell || screen != currentScreen {
            currentCell = cell; currentScreen = screen
            OverlayController.shared.updateDrag(highlight: cell, on: screen)
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard active else { return }
        OverlayController.shared.hide()
        if let w = candidate, let cell = currentCell, let screen = currentScreen {
            // Let the app finish its own drag handling first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                GridManager.shared.place(w, inCells: [cell], on: screen)
            }
        }
    }

    private func reset() {
        candidate = nil; isMoving = false
        active = false; currentCell = nil; currentScreen = nil
    }
}
