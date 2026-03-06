import Cocoa

class SetupWindowController: NSWindowController, NSWindowDelegate {
    var onComplete: ((Config) -> Void)?
    var telegramClient: TelegramClient?

    // Fields
    private let chatIdField = NSTextField()
    private let hotkeyField = HotkeyRecorderView(frame: .zero)
    private let screenshotHotkeyField = HotkeyRecorderView(frame: .zero)
    private let dictationHotkeyField = HotkeyRecorderView(frame: .zero)
    private let modePopup = NSPopUpButton()
    private let transcriptionPopup = NSPopUpButton()
    private let geminiKeyField = NSTextField()
    private var geminiLabel: NSTextField?
    // Custom endpoint fields
    private let customEndpointField = NSTextField()
    private let customApiKeyField = NSTextField()
    private let customModelField = NSTextField()
    private var customEndpointLabel: NSTextField?
    private var customApiKeyLabel: NSTextField?
    private var customModelLabel: NSTextField?
    // Send-as-text checkbox
    private let sendAsTextCheck = NSButton(checkboxWithTitle: "Send voice as transcribed text (not audio)", target: nil, action: nil)
    private let downloadModelButton = NSButton(title: "Download Model (~460MB)", target: nil, action: nil)
    private let modelStatusLabel = NSTextField(labelWithString: "")
    private let launchAtLoginCheck = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private var loginRowY: Int = 0

    // User API fields
    private let apiIdField = NSTextField()
    private let apiHashField = NSTextField()
    private let phoneField = NSTextField()
    private let codeField = NSTextField()
    private let loginButton = NSButton(title: "Send Code", target: nil, action: nil)
    private let loginStatus = NSTextField(labelWithString: "")

    private var contentView: NSView!
    private var existingConfig: Config = .default

