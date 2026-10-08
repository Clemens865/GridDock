import AppKit

/// Installs Claude Code hooks that report each session's state to GridDock.
/// The hook script writes one small JSON file per session into `sessionsDir`.
enum ClaudeHooks {
    static var supportDir: URL { ProjectLayoutStore.shared.fileURL.deletingLastPathComponent() }
    static var sessionsDir: URL { supportDir.appendingPathComponent("sessions", isDirectory: true) }
    static var scriptURL: URL { supportDir.appendingPathComponent("claude-hook.sh") }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Hook event → state argument passed to the script.
    static let events: [(event: String, state: String)] = [
        ("SessionStart", "done"),
        ("UserPromptSubmit", "working"),
        ("PostToolUse", "working"),
        ("Notification", "notify"),   // permission prompt → waiting, idle reminder → done
        ("Stop", "done"),
        ("SessionEnd", "ended"),
    ]

    static let script = #"""
    #!/bin/sh
    # GridDock <- Claude Code hook. $1: working | done | notify | ended. Silent, always exits 0.
    DIR="$HOME/Library/Application Support/GridDock/sessions"
    INPUT=$(cat)
    field() { printf '%s' "$INPUT" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
    SID=$(field session_id)
    [ -z "$SID" ] && exit 0
    STATE="$1"
    if [ "$STATE" = notify ]; then
      case "$(field message)" in *ermission*|*pprov*) STATE=waiting ;; *) STATE=done ;; esac
    fi
    if [ "$STATE" = ended ]; then rm -f "$DIR/$SID.json"; exit 0; fi
    # The terminal (tty) Claude runs in identifies its Terminal window exactly.
    PID=$PPID; TTY=""
    for _ in 1 2 3 4 5 6; do
      T=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
      if [ -n "$T" ] && [ "$T" != "??" ]; then TTY="/dev/$T"; break; fi
      PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
      if [ -z "$PID" ] || [ "$PID" -le 1 ]; then break; fi
    done
    mkdir -p "$DIR"
    CWD=$(field cwd | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"state":"%s","cwd":"%s","tty":"%s","ts":%s}' "$STATE" "$CWD" "$TTY" "$(date +%s)" > "$DIR/$SID.tmp" \
      && mv -f "$DIR/$SID.tmp" "$DIR/$SID.json"
    exit 0
    """#

    private static var commandPrefix: String { "'\(scriptURL.path)'" }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("GridDock/claude-hook.sh")
    }

    /// Writes the script and merges GridDock's hooks into ~/.claude/settings.json (after a backup).
    /// Existing hooks are left untouched.
    static func install() throws {
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let data = (try? Data(contentsOf: settingsURL)) ?? Data("{}".utf8)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "GridDock", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object"])
        }
        let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.griddock-backup")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: settingsURL, to: backup)

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, state) in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { entry in   // replace an older GridDock entry, keep everyone else's
                (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("GridDock/claude-hook.sh") == true } == true
            }
            entries.append(["hooks": [["type": "command", "command": "\(commandPrefix) \(state)"]]])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// Asks first, installs, and reports the result.
    static func promptInstall() {
        let alert = NSAlert()
        alert.messageText = "Show Claude Code session status"
        alert.informativeText = """
        GridDock will add six hooks to ~/.claude/settings.json (a backup is saved next to it as settings.json.griddock-backup). Your existing hooks stay as they are.

        Each Claude session then reports whether it is working, needs you, or is done, and GridDock frames its Terminal window in that colour. Sessions started before this pick it up from their next prompt.
        """
        alert.addButton(withTitle: "Install hooks")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try install()
            PageHUD.shared.flash(message: "Claude hooks installed")
        } catch {
            let fail = NSAlert(error: error)
            fail.runModal()
        }
    }
}
