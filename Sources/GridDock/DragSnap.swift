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
    private var startFrame: CGRect?
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
        if suspended { return }
        guard let w = AX.window(at: ScreenGeometry.mouseAX) else { return }
        candidate = w
        startFrame = w.frame
    }

    private func mouseDragged(_ e: NSEvent) {
        guard let w = candidate, let start = startFrame else { return }
        if !isMoving {
            // A move changes origin but not size; a resize changes size. Only snap moves.
            guard let now = w.frame, now.size == start.size, now.origin != start.origin else { return }
            isMoving = true
        }
        let wantsSnap = snapOnEveryDrag || e.modifierFlags.contains(.option)
        if !wantsSnap {
            if active { OverlayController.shared.hide(); active = false }
            return
        }
        if !active { OverlayController.shared.showDrag(); active = true }
        let p = ScreenGeometry.mouseAX
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
        candidate = nil; startFrame = nil; isMoving = false
        active = false; currentCell = nil; currentScreen = nil
    }
}
