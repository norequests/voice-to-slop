import Foundation

struct Config: Codable {
    var botToken: String
    var chatId: String
    var hotkey: String  // e.g. "F5", "F6", "F13"

    static let configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TelegramVoiceHotkey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static let `default` = Config(
        botToken: "",
        chatId: "",
        hotkey: "F5"
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

    var keyCode: UInt32 {
        Self.keyCodeMap[hotkey.uppercased()] ?? 0x60 // default F5
    }

    static let keyCodeMap: [String: UInt32] = [
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76,
        "F5": 0x60, "F6": 0x61, "F7": 0x62, "F8": 0x64,
        "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        "F13": 0x69, "F14": 0x6B, "F15": 0x71, "F16": 0x6A,
        "F17": 0x40, "F18": 0x4F, "F19": 0x50, "F20": 0x5A,
    ]
}