    convenience init(existing: Config, existingClient: TelegramClient? = nil, onComplete: @escaping (Config) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice to Slop"
        window.center()

        self.init(window: window)
        self.onComplete = onComplete
        self.existingConfig = existing
        self.telegramClient = existingClient
        window.delegate = self

        // Edit menu for paste support
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = {
            let m = NSMenu(title: "Edit")
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            return m
        }()
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        var y = 665

        // ── Telegram API Credentials ──
        let credHeader = makeLabel("Telegram API", bold: true, size: 14)
        credHeader.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        contentView.addSubview(credHeader)

        let helpLabel = makeLabel("Get from my.telegram.org → API Development Tools")
        helpLabel.frame = NSRect(x: 180, y: y + 1, width: 350, height: 16)
        helpLabel.font = .systemFont(ofSize: 10)
        helpLabel.textColor = .secondaryLabelColor
        contentView.addSubview(helpLabel)
        y -= 30

        let apiIdLabel = makeLabel("API ID:")
        apiIdLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(apiIdLabel)

        apiIdField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        apiIdField.placeholderString = "12345678"
        apiIdField.stringValue = existing.apiId > 0 ? String(existing.apiId) : ""
        apiIdField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        contentView.addSubview(apiIdField)
        y -= 30

        let apiHashLabel = makeLabel("API Hash:")
        apiHashLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(apiHashLabel)

        apiHashField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        apiHashField.placeholderString = "abc123def456..."
        apiHashField.stringValue = existing.apiHash
        apiHashField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        apiHashField.usesSingleLineMode = true
        apiHashField.cell?.isScrollable = true
        contentView.addSubview(apiHashField)
        y -= 35

        // ── Login ──
        if existing.userLoggedIn {
            loginStatus.frame = NSRect(x: 115, y: y, width: 300, height: 20)
            loginStatus.stringValue = "✅ Telegram authenticated"
            loginStatus.font = .systemFont(ofSize: 13)
            loginStatus.textColor = .systemGreen
            contentView.addSubview(loginStatus)

            loginButton.frame = NSRect(x: 420, y: y - 3, width: 80, height: 26)
            loginButton.title = "Re-auth"
            loginButton.bezelStyle = .rounded
            loginButton.target = self
            loginButton.action = #selector(startReauth)
            contentView.addSubview(loginButton)

            // Store the login row Y so Re-auth can position phone/code fields here
            loginRowY = y

            // Reserve space for phone/code fields (shown on Re-auth)
            y -= 95
        } else {
            let phoneLabel = makeLabel("Phone:")
            phoneLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
            contentView.addSubview(phoneLabel)

            phoneField.frame = NSRect(x: 115, y: y - 2, width: 200, height: 24)
            phoneField.placeholderString = "+1234567890"
            phoneField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            contentView.addSubview(phoneField)

            loginButton.frame = NSRect(x: 325, y: y - 3, width: 100, height: 26)
            loginButton.bezelStyle = .rounded
            loginButton.target = self
            loginButton.action = #selector(handleLogin)
            contentView.addSubview(loginButton)
            y -= 30

            let codeLabel = makeLabel("Code:")
            codeLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
            contentView.addSubview(codeLabel)

            codeField.frame = NSRect(x: 115, y: y - 2, width: 200, height: 24)
            codeField.placeholderString = "12345"
            codeField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            contentView.addSubview(codeField)

            loginStatus.frame = NSRect(x: 325, y: y, width: 175, height: 20)
            loginStatus.font = .systemFont(ofSize: 11)
            loginStatus.textColor = .secondaryLabelColor
            contentView.addSubview(loginStatus)
            y -= 35
        }

        // ── Chat ID ──
        let divider1 = NSBox()
        divider1.boxType = .separator
        divider1.frame = NSRect(x: 20, y: y + 5, width: 480, height: 1)
        contentView.addSubview(divider1)
        y -= 5

        let chatLabel = makeLabel("Chat ID:")
        chatLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(chatLabel)

        chatIdField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        chatIdField.placeholderString = "Target chat ID (numeric)"
        chatIdField.stringValue = existing.chatId
        chatIdField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        chatIdField.usesSingleLineMode = true
        chatIdField.cell?.isScrollable = true
        contentView.addSubview(chatIdField)
        y -= 35

        // ── Hotkey ──
        let hotkeyLabel = makeLabel("Hotkey:")
        hotkeyLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(hotkeyLabel)

        hotkeyField.frame = NSRect(x: 115, y: y - 4, width: 200, height: 28)
        if !existing.hotkeyDisplay.isEmpty {
            hotkeyField.title = existing.hotkeyDisplay
            hotkeyField.recordedHotkey = HotkeyRecorderView.RecordedHotkey(
                keyCode: existing.hotkeyKeyCode,
                modifiers: existing.hotkeyModifiers,
                displayString: existing.hotkeyDisplay
            )
        }
        contentView.addSubview(hotkeyField)
        y -= 30

        let ssHotkeyLabel = makeLabel("Screenshot:")
        ssHotkeyLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(ssHotkeyLabel)

        screenshotHotkeyField.frame = NSRect(x: 115, y: y - 4, width: 200, height: 28)
        if !existing.screenshotHotkeyDisplay.isEmpty {
            screenshotHotkeyField.title = existing.screenshotHotkeyDisplay
            screenshotHotkeyField.recordedHotkey = HotkeyRecorderView.RecordedHotkey(
                keyCode: existing.screenshotHotkeyKeyCode,
                modifiers: existing.screenshotHotkeyModifiers,
                displayString: existing.screenshotHotkeyDisplay
            )
        }
        contentView.addSubview(screenshotHotkeyField)

        let ssHelp = makeLabel("Hold to screenshot + record voice")
        ssHelp.frame = NSRect(x: 320, y: y - 2, width: 200, height: 16)
        ssHelp.font = .systemFont(ofSize: 10)
        ssHelp.textColor = .secondaryLabelColor
        contentView.addSubview(ssHelp)
        y -= 35

        let dictationHotkeyLabel = makeLabel("Dictation:")
        dictationHotkeyLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(dictationHotkeyLabel)

        dictationHotkeyField.frame = NSRect(x: 115, y: y - 4, width: 200, height: 28)
        if !existing.dictationDisplay.isEmpty {
            dictationHotkeyField.title = existing.dictationDisplay
            dictationHotkeyField.recordedHotkey = HotkeyRecorderView.RecordedHotkey(
                keyCode: existing.dictationKeyCode,
                modifiers: existing.dictationModifiers,
                displayString: existing.dictationDisplay
            )
        }
        contentView.addSubview(dictationHotkeyField)

        let dictationHelp = makeLabel("Record voice and copy transcription to clipboard")
        dictationHelp.frame = NSRect(x: 320, y: y - 2, width: 200, height: 16)
        dictationHelp.font = .systemFont(ofSize: 10)
        dictationHelp.textColor = .secondaryLabelColor
        contentView.addSubview(dictationHelp)
        y -= 35

        let modeLabel = makeLabel("Mode:")
        modeLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(modeLabel)

        modePopup.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        modePopup.addItems(withTitles: [
            "Hold to record (release sends)",
            "Press to start, any key stops"
        ])
        modePopup.selectItem(at: existing.recordingMode == .pressToToggle ? 1 : 0)
        contentView.addSubview(modePopup)
        y -= 30

        // ── Transcription ──
        let transcriptionLabel = makeLabel("Transcription:")
        transcriptionLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(transcriptionLabel)

        transcriptionPopup.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        transcriptionPopup.addItems(withTitles: [
            "Local (whisper.cpp — offline, ~10s)",
            "Gemini (cloud — fast, needs API key)",
            "Custom endpoint (OpenAI-compatible)"
        ])
        let modeIndex: Int
        switch existing.transcriptionMode {
        case "gemini": modeIndex = 1
        case "custom": modeIndex = 2
        default:       modeIndex = 0
        }
        transcriptionPopup.selectItem(at: modeIndex)
        transcriptionPopup.target = self
        transcriptionPopup.action = #selector(transcriptionModeChanged)
        contentView.addSubview(transcriptionPopup)
        y -= 30

        // ── Gemini key ──
        let geminiLabel_ = makeLabel("Gemini Key:")
        self.geminiLabel = geminiLabel_
        let geminiLabel = geminiLabel_
        geminiLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(geminiLabel)

        geminiKeyField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        geminiKeyField.placeholderString = "AIza..."
        geminiKeyField.stringValue = existing.geminiApiKey
        geminiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        geminiKeyField.usesSingleLineMode = true
        geminiKeyField.cell?.isScrollable = true
        geminiKeyField.isHidden = existing.transcriptionMode != "gemini"
        contentView.addSubview(geminiKeyField)
        geminiLabel.isHidden = existing.transcriptionMode != "gemini"

        // ── Custom endpoint fields ──
        let customEndpointLabel_ = makeLabel("Endpoint URL:")
        self.customEndpointLabel = customEndpointLabel_
        customEndpointLabel_.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(customEndpointLabel_)

        customEndpointField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        customEndpointField.placeholderString = "https://api.openai.com  (or your whisper server)"
        customEndpointField.stringValue = existing.customEndpointUrl
        customEndpointField.usesSingleLineMode = true
        customEndpointField.cell?.isScrollable = true
        customEndpointField.isHidden = existing.transcriptionMode != "custom"
        contentView.addSubview(customEndpointField)
        customEndpointLabel_.isHidden = existing.transcriptionMode != "custom"
        y -= 30

        let customApiKeyLabel_ = makeLabel("API Key:")
        self.customApiKeyLabel = customApiKeyLabel_
        customApiKeyLabel_.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(customApiKeyLabel_)

        customApiKeyField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        customApiKeyField.placeholderString = "sk-... (leave blank for no auth)"
        customApiKeyField.stringValue = existing.customApiKey
        customApiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        customApiKeyField.usesSingleLineMode = true
        customApiKeyField.cell?.isScrollable = true
        customApiKeyField.isHidden = existing.transcriptionMode != "custom"
        contentView.addSubview(customApiKeyField)
        customApiKeyLabel_.isHidden = existing.transcriptionMode != "custom"
        y -= 30

        let customModelLabel_ = makeLabel("Model:")
        self.customModelLabel = customModelLabel_
        customModelLabel_.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(customModelLabel_)

        customModelField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        customModelField.placeholderString = "whisper-1 (default)"
        customModelField.stringValue = existing.customModelName
        customModelField.usesSingleLineMode = true
        customModelField.cell?.isScrollable = true
        customModelField.isHidden = existing.transcriptionMode != "custom"
        contentView.addSubview(customModelField)
        customModelLabel_.isHidden = existing.transcriptionMode != "custom"

        // ── Download model button (for local mode) ──
        downloadModelButton.frame = NSRect(x: 115, y: y - 2, width: 200, height: 24)
        downloadModelButton.bezelStyle = .rounded
        downloadModelButton.target = self
        downloadModelButton.action = #selector(downloadWhisperModel)
        contentView.addSubview(downloadModelButton)

        modelStatusLabel.frame = NSRect(x: 320, y: y, width: 180, height: 16)
        modelStatusLabel.font = .systemFont(ofSize: 10)
        modelStatusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(modelStatusLabel)

        updateTranscriptionUI(mode: existing.transcriptionMode)
        y -= 30

        // ── Send-as-text option ──
        sendAsTextCheck.frame = NSRect(x: 115, y: y, width: 385, height: 20)
        sendAsTextCheck.state = existing.sendVoiceAsText ? .on : .off
        sendAsTextCheck.toolTip = "When enabled, voice recordings are transcribed and sent as text messages instead of voice notes."
        contentView.addSubview(sendAsTextCheck)
        y -= 30

        launchAtLoginCheck.frame = NSRect(x: 115, y: y, width: 380, height: 20)
        launchAtLoginCheck.state = existing.launchAtLogin ? .on : .off
        contentView.addSubview(launchAtLoginCheck)

        // Save button
        let saveButton = NSButton(title: "Save & Start", target: self, action: #selector(saveConfig))
        saveButton.frame = NSRect(x: 380, y: 15, width: 120, height: 36)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)

        window.contentView = contentView
    }

