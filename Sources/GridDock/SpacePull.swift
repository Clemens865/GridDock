import AppKit
import ApplicationServices

/// Carries a window from another desktop to the grid desktop: presses on its title bar,
/// switches desktops with ⌃← / ⌃→ while "holding" it, then lets go — exactly what you'd do
/// by hand. Needs Mission Control's "Move left/right a space" shortcuts (on by default).
enum SpacePull {
    private static let src = CGEventSource(stateID: .hidSystemState)

    private static func mouse(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func ctrlArrow(right: Bool) {
        let key: CGKeyCode = right ? 124 : 123
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            // Real arrow-key presses carry the fn + numeric-pad flags; without them macOS ignores ⌃← / ⌃→.
            e?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            e?.post(tap: .cghidEventTap)
        }
    }

    /// The user's "Switch to Desktop N" shortcut (Keyboard Shortcuts → Mission Control), if enabled:
    /// (key code, modifier flags). It jumps straight there instead of walking past fullscreen apps.
    static func directShortcut(toDesktop n: Int) -> (CGKeyCode, CGEventFlags)? {
        guard (1...16).contains(n),
              let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all[String(117 + n)] as? [String: Any],
              (entry["enabled"] as? Bool ?? (entry["enabled"] as? Int == 1)),
              let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3
        else { return nil }
        return (CGKeyCode(params[1]), CGEventFlags(rawValue: UInt64(params[2])))
    }

    private static func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func elementFrame(_ el: AXUIElement) -> CGRect? {
        AXWindow(element: el, pid: 0).frame
    }

    /// A point on the title bar that drags the window but hits no button, tab or text:
    /// the gap between the close and minimise buttons. Falls back to the title bar's middle.
    private static func grabPoint(_ w: AXWindow) -> CGPoint? {
        if let close: AXUIElement = AX.attr(w.element, kAXCloseButtonAttribute),
           let mini: AXUIElement = AX.attr(w.element, kAXMinimizeButtonAttribute),
           let c = elementFrame(close), let m = elementFrame(mini), m.minX > c.maxX {
            return CGPoint(x: (c.maxX + m.minX) / 2, y: c.midY)
        }
        guard let f = w.frame else { return nil }
        return CGPoint(x: f.midX, y: f.minY + 8)
    }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// Waits until the active Space is `id` (or gives up after `timeout`).
    private static func waitFor(space id: UInt64, timeout: Double) async -> Bool {
        var t = 0.0
        while t < timeout {
            if Spaces.current == id { return true }
            await sleep(0.05); t += 0.05
        }
        return Spaces.current == id
    }

    /// Switches to a Space without carrying anything: direct "Switch to Desktop N" jump if
    /// available, otherwise ⌃← / ⌃→ steps (which also walk through fullscreen apps).
    @MainActor
    static func go(to space: UInt64) async -> Bool {
        guard let now = Spaces.current else { return false }
        if now == space { return true }
        if let n = Spaces.desktopNumber(of: space), let (key, flags) = directShortcut(toDesktop: n) {
            press(key, flags)
            return await waitFor(space: space, timeout: 2)
        }
        let order = Spaces.ordered().map(\.id)
        guard let from = order.firstIndex(of: now), let to = order.firstIndex(of: space) else { return false }
        let right = to > from
        for i in 1...abs(to - from) {
            ctrlArrow(right: right)
            if !(await waitFor(space: order[from + (right ? i : -i)], timeout: 1.5)) {
                Log.write("go: step \(i) towards space \(space) didn't happen (now \(Spaces.current ?? 0))")
                return false
            }
            await sleep(0.1)
        }
        await sleep(0.2)
        return true
    }

    @MainActor
    static func pullToHome(_ w: AXWindow) async -> Bool {
        guard let home = Spaces.home, let winSpace = Spaces.space(of: w) else { Log.write("pull: no space info for \(w.appName)"); return false }
        if winSpace == home { return true }
        Log.write("pull: \(w.appName) from space \(winSpace) to \(home)")
        let order = Spaces.ordered().map(\.id)
        guard let from = order.firstIndex(of: winSpace), let to = order.firstIndex(of: home) else { return false }

        // 1. Be on the window's desktop, with the window in front.
        w.focus()
        guard await waitFor(space: winSpace, timeout: 2) else { return false }
        await sleep(0.25)
        guard let grab = grabPoint(w) else { return false }

        DragSnap.shared.suspended = true
        defer { DragSnap.shared.suspended = false }
        let cursor = CGEvent(source: nil)?.location ?? grab

        // 2. Hold the window by its title bar.
        CGWarpMouseCursorPosition(grab)
        mouse(.leftMouseDown, grab)
        await sleep(0.08)
        mouse(.leftMouseDragged, CGPoint(x: grab.x + 1, y: grab.y))
        await sleep(0.08)

        // 3. Go to the grid desktop: one jump if "Switch to Desktop N" is on, otherwise step with ⌃← / ⌃→.
        if let (key, flags) = directShortcut(toDesktop: Spaces.homeNumber) {
            press(key, flags)
            _ = await waitFor(space: home, timeout: 2)
            await sleep(0.15)
        } else {
            let right = to > from
            for i in 1...abs(to - from) {
                ctrlArrow(right: right)
                let step = order[from + (right ? i : -i)]
                if !(await waitFor(space: step, timeout: 1.5)) { break }
                await sleep(0.15)
            }
        }

        // 4. Let go and put the cursor back.
        mouse(.leftMouseUp, CGPoint(x: grab.x + 1, y: grab.y))
        await sleep(0.2)
        CGWarpMouseCursorPosition(cursor)
        let ok = Spaces.space(of: w) == home
        Log.write("pull: \(w.appName) \(ok ? "arrived" : "FAILED, now on space \(Spaces.space(of: w) ?? 0)")")
        return ok
    }
}
