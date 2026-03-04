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

    var _targetKeyCode: CGKeyCode = 0
    var _targetModifiers: UInt = 0
    var _mode: RecordingMode = .holdToRecord

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

    // Rebuild menu contents every time it opens — always fresh status
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

            if !AXIsProcessTrusted() || eventTap == nil {
                let retryItem = NSMenuItem(title: "Retry Permissions", action: #selector(retryPermissions), keyEquivalent: "r")
                retryItem.target = self
                menu.addItem(retryItem)
            }
        } else {
            menu.addItem(NSMenuItem(title: "Not configured", action: nil, keyEquivalent: ""))
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

    // MARK: - Accessibility

    func tryStartListening() {
        if AXIsProcessTrusted() {
            startListening()
            buildMenu()
            log("🎤 Ready — \(config.hotkeyDisplay)")
        } else {
            // Show the system prompt once
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            )

            // Poll every 2 seconds until granted
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

    // MARK: - Edit Menu (for paste in setup)

    func ensureEditMenu() {
        if NSApp.mainMenu == nil {
            let mainMenu = NSMenu()
            let editItem = NSMenuItem()
            editItem.submenu = {
                let m = NSMenu(title: "Edit")
                m.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
                m.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
                m.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
                m.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
                return m
            }()
            mainMenu.addItem(editItem)
            NSApp.mainMenu = mainMenu
        }
    }

    // MARK: - Setup Window

    @objc func showSetup() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ensureEditMenu()

        setupWindow = SetupWindowController(existing: config) { [weak self] newConfig in
            guard let self = self else { return }
            self.config = newConfig
            self.buildMenu()

            // Kill old event tap if re-configuring
            if let oldTap = self.eventTap {
                CGEvent.tapEnable(tap: oldTap, enable: false)
                self.eventTap = nil
            }

            self.tryStartListening()
            self.updateLaunchAtLogin(newConfig.launchAtLogin)
            NSApp.setActivationPolicy(.accessory)
            log("🎤 Config saved — \(newConfig.hotkeyDisplay)")
        }
        setupWindow?.showWindow(nil)
        setupWindow?.window?.makeKeyAndOrderFront(nil)
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
        // Don't create duplicate taps
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

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        log("✅ Event tap active — listening for \(config.hotkeyDisplay)")
    }

    func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it
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

        switch _mode {
        case .holdToRecord:
            if type == .keyDown && hotkeyMatch && !isRepeat {
                DispatchQueue.main.async { self.startRecording() }
                return nil
            }
            if type == .keyUp && keyCode == _targetKeyCode && isRecording {
                DispatchQueue.main.async { self.stopAndSend() }
                return nil
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

    // MARK: - Icon & Visual Feedback

    func updateIcon(recording: Bool) {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }

            if recording {
                // Red circle + mic for recording state
                let image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Recording")
                image?.isTemplate = false

                // Tint it red
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

        // Check file exists and has content
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

        // Convert m4a → ogg/opus for native Telegram voice playback
        let oggURL = url.deletingPathExtension().appendingPathExtension("ogg")
        convertToOgg(input: url, output: oggURL) { [self] success in
            let sendURL = success ? oggURL : url
            let filename = success ? "voice.ogg" : "voice.m4a"
            let mime = success ? "audio/ogg" : "audio/m4a"

            self.sendVoice(fileURL: sendURL, filename: filename, mimeType: mime) { sent in
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: oggURL)
                log(sent ? "✅ Sent to Telegram" : "❌ Send failed")
            }
        }
    }

    func convertToOgg(input: URL, output: URL, completion: @escaping (Bool) -> Void) {
        // Use afconvert (built into macOS) to convert to CAF, then use opusenc if available
        // Simplest: use ffmpeg if installed, otherwise send m4a as-is
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.fileExists(atPath: $0) }

        guard let ffmpegPath = ffmpeg else {
            log("⚠️ ffmpeg not found — sending m4a (install: brew install ffmpeg)")
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

    // MARK: - Telegram API

    func sendVoice(fileURL: URL, filename: String, mimeType: String, completion: @escaping (Bool) -> Void) {
        let endpoint = URL(string: "https://api.telegram.org/bot\(config.botToken)/sendVoice")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(config.chatId)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"voice\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)

        do {
            body.append(try Data(contentsOf: fileURL))
        } catch {
            log("❌ Read error: \(error)")
            completion(false)
            return
        }

        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                log("❌ Network: \(error)")
                completion(false)
                return
            }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if !ok, let data = data, let text = String(data: data, encoding: .utf8) {
                log("❌ API: \(text)")
            }
            completion(ok)
        }.resume()
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
