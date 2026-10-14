import AppKit

/// Watches window drags system-wide. While a window is dragged (with ⌥ held, unless
/// "snap on every drag" is on), the grid appears; releasing over a cell places the window there.
///
/// The grid only appears once the window under the cursor has actually moved. Clicks and small
/// drags on toolbars, menus, tabs or text never move the window, so they never bring up the grid.
final class DragSnap {
    static let shared = DragSnap()

    private let alwaysKey = "snapOnEveryDrag"
    var snapOnEveryDrag: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysKey) }
    }

    init() {
        UserDefaults.standard.register(defaults: [alwaysKey: true])
    }

    /// Set while GridDock itself drags a window (desktop pull), so that drag isn't snapped.
    var suspended = false

    enum Gesture: Equatable { case undecided, windowMove, other }

    /// How far the cursor travels before we look at the window at all.
    static let startTravel: CGFloat = 4
    /// How far the window must move to count as being dragged.
    static let moveThreshold: CGFloat = 6
    /// Cursor travel after which a window that still hasn't moved is not being dragged.
    static let giveUpTravel: CGFloat = 50

    /// Decides what a drag gesture is from the window's frame at the start and now.
    static func classify(start: CGRect, now: CGRect, mouseTravel: CGFloat) -> Gesture {
        if abs(now.width - start.width) > 2 || abs(now.height - start.height) > 2 { return .other }  // resizing
        if hypot(now.minX - start.minX, now.minY - start.minY) >= moveThreshold { return .windowMove }
        return mouseTravel > giveUpTravel ? .other : .undecided
    }

    private var monitors: [Any] = []
    private var downPoint: CGPoint?
    private var candidate: AXWindow?
    private var startFrame: CGRect?
    private var gesture: Gesture = .undecided
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
        downPoint = ScreenGeometry.mouseAX
    }

    private func mouseDragged(_ e: NSEvent) {
        if suspended || gesture == .other { return }
        let wantsSnap = snapOnEveryDrag || e.modifierFlags.contains(.option)
        if !wantsSnap {
            if active { OverlayController.shared.hide(); active = false }
            return
        }
        let p = ScreenGeometry.mouseAX
        guard let down = downPoint else { return }

        if gesture == .undecided {
            let travel = hypot(p.x - down.x, p.y - down.y)
            if candidate == nil {
                guard travel >= Self.startTravel else { return }
                // Look up the window only once the cursor really travels (not on every click).
                guard let w = AX.window(at: down), let f = w.frame else { gesture = .other; return }
                candidate = w; startFrame = f
            }
            guard let w = candidate, let start = startFrame, let now = w.frame else { gesture = .other; return }
            gesture = Self.classify(start: start, now: now, mouseTravel: travel)
            guard gesture == .windowMove else { return }
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
        downPoint = nil; candidate = nil; startFrame = nil; gesture = .undecided
        active = false; currentCell = nil; currentScreen = nil
    }
}