    @objc func transcriptionModeChanged() {
        let mode: String
        switch transcriptionPopup.indexOfSelectedItem {
        case 1:  mode = "gemini"
        case 2:  mode = "custom"
        default: mode = "local"
        }
        updateTranscriptionUI(mode: mode)
    }

    private func updateTranscriptionUI(mode: String) {
        let isGemini = mode == "gemini"
        let isCustom = mode == "custom"
        let isLocal  = mode == "local"

        geminiKeyField.isHidden   = !isGemini
        geminiLabel?.isHidden     = !isGemini

        customEndpointField.isHidden   = !isCustom
        customApiKeyField.isHidden     = !isCustom
        customModelField.isHidden      = !isCustom
        customEndpointLabel?.isHidden  = !isCustom
        customApiKeyLabel?.isHidden    = !isCustom
        customModelLabel?.isHidden     = !isCustom

        downloadModelButton.isHidden = !isLocal || whisperModelExists()
        modelStatusLabel.isHidden    = !isLocal
        if isLocal {
            let hasModel = whisperModelExists()
            downloadModelButton.isHidden = hasModel
            if hasModel {
                let modelName = whisperModelName()
                modelStatusLabel.stringValue = "✅ \(modelName) installed"
                modelStatusLabel.textColor = .systemGreen
            } else {
                modelStatusLabel.stringValue = "No model found"
                modelStatusLabel.textColor = .systemOrange
            }
        }
    }

