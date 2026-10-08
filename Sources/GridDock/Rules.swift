import AppKit

/// Which windows get tiled. Dialogs, fixed-size windows and listed apps "float":
/// they stay where they are, on top of the grid, and never take a cell.
struct Rules: Codable {
    /// Bundle IDs that are never tiled.
    var floatApps: [String]
    /// Windows smaller than this are treated as dialogs/utilities.
    var minTileWidth: CGFloat
    var minTileHeight: CGFloat

    static let defaults = Rules(
        floatApps: [
            "com.apple.systempreferences",
            "com.apple.Passwords",
            "com.apple.calculator",
            "com.apple.ActivityMonitor",
            "com.apple.archiveutility",
            "com.apple.FaceTime",
        ],
        minTileWidth: 400,
        minTileHeight: 250
    )

    static var fileURL: URL {
        ProjectLayoutStore.shared.fileURL.deletingLastPathComponent().appendingPathComponent("rules.json")
    }

    /// Loaded from rules.json (created with the defaults on first use, so it can be edited).
    static let current: Rules = {
        if let data = try? Data(contentsOf: fileURL), let r = try? JSONDecoder().decode(Rules.self, from: data) {
            return r
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(Rules.defaults).write(to: fileURL)
        return .defaults
    }()

    /// True when the window should take part in the grid.
    static func tiles(_ w: AXWindow) -> Bool {
        let r = current
        if let bid = w.bundleID, r.floatApps.contains(bid) { return false }
        guard let f = w.frame, f.width >= r.minTileWidth, f.height >= r.minTileHeight else { return false }
        // Windows that can't be resized (preference panes, some dialogs) would spill out of their cell.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(w.element, kAXSizeAttribute as CFString, &settable) == .success, !settable.boolValue {
            return false
        }
        return true
    }
}
