import AppKit

/// Watches window drags system-wide. While a window is dragged (with ⌥ held, unless
/// "snap on every drag" is on), the grid appears; releasing over a cell places the window there.
/// When the windows form a tiling, `Tiler` takes over: it previews and applies the layout a move
/// or a resize produces (screen edge, gap, split, swap, push through).
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

    enum Gesture: Equatable { case undecided, windowMove, resize, other }

    /// How far the cursor travels before we look at the window at all.
    static let startTravel: CGFloat = 4
    /// How far the window must move to count as being dragged.
    static let moveThreshold: CGFloat = 6
    /// Cursor travel after which a window that still hasn't moved is not being dragged.
    static let giveUpTravel: CGFloat = 50

    /// Decides what a drag gesture is from the window's frame at the start and now.
    static func classify(start: CGRect, now: CGRect, mouseTravel: CGFloat) -> Gesture {
        if abs(now.width - start.width) > 2 || abs(now.height - start.height) > 2 { return .resize }
        if hypot(now.minX - start.minX, now.minY - start.minY) >= moveThreshold { return .windowMove }
        return mouseTravel > giveUpTravel ? .other : .undecided
    }

    private var monitors: [Any] = []
    private var downPoint: CGPoint?
    private var candidate: AXWindow?
    private var startFrame: CGRect?
    /// The window under the cursor at mouse-down, and its window-server frame then.
    private var downWindow: CGWindowID?
    private var downFrame: CGRect?
    private var candidateID: CGWindowID?
    private var currentFrame: CGRect? { candidateID.flatMap(AX.serverFrame) ?? candidate?.frame }
    private var gesture: Gesture = .undecided
    private var active = false
    private var currentCell: Int?
    private var currentScreen: NSScreen?
    private var lastResizeCheck: TimeInterval = 0

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in self?.mouseDown(e) }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in self?.mouseDragged(e) }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() }
        monitors = [down, drag, up].compactMap { $0 }
    }

    private func mouseDown(_ e: NSEvent) {
        reset()
        downPoint = ScreenGeometry.mouseAX
        // The event says which window it hit; reading its frame now gives a true starting point.
        let n = e.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0
        if n > 0 { downWindow = CGWindowID(n); downFrame = AX.serverFrame(CGWindowID(n)) }
    }

    private func mouseDragged(_ e: NSEvent) {
        if suspended || gesture == .other { return }
        let p = ScreenGeometry.mouseAX
        guard let down = downPoint else { return }
        let tiler = Tiler.shared

        if gesture == .undecided {
            let travel = hypot(p.x - down.x, p.y - down.y)
            if candidate == nil {
                guard travel >= Self.startTravel else { return }
                // Look up the window only once the cursor really travels (not on every click).
                guard let w = downWindow.flatMap(AX.window(withID:)) ?? AX.window(at: down),
                      let id = Spaces.windowID(w), downWindow == nil || downWindow == id,
                      let f = (downWindow == id ? downFrame : nil) ?? AX.serverFrame(id) ?? w.frame else {
                    gesture = .other
                    Log.write("drag: no tileable window under the cursor (window \(downWindow.map(String.init) ?? "?"))")
                    return
                }
                candidate = w; candidateID = id; startFrame = f
            }
            // The window server's frame: the AX frame often lags behind until the mouse is released.
            guard let w = candidate, let start = startFrame,
                  let now = candidateID.flatMap(AX.serverFrame) ?? w.frame else { gesture = .other; return }
            gesture = Self.classify(start: start, now: now, mouseTravel: travel)
            if gesture != .undecided { Log.write("drag: \(gesture) \(w.appName)") }
            if gesture == .resize { tiler.begin(.resize, window: w, startFrame: start) }
            guard gesture == .windowMove else { return }
        }

        if gesture == .resize {
            // Reading the frame asks the app, so don't do it on every single event.
            let t = e.timestamp
            guard tiler.isReady, t - lastResizeCheck > 1.0 / 30, let f = currentFrame else { return }
            lastResizeCheck = t
            tiler.resize(to: f)
            return
        }

        let wantsSnap = snapOnEveryDrag || e.modifierFlags.contains(.option)
        if !wantsSnap {
            if active { OverlayController.shared.hide(); active = false; tiler.cancel() }
            return
        }

        if !active {
            OverlayController.shared.showDrag(); active = true
            if let w = candidate, let start = startFrame { tiler.begin(.move, window: w, startFrame: start) }
        }
        if tiler.isReady { tiler.move(to: p); return }
        let screen = ScreenGeometry.screen(containingAX: p)
        let cell = GridManager.shared.cellIndex(atAX: p, on: screen)
        if cell != currentCell || screen != currentScreen {
            currentCell = cell; currentScreen = screen
            OverlayController.shared.updateDrag(highlight: cell, on: screen)
        }
    }

    private func mouseUp() {
        defer { reset() }
        let tiler = Tiler.shared
        if gesture == .resize {
            guard tiler.isReady else { tiler.cancel(); OverlayController.shared.hide(); return }
            OverlayController.shared.hide()
            if let f = currentFrame { tiler.resize(to: f) }
            tiler.finish()
            return
        }
        guard active else { tiler.cancel(); return }
        if tiler.isReady {
            tiler.move(to: ScreenGeometry.mouseAX)
            OverlayController.shared.hide()
            tiler.finish()
            return
        }
        tiler.cancel()
        OverlayController.shared.hide()
        if let w = candidate, let cell = currentCell, let screen = currentScreen {
            // Let the app finish its own drag handling first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                GridManager.shared.place(w, inCells: [cell], on: screen)
                GapFill.shared.fill(dropped: w, into: [cell])
            }
        }
    }

    private func reset() {
        downPoint = nil; candidate = nil; candidateID = nil; startFrame = nil; gesture = .undecided
        downWindow = nil; downFrame = nil
        active = false; currentCell = nil; currentScreen = nil
    }
}
