import AppKit
import SwiftUI

/// ⌃⌥H — an overlay listing every GridDock shortcut. Esc, a click outside or ⌃⌥H again closes it.
final class ShortcutSheet: NSObject, NSWindowDelegate {
    static let shared = ShortcutSheet()

    static let groups: [(String, [(String, String)])] = [
        ("Grid", [
            ("⌃⌥G", "Show grid, then 1–9 or click a cell (⇧-click two cells to span, Tab = next grid)"),
            ("⌃⌥1 … 9", "Put the focused window into cell 1–9"),
            ("⌃⌥L", "Next grid layout"),
            ("⌃⌥T", "Tile all windows (grid sized to however many there are)"),
            ("⌃⌥A", "Arrange everything: all apps from every desktop & fullscreen onto pages"),
            ("⌥ + drag", "Drag a window while holding ⌥ and drop it on a cell"),
        ]),
        ("Pages", [
            ("⌃⌥← / →", "Previous / next page"),
            ("⌥ + two-finger swipe", "Previous / next page"),
            ("⌃⌥⇧← / →", "Send focused window to the previous / next page"),
            ("⌃⌥N", "New empty page"),
        ]),
        ("Windows", [
            ("⌃⌥D", "Overview of all cells, pages and windows"),
            ("from another desktop", "Any placement carries the window to the grid desktop (set in the menu)"),
            ("⌃⌥H", "This list"),
        ]),
    ]

    private var panel: NSPanel?

    func toggle() {
        if let p = panel, p.isVisible { close(); return }
        let host = NSHostingView(rootView: ShortcutList(onClose: { [weak self] in self?.close() }))
        let size = host.fittingSize
        let p = KeyPanel(contentRect: CGRect(origin: .zero, size: size),
                         styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.delegate = self
        p.onEscape = { [weak self] in self?.close() }
        let vf = ScreenGeometry.screen(containingAX: ScreenGeometry.mouseAX).visibleFrame
        p.setFrameOrigin(CGPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

private struct ShortcutList: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "square.grid.3x2").font(.title2)
                Text("GridDock shortcuts").font(.title2.bold())
                Spacer()
                Text("Esc to close").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ShortcutSheet.groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.0.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(group.1, id: \.0) { key, text in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(key)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                                .frame(width: 190, alignment: .leading)
                            Text(text)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 680)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 16)))
        .onTapGesture(perform: onClose)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
