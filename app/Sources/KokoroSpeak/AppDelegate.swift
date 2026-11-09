import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let speaker = Speaker()
    private let miniPlayer = MiniPlayer()
    private let hotKey = HotKey()
    private var nowSpeaking: NowSpeakingView?
    private var errorResetTimer: Timer?
    /// Drives the wave animation and word highlighting. Runs only while speaking.
    private var frameTimer: Timer?
    private var phase: CGFloat = 0
    private var tickCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        speaker.onStateChange = { [weak self] state in self?.stateChanged(state) }
        miniPlayer.onPause = { [weak self] in self?.togglePause() }
        miniPlayer.onStop = { [weak self] in self?.speaker.stop() }
        updateIcon()

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        if !hotKey.register() {
            speaker.report("Another app is using ⌥ Esc")
        }
    }

    // MARK: - ⌥ Esc

    /// Speaks the selected text, or stops if already speaking, like the built-in Speak Selection.
    private func hotKeyPressed() {
        log.info("hot key pressed, busy=\(self.speaker.isBusy, privacy: .public)")
        if speaker.isBusy { return speaker.stop() }
        guard Selection.isAllowed(prompt: true) else {
            speaker.report("Allow Kokoro Speak in Privacy & Security > Accessibility, then press ⌥ Esc again")
            return
        }
        Selection.read { [weak self] text in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return self.speaker.report("Select some text first")
            }
            self.speaker.speak(text, voice: Settings.voice, speed: Settings.speed)
        }
    }

    // MARK: - Services menu entry (Services > Speak with Kokoro Speak)

    /// Speaks the selected text, or stops if already speaking, like the built-in Speak Selection.
    @objc(speakSelection:userData:error:)
    func speakSelection(_ pasteboard: NSPasteboard, userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        log.info("service invoked, busy=\(self.speaker.isBusy, privacy: .public)")
        if speaker.isBusy { return speaker.stop() }
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "No text was selected" as NSString
            return
        }
        speaker.speak(text, voice: Settings.voice, speed: Settings.speed)
    }

    // MARK: - State and animation

    private func stateChanged(_ state: Speaker.State) {
        errorResetTimer?.invalidate()
        switch state {
        case .loading, .speaking:
            startFrames()
            if Settings.showMiniPlayer { miniPlayer.show() }
        case .idle:
            stopFrames()
            miniPlayer.hide()
        case .failed:
            stopFrames()
            miniPlayer.hide(after: 0)
            let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in self?.updateIcon(forceIdle: true) }
            RunLoop.main.add(timer, forMode: .common)
            errorResetTimer = timer
        }
        updateIcon()
        tick()
    }

    private func startFrames() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)  // keeps running while a menu is open
        frameTimer = timer
    }

    private func stopFrames() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func tick() {
        let loading = speaker.state == .loading
        if !speaker.isPaused { phase += 0.45 }
        let snapshot = speaker.snapshot()
        tickCount += 1
        if tickCount % 15 == 0, let left = snapshot?.secondsLeft {
            log.debug("time left \(left, format: .fixed(precision: 1), privacy: .public)s")
        }
        if speaker.isBusy {
            statusItem.button?.image = SpokenText.activityImage(size: 18, phase: phase, snapshot: snapshot,
                                                                color: .controlAccentColor)
        }
        if miniPlayer.isVisible {
            miniPlayer.update(snapshot, voice: Settings.voice, phase: phase, loading: loading)
        }
        nowSpeaking?.update(snapshot, voice: Settings.voice, phase: phase, loading: loading)
    }

    private func updateIcon(forceIdle: Bool = false) {
        let state = forceIdle ? .idle : speaker.state
        let tip: String
        switch state {
        case .idle: tip = "Kokoro Speak: select text and press ⌥ Esc"
        case .loading: tip = "Loading voice… click to stop, right-click for options"
        case .speaking: tip = "Speaking… click to stop, right-click for options"
        case .failed(let reason): tip = reason
        }
        statusItem.button?.toolTip = tip
        if state == .loading || state == .speaking { return }  // the frame timer draws the wave
        let symbol = state == .idle ? "speaker.wave.2" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image?.isTemplate = true
        statusItem.button?.image = image
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
        if menu === statusItem.menu {
            statusItem.menu = nil
            nowSpeaking = nil
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        if speaker.isBusy {
            let view = NowSpeakingView()
            nowSpeaking = view
            let header = NSMenuItem()
            header.view = view
            menu.addItem(header)
            tick()
            menu.addItem(.separator())
            let stop = item("Stop", symbol: "stop", action: #selector(stopSpeaking), key: "\u{1b}")
            stop.keyEquivalentModifierMask = [.option]
            menu.addItem(stop)
            menu.addItem(item(speaker.isPaused ? "Resume" : "Pause",
                              symbol: speaker.isPaused ? "play" : "pause", action: #selector(togglePause)))
            menu.addItem(item("Skip sentence", symbol: "forward.end", action: #selector(skip)))
        } else {
            let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if !Selection.isAllowed(prompt: false) {
                menu.addItem(item("Allow reading selected text…", symbol: "lock.open", action: #selector(allowAccess)))
            }
            menu.addItem(.separator())
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

        let highlightItem = item("Highlight", symbol: "highlighter", action: nil)
        let highlightMenu = NSMenu()
        for highlight in Settings.Highlight.allCases {
            let option = NSMenuItem(title: highlight.title, action: #selector(chooseHighlight(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = highlight.rawValue
            option.state = highlight == Settings.highlight ? .on : .off
            option.image = swatch(SpokenText.highlightColor(highlight))
            highlightMenu.addItem(option)
        }
        highlightItem.submenu = highlightMenu
        menu.addItem(highlightItem)

        let mini = item("Show mini player", symbol: "rectangle.bottomhalf.inset.filled", action: #selector(toggleMiniPlayer))
        mini.state = Settings.showMiniPlayer ? .on : .off
        menu.addItem(mini)
        menu.addItem(.separator())

        let login = item("Open at login", symbol: nil, action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit Kokoro Speak", symbol: nil, action: #selector(quit), key: "q"))
        return menu
    }

    private func headerText() -> String {
        if case .failed(let reason) = speaker.state { return reason }
        return "\(Voices.displayName(Settings.voice)) · select text and press ⌥ Esc"
    }

    private func item(_ title: String, symbol: String?, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    // MARK: - Actions

    @objc private func stopSpeaking() { speaker.stop() }

    @objc private func allowAccess() {
        if !Selection.isAllowed(prompt: true) { Selection.openAccessibilitySettings() }
    }

    @objc private func togglePause() {
        speaker.togglePause()
        tick()
    }

    @objc private func skip() { speaker.skip() }

    @objc private func speakClipboard() {
        speaker.speak(NSPasteboard.general.string(forType: .string) ?? "", voice: Settings.voice, speed: Settings.speed)
    }

    @objc private func chooseSpeed(_ sender: NSMenuItem) {
        if let speed = sender.representedObject as? Double { Settings.speed = speed }
    }

    @objc private func chooseHighlight(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let highlight = Settings.Highlight(rawValue: raw) {
            Settings.highlight = highlight
        }
    }

    @objc private func toggleMiniPlayer() {
        Settings.showMiniPlayer.toggle()
        if Settings.showMiniPlayer && speaker.isBusy { miniPlayer.show() } else { miniPlayer.hide(after: 0) }
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
