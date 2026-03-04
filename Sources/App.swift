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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
            checkAccessibilityPermission()
            startListening()
            print("🎤 Ready — hold \(config.hotkeyDisplay) to record")
        } else {
            showSetup()
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Telegram Voice Hotkey", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let statusLabel = config.isConfigured
            ? "Hold \(config.hotkeyDisplay) to record"
            : "Not configured"
        menu.addItem(NSMenuItem(title: statusLabel, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSetup), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func checkAccessibilityPermission() {
        // Check without prompting first
        let trusted = AXIsProcessTrusted()
        if !trusted {
            // Prompt once
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            )

            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Grant access in System Settings → Privacy & Security → Accessibility.\n\nAfter granting, quit and reopen the app."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

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

    @objc func showSetup() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ensureEditMenu()

        setupWindow = SetupWindowController(existing: config) { [weak self] newConfig in
            self?.config = newConfig
            self?.buildMenu()
            self?.checkAccessibilityPermission()
            self?.startListening()
            self?.updateLaunchAtLogin(newConfig.launchAtLogin)
            NSApp.setActivationPolicy(.accessory)
            print("🎤 Config saved — hold \(newConfig.hotkeyDisplay) to record")
        }
        setupWindow?.showWindow(nil)
        setupWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    print("✅ Launch at login enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    print("✅ Launch at login disabled")
                }
            } catch {
                print("⚠️ Launch at login failed: \(error)")
            }
        }
    }

    func startListening() {
        let targetKeyCode = config.hotkeyKeyCode
        let targetModifiers = NSEvent.ModifierFlags(rawValue: config.hotkeyModifiers)
            .intersection(.deviceIndependentFlagsMask)
        let mode = config.recordingMode

        func hotkeyMatches(_ event: NSEvent) -> Bool {
            guard event.keyCode == targetKeyCode else { return false }
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return eventMods == targetModifiers
        }

        switch mode {
        case .holdToRecord:
            // Hold mode: key down starts, key up stops
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard hotkeyMatches(event), !event.isARepeat else { return }
                self?.startRecording()
            }
            NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard event.keyCode == targetKeyCode else { return }
                self?.stopAndSend()
            }
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if hotkeyMatches(event), !event.isARepeat {
                    self?.startRecording()
                    return nil
                }
                return event
            }
            NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                if event.keyCode == targetKeyCode {
                    self?.stopAndSend()
                    return nil
                }
                return event
            }

        case .pressToToggle:
            // Toggle mode: hotkey starts recording, ANY key stops & sends
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return }
                if self.isRecording {
                    // Any key stops recording
                    self.stopAndSend()
                } else if hotkeyMatches(event), !event.isARepeat {
                    self.startRecording()
                }
            }
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                if self.isRecording {
                    self.stopAndSend()
                    return nil
                } else if hotkeyMatches(event), !event.isARepeat {
                    self.startRecording()
                    return nil
                }
                return event
            }
        }
    }

    func updateIcon(recording: Bool) {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                button.image = NSImage(
                    systemSymbolName: recording ? "mic.fill" : "mic",
                    accessibilityDescription: "Voice"
                )
                button.image?.isTemplate = true
            }
        }
    }

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
            print("❌ Failed to start recording: \(error)")
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
                print("⏭ Too short")
                try? FileManager.default.removeItem(at: url)
                return
            }
        } catch {}

        sendVoice(fileURL: url) { success in
            try? FileManager.default.removeItem(at: url)
            print(success ? "✅ Sent" : "❌ Failed")
        }
    }

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
