import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    print(message)

    let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("TelegramVoiceHotkey")
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let logFile = logDir.appendingPathComponent("app.log")

    if let handle = try? FileHandle(forWritingTo: logFile) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.data(using: .utf8)?.write(to: logFile)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var recorder: AVAudioRecorder?
    var tempURL: URL?
    var isRecording = false
    var config: Config = .default
    var setupWindow: SetupWindowController?
    var eventTap: CFMachPort?
    var accessibilityTimer: Timer?
    var telegramClient: TelegramClient?

    var _targetKeyCode: CGKeyCode = 0
    var _targetModifiers: UInt = 0
    var _mode: RecordingMode = .holdToRecord
    // Screenshot combo
    var _screenshotKeyCode: CGKeyCode = 0
    var _screenshotModifiers: UInt = 0
    var screenshotPath: String?
    var isScreenshotMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)
        buildMenu()

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Microphone access required"
                    alert.informativeText = "Grant microphone access in System Settings → Privacy & Security → Microphone"
                    alert.runModal()
                }
            }
        }

        config = Config.load()
        log("📋 Config loaded — apiId=\(config.apiId) chatId=\(config.chatId) loggedIn=\(config.userLoggedIn) isConfigured=\(config.isConfigured)")
        if config.isConfigured {
            startTelegramClient()
            tryStartListening()
        } else if config.hasCredentials {
            // Has API creds but not logged in yet — start TDLib for login, show setup
            startTelegramClient()
            showSetup()
        } else {
            showSetup()
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Telegram Voice Hotkey", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        if config.isConfigured {
            let modeDesc = config.recordingMode == .holdToRecord
                ? "Hold \(config.hotkeyDisplay) to record"
                : "Press \(config.hotkeyDisplay) to record, any key to stop"
            menu.addItem(NSMenuItem(title: modeDesc, action: nil, keyEquivalent: ""))

            let accessStatus = AXIsProcessTrusted() ? "✅ Accessibility: Granted" : "❌ Accessibility: Not granted"
            menu.addItem(NSMenuItem(title: accessStatus, action: nil, keyEquivalent: ""))

            let tapStatus = eventTap != nil ? "✅ Hotkey: Active" : "❌ Hotkey: Inactive"
            menu.addItem(NSMenuItem(title: tapStatus, action: nil, keyEquivalent: ""))

            let tdlibStatus = telegramClient?.isLoggedIn == true ? "✅ Telegram: Connected" : "❌ Telegram: Not connected"
            menu.addItem(NSMenuItem(title: tdlibStatus, action: nil, keyEquivalent: ""))

            if !AXIsProcessTrusted() || eventTap == nil {
                let retryItem = NSMenuItem(title: "Retry Permissions", action: #selector(retryPermissions), keyEquivalent: "r")
                retryItem.target = self
                menu.addItem(retryItem)
            }
        } else {
            menu.addItem(NSMenuItem(title: "Not configured — open Settings", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSetup), keyEquivalent: ","))

        let logItem = NSMenuItem(title: "View Log...", action: #selector(openLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func openLog() {
        let logFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TelegramVoiceHotkey/app.log")
        NSWorkspace.shared.open(logFile)
    }

    @objc func retryPermissions() {
        if let oldTap = eventTap {
            CGEvent.tapEnable(tap: oldTap, enable: false)
            eventTap = nil
        }
        tryStartListening()
    }

    // MARK: - Permissions (Accessibility + Screen Recording)

    func requestAllPermissions() {
        // Trigger Screen Recording permission prompt (needed for screenshot feature).
        // CGWindowListCopyWindowInfo triggers the system dialog on first call.
        let _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        log("📸 Screen Recording permission requested")
    }

    func tryStartListening() {
        // Request all permissions upfront (one-time onboarding)
        requestAllPermissions()

        if AXIsProcessTrusted() {
            startListening()
            buildMenu()
            log("🎤 Ready — \(config.hotkeyDisplay)")
        } else {
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            )

            log("⏳ Waiting for Accessibility permission...")
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.accessibilityTimer = nil
                    self?.startListening()
                    self?.buildMenu()
                    self?.updateIcon(recording: false)
                    log("✅ Accessibility granted — hotkey active")
                }
            }
            buildMenu()
        }
    }

    // MARK: - Setup Window

    @objc func showSetup() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        setupWindow = SetupWindowController(existing: config, existingClient: telegramClient) { [weak self] newConfig in
            guard let self = self else { return }
            self.config = newConfig

            // Restart TDLib if needed
            if self.telegramClient == nil && newConfig.hasCredentials {
                self.startTelegramClient()
            }

            self.buildMenu()

            if let oldTap = self.eventTap {
                CGEvent.tapEnable(tap: oldTap, enable: false)
                self.eventTap = nil
            }

            if newConfig.isConfigured {
                self.tryStartListening()
            }
            self.updateLaunchAtLogin(newConfig.launchAtLogin)
            NSApp.setActivationPolicy(.accessory)
            log("🎤 Config saved — \(newConfig.hotkeyDisplay) apiId=\(newConfig.apiId) chatId=\(newConfig.chatId) loggedIn=\(newConfig.userLoggedIn) isConfigured=\(newConfig.isConfigured)")
        }
        setupWindow?.showWindow(nil)
        setupWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - TDLib

    func startTelegramClient() {
        guard config.apiId > 0, !config.apiHash.isEmpty else {
            log("⏭ TDLib skipped — no valid API credentials")
            return
        }
        guard TelegramClient.isAvailable else {
            log("⏭ TDLib skipped — library not available (run scripts/setup-tdlib.sh)")
            return
        }
        if telegramClient != nil { return }

        telegramClient = TelegramClient(apiId: config.apiId, apiHash: config.apiHash)
        telegramClient?.onAuthStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                if state == .ready {
                    log("✅ TDLib: User authenticated and ready")
                    self?.config.userLoggedIn = true
                    self?.config.save()
                    self?.buildMenu()
                }
            }
        }
        telegramClient?.onError = { msg in
            log("❌ TDLib error: \(msg)")
        }
        telegramClient?.start()
        log("🔑 TDLib client started (apiId=\(config.apiId))")
    }

    // MARK: - Launch at Login

    func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log("⚠️ Launch at login: \(error)")
            }
        }
    }

    // MARK: - Event Tap (Global Hotkey)

    func startListening() {
        if eventTap != nil { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return delegate.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            log("❌ Failed to create event tap")
            return
        }

        self.eventTap = tap
        self._targetKeyCode = CGKeyCode(config.hotkeyKeyCode)
        self._targetModifiers = config.hotkeyModifiers
        self._mode = config.recordingMode
        if config.hasScreenshotHotkey {
            self._screenshotKeyCode = CGKeyCode(config.screenshotHotkeyKeyCode)
            self._screenshotModifiers = config.screenshotHotkeyModifiers
            log("📸 Screenshot hotkey: \(config.screenshotHotkeyDisplay)")
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        log("✅ Event tap active — listening for \(config.hotkeyDisplay)")
    }

    func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        let relevantFlags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let currentMods = flags.intersection(relevantFlags)
        let targetMods = CGEventFlags(rawValue: UInt64(
            NSEvent.ModifierFlags(rawValue: _targetModifiers)
                .intersection(.deviceIndependentFlagsMask).rawValue
        ))

        let hotkeyMatch = keyCode == _targetKeyCode && currentMods == targetMods

        // Screenshot combo hotkey
        let screenshotTargetMods = CGEventFlags(rawValue: UInt64(
            NSEvent.ModifierFlags(rawValue: _screenshotModifiers)
                .intersection(.deviceIndependentFlagsMask).rawValue
        ))
        let screenshotMatch = _screenshotKeyCode > 0 && keyCode == _screenshotKeyCode && currentMods == screenshotTargetMods

        // Handle screenshot combo (always hold-to-record style)
        if type == .keyDown && screenshotMatch && !isRepeat && !isRecording {
            DispatchQueue.main.async { self.startScreenshotRecording() }
            return nil
        }
        if type == .keyUp && keyCode == _screenshotKeyCode && isRecording && isScreenshotMode {
            DispatchQueue.main.async { self.stopAndSendScreenshot() }
            return nil
        }

        // Regular voice hotkey
        switch _mode {
        case .holdToRecord:
            if type == .keyDown && hotkeyMatch && !isRepeat {
                DispatchQueue.main.async { self.startRecording() }
                return nil
            }
            if type == .keyUp && keyCode == _targetKeyCode && isRecording && !isScreenshotMode {
                DispatchQueue.main.async { self.stopAndSend() }
                return nil
            }

        case .pressToToggle:
            if type == .keyDown {
                if isRecording && !isScreenshotMode {
                    DispatchQueue.main.async { self.stopAndSend() }
                    return nil
                } else if hotkeyMatch && !isRepeat {
                    DispatchQueue.main.async { self.startRecording() }
                    return nil
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Icon

    func updateIcon(recording: Bool) {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }

            if recording {
                let image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Recording")
                image?.isTemplate = false

                let tinted = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
                    NSColor.systemRed.set()
                    image?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    image?.draw(in: rect, from: .zero, operation: .sourceAtop, fraction: 1.0)
                    return true
                }
                button.image = tinted

                let tooltip = self._mode == .pressToToggle
                    ? "🔴 Recording — press any key to stop"
                    : "🔴 Recording — release to send"
                button.toolTip = tooltip
            } else {
                let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Voice Hotkey")
                image?.isTemplate = true
                button.image = image

                if self.config.isConfigured {
                    let tip = self._mode == .pressToToggle
                        ? "Press \(self.config.hotkeyDisplay) to record"
                        : "Hold \(self.config.hotkeyDisplay) to record"
                    button.toolTip = tip
                } else {
                    button.toolTip = "Telegram Voice Hotkey — not configured"
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording, config.isConfigured else {
            log("⚠️ startRecording skipped — isRecording=\(isRecording), configured=\(config.isConfigured)")
            return
        }
        isRecording = true
        updateIcon(recording: true)

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).m4a")
        tempURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            let started = rec.record()
            if started {
                recorder = rec
                log("🔴 Recording to: \(url.path)")
            } else {
                log("❌ AVAudioRecorder.record() returned false")
                isRecording = false
                updateIcon(recording: false)
            }
        } catch {
            log("❌ AVAudioRecorder init failed: \(error)")
            isRecording = false
            updateIcon(recording: false)
        }
    }

    // MARK: - Screenshot + Voice Combo

    func startScreenshotRecording() {
        guard !isRecording, config.isConfigured else {
            log("⚠️ startScreenshotRecording skipped")
            return
        }

        // Capture screenshot first
        ScreenCapture.captureScreen { [weak self] path in
            guard let self = self, let path = path else {
                log("❌ Screenshot capture failed — aborting")
                return
            }
            self.screenshotPath = path
            self.isScreenshotMode = true
            // Now start recording voice
            self.startRecording()
        }
    }

    func stopAndSendScreenshot() {
        guard isRecording, isScreenshotMode else { return }
        isRecording = false
        isScreenshotMode = false
        updateIcon(recording: false)

        guard let rec = recorder else {
            log("⬛ No recorder to stop")
            return
        }

        let duration = rec.currentTime
        rec.stop()
        recorder = nil

        guard let audioURL = tempURL else {
            log("⬛ No temp URL")
            return
        }

        guard let ssPath = screenshotPath else {
            log("❌ No screenshot — falling back to voice only")
            // Fall back to regular send
            isScreenshotMode = false
            stopAndSend()
            return
        }

        log("⬛ Screenshot+voice stopped — duration: \(String(format: "%.1f", duration))s")

        guard let client = telegramClient, client.isLoggedIn else {
            log("❌ TDLib not connected — can't send")
            return
        }

        let chatId = Int64(config.chatId) ?? 0

        if duration < 0.5 {
            // Too short to transcribe — send screenshot without caption
            log("⏭ Voice too short, sending screenshot only")
            client.sendPhoto(chatId: chatId, photoPath: ssPath, caption: nil) { sent in
                try? FileManager.default.removeItem(atPath: ssPath)
                try? FileManager.default.removeItem(at: audioURL)
                log(sent ? "✅ Sent screenshot" : "❌ Screenshot send failed")
            }
            return
        }

        // Transcribe voice locally, then send screenshot with caption
        log("📝 Transcribing voice locally...")
        WhisperTranscriber.transcribe(audioPath: audioURL.path) { [weak self] transcript in
            guard let self = self else { return }

            let caption = transcript ?? "[voice note attached]"
            log("📸 Sending screenshot + caption: \(caption.prefix(80))...")

            client.sendPhoto(chatId: chatId, photoPath: ssPath, caption: caption) { sent in
                try? FileManager.default.removeItem(atPath: ssPath)
                try? FileManager.default.removeItem(at: audioURL)
                log(sent ? "✅ Sent screenshot + voice" : "❌ Send failed")
            }

            // Also send the voice note as a reply for the AI to hear the original audio
            let oggURL = audioURL.deletingPathExtension().appendingPathExtension("ogg")
            self.convertToOgg(input: audioURL, output: oggURL) { _ in
                // Voice note sent separately so OpenClaw gets both
            }
        }
    }

    func stopAndSend() {
        guard isRecording else { return }
        isRecording = false
        updateIcon(recording: false)

        guard let rec = recorder else {
            log("⬛ No recorder to stop")
            return
        }

        let duration = rec.currentTime
        rec.stop()
        recorder = nil

        guard let url = tempURL else {
            log("⬛ No temp URL")
            return
        }

        log("⬛ Stopped — duration: \(String(format: "%.1f", duration))s")

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs[.size] as? Int ?? 0
            log("📁 File size: \(size) bytes")

            if duration < 0.5 || size < 1000 {
                log("⏭ Too short (\(String(format: "%.1f", duration))s, \(size)b), discarding")
                try? FileManager.default.removeItem(at: url)
                return
            }
        } catch {
            log("❌ Can't read file: \(error)")
            return
        }

        guard let client = telegramClient, client.isLoggedIn else {
            log("❌ TDLib not connected — can't send")
            return
        }

        let oggURL = url.deletingPathExtension().appendingPathExtension("ogg")
        convertToOgg(input: url, output: oggURL) { [self] success in
            let sendURL = success ? oggURL : url
            let chatId = Int64(self.config.chatId) ?? 0
            client.sendVoiceNote(chatId: chatId, filePath: sendURL.path, duration: Int(duration)) { sent in
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: oggURL)
                log(sent ? "✅ Sent voice note" : "❌ Send failed")
            }
        }
    }

    func convertToOgg(input: URL, output: URL, completion: @escaping (Bool) -> Void) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path
        let candidates = [bundled, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        let ffmpeg = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

        guard let ffmpegPath = ffmpeg else {
            log("⚠️ ffmpeg not found — sending m4a")
            completion(false)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-y", "-i", input.path, "-c:a", "libopus", "-b:a", "32k", "-vn", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                log("🔄 Converted to OGG/Opus")
                completion(true)
            } else {
                log("⚠️ ffmpeg failed (exit \(process.terminationStatus)) — sending m4a")
                completion(false)
            }
        } catch {
            log("⚠️ ffmpeg error: \(error) — sending m4a")
            completion(false)
        }
    }
}

// ─── Main ────────────────────────────────────────────────────────────────────
@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
