import Cocoa

class SetupWindowController: NSWindowController, NSWindowDelegate {
    var onComplete: ((Config) -> Void)?

    private let botTokenField = NSTextField()
    private let chatIdField = NSTextField()
    private let hotkeyPopup = NSPopUpButton()

    convenience init(existing: Config, onComplete: @escaping (Config) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
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
        titleLabel.frame = NSRect(x: 20, y: 210, width: 380, height: 24)
        view.addSubview(titleLabel)

        let tokenLabel = makeLabel("Bot Token:")
        tokenLabel.frame = NSRect(x: 20, y: 175, width: 100, height: 20)
        view.addSubview(tokenLabel)

        botTokenField.frame = NSRect(x: 120, y: 173, width: 280, height: 24)
        botTokenField.placeholderString = "123456:ABC-DEF..."
        botTokenField.stringValue = existing.botToken
        view.addSubview(botTokenField)

        let chatLabel = makeLabel("Chat ID:")
        chatLabel.frame = NSRect(x: 20, y: 140, width: 100, height: 20)
        view.addSubview(chatLabel)

        chatIdField.frame = NSRect(x: 120, y: 138, width: 280, height: 24)
        chatIdField.placeholderString = "Your Telegram chat ID"
        chatIdField.stringValue = existing.chatId
        view.addSubview(chatIdField)

        let hotkeyLabel = makeLabel("Hotkey:")
        hotkeyLabel.frame = NSRect(x: 20, y: 105, width: 100, height: 20)
        view.addSubview(hotkeyLabel)

        hotkeyPopup.frame = NSRect(x: 120, y: 103, width: 120, height: 24)
        let keys = ["F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "F13", "F14", "F15", "F16"]
        hotkeyPopup.addItems(withTitles: keys)
        if let idx = keys.firstIndex(of: existing.hotkey.uppercased()) {
            hotkeyPopup.selectItem(at: idx)
        }
        view.addSubview(hotkeyPopup)

        let helpLabel = makeLabel("Hold the hotkey to record, release to send.", bold: false, size: 11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.frame = NSRect(x: 20, y: 70, width: 380, height: 18)
        view.addSubview(helpLabel)

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
        let hotkey = hotkeyPopup.titleOfSelectedItem ?? "F5"

        guard !token.isEmpty, !chatId.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Missing fields"
            alert.informativeText = "Bot token and chat ID are required."
            alert.runModal()
            return
        }

        let config = Config(botToken: token, chatId: chatId, hotkey: hotkey)
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
