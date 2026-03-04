import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
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
        } else {
            menu.addItem(NSMenuItem(title: "Not configured", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSetup), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Accessibility

    func tryStartListening() {
        if AXIsProcessTrusted() {
            startListening()
            buildMenu()
            print("🎤 Ready — \(config.hotkeyDisplay)")
        } else {
            // Show the system prompt once
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            )

            // Poll every 2 seconds until granted
            print("⏳ Waiting for Accessibility permission...")
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.accessibilityTimer = nil
                    self?.startListening()
                    self?.buildMenu()
                    self?.updateIcon(recording: false)
                    print("✅ Accessibility granted — hotkey active")
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
            print("🎤 Config saved — \(newConfig.hotkeyDisplay)")
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
                print("⚠️ Launch at login: \(error)")
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
            print("❌ Failed to create event tap")
            return
        }

        self.eventTap = tap
        self._targetKeyCode = CGKeyCode(config.hotkeyKeyCode)
        self._targetModifiers = config.hotkeyModifiers
        self._mode = config.recordingMode

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("✅ Event tap active — listening for \(config.hotkeyDisplay)")
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
        guard !isRecording, config.isConfigured else { return }
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
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            print("🔴 Recording...")
        } catch {
            print("❌ Record failed: \(error)")
            isRecording = false
            updateIcon(recording: false)
        }
    }

    func stopAndSend() {
        guard isRecording else { return }
        isRecording = false
        updateIcon(recording: false)

        recorder?.stop()
        recorder = nil
        print("⬛ Stopped")

        guard let url = tempURL else { return }

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs[.size] as? Int ?? 0
            if size < 5000 {
                print("⏭ Too short, discarding")
                try? FileManager.default.removeItem(at: url)
                return
            }
        } catch {}

        sendVoice(fileURL: url) { success in
            try? FileManager.default.removeItem(at: url)
            print(success ? "✅ Sent to Telegram" : "❌ Send failed")
        }
    }

    // MARK: - Telegram API

    func sendVoice(fileURL: URL, completion: @escaping (Bool) -> Void) {
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
        body.append("Content-Disposition: form-data; name=\"voice\"; filename=\"voice.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)

        do {
            body.append(try Data(contentsOf: fileURL))
        } catch {
            print("❌ Read error: \(error)")
            completion(false)
            return
        }

        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Network: \(error)")
                completion(false)
                return
            }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if !ok, let data = data, let text = String(data: data, encoding: .utf8) {
                print("❌ API: \(text)")
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
