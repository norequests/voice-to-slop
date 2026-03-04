import Foundation

// Dynamically load TDLib so the app works without it (Bot API mode)
private let tdlibHandle: UnsafeMutableRawPointer? = {
    // Look in app bundle first, then system
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("lib/libtdjson.dylib").path
    if let path = bundled, FileManager.default.fileExists(atPath: path) {
        return dlopen(path, RTLD_NOW)
    }
    // Try versioned name
    let bundledVersioned = Bundle.main.resourceURL?.appendingPathComponent("lib/libtdjson.1.8.62.dylib").path
    if let path = bundledVersioned, FileManager.default.fileExists(atPath: path) {
        return dlopen(path, RTLD_NOW)
    }
    // System paths
    for path in ["/opt/homebrew/lib/libtdjson.dylib", "/usr/local/lib/libtdjson.dylib"] {
        if FileManager.default.fileExists(atPath: path) {
            return dlopen(path, RTLD_NOW)
        }
    }
    return nil
}()

// Function pointers
private typealias TdCreateClientId = @convention(c) () -> Int32
private typealias TdSend = @convention(c) (Int32, UnsafePointer<CChar>) -> Void
private typealias TdReceive = @convention(c) (Double) -> UnsafePointer<CChar>?
private typealias TdExecute = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?

private let _td_create_client_id: TdCreateClientId? = {
    guard let h = tdlibHandle, let sym = dlsym(h, "td_create_client_id") else { return nil }
    return unsafeBitCast(sym, to: TdCreateClientId.self)
}()

private let _td_send: TdSend? = {
    guard let h = tdlibHandle, let sym = dlsym(h, "td_send") else { return nil }
    return unsafeBitCast(sym, to: TdSend.self)
}()

private let _td_receive: TdReceive? = {
    guard let h = tdlibHandle, let sym = dlsym(h, "td_receive") else { return nil }
    return unsafeBitCast(sym, to: TdReceive.self)
}()

private let _td_execute: TdExecute? = {
    guard let h = tdlibHandle, let sym = dlsym(h, "td_execute") else { return nil }
    return unsafeBitCast(sym, to: TdExecute.self)
}()

/// Wraps TDLib JSON client for sending messages as the authenticated user.
/// Loaded dynamically — if TDLib isn't available, isAvailable returns false.
class TelegramClient {
    private var clientId: Int32 = -1
    private var running = false
    /// Shared serial queue — TDLib requires td_receive be called from one thread only
    private static let sharedQueue = DispatchQueue(label: "tdlib.receive", qos: .background)
    private static var receiveLoopRunning = false

    enum AuthState {
        case waitingForPhone
        case waitingForCode
        case waitingForPassword
        case ready
        case closed
    }

    var authState: AuthState = .waitingForPhone
    var onAuthStateChanged: ((AuthState) -> Void)?
    var onError: ((String) -> Void)?

    private let apiId: Int
    private let apiHash: String

    static var isAvailable: Bool {
        return tdlibHandle != nil && _td_create_client_id != nil
    }

    /// Set up TDLib logging ONCE before any client is created
    private static var loggingConfigured = false
    private static func configureLogging() {
        guard !loggingConfigured, let execFn = _td_execute else { return }
        loggingConfigured = true

        // Write TDLib internal logs to file for debugging
        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TelegramVoiceHotkey")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let tdLogPath = logDir.appendingPathComponent("tdlib.log").path

        let logFileReq = "{\"@type\":\"setLogStream\",\"log_stream\":{\"@type\":\"logStreamFile\",\"path\":\"\(tdLogPath)\",\"max_file_size\":10485760,\"redirect_stderr\":false}}"
        logFileReq.withCString { _ = execFn($0) }

        let verbReq = "{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":1}"
        verbReq.withCString { _ = execFn($0) }

