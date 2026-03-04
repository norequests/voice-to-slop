import Cocoa

class SetupWindowController: NSWindowController, NSWindowDelegate {
    var onComplete: ((Config) -> Void)?
    var telegramClient: TelegramClient?

    // Shared fields
    private let chatIdField = NSTextField()
    private let hotkeyField = HotkeyRecorderView(frame: .zero)
    private let modePopup = NSPopUpButton()
    private let launchAtLoginCheck = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let sendModePopup = NSPopUpButton()

    // Bot API fields
    private let botTokenField = NSTextField()
    private let botTokenLabel = NSTextField(labelWithString: "Bot Token:")

    // User API fields
    private let apiIdField = NSTextField()
    private let apiHashField = NSTextField()
    private let phoneField = NSTextField()
    private let codeField = NSTextField()
    private let apiIdLabel = NSTextField(labelWithString: "API ID:")
    private let apiHashLabel = NSTextField(labelWithString: "API Hash:")
    private let phoneLabel = NSTextField(labelWithString: "Phone:")
    private let codeLabel = NSTextField(labelWithString: "Code:")
    private let loginButton = NSButton(title: "Send Code", target: nil, action: nil)
    private let loginStatus = NSTextField(labelWithString: "")
    private let apiHelpLabel = NSTextField(labelWithString: "")

    private var contentView: NSView!
    private var existingConfig: Config = .default

    convenience init(existing: Config, onComplete: @escaping (Config) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Telegram Voice Hotkey"
        window.center()

        self.init(window: window)
        self.onComplete = onComplete
        self.existingConfig = existing
        window.delegate = self

        contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        var y = 380

        // Send Mode
        let sendLabel = makeLabel("Send as:")
        sendLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(sendLabel)

        sendModePopup.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        sendModePopup.addItems(withTitles: [
            "Bot API (message appears from your bot)",
            "User API (message appears from you)"
        ])
        sendModePopup.selectItem(at: existing.sendMode == .userAPI ? 1 : 0)
        sendModePopup.target = self
        sendModePopup.action = #selector(sendModeChanged)
        contentView.addSubview(sendModePopup)
        y -= 35

        // ── Bot API fields ──
        botTokenLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(botTokenLabel)

        botTokenField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        botTokenField.placeholderString = "123456:ABC-DEF..."
        botTokenField.stringValue = existing.botToken
        botTokenField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        botTokenField.usesSingleLineMode = true
        botTokenField.cell?.isScrollable = true
        contentView.addSubview(botTokenField)

        // ── User API fields ──
        apiIdLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(apiIdLabel)

        apiIdField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        apiIdField.placeholderString = "From my.telegram.org"
        apiIdField.stringValue = existing.apiId > 0 ? String(existing.apiId) : ""
        apiIdField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        contentView.addSubview(apiIdField)
        y -= 35

        apiHashLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(apiHashLabel)

        apiHashField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        apiHashField.placeholderString = "From my.telegram.org"
        apiHashField.stringValue = existing.apiHash
        apiHashField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        apiHashField.usesSingleLineMode = true
        apiHashField.cell?.isScrollable = true
        contentView.addSubview(apiHashField)

        apiHelpLabel.frame = NSRect(x: 115, y: y - 20, width: 385, height: 16)
        apiHelpLabel.font = .systemFont(ofSize: 10)
        apiHelpLabel.textColor = .secondaryLabelColor
        apiHelpLabel.stringValue = "Get credentials at my.telegram.org → API Development Tools"
        contentView.addSubview(apiHelpLabel)
        y -= 35

        if existing.userLoggedIn {
            // Already authenticated — show status instead of login fields
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

            // Hide login fields
            phoneLabel.isHidden = true
            phoneField.isHidden = true
            codeLabel.isHidden = true
            codeField.isHidden = true
            y -= 40
        } else {
            // Not authenticated — show login flow
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
            y -= 35

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
            y -= 40
        }

        // ── Shared fields ──
        let chatLabel = makeLabel("Chat ID:")
        chatLabel.frame = NSRect(x: 20, y: y, width: 90, height: 20)
        contentView.addSubview(chatLabel)

        chatIdField.frame = NSRect(x: 115, y: y - 2, width: 385, height: 24)
        chatIdField.placeholderString = "Chat ID (your bot's chat or any chat)"
        chatIdField.stringValue = existing.chatId
        chatIdField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        chatIdField.usesSingleLineMode = true
        chatIdField.cell?.isScrollable = true
        contentView.addSubview(chatIdField)
        y -= 35

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
        updateFieldVisibility()
    }

    @objc func sendModeChanged() {
        updateFieldVisibility()
    }

