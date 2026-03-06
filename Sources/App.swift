import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

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
    private let telegramMessageLimit = 4096
    private let finalChunkSuffix = " (end of message — reply now)"

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
    // Dictation hotkey
    var _dictationKeyCode: CGKeyCode = 0
    var _dictationModifiers: UInt = 0
    var isDictationMode = false
    var notificationPermissionRequested = false

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
        log("📋 Config loaded — apiId=\(config.apiId) chatId=\(config.chatId) loggedIn=\(config.userLoggedIn)")

        if config.hasCredentials {
            // Start TDLib — it will tell us the actual auth state
            startTelegramClient()
        }

        // If we have enough config to listen, start listening
        if config.isConfigured {
            tryStartListening()
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
        menu.addItem(NSMenuItem(title: "Voice to Slop", action: nil, keyEquivalent: ""))
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

            let tdlibConnected = telegramClient?.isLoggedIn == true
            let tdlibStatus = tdlibConnected ? "✅ Telegram: Connected" : "⏳ Telegram: Connecting..."
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

            // Ensure TDLib is running
            if self.telegramClient == nil && newConfig.hasCredentials {
                self.startTelegramClient()
            } else if let setupClient = self.setupWindow?.telegramClient, self.telegramClient == nil {
                self.telegramClient = setupClient
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
            log("⏭ TDLib skipped — no credentials")
            return
        }
        guard TelegramClient.isAvailable else {
            log("⏭ TDLib skipped — dylib not found")
            return
        }
        guard telegramClient == nil else { return }

        let client = TelegramClient(apiId: config.apiId, apiHash: config.apiHash)
        telegramClient = client

        client.onAuthStateChanged = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.config.userLoggedIn = true
                self.config.save()
                self.buildMenu()
                // If we weren't listening yet (e.g. recovered session), start now
                if self.eventTap == nil && !self.config.chatId.isEmpty {
                    self.tryStartListening()
                }
            case .waitingForPhone:
                self.config.userLoggedIn = false
                self.config.save()
                self.buildMenu()
                self.showSetup()
            case .closed:
                // Client will recreate itself — just update menu
                self.buildMenu()
            default:
                self.buildMenu()
            }
        }
        client.onError = { msg in
            log("❌ TDLib: \(msg)")
        }
        client.start()
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
        if config.hasDictationHotkey {
            self._dictationKeyCode = CGKeyCode(config.dictationKeyCode)
            self._dictationModifiers = config.dictationModifiers
            log("📝 Dictation hotkey: \(config.dictationDisplay)")
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
        let dictationTargetMods = CGEventFlags(rawValue: UInt64(
            NSEvent.ModifierFlags(rawValue: _dictationModifiers)
                .intersection(.deviceIndependentFlagsMask).rawValue
        ))
        let dictationMatch = _dictationKeyCode > 0 && keyCode == _dictationKeyCode && currentMods == dictationTargetMods

        // ── Screenshot combo (always hold-to-record) ──
        if type == .keyDown && screenshotMatch && !isRepeat && !isRecording {
            DispatchQueue.main.async { self.startScreenshotRecording() }
            return nil
        }
        // While recording in screenshot mode, suppress ALL key events (no beeps)
        if isRecording && isScreenshotMode {
            if type == .keyDown && keyCode == _screenshotKeyCode {
                return nil  // suppress auto-repeat
            }
            if type == .keyUp && keyCode == _screenshotKeyCode {
                DispatchQueue.main.async { self.stopAndSendScreenshot() }
                return nil
            }
            // Suppress any other keys during screenshot recording too
            return nil
        }

        // ── Dictation hotkey (always hold-to-record) ──
        if type == .keyDown && dictationMatch && !isRepeat && !isRecording {
            DispatchQueue.main.async { self.startDictationRecording() }
            return nil
        }
        if isRecording && isDictationMode {
            if type == .keyDown && keyCode == _dictationKeyCode {
                return nil
            }
            if type == .keyUp && keyCode == _dictationKeyCode {
                DispatchQueue.main.async { self.stopAndDictate() }
                return nil
            }
            return nil
        }

        // ── Regular voice hotkey ──
        switch _mode {
        case .holdToRecord:
            if type == .keyDown && hotkeyMatch && !isRepeat {
                DispatchQueue.main.async { self.startRecording() }
                return nil
            }
            // While recording, suppress ALL key events from the hotkey (including auto-repeat)
            if isRecording {
                if type == .keyDown && keyCode == _targetKeyCode {
                    return nil  // suppress auto-repeat beeps
                }
                if type == .keyUp && keyCode == _targetKeyCode {
                    DispatchQueue.main.async { self.stopAndSend() }
                    return nil
                }
            }

        case .pressToToggle:
            if type == .keyDown {
                if isRecording {
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
                let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Voice to Slop")
                image?.isTemplate = true
                button.image = image

                if self.config.isConfigured {
                    let tip = self._mode == .pressToToggle
                        ? "Press \(self.config.hotkeyDisplay) to record"
                        : "Hold \(self.config.hotkeyDisplay) to record"
                    button.toolTip = tip
                } else {
                    button.toolTip = "Voice to Slop — not configured"
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
        startAudioRecording()
    }

    private func startAudioRecording() {
        guard !isRecording else {
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

    func startDictationRecording() {
        guard !isRecording else {
            log("⚠️ startDictationRecording skipped")
            return
        }
        switch config.transcriptionMode {
        case "gemini":
            if config.geminiApiKey.isEmpty {
                showLocalNotification(
                    title: "Voice to Slop",
                    subtitle: "Dictation unavailable",
                    body: "Gemini API key missing. Add it in settings."
                )
                return
            }
        case "custom":
            if config.customEndpointUrl.isEmpty {
                showLocalNotification(
                    title: "Voice to Slop",
                    subtitle: "Dictation unavailable",
                    body: "Custom endpoint URL missing. Add it in settings."
                )
                return
            }
        default:
            guard WhisperTranscriber.hasLocalModel else {
                showLocalNotification(
                    title: "Voice to Slop",
                    subtitle: "Dictation unavailable",
                    body: "Local transcription model not found. Switch to Gemini or Custom mode in settings."
                )
                return
            }
        }
        isDictationMode = true
        startAudioRecording()
        if !isRecording {
            isDictationMode = false
        }
    }

    // MARK: - Transcription helper

    /// Returns a closure that transcribes `audioPath` using the current config.
    func makeTranscribeClosure(audioPath: String) -> (@escaping (String?) -> Void) -> Void {
        switch config.transcriptionMode {
        case "gemini":
            guard !config.geminiApiKey.isEmpty else {
                log("⚠️ Gemini mode selected but no API key — falling back to local")
                return { completion in WhisperTranscriber.transcribe(audioPath: audioPath, completion: completion) }
            }
            log("📝 Transcribing via Gemini...")
            return { completion in
                GeminiTranscriber.transcribe(audioPath: audioPath, apiKey: self.config.geminiApiKey, completion: completion)
            }
        case "custom":
            guard !config.customEndpointUrl.isEmpty else {
                log("⚠️ Custom mode selected but no endpoint URL — falling back to local")
                return { completion in WhisperTranscriber.transcribe(audioPath: audioPath, completion: completion) }
            }
            log("📝 Transcribing via custom endpoint (\(config.customEndpointUrl))...")
            return { completion in
                CustomTranscriber.transcribe(
                    audioPath: audioPath,
                    endpointUrl: self.config.customEndpointUrl,
                    apiKey: self.config.customApiKey,
                    modelName: self.config.customModelName,
                    completion: completion
                )
            }
        default:
            log("📝 Transcribing locally via whisper...")
            return { completion in WhisperTranscriber.transcribe(audioPath: audioPath, completion: completion) }
        }
    }

    /// Returns a closure that transcribes `audioPath`, copies transcript to clipboard, and notifies.
    func makeDictationClosure(audioPath: String) -> (@escaping (Bool) -> Void) -> Void {
        let transcribe = makeTranscribeClosure(audioPath: audioPath)
        return { [weak self] completion in
            transcribe { transcript in
                guard let self = self else {
                    completion(false)
                    return
                }
                guard let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    self.showLocalNotification(title: "Voice to Slop", subtitle: "Dictation failed", body: "No speech detected")
                    completion(false)
                    return
                }

                DispatchQueue.main.async {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    let copied = pasteboard.setString(text, forType: .string)
                    if copied {
                        self.showLocalNotification(
                            title: "Voice to Slop",
                            subtitle: "Copied to clipboard",
                            body: String(text.prefix(50))
                        )
                        log("✅ Dictation copied to clipboard")
                        completion(true)
                    } else {
                        self.showLocalNotification(title: "Voice to Slop", subtitle: "Dictation failed", body: "Clipboard write failed")
                        completion(false)
                    }
                }
            }
        }
    }

    private func splitForTelegram(text: String) -> [String] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        let chars = Array(source)
        var totalParts = 1

        for _ in 0..<8 {
            var messages: [String] = []
            var cursor = 0
            var part = 1

            while cursor < chars.count {
                let prefix = "[\(part)/\(totalParts)] "
                var available = telegramMessageLimit - prefix.count
                guard available > 0 else { return [] }

                let remaining = chars.count - cursor
                var take = min(remaining, available)

                if remaining <= available {
                    let lastAvailable = available - finalChunkSuffix.count
                    if lastAvailable > 0, remaining <= lastAvailable {
                        take = remaining
                    } else if lastAvailable > 0, remaining > lastAvailable {
                        take = lastAvailable
                    }
                }

                let body = String(chars[cursor..<(cursor + take)])
                cursor += take
                let isLast = cursor >= chars.count
                let suffix = isLast ? finalChunkSuffix : ""
                messages.append(prefix + body + suffix)
                part += 1
            }

            let isValid = !messages.isEmpty && messages.allSatisfy { $0.count <= telegramMessageLimit }
            if isValid && messages.count == totalParts {
                return messages
            }
            totalParts = max(messages.count, totalParts + 1)
        }

        let fallbackPrefix = "[1/1] "
        let fallbackLimit = max(1, telegramMessageLimit - fallbackPrefix.count - finalChunkSuffix.count)
        var fallbackMessages: [String] = []
        var start = 0
        while start < chars.count {
            let end = min(start + fallbackLimit, chars.count)
            fallbackMessages.append(String(chars[start..<end]))
            start = end
        }
        return fallbackMessages.enumerated().map { idx, chunk in
            let prefix = "[\(idx + 1)/\(fallbackMessages.count)] "
            let suffix = idx == fallbackMessages.count - 1 ? finalChunkSuffix : ""
            return prefix + chunk + suffix
        }
    }

    private func saveFailedTranscription(_ text: String) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-to-slop-transcription-\(stamp).txt")
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            log("💾 Saved unsent transcription to \(fileURL.path)")
            return fileURL
        } catch {
            log("❌ Failed to save unsent transcription: \(error)")
            return nil
        }
    }

    private func sendTranscriptionText(chatId: Int64, text: String, client: TelegramClient) {
        let parts = splitForTelegram(text: text)
        guard !parts.isEmpty else {
            log("⚠️ Empty transcription after trimming — nothing sent")
            return
        }

        log("📤 Sending transcription in \(parts.count) part(s)")
        sendChunk(parts: parts, at: 0, chatId: chatId, client: client) { [weak self] success in
            guard let self = self else { return }
            if success {
                log("✅ Sent transcript as text (\(parts.count) part(s))")
                return
            }
            let fileURL = self.saveFailedTranscription(text)
            let body: String
            if let fileURL = fileURL {
                body = "Send failed. Transcription saved to \(fileURL.path)"
            } else {
                body = "Send failed and backup save failed. Check app log."
            }
            self.showLocalNotification(title: "Voice to Slop", subtitle: "Text send failed", body: body)
        }
    }

    private func sendChunk(parts: [String], at index: Int, chatId: Int64, client: TelegramClient, completion: @escaping (Bool) -> Void) {
        if index >= parts.count {
            completion(true)
            return
        }
        client.sendTextMessage(chatId: chatId, text: parts[index]) { [weak self] sent in
            guard let self = self else {
                completion(false)
                return
            }
            guard sent else {
                log("❌ Failed sending transcript chunk \(index + 1)/\(parts.count)")
                completion(false)
                return
            }
            self.sendChunk(parts: parts, at: index + 1, chatId: chatId, client: client, completion: completion)
        }
    }

    func showLocalNotification(title: String, subtitle: String, body: String) {
        let postNotification = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }

        guard !notificationPermissionRequested else {
            postNotification()
            return
        }
        notificationPermissionRequested = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            postNotification()
        }
    }

    func stopAndSendScreenshot() {
        guard isRecording, isScreenshotMode else { return }
        isRecording = false
        isScreenshotMode = false
        isDictationMode = false
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

        // Transcribe voice, then send screenshot with caption
        let transcribe = makeTranscribeClosure(audioPath: audioURL.path)
        transcribe { [weak self] transcript in
            guard let self = self else { return }

            let caption = transcript ?? "[voice note attached]"
            log("📸 Sending screenshot + caption: \(caption.prefix(80))...")

            client.sendPhoto(chatId: chatId, photoPath: ssPath, caption: caption) { sent in
                log(sent ? "✅ Sent screenshot + voice" : "❌ Send failed")
                // Delay cleanup — TDLib needs the file for upload
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    try? FileManager.default.removeItem(atPath: ssPath)
                }
            }

            // Also send the voice note as a reply for the AI to hear the original audio
            let oggURL = audioURL.deletingPathExtension().appendingPathExtension("ogg")
            self.convertToOgg(input: audioURL, output: oggURL) { _ in
                // Delay cleanup — TDLib needs file for upload
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    try? FileManager.default.removeItem(at: audioURL)
                    try? FileManager.default.removeItem(at: oggURL)
                }
            }
        }
    }

    func stopAndSend() {
        guard isRecording else { return }
        isRecording = false
        isDictationMode = false
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

        let chatId = Int64(config.chatId) ?? 0

        // If sendVoiceAsText + a cloud transcription mode is configured, transcribe first
        let shouldTranscribe = config.sendVoiceAsText && config.transcriptionMode != "local"
        if shouldTranscribe {
            log("📝 sendVoiceAsText=true — transcribing before send...")
            let transcribe = makeTranscribeClosure(audioPath: url.path)
            transcribe { [self] transcript in
                // Cleanup temp audio regardless
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    try? FileManager.default.removeItem(at: url)
                }
                guard let text = transcript, !text.isEmpty else {
                    log("⚠️ Transcription empty/failed — falling back to voice note")
                    // fall back: convert + send voice
                    let oggURL = url.deletingPathExtension().appendingPathExtension("ogg")
                    self.convertToOgg(input: url, output: oggURL) { success in
                        let sendURL = success ? oggURL : url
                        client.sendVoiceNote(chatId: chatId, filePath: sendURL.path, duration: Int(duration)) { sent in
                            log(sent ? "✅ Sent voice note (fallback)" : "❌ Send failed")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                                try? FileManager.default.removeItem(at: url)
                                try? FileManager.default.removeItem(at: oggURL)
                            }
                        }
                    }
                    return
                }
                log("📤 Sending transcript as text message...")
                self.sendTranscriptionText(chatId: chatId, text: text, client: client)
            }
        } else {
            let oggURL = url.deletingPathExtension().appendingPathExtension("ogg")
            convertToOgg(input: url, output: oggURL) { [self] success in
                let sendURL = success ? oggURL : url
                client.sendVoiceNote(chatId: chatId, filePath: sendURL.path, duration: Int(duration)) { sent in
                    log(sent ? "✅ Sent voice note" : "❌ Send failed")
                    // Delay cleanup — TDLib needs the file for upload
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                        try? FileManager.default.removeItem(at: url)
                        try? FileManager.default.removeItem(at: oggURL)
                    }
                }
            }
        }
    }

    func stopAndDictate() {
        guard isRecording, isDictationMode else { return }
        isRecording = false
        isDictationMode = false
        updateIcon(recording: false)

        guard let rec = recorder else {
            log("⬛ No recorder to stop (dictation)")
            return
        }

        let duration = rec.currentTime
        rec.stop()
        recorder = nil

        guard let url = tempURL else {
            log("⬛ No temp URL (dictation)")
            return
        }

        log("⬛ Dictation stopped — duration: \(String(format: "%.1f", duration))s")

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs[.size] as? Int ?? 0
            log("📁 Dictation file size: \(size) bytes")

            if duration < 0.5 || size < 1000 {
                log("⏭ Dictation too short (\(String(format: "%.1f", duration))s, \(size)b), discarding")
                try? FileManager.default.removeItem(at: url)
                return
            }
        } catch {
            log("❌ Can't read dictation file: \(error)")
            showLocalNotification(title: "Voice to Slop", subtitle: "Dictation failed", body: "Could not read recorded audio")
            try? FileManager.default.removeItem(at: url)
            return
        }

        let dictate = makeDictationClosure(audioPath: url.path)
        dictate { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                try? FileManager.default.removeItem(at: url)
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