        log("📋 TDLib logs → \(tdLogPath)")
    }

    init(apiId: Int, apiHash: String) {
        self.apiId = apiId
        self.apiHash = apiHash
        TelegramClient.configureLogging()
        if let create = _td_create_client_id {
            self.clientId = create()
            log("📋 TDLib client created (id=\(self.clientId))")
        }
    }

    func start() {
        guard TelegramClient.isAvailable, clientId >= 0 else {
            log("❌ TDLib not available")
            return
        }
        guard apiId > 0, !apiHash.isEmpty else {
            log("❌ TDLib: invalid API credentials (apiId=\(apiId))")
            return
        }

        running = true
        registerClient()
        log("🔑 TDLib starting — clientId=\(clientId), apiId=\(apiId), dataDir=\(tdlibDataDir())")

        // Start shared receive loop if not already running
        if !TelegramClient.receiveLoopRunning {
            TelegramClient.receiveLoopRunning = true
            TelegramClient.sharedQueue.async {
                TelegramClient.globalReceiveLoop()
            }
        }
    }

    func stop() {
        running = false
        send(["@type": "close"])
    }

    func sendPhoneNumber(_ phone: String) {
        send(["@type": "setAuthenticationPhoneNumber", "phone_number": phone])
    }

    func sendCode(_ code: String) {
        send(["@type": "checkAuthenticationCode", "code": code])
    }

    func sendPassword(_ password: String) {
        send(["@type": "checkAuthenticationPassword", "password": password])
    }

    func sendVoiceNote(chatId: Int64, filePath: String, duration: Int, completion: @escaping (Bool) -> Void) {
        // TDLib needs us to open/create the private chat first
        let chatExtra = "create_chat_\(chatId)"
        let sendExtra = UUID().uuidString

        // Register a one-shot handler for the chat creation response
        pendingCallbacks[chatExtra] = { [weak self] response in
            guard let self = self else { return }
            let type = response["@type"] as? String ?? ""

            // Get the actual chat_id (might differ from user_id)
            var tdChatId = chatId
            if type == "chat", let cid = response["id"] as? Int64 {
                tdChatId = cid
            }

            self.send([
                "@type": "sendMessage",
                "@extra": sendExtra,
                "chat_id": tdChatId,
                "input_message_content": [
                    "@type": "inputMessageVoiceNote",
                    "voice_note": [
                        "@type": "inputFileLocal",
                        "path": filePath,
                    ],
                    "duration": duration,
                ],
            ])
        }

        pendingCallbacks[sendExtra] = { response in
            let type = response["@type"] as? String ?? ""
            let ok = type == "message"
            DispatchQueue.main.async { completion(ok) }
        }

        send([
            "@type": "createPrivateChat",
            "@extra": chatExtra,
            "user_id": chatId,
            "force": false,
        ])
    }

    private var pendingCallbacks: [String: ([String: Any]) -> Void] = [:]

    var isLoggedIn: Bool { authState == .ready }

    // MARK: - Client Registry (for shared receive loop)

    private static var clients: [Int32: TelegramClient] = [:]

    private func registerClient() {
        TelegramClient.clients[clientId] = self
    }

    private static func globalReceiveLoop() {
        guard let receiveFn = _td_receive else { return }
        while true {
            guard let resultPtr = receiveFn(1.0) else { continue }
            let json = String(cString: resultPtr)

            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let type = dict["@type"] as? String ?? "?"

            // TDLib includes client_id in responses — try both key formats
            let clientId: Int32
            if let cid = dict["client_id"] as? Int32 {
                clientId = cid
            } else if let cid = dict["@client_id"] as? Int32 {
                clientId = cid
            } else if let cid = dict["client_id"] as? Int {
                clientId = Int32(cid)
            } else if let cid = dict["@client_id"] as? Int {
                clientId = Int32(cid)
            } else {
                log("⚠️ TDLib response missing client_id: \(type)")
                // Try dispatching to first registered client
                if let first = clients.values.first {
                    first.handleUpdate(type: type, data: dict)
                }
                continue
            }

            if let client = clients[clientId] {
                // Check for @extra callback first
                if let extra = dict["@extra"] as? String,
                   let callback = client.pendingCallbacks.removeValue(forKey: extra) {
                    callback(dict)
                } else if let type = dict["@type"] as? String {
                    client.handleUpdate(type: type, data: dict)
                }
            } else {
                log("⚠️ TDLib response for unknown client \(clientId): \(type)")
            }
        }
    }

    // MARK: - Internal

    private func send(_ dict: [String: Any]) {
        guard let sendFn = _td_send else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { sendFn(clientId, $0) }
    }

    private func handleUpdate(type: String, data: [String: Any]) {
        switch type {
        case "updateAuthorizationState":
            guard let authState = data["authorization_state"] as? [String: Any],
                  let stateType = authState["@type"] as? String else { return }

            switch stateType {
            case "authorizationStateWaitTdlibParameters":
                log("📋 TDLib requesting parameters...")
                send([
                    "@type": "setTdlibParameters",
                    "database_directory": tdlibDataDir(),
                    "files_directory": tdlibDataDir() + "/files",
                    "database_encryption_key": "",
                    "use_file_database": true,
                    "use_chat_info_database": true,
                    "use_message_database": true,
                    "use_secret_chats": false,
                    "api_id": apiId,
                    "api_hash": apiHash,
                    "system_language_code": "en",
                    "device_model": "macOS",
                    "system_version": "",
                    "application_version": "1.0.0",
                ])
            case "authorizationStateWaitPhoneNumber":
                updateAuthState(.waitingForPhone)
            case "authorizationStateWaitCode":
                updateAuthState(.waitingForCode)
            case "authorizationStateWaitPassword":
                updateAuthState(.waitingForPassword)
            case "authorizationStateReady":
                updateAuthState(.ready)
                log("✅ TDLib: logged in")
            case "authorizationStateClosed":
                updateAuthState(.closed)
            default:
                log("📋 TDLib auth state: \(stateType)")
                break
            }

        case "error":
            let msg = data["message"] as? String ?? "Unknown error"
            let code = data["code"] as? Int ?? 0
            // Ignore the "call setTdlibParameters first" error — it's a timing artifact
            if msg.contains("setTdlibParameters") {
                log("⚠️ TDLib init timing error (ignored): \(msg)")
            } else {
                log("❌ TDLib error (\(code)): \(msg)")
                DispatchQueue.main.async { self.onError?(msg) }
            }

        default:
            break
        }
    }

    private func updateAuthState(_ state: AuthState) {
        DispatchQueue.main.async {
            self.authState = state
            self.onAuthStateChanged?(state)
        }
    }

    private func tdlibDataDir() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TelegramVoiceHotkey/tdlib")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
