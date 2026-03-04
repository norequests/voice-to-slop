import Cocoa
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var recorder: AVAudioRecorder?
    var tempURL: URL?
    var isRecording = false
    var config: Config = .default
    var setupWindow: SetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(recording: false)
        buildMenu()

        // Request mic permission
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

        // Load config or show setup
        config = Config.load()
        if config.isConfigured {
            startListening()
            print("🎤 Ready — hold \(config.hotkey) to record")
        } else {
            showSetup()
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Telegram Voice Hotkey", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let statusLabel = config.isConfigured
            ? "Hold \(config.hotkey) to record"
            : "Not configured"
        menu.addItem(NSMenuItem(title: statusLabel, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSetup), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func showSetup() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringAllOtherApps: true)

        setupWindow = SetupWindowController(existing: config) { [weak self] newConfig in
            self?.config = newConfig
            self?.buildMenu()
            self?.startListening()
            NSApp.setActivationPolicy(.accessory)
            print("🎤 Config saved — hold \(newConfig.hotkey) to record")
        }
        setupWindow?.showWindow(nil)
        setupWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func startListening() {
        let keyCode = config.keyCode

        // Global key monitor — key down
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == keyCode, !event.isARepeat else { return }
            self?.startRecording()
        }

        // Global key monitor — key up
        NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard event.keyCode == keyCode else { return }
            self?.stopAndSend()
        }

        // Local events (when app is focused)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == keyCode, !event.isARepeat {
                self?.startRecording()
                return nil
            }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.keyCode == keyCode {
                self?.stopAndSend()
                return nil
            }
            return event
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

        // Skip if too short (accidental tap)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs[.size] as? Int ?? 0
            if size < 5000 {
                print("⏭ Too short, skipping")
                try? FileManager.default.removeItem(at: url)
                return
            }
        } catch {}

        sendVoice(fileURL: url) { success in
            try? FileManager.default.removeItem(at: url)
            print(success ? "✅ Sent" : "❌ Failed to send")
        }
    }

    func sendVoice(fileURL: URL, completion: @escaping (Bool) -> Void) {
        let endpoint = URL(string: "https://api.telegram.org/bot\(config.botToken)/sendVoice")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // chat_id
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(config.chatId)\r\n".data(using: .utf8)!)

        // voice file
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
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