    func updateFieldVisibility() {
        let isUserMode = sendModePopup.indexOfSelectedItem == 1

        // Bot API fields
        botTokenLabel.isHidden = isUserMode
        botTokenField.isHidden = isUserMode

        // User API fields
        apiIdLabel.isHidden = !isUserMode
        apiIdField.isHidden = !isUserMode
        apiHashLabel.isHidden = !isUserMode
        apiHashField.isHidden = !isUserMode
        apiHelpLabel.isHidden = !isUserMode
        phoneLabel.isHidden = !isUserMode
        phoneField.isHidden = !isUserMode
        codeLabel.isHidden = !isUserMode
        codeField.isHidden = !isUserMode
        loginButton.isHidden = !isUserMode
        loginStatus.isHidden = !isUserMode
    }

    @objc func startReauth() {
        // Clear TDLib session data to force re-login
        let tdlibDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TelegramVoiceHotkey/tdlib")
        try? FileManager.default.removeItem(at: tdlibDir)

        existingConfig.userLoggedIn = false
        existingConfig.save()

        // Show login fields
        phoneLabel.isHidden = false
        phoneField.isHidden = false
        codeLabel.isHidden = false
        codeField.isHidden = false
        loginStatus.stringValue = "Enter phone to re-authenticate"
        loginStatus.textColor = .secondaryLabelColor
        loginButton.title = "Send Code"
        loginButton.action = #selector(handleLogin)
        loginButton.isEnabled = true
        telegramClient = nil
    }

    @objc func handleLogin() {
        guard let apiId = Int(apiIdField.stringValue.trimmingCharacters(in: .whitespaces)),
              apiId > 0 else {
            showAlert("Invalid API ID")
            return
        }

        let apiHash = apiHashField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !apiHash.isEmpty else {
            showAlert("API Hash is required")
            return
        }

        if telegramClient == nil {
            telegramClient = TelegramClient(apiId: apiId, apiHash: apiHash)
            telegramClient?.onAuthStateChanged = { [weak self] state in
                self?.handleAuthState(state)
            }
            telegramClient?.onError = { [weak self] msg in
                self?.loginStatus.stringValue = "❌ \(msg)"
                self?.loginStatus.textColor = .systemRed
            }
            telegramClient?.start()
        }

        let phone = phoneField.stringValue.trimmingCharacters(in: .whitespaces)
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)

        if !code.isEmpty {
            telegramClient?.sendCode(code)
            loginButton.title = "Verifying..."
            loginButton.isEnabled = false
        } else if !phone.isEmpty {
            telegramClient?.sendPhoneNumber(phone)
            loginButton.title = "Verify Code"
            loginStatus.stringValue = "📱 Code sent to Telegram"
            loginStatus.textColor = .systemOrange
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
        }
    }

    @objc func saveConfig() {
        let chatId = chatIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatId.isEmpty else {
            showAlert("Chat ID is required")
            return
        }

        guard let recorded = hotkeyField.recordedHotkey, !recorded.displayString.isEmpty else {
            showAlert("Click the hotkey field and press your desired shortcut.")
            return
        }

        let isUserMode = sendModePopup.indexOfSelectedItem == 1
        let mode: RecordingMode = modePopup.indexOfSelectedItem == 1 ? .pressToToggle : .holdToRecord
        let launchAtLogin = launchAtLoginCheck.state == .on

        if isUserMode {
            guard let apiId = Int(apiIdField.stringValue.trimmingCharacters(in: .whitespaces)), apiId > 0 else {
                showAlert("Valid API ID required for User API mode")
                return
            }
            let apiHash = apiHashField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !apiHash.isEmpty else {
                showAlert("API Hash required for User API mode")
                return
            }
            let loggedIn = telegramClient?.isLoggedIn ?? existingConfig.userLoggedIn

            let config = Config(
                botToken: botTokenField.stringValue.trimmingCharacters(in: .whitespaces),
                chatId: chatId,
                hotkeyKeyCode: recorded.keyCode,
                hotkeyModifiers: recorded.modifiers,
                hotkeyDisplay: recorded.displayString,
                recordingMode: mode,
                launchAtLogin: launchAtLogin,
                sendMode: .userAPI,
                apiId: apiId,
                apiHash: apiHash,
                userLoggedIn: loggedIn
            )
            config.save()
            onComplete?(config)
        } else {
            let token = botTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                showAlert("Bot token required for Bot API mode")
                return
            }

            let config = Config(
                botToken: token,
                chatId: chatId,
                hotkeyKeyCode: recorded.keyCode,
                hotkeyModifiers: recorded.modifiers,
                hotkeyDisplay: recorded.displayString,
                recordingMode: mode,
                launchAtLogin: launchAtLogin,
                sendMode: .botAPI,
                apiId: 0,
                apiHash: "",
                userLoggedIn: false
            )
            config.save()
            onComplete?(config)
        }
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
