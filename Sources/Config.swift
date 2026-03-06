import Foundation

enum RecordingMode: String, Codable {
    case holdToRecord = "hold"
    case pressToToggle = "toggle"
}

struct Config: Codable {
    var chatId: String
    var hotkeyKeyCode: UInt16
    var hotkeyModifiers: UInt
    var hotkeyDisplay: String
    var recordingMode: RecordingMode
    var launchAtLogin: Bool
    var apiId: Int
    var apiHash: String
    var userLoggedIn: Bool
    // Screenshot+voice combo hotkey
    var screenshotHotkeyKeyCode: UInt16
    var screenshotHotkeyModifiers: UInt
    var screenshotHotkeyDisplay: String
    // Dictation hotkey (voice -> clipboard)
    var dictationKeyCode: UInt16
    var dictationModifiers: UInt
    var dictationDisplay: String
    // Transcription
    var transcriptionMode: String  // "local", "gemini", or "custom"
    var geminiApiKey: String
    // Custom transcription endpoint (OpenAI-compatible)
    var customEndpointUrl: String
    var customApiKey: String
    var customModelName: String
    // Voice send behaviour
    var sendVoiceAsText: Bool  // true = transcribe → send text; false = send raw voice note

    init(chatId: String, hotkeyKeyCode: UInt16, hotkeyModifiers: UInt,
         hotkeyDisplay: String, recordingMode: RecordingMode, launchAtLogin: Bool,
         apiId: Int, apiHash: String, userLoggedIn: Bool,
         screenshotHotkeyKeyCode: UInt16 = 0, screenshotHotkeyModifiers: UInt = 0,
         screenshotHotkeyDisplay: String = "",
         dictationKeyCode: UInt16 = 0x0B, dictationModifiers: UInt = 786432,
         dictationDisplay: String = "⌃⌥B",
         transcriptionMode: String = "local", geminiApiKey: String = "",
         customEndpointUrl: String = "", customApiKey: String = "",
         customModelName: String = "", sendVoiceAsText: Bool = false) {
        self.chatId = chatId; self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers; self.hotkeyDisplay = hotkeyDisplay
        self.recordingMode = recordingMode; self.launchAtLogin = launchAtLogin
        self.apiId = apiId; self.apiHash = apiHash; self.userLoggedIn = userLoggedIn
        self.screenshotHotkeyKeyCode = screenshotHotkeyKeyCode
        self.screenshotHotkeyModifiers = screenshotHotkeyModifiers
        self.screenshotHotkeyDisplay = screenshotHotkeyDisplay
        self.dictationKeyCode = dictationKeyCode
        self.dictationModifiers = dictationModifiers
        self.dictationDisplay = dictationDisplay
        self.transcriptionMode = transcriptionMode
        self.geminiApiKey = geminiApiKey
        self.customEndpointUrl = customEndpointUrl
        self.customApiKey = customApiKey
        self.customModelName = customModelName
        self.sendVoiceAsText = sendVoiceAsText
    }

