import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let speaker = Speaker()
    private var errorResetTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        speaker.onStateChange = { [weak self] state in self?.stateChanged(state) }
        updateIcon()

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    // MARK: - Services menu entry (bound to ⌥⎋ by install.sh)

    /// Speaks the selected text, or stops if already speaking, like the built-in Speak Selection.
    @objc(speakSelection:userData:error:)
    func speakSelection(_ pasteboard: NSPasteboard, userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if speaker.isBusy { return speaker.stop() }
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "No text was selected" as NSString
            return
        }
        speaker.speak(text, voice: Settings.voice, speed: Settings.speed)
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if speaker.isBusy && !isRightClick {
            speaker.stop()
            return
        }
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem.menu { statusItem.menu = nil }
    }

    private func stateChanged(_ state: Speaker.State) {
        errorResetTimer?.invalidate()
        if case .failed = state {
            let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in self?.updateIcon(forceIdle: true) }
            RunLoop.main.add(timer, forMode: .common)
            errorResetTimer = timer
        }
        updateIcon()
    }

    private func updateIcon(forceIdle: Bool = false) {
        let symbol: String
        let tip: String
        switch forceIdle ? .idle : speaker.state {
        case .idle: (symbol, tip) = ("speaker.wave.2", "Kokoro Speak: select text and press ⌥ Esc")
        case .loading: (symbol, tip) = ("ellipsis.circle", "Loading voice… click to stop")
        case .speaking: (symbol, tip) = ("waveform", "Speaking… click to stop")
        case .failed(let reason): (symbol, tip) = ("exclamationmark.triangle", reason)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tip
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if speaker.isBusy {
            menu.addItem(item("Stop", symbol: "stop.fill", action: #selector(stopSpeaking)))
        } else {
            menu.addItem(item("Speak clipboard", symbol: "doc.on.clipboard", action: #selector(speakClipboard)))
        }
        menu.addItem(.separator())

        let voiceItem = item("Voice", symbol: "person.wave.2", action: nil)
        let voiceMenu = NSMenu()
        let voiceView = VoiceMenuView(selected: Settings.voice)
        voiceView.onSelect = { [weak self] voice in
            Settings.voice = voice
            self?.speaker.speak("Hi, I'm \(Voices.displayName(voice)).", voice: voice, speed: Settings.speed)
        }
        let viewItem = NSMenuItem()
        viewItem.view = voiceView
        voiceMenu.addItem(viewItem)
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        let speedItem = item("Speed", symbol: "gauge.with.dots.needle.50percent", action: nil)
        let speedMenu = NSMenu()
        for speed in Settings.speeds {
            let option = NSMenuItem(title: String(format: "%.1f×", speed), action: #selector(chooseSpeed(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = speed
            option.state = speed == Settings.speed ? .on : .off
            speedMenu.addItem(option)
        }
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)
        menu.addItem(.separator())

        let login = item("Open at login", symbol: nil, action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit Kokoro Speak", symbol: nil, action: #selector(quit), key: "q"))
        return menu
    }

    private func headerText() -> String {
        switch speaker.state {
        case .idle: return "\(Voices.displayName(Settings.voice)) · select text and press ⌥ Esc"
        case .loading: return "Loading \(Voices.displayName(Settings.voice))…"
        case .speaking: return "Speaking with \(Voices.displayName(Settings.voice))"
        case .failed(let reason): return reason
        }
    }

    private func item(_ title: String, symbol: String?, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func stopSpeaking() { speaker.stop() }

    @objc private func speakClipboard() {
        speaker.speak(NSPasteboard.general.string(forType: .string) ?? "", voice: Settings.voice, speed: Settings.speed)
    }

    @objc private func chooseSpeed(_ sender: NSMenuItem) {
        if let speed = sender.representedObject as? Double { Settings.speed = speed }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func quit() {
        speaker.stop()
        NSApp.terminate(nil)
    }
}
