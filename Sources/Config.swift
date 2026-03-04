import Foundation

enum RecordingMode: String, Codable {
    case holdToRecord = "hold"     // hold hotkey, release to send
    case pressToToggle = "toggle"  // press to start, press any key to stop & send
}

struct Config: Codable {
    var botToken: String
    var chatId: String
    var hotkeyKeyCode: UInt16
    var hotkeyModifiers: UInt
    var hotkeyDisplay: String
    var recordingMode: RecordingMode

    static let configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TelegramVoiceHotkey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static let `default` = Config(
        botToken: "",
        chatId: "",
        hotkeyKeyCode: 0x60, // F5
        hotkeyModifiers: 0,
        hotkeyDisplay: "F5",
        recordingMode: .holdToRecord
    )

    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              !config.botToken.isEmpty, !config.chatId.isEmpty
        else {
            return .default
        }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            try? data.write(to: Config.configURL)
        }
    }

    var isConfigured: Bool {
        !botToken.isEmpty && !chatId.isEmpty
    }
}
