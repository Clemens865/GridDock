import AppKit
import QuartzCore

/// Click-through frames around Terminal windows that run a Claude session:
/// orange (pulsing) = needs you, blue = working, green = done.
@MainActor
final class StatusBorders {
    static let shared = StatusBorders()

    private var panels: [String: (NSPanel, BorderView)] = [:]   // by session id

    private static let enabledKey = "showSessionBorders"
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); update() }
    }

    func update() {
        var keep = Set<String>()
        let onGridDesktop = !Spaces.isAvailable || Spaces.current == Spaces.home
        if enabled && onGridDesktop {
            for s in SessionMonitor.shared.sessions {
                guard let w = SessionMonitor.shared.window(for: s), !w.isMinimized, !w.isFullscreen,
                      let f = w.frame, !ScreenGeometry.isParked(f),
                      Spaces.space(of: w) == Spaces.current else { continue }
                keep.insert(s.id)
                show(s, around: f)
            }
        }
        for (id, entry) in panels where !keep.contains(id) {
            entry.0.orderOut(nil)
            panels[id] = nil
        }
    }

    private func show(_ s: ClaudeSession, around axFrame: CGRect) {
        let frame = ScreenGeometry.flip(axFrame).insetBy(dx: -3, dy: -3)
        let entry: (NSPanel, BorderView)
        if let existing = panels[s.id] {
            entry = existing
        } else {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let v = BorderView(frame: CGRect(origin: .zero, size: frame.size))
            v.autoresizingMask = [.width, .height]
            p.contentView = v
            entry = (p, v)
            panels[s.id] = entry
        }
        if entry.0.frame != frame { entry.0.setFrame(frame, display: true) }
        entry.1.configure(state: s.state, project: s.project)
        entry.0.orderFrontRegardless()
    }
}

final class BorderView: NSView {
    private var state: ClaudeSession.State?
    private var project = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(state: ClaudeSession.State, project: String) {
        guard state != self.state || project != self.project else { return }
        self.state = state
        self.project = project
        needsDisplay = true
        layer?.removeAnimation(forKey: "pulse")
        if state == .waiting {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer?.add(pulse, forKey: "pulse")
        } else {
            layer?.opacity = 1
        }
    }

    private var color: NSColor {
        switch state {
        case .waiting: return .systemOrange
        case .working: return .systemBlue
        default: return .systemGreen
        }
    }

    private var label: String {
        switch state {
        case .waiting: return "Needs you"
        case .working: return "Working…"
        default: return "Done"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard state != nil else { return }
        let width: CGFloat = state == .waiting ? 4 : 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: 12, yRadius: 12)
        path.lineWidth = width
        color.withAlphaComponent(state == .done ? 0.7 : 1).setStroke()
        path.stroke()

        // Pill in the top-right corner (over the title bar's empty right side).
        let text = "\(label)  ·  \(project)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let pill = CGRect(x: bounds.maxX - size.width - 30, y: bounds.maxY - size.height - 12,
                          width: size.width + 16, height: size.height + 6)
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: attrs)
    }
}
