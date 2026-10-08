import Foundation

/// Appends to ~/Library/Logs/GridDock.log (readable in Console.app) for diagnosing moves between desktops.
enum Log {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/GridDock.log")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    /// Starts a fresh log once it passes 1 MB.
    static func trimIfLarge() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
    }

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