    private func whisperModelDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TelegramVoiceHotkey/models")
    }

    private func whisperModelExists() -> Bool {
        let dir = whisperModelDir().path
        for name in ["ggml-small.en.bin", "ggml-base.en.bin"] {
            if FileManager.default.fileExists(atPath: "\(dir)/\(name)") { return true }
        }
        return false
    }

    private func whisperModelName() -> String {
        let dir = whisperModelDir().path
        if FileManager.default.fileExists(atPath: "\(dir)/ggml-small.en.bin") { return "small.en" }
        if FileManager.default.fileExists(atPath: "\(dir)/ggml-base.en.bin") { return "base.en" }
        return "none"
    }

    @objc func downloadWhisperModel() {
        downloadModelButton.isEnabled = false
        downloadModelButton.title = "Downloading..."
        modelStatusLabel.stringValue = "⏳ Downloading small.en..."
        modelStatusLabel.textColor = .secondaryLabelColor

        let modelDir = whisperModelDir()
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let destPath = modelDir.appendingPathComponent("ggml-small.en.bin")

        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.modelStatusLabel.stringValue = "❌ \(error.localizedDescription)"
                    self.modelStatusLabel.textColor = .systemRed
                    self.downloadModelButton.isEnabled = true
                    self.downloadModelButton.title = "Retry Download"
                    return
                }
                guard let tempURL = tempURL else {
                    self.modelStatusLabel.stringValue = "❌ Download failed"
                    self.modelStatusLabel.textColor = .systemRed
                    self.downloadModelButton.isEnabled = true
                    self.downloadModelButton.title = "Retry Download"
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destPath)
                    try FileManager.default.moveItem(at: tempURL, to: destPath)
                    self.modelStatusLabel.stringValue = "✅ small.en installed"
                    self.modelStatusLabel.textColor = .systemGreen
                    self.downloadModelButton.isHidden = true
                    log("📥 Whisper small.en model downloaded")
                } catch {
                    self.modelStatusLabel.stringValue = "❌ \(error.localizedDescription)"
                    self.modelStatusLabel.textColor = .systemRed
                    self.downloadModelButton.isEnabled = true
                    self.downloadModelButton.title = "Retry Download"
                }
            }
        }
        task.resume()
    }

    @objc func startReauth() {
        loginStatus.stringValue = "Logging out..."
        loginStatus.textColor = .secondaryLabelColor
        loginButton.isEnabled = false

        existingConfig.userLoggedIn = false
        existingConfig.save()

        // Use logOut — TDLib will go closed → recreate → waitingForPhoneNumber
        let client = telegramClient ?? (NSApp.delegate as? AppDelegate)?.telegramClient
        client?.onAuthStateChanged = { [weak self] state in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.handleAuthState(state)
                if state == .waitingForPhone {
                    self.showReauthFields()
                }
            }
        }
        client?.logOut()

        // Fallback: if logOut doesn't trigger state change in 5s, show fields anyway
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            if self.loginButton.title == "Logging out..." {
                self.showReauthFields()
            }
        }
    }

    private func showReauthFields() {
        loginStatus.stringValue = "Enter phone to re-authenticate"
        loginStatus.textColor = .secondaryLabelColor
        loginButton.title = "Send Code"
        loginButton.action = #selector(handleLogin)
        loginButton.isEnabled = true

        let y = loginRowY - 30
        if phoneField.superview == nil {
            phoneField.frame = NSRect(x: 115, y: y, width: 200, height: 24)
            phoneField.placeholderString = "+1234567890"
            phoneField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            window?.contentView?.addSubview(phoneField)
        }
        phoneField.frame = NSRect(x: 115, y: y, width: 200, height: 24)
        phoneField.isHidden = false

        if codeField.superview == nil {
            codeField.frame = NSRect(x: 115, y: y - 30, width: 200, height: 24)
            codeField.placeholderString = "12345"
            codeField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            window?.contentView?.addSubview(codeField)
        }
        codeField.frame = NSRect(x: 115, y: y - 30, width: 200, height: 24)
        codeField.isHidden = false
    }

    @objc func handleLogin() {
        guard let apiId = Int(apiIdField.stringValue.trimmingCharacters(in: .whitespaces)),
              apiId > 0 else {
            showAlert("Invalid API ID — get one from my.telegram.org")
            return
        }

        let apiHash = apiHashField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !apiHash.isEmpty else {
            showAlert("API Hash is required — get it from my.telegram.org")
            return
        }

        guard TelegramClient.isAvailable else {
            showAlert("TDLib not found. Run scripts/setup-tdlib.sh to build it, then rebuild the app.")
            return
        }

        // Ensure we have a client (reuse AppDelegate's if possible)
        if telegramClient == nil {
            if let appClient = (NSApp.delegate as? AppDelegate)?.telegramClient {
                telegramClient = appClient
            } else {
                let client = TelegramClient(apiId: apiId, apiHash: apiHash)
                telegramClient = client
                client.start()
                // Also set on AppDelegate so it's shared
                (NSApp.delegate as? AppDelegate)?.telegramClient = client
            }
        }

        // Wire callbacks
        telegramClient?.onAuthStateChanged = { [weak self] state in
            DispatchQueue.main.async { self?.handleAuthState(state) }
        }
        telegramClient?.onError = { [weak self] msg in
            DispatchQueue.main.async {
                self?.loginStatus.stringValue = "❌ \(msg)"
                self?.loginStatus.textColor = .systemRed
            }
        }

        let phone = phoneField.stringValue.trimmingCharacters(in: .whitespaces)
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)

        if !code.isEmpty {
            telegramClient?.sendCode(code)
            loginButton.title = "Verifying..."
            loginButton.isEnabled = false
        } else if !phone.isEmpty {
            // If client is still initializing, queue the phone send
            if telegramClient?.authState == .waitingForPhone {
                telegramClient?.sendPhoneNumber(phone)
                loginButton.title = "Verify Code"
                loginStatus.stringValue = "📱 Code sent to Telegram"
                loginStatus.textColor = .systemOrange
            } else {
                // TDLib not ready yet — wait for waitingForPhone
                loginButton.title = "Connecting..."
                loginButton.isEnabled = false
                loginStatus.stringValue = "Waiting for TDLib..."
                loginStatus.textColor = .secondaryLabelColor

                telegramClient?.onAuthStateChanged = { [weak self] state in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if state == .waitingForPhone {
                            self.telegramClient?.sendPhoneNumber(phone)
                            self.loginButton.title = "Verify Code"
                            self.loginButton.isEnabled = true
                            self.loginStatus.stringValue = "📱 Code sent to Telegram"
                            self.loginStatus.textColor = .systemOrange
                            // Restore normal callback
                            self.telegramClient?.onAuthStateChanged = { [weak self] s in
                                DispatchQueue.main.async { self?.handleAuthState(s) }
                            }
                        } else if state == .ready {
                            self.telegramClient?.onAuthStateChanged = { [weak self] s in
                                DispatchQueue.main.async { self?.handleAuthState(s) }
                            }
                        }
                        self.handleAuthState(state)
                    }
                }
            }
        } else {
            showAlert("Enter your phone number")
        }
    }

    func handleAuthState(_ state: TelegramClient.AuthState) {
        switch state {
        case .waitingForPhone:
            loginButton.title = "Send Code"
            loginButton.isEnabled = true
            loginStatus.stringValue = "Enter phone number"
            loginStatus.textColor = .secondaryLabelColor
        case .waitingForCode:
            loginButton.title = "Verify Code"
            loginButton.isEnabled = true
            loginStatus.stringValue = "📱 Enter code from Telegram"
            loginStatus.textColor = .systemOrange
        case .waitingForPassword:
            loginButton.title = "Submit Password"
            loginButton.isEnabled = true
            loginStatus.stringValue = "🔐 2FA password required"
            loginStatus.textColor = .systemOrange
            codeField.placeholderString = "2FA password"
        case .ready:
            loginButton.title = "✅ Logged In"
            loginButton.isEnabled = false
            loginStatus.stringValue = "✅ Authenticated"
            loginStatus.textColor = .systemGreen
        case .closed:
            loginButton.title = "Send Code"
            loginButton.isEnabled = true
        case .initializing, .loggingOut:
            loginButton.isEnabled = false
            loginStatus.stringValue = "⏳ \(state)..."
            loginStatus.textColor = .secondaryLabelColor
        }
    }

    @objc func saveConfig() {
        guard let apiId = Int(apiIdField.stringValue.trimmingCharacters(in: .whitespaces)),
              apiId > 0 else {
            showAlert("Valid API ID required — get one from my.telegram.org")
            return
        }

        let apiHash = apiHashField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !apiHash.isEmpty else {
            showAlert("API Hash required — get it from my.telegram.org")
            return
        }

        let chatId = chatIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatId.isEmpty else {
            showAlert("Chat ID is required")
            return
        }

        guard let recorded = hotkeyField.recordedHotkey, !recorded.displayString.isEmpty else {
            showAlert("Click the hotkey field and press your desired shortcut.")
            return
        }

        let mode: RecordingMode = modePopup.indexOfSelectedItem == 1 ? .pressToToggle : .holdToRecord
        let launchAtLogin = launchAtLoginCheck.state == .on
        let loggedIn = telegramClient?.isLoggedIn ?? existingConfig.userLoggedIn

        let config = Config(
            chatId: chatId,
            hotkeyKeyCode: recorded.keyCode,
            hotkeyModifiers: recorded.modifiers,
            hotkeyDisplay: recorded.displayString,
            recordingMode: mode,
            launchAtLogin: launchAtLogin,
            apiId: apiId,
            apiHash: apiHash,
            userLoggedIn: loggedIn,
            screenshotHotkeyKeyCode: screenshotHotkeyField.recordedHotkey?.keyCode ?? 0,
            screenshotHotkeyModifiers: screenshotHotkeyField.recordedHotkey?.modifiers ?? 0,
            screenshotHotkeyDisplay: screenshotHotkeyField.recordedHotkey?.displayString ?? "",
            dictationKeyCode: dictationHotkeyField.recordedHotkey?.keyCode ?? 0x0B,
            dictationModifiers: dictationHotkeyField.recordedHotkey?.modifiers ?? 786432,
            dictationDisplay: dictationHotkeyField.recordedHotkey?.displayString ?? "⌃⌥B",
            transcriptionMode: {
                switch transcriptionPopup.indexOfSelectedItem {
                case 1:  return "gemini"
                case 2:  return "custom"
                default: return "local"
                }
            }(),
            geminiApiKey: geminiKeyField.stringValue.trimmingCharacters(in: .whitespaces),
            customEndpointUrl: customEndpointField.stringValue.trimmingCharacters(in: .whitespaces),
            customApiKey: customApiKeyField.stringValue.trimmingCharacters(in: .whitespaces),
            customModelName: customModelField.stringValue.trimmingCharacters(in: .whitespaces),
            sendVoiceAsText: sendAsTextCheck.state == .on
        )
        config.save()
        onComplete?(config)
        close()
    }

    private func showAlert(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.runModal()
    }

    private func makeLabel(_ text: String, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return label
    }
}