    enum CodingKeys: String, CodingKey {
        case chatId, hotkeyKeyCode, hotkeyModifiers, hotkeyDisplay
        case recordingMode, launchAtLogin, apiId, apiHash, userLoggedIn
        case screenshotHotkeyKeyCode, screenshotHotkeyModifiers, screenshotHotkeyDisplay
        case dictationKeyCode, dictationModifiers, dictationDisplay
        case transcriptionMode, geminiApiKey
        case customEndpointUrl, customApiKey, customModelName
        case sendVoiceAsText
        // Legacy keys we skip on read
        case botToken, sendMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatId = try c.decodeIfPresent(String.self, forKey: .chatId) ?? ""
        hotkeyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .hotkeyKeyCode) ?? 0x60
        hotkeyModifiers = try c.decodeIfPresent(UInt.self, forKey: .hotkeyModifiers) ?? 0
        hotkeyDisplay = try c.decodeIfPresent(String.self, forKey: .hotkeyDisplay) ?? "F5"
        recordingMode = try c.decodeIfPresent(RecordingMode.self, forKey: .recordingMode) ?? .holdToRecord
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        apiId = try c.decodeIfPresent(Int.self, forKey: .apiId) ?? 0
        apiHash = try c.decodeIfPresent(String.self, forKey: .apiHash) ?? ""
        userLoggedIn = try c.decodeIfPresent(Bool.self, forKey: .userLoggedIn) ?? false
        screenshotHotkeyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .screenshotHotkeyKeyCode) ?? 0
        screenshotHotkeyModifiers = try c.decodeIfPresent(UInt.self, forKey: .screenshotHotkeyModifiers) ?? 0
        screenshotHotkeyDisplay = try c.decodeIfPresent(String.self, forKey: .screenshotHotkeyDisplay) ?? ""
        dictationKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .dictationKeyCode) ?? 0x0B
        dictationModifiers = try c.decodeIfPresent(UInt.self, forKey: .dictationModifiers) ?? 786432
        dictationDisplay = try c.decodeIfPresent(String.self, forKey: .dictationDisplay) ?? "⌃⌥B"
        transcriptionMode = try c.decodeIfPresent(String.self, forKey: .transcriptionMode) ?? "local"
        geminiApiKey = try c.decodeIfPresent(String.self, forKey: .geminiApiKey) ?? ""
        customEndpointUrl = try c.decodeIfPresent(String.self, forKey: .customEndpointUrl) ?? ""
        customApiKey = try c.decodeIfPresent(String.self, forKey: .customApiKey) ?? ""
        customModelName = try c.decodeIfPresent(String.self, forKey: .customModelName) ?? ""
        sendVoiceAsText = try c.decodeIfPresent(Bool.self, forKey: .sendVoiceAsText) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chatId, forKey: .chatId)
        try c.encode(hotkeyKeyCode, forKey: .hotkeyKeyCode)
        try c.encode(hotkeyModifiers, forKey: .hotkeyModifiers)
        try c.encode(hotkeyDisplay, forKey: .hotkeyDisplay)
        try c.encode(recordingMode, forKey: .recordingMode)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(apiId, forKey: .apiId)
        try c.encode(apiHash, forKey: .apiHash)
        try c.encode(userLoggedIn, forKey: .userLoggedIn)
        try c.encode(screenshotHotkeyKeyCode, forKey: .screenshotHotkeyKeyCode)
        try c.encode(screenshotHotkeyModifiers, forKey: .screenshotHotkeyModifiers)
        try c.encode(screenshotHotkeyDisplay, forKey: .screenshotHotkeyDisplay)
        try c.encode(dictationKeyCode, forKey: .dictationKeyCode)
        try c.encode(dictationModifiers, forKey: .dictationModifiers)
        try c.encode(dictationDisplay, forKey: .dictationDisplay)
        try c.encode(transcriptionMode, forKey: .transcriptionMode)
        try c.encode(geminiApiKey, forKey: .geminiApiKey)
        try c.encode(customEndpointUrl, forKey: .customEndpointUrl)
        try c.encode(customApiKey, forKey: .customApiKey)
        try c.encode(customModelName, forKey: .customModelName)
        try c.encode(sendVoiceAsText, forKey: .sendVoiceAsText)
    }

    static let configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TelegramVoiceHotkey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static let `default` = Config(
        chatId: "",
        hotkeyKeyCode: 0x2D,       // N
        hotkeyModifiers: 786432,    // ⌃⌥ (Control + Option)
        hotkeyDisplay: "⌃⌥N",
        recordingMode: .holdToRecord,
        launchAtLogin: false,
        apiId: 0,
        apiHash: "",
        userLoggedIn: false,
        screenshotHotkeyKeyCode: 0x2E,    // M
        screenshotHotkeyModifiers: 786432, // ⌃⌥
        screenshotHotkeyDisplay: "⌃⌥M",
        dictationKeyCode: 0x0B,           // B
        dictationModifiers: 786432,       // ⌃⌥
        dictationDisplay: "⌃⌥B"
    )

    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data)
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

    var hasCredentials: Bool {
        apiId > 0 && !apiHash.isEmpty
    }

    var isConfigured: Bool {
        hasCredentials && !chatId.isEmpty && userLoggedIn
    }

    var hasScreenshotHotkey: Bool {
        screenshotHotkeyKeyCode > 0 && !screenshotHotkeyDisplay.isEmpty
    }

    var hasDictationHotkey: Bool {
        dictationKeyCode > 0 && !dictationDisplay.isEmpty
    }
}
