import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's RegisterEventHotKey (works without extra permissions).
final class Hotkeys {
    static let shared = Hotkeys()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { Hotkeys.shared.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// modifiers: Carbon flags, e.g. controlKey | optionKey
    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x47524944), id: id) // 'GRID'
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
            handlers[id] = action
        }
    }

    static let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// ⌃⌥G grid picker · ⌃⌥1–9 place focused window · ⌃⌥L next layout · ⌃⌥D dashboard
    /// ⌃⌥←/→ switch page · ⌃⌥⇧←/→ send window to page · ⌃⌥N new page · ⌃⌥T tile all · ⌃⌥H shortcuts
    func registerDefaults(dashboard: @escaping () -> Void) {
        let mods = controlKey | optionKey
        let pm = PageManager.shared
        register(keyCode: kVK_LeftArrow, modifiers: mods) { pm.previous() }
        register(keyCode: kVK_RightArrow, modifiers: mods) { pm.next() }
        register(keyCode: kVK_LeftArrow, modifiers: mods | shiftKey) { pm.sendFocused(forward: false) }
        register(keyCode: kVK_RightArrow, modifiers: mods | shiftKey) { pm.sendFocused(forward: true) }
        register(keyCode: kVK_ANSI_N, modifiers: mods) { pm.newPage() }
        register(keyCode: kVK_ANSI_T, modifiers: mods) { pm.tileAll() }
        register(keyCode: kVK_ANSI_H, modifiers: mods) { ShortcutSheet.shared.toggle() }
        register(keyCode: kVK_ANSI_A, modifiers: mods) { Task { @MainActor in AutoArrange.shared.arrangeEverything() } }
        register(keyCode: kVK_ANSI_G, modifiers: mods) { OverlayController.shared.showPicker() }
        register(keyCode: kVK_ANSI_L, modifiers: mods) { GridManager.shared.cycleLayout() }
        register(keyCode: kVK_ANSI_D, modifiers: mods, dashboard)
        for (i, code) in Self.digitKeyCodes.enumerated() {
            register(keyCode: code, modifiers: mods) { GridManager.shared.placeFocused(inCell: i) }
        }
    }
}
