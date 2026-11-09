import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (⌥ Esc by default) using the Carbon hot key API,
/// which works in every app and needs no special permission.
final class HotKey {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Returns false if another app has already claimed the shortcut.
    @discardableResult
    func register(keyCode: Int = kVK_Escape, modifiers: Int = optionKey) -> Bool {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.onPress?() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4B6F6B6F), id: 1)  // "Koko"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    deinit { unregister() }
}

/// Reads the text selected in the frontmost app.
enum Selection {
    /// Whether Kokoro Speak may read other apps' selections. With `prompt`, macOS shows its
    /// "allow in Accessibility settings" dialog the first time.
    static func isAllowed(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Tries the accessibility API first, then falls back to copying with ⌘C
    /// (restoring the clipboard afterwards) for apps that don't expose their selection.
    static func read(completion: @escaping (String?) -> Void) {
        if let text = viaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return completion(text)
        }
        viaCopy(completion: completion)
    }

    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func viaCopy(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pasteboard.changeCount

        // ⌘C with only Command held, even though the user is still holding Option.
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }

        var attempts = 0
        func check() {
            attempts += 1
            if pasteboard.changeCount != before || attempts >= 12 {
                let text = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
                if pasteboard.changeCount != before {
                    pasteboard.clearContents()
                    let items = saved.map { entries -> NSPasteboardItem in
                        let item = NSPasteboardItem()
                        entries.forEach { item.setData($0.1, forType: $0.0) }
                        return item
                    }
                    if !items.isEmpty { pasteboard.writeObjects(items) }
                }
                completion(text)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: check)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
    }
}
