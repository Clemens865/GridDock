import AppKit
import ApplicationServices

/// A window of any app, wrapped around its AX element.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var appName: String { app?.localizedName ?? "?" }
    var bundleID: String? { app?.bundleIdentifier }

    var title: String { (AX.attr(element, kAXTitleAttribute) as String?) ?? "" }

    var frame: CGRect? {
        guard let posVal: AXValue = AX.attr(element, kAXPositionAttribute),
              let sizeVal: AXValue = AX.attr(element, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &p)
        AXValueGetValue(sizeVal, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    var isMinimized: Bool { (AX.attr(element, kAXMinimizedAttribute) as Bool?) ?? false }
    var isFullscreen: Bool { (AX.attr(element, "AXFullScreen") as Bool?) ?? false }
    var isStandard: Bool { (AX.attr(element, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }

    /// Moves and resizes the window. Size→position→size handles apps that clamp to the current screen.
    func setFrame(_ r: CGRect) {
        var size = r.size, origin = r.origin
        let sizeVal = AXValueCreate(.cgSize, &size)!
        let posVal = AXValueCreate(.cgPoint, &origin)!
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
    }

    /// Leaves native fullscreen (which lives on its own Space) and calls back once macOS has
    /// finished the animation and the window is back on a normal desktop.
    func exitFullscreen(then done: @escaping () -> Void) {
        guard isFullscreen else { return done() }
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
        var tries = 0
        func poll() {
            tries += 1
            if !isFullscreen || tries > 30 {
                // The exit animation keeps running briefly after the flag flips.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
            }
        }
        poll()
    }

    func focus() {
        if isMinimized { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        app?.activate()
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    func isSame(_ other: AXWindow) -> Bool { CFEqual(element, other.element) }
}

enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to the Accessibility settings.
    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func focusedWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if let win: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) {
            return AXWindow(element: win, pid: app.processIdentifier)
        }
        return windows(of: app).first
    }

    static func windows(of app: NSRunningApplication, includeMinimized: Bool = false) -> [AXWindow] {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.3) // don't hang on unresponsive apps
        let list: [AXUIElement] = attr(appEl, kAXWindowsAttribute) ?? []
        return list.map { AXWindow(element: $0, pid: app.processIdentifier) }
                   .filter { $0.isStandard && (includeMinimized || !$0.isMinimized) }
    }

    /// All visible standard windows of regular (Dock) apps, excluding GridDock itself.
    static func allWindows() -> [AXWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isHidden }
            .flatMap { windows(of: $0) }
    }

    /// Windows actually visible on the current desktop (Space): on screen per the window server,
    /// not parked by a hidden GridDock page. Windows on other Spaces can't be moved here by any public API.
    static func visibleWindows() -> [AXWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreen: [(pid_t, CGRect)] = info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return (pid, CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
        return allWindows().filter { w in
            guard let f = w.frame, !ScreenGeometry.isParked(f) else { return false }
            return onScreen.contains { $0.0 == w.pid && abs($0.1.minX - f.minX) < 2 && abs($0.1.minY - f.minY) < 2
                                       && abs($0.1.width - f.width) < 2 && abs($0.1.height - f.height) < 2 }
        }
    }

    /// Window whose frame contains the given AX point, front-most first (uses the CG window list for z-order).
    static func window(at p: CGPoint) -> AXWindow? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p),
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            return windows(of: app).first { $0.frame?.contains(p) == true }
        }
        return nil
    }
}
