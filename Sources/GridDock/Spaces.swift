import AppKit
import ApplicationServices

/// macOS desktops (Spaces). Reading which Space a window is on uses read-only window-server
/// calls (looked up at runtime; no SIP changes). Moving a window to another Space has no API,
/// so `pull` does what a person would: hold the window by its title bar and switch desktops.
enum Spaces {
    private typealias MainConn = @convention(c) () -> UInt32
    private typealias ActiveSpace = @convention(c) (UInt32) -> UInt64
    private typealias SpacesForWindows = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias DisplaySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let p = dlsym(skylight, name) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // -2 = RTLD_DEFAULT
        return unsafeBitCast(p, to: T.self)
    }
    private static let mainConn = sym("SLSMainConnectionID", MainConn.self) ?? sym("CGSMainConnectionID", MainConn.self)
    private static let activeSpace = sym("SLSGetActiveSpace", ActiveSpace.self) ?? sym("CGSGetActiveSpace", ActiveSpace.self)
    private static let spacesForWindows = sym("SLSCopySpacesForWindows", SpacesForWindows.self) ?? sym("CGSCopySpacesForWindows", SpacesForWindows.self)
    private static let displaySpaces = sym("SLSCopyManagedDisplaySpaces", DisplaySpaces.self) ?? sym("CGSCopyManagedDisplaySpaces", DisplaySpaces.self)
    private static let getWindow = sym("_AXUIElementGetWindow", GetWindow.self)

    static var isAvailable: Bool { mainConn != nil && activeSpace != nil && spacesForWindows != nil && displaySpaces != nil && getWindow != nil }

    struct Space { let id: UInt64; let isFullscreen: Bool }

    /// Spaces of the main display in Mission Control order (desktops and fullscreen apps), as ⌃←/⌃→ walks them.
    static func ordered() -> [Space] {
        guard let mainConn, let displaySpaces,
              let displays = displaySpaces(mainConn())?.takeRetainedValue() as? [[String: Any]],
              let main = displays.first,
              let list = main["Spaces"] as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let id = (s["id64"] as? NSNumber)?.uint64Value ?? (s["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
            return Space(id: id, isFullscreen: (s["type"] as? Int ?? 0) == 4)
        }
    }

    /// Regular desktops only ("Desktop 1, 2, …"), without fullscreen-app spaces.
    static func desktops() -> [Space] { ordered().filter { !$0.isFullscreen } }

    static var current: UInt64? { mainConn.flatMap { c in activeSpace?(c()) } }

    static func windowID(_ w: AXWindow) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard let getWindow, getWindow(w.element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    static func space(of w: AXWindow) -> UInt64? {
        windowID(w).flatMap(space(ofWindowID:))
    }

    static func space(ofWindowID wid: CGWindowID) -> UInt64? {
        guard let mainConn, let spacesForWindows,
              let arr = spacesForWindows(mainConn(), 0x7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return arr.first?.uint64Value
    }

    // MARK: Grid desktop (the one desktop all grids live on)

    private static let homeKey = "gridDesktopNumber"
    private static let pullKey = "pullToGridDesktop"

    /// 1-based desktop number the grid lives on.
    static var homeNumber: Int {
        get { max(1, UserDefaults.standard.integer(forKey: homeKey)) }
        set { UserDefaults.standard.set(newValue, forKey: homeKey) }
    }

    static var pullEnabled: Bool {
        get { UserDefaults.standard.object(forKey: pullKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: pullKey) }
    }

    static var home: UInt64? {
        let d = desktops()
        return d.indices.contains(homeNumber - 1) ? d[homeNumber - 1].id : d.first?.id
    }

    static func desktopNumber(of spaceID: UInt64) -> Int? {
        desktops().firstIndex { $0.id == spaceID }.map { $0 + 1 }
    }

    /// True when the window lives on a different Space than the grid desktop.
    static func needsPull(_ w: AXWindow) -> Bool {
        guard pullEnabled, isAvailable, let home, let s = space(of: w) else { return false }
        return s != home
    }
}
