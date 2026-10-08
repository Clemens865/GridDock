import AppKit

/// Draws the active grid's cells over one screen.
final class OverlayView: NSView {
    var screenRef: NSScreen!
    var highlighted: Set<Int> = [] { didSet { needsDisplay = true } }
    var showHints = true
    var onClickCell: ((Int, Bool) -> Void)?   // (cell, shiftHeld)

    override var isFlipped: Bool { true }

    /// Cell rect in this view's coordinates.
    func rect(forCell i: Int) -> CGRect? {
        guard let f = GridManager.shared.frame(ofCell: i, on: screenRef) else { return nil }
        let screenAX = ScreenGeometry.flip(screenRef.frame)
        return f.offsetBy(dx: -screenAX.minX, dy: -screenAX.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        let layout = GridManager.shared.layout
        for i in layout.cells.indices {
            guard let r = rect(forCell: i) else { continue }
            let on = highlighted.contains(i)
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
            (on ? NSColor.controlAccentColor.withAlphaComponent(0.45) : NSColor.white.withAlphaComponent(0.10)).setFill()
            path.fill()
            (on ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.6)).setStroke()
            path.lineWidth = on ? 3 : 1.5
            path.stroke()
            if showHints && i < 9 {
                let label = "\(i + 1)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: min(72, r.height / 3), weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                ]
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
            }
        }
        if showHints {
            let dest = OverlayController.shared.pullHint.map { "\($0)   ·   " } ?? ""
            let hint = "\(dest)\(layout.name)   ·   1–9 / click: place   ·   ⇧click: span   ·   Tab: next layout   ·   Esc: cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attrs)
            let box = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 64, width: size.width + 28, height: size.height + 14)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            hint.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in GridManager.shared.layout.cells.indices where rect(forCell: i)?.contains(p) == true {
            onClickCell?(i, event.modifierFlags.contains(.shift))
            return
        }
    }
}

final class OverlayWindow: NSWindow {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

/// One overlay window per screen.
final class OverlayController {
    static let shared = OverlayController()

    private var windows: [(OverlayWindow, OverlayView)] = []
    private var target: AXWindow?
    private var spanSelection: [Int] = []
    private(set) var isPicking = false
    /// Shown in the picker when the target window will be carried to the grid desktop.
    private(set) var pullHint: String?

    private init() {
        NotificationCenter.default.addObserver(forName: .gridLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            self?.windows.forEach { $0.1.needsDisplay = true }
        }
    }

    private func build(interactive: Bool) {
        hide()
        for screen in NSScreen.screens {
            let win = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .screenSaver
            win.hasShadow = false
            win.ignoresMouseEvents = !interactive
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.screenRef = screen
            view.showHints = interactive
            win.contentView = view
            win.setFrame(screen.frame, display: false)
            windows.append((win, view))
        }
    }

    // MARK: Hotkey picker mode

    func showPicker() {
        guard let w = AX.focusedWindow() else { NSSound.beep(); return }
        target = w
        pullHint = (w.isFullscreen || Spaces.needsPull(w)) ? "→ goes to your grid on Desktop \(Spaces.homeNumber)" : nil
        spanSelection = []
        isPicking = true
        build(interactive: true)
        for (win, view) in windows {
            view.onClickCell = { [weak self] i, shift in self?.pick(i, on: view.screenRef, span: shift) }
            win.onKey = { [weak self] e in self?.handleKey(e, screen: view.screenRef) }
            win.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let home = GridManager.shared.screen(for: w)
        windows.first { $0.1.screenRef == home }?.0.makeKey()
    }

    private func handleKey(_ e: NSEvent, screen: NSScreen) {
        switch e.keyCode {
        case 53: cancel()                                   // Esc
        case 48: GridManager.shared.cycleLayout()           // Tab
        default:
            if let c = e.charactersIgnoringModifiers, let n = Int(c), n >= 1 {
                pick(n - 1, on: screen, span: e.modifierFlags.contains(.shift))
            }
        }
    }

    private func pick(_ i: Int, on screen: NSScreen, span: Bool) {
        if span {
            if !spanSelection.contains(i) { spanSelection.append(i) }
            windows.forEach { $0.1.highlighted = Set(spanSelection) }
            if spanSelection.count < 2 { return }
        }
        let cells = span ? spanSelection : [i]
        guard let t = target else { return cancel() }
        hide()
        GridManager.shared.place(t, inCells: cells, on: screen)
        t.focus()
    }

    func cancel() {
        hide()
        target?.focus()
    }

    // MARK: Drag mode (non-interactive, follows the cursor)

    func showDrag() {
        if windows.isEmpty || isPicking { build(interactive: false); windows.forEach { $0.0.orderFrontRegardless() } }
    }

    func updateDrag(highlight cell: Int?, on screen: NSScreen) {
        for (_, view) in windows { view.highlighted = (view.screenRef == screen && cell != nil) ? [cell!] : [] }
    }

    func hide() {
        windows.forEach { $0.0.orderOut(nil) }
        windows = []
        isPicking = false
    }
}
