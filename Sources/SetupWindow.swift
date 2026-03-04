import Cocoa

class SetupWindowController: NSWindowController, NSWindowDelegate {
    var onComplete: ((Config) -> Void)?

    private let botTokenField = NSTextField()
    private let chatIdField = NSTextField()
    private let hotkeyField = HotkeyRecorderView(frame: .zero)
    private let modePopup = NSPopUpButton()

    convenience init(existing: Config, onComplete: @escaping (Config) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Telegram Voice Hotkey — Setup"
        window.center()

        self.init(window: window)
        self.onComplete = onComplete
        window.delegate = self

        let view = NSView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]

        let titleLabel = makeLabel("Configure your Telegram voice hotkey", bold: true)
        titleLabel.frame = NSRect(x: 20, y: 230, width: 380, height: 24)
        view.addSubview(titleLabel)

        // Bot Token
        let tokenLabel = makeLabel("Bot Token:")
        tokenLabel.frame = NSRect(x: 20, y: 195, width: 100, height: 20)
        view.addSubview(tokenLabel)

        botTokenField.frame = NSRect(x: 120, y: 193, width: 280, height: 24)
        botTokenField.placeholderString = "123456:ABC-DEF..."
        botTokenField.stringValue = existing.botToken
        view.addSubview(botTokenField)

        // Chat ID
        let chatLabel = makeLabel("Chat ID:")
        chatLabel.frame = NSRect(x: 20, y: 160, width: 100, height: 20)
        view.addSubview(chatLabel)

        chatIdField.frame = NSRect(x: 120, y: 158, width: 280, height: 24)
        chatIdField.placeholderString = "Your Telegram chat ID"
        chatIdField.stringValue = existing.chatId
        view.addSubview(chatIdField)

        // Hotkey recorder
        let hotkeyLabel = makeLabel("Hotkey:")
        hotkeyLabel.frame = NSRect(x: 20, y: 125, width: 100, height: 20)
        view.addSubview(hotkeyLabel)

        hotkeyField.frame = NSRect(x: 120, y: 119, width: 200, height: 30)
        if !existing.hotkeyDisplay.isEmpty {
            hotkeyField.title = existing.hotkeyDisplay
            hotkeyField.recordedHotkey = HotkeyRecorderView.RecordedHotkey(
                keyCode: existing.hotkeyKeyCode,
                modifiers: existing.hotkeyModifiers,
                displayString: existing.hotkeyDisplay
            )
        }
        view.addSubview(hotkeyField)

        // Recording mode
        let modeLabel = makeLabel("Mode:")
        modeLabel.frame = NSRect(x: 20, y: 90, width: 100, height: 20)
        view.addSubview(modeLabel)

        modePopup.frame = NSRect(x: 120, y: 88, width: 280, height: 24)
        modePopup.addItems(withTitles: [
            "Hold to record (release sends)",
            "Press to start, press any key to stop & send"
        ])
        modePopup.selectItem(at: existing.recordingMode == .pressToToggle ? 1 : 0)
        view.addSubview(modePopup)

        // Help text
        let helpLabel = makeLabel("Click the hotkey button, then press your desired shortcut.", bold: false, size: 11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.frame = NSRect(x: 20, y: 60, width: 380, height: 18)
        view.addSubview(helpLabel)

        // Save button
        let saveButton = NSButton(title: "Save & Start", target: self, action: #selector(saveConfig))
        saveButton.frame = NSRect(x: 290, y: 20, width: 110, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        view.addSubview(saveButton)

        window.contentView = view
    }

    @objc func saveConfig() {
        let token = botTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatId = chatIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !token.isEmpty, !chatId.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Missing fields"
            alert.informativeText = "Bot token and chat ID are required."
            alert.runModal()
            return
        }

        guard let recorded = hotkeyField.recordedHotkey, !recorded.displayString.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No hotkey set"
            alert.informativeText = "Click the hotkey field and press your desired shortcut."
            alert.runModal()
            return
        }

        let mode: RecordingMode = modePopup.indexOfSelectedItem == 1 ? .pressToToggle : .holdToRecord

        let config = Config(
            botToken: token,
            chatId: chatId,
            hotkeyKeyCode: recorded.keyCode,
            hotkeyModifiers: recorded.modifiers,
            hotkeyDisplay: recorded.displayString,
            recordingMode: mode
        )
        config.save()
        onComplete?(config)
        close()
    }

    private func makeLabel(_ text: String, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return label
    }
}
