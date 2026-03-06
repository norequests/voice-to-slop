import Foundation

// ─── TDLib Dynamic Loading ──────────────────────────────────────────────────
// Load TDLib at runtime so the app can still compile/run without it.

private let tdlibHandle: UnsafeMutableRawPointer? = {
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent("lib/libtdjson.dylib").path,
        Bundle.main.resourceURL?.appendingPathComponent("lib/libtdjson.1.8.62.dylib").path,
        "/opt/homebrew/lib/libtdjson.dylib",
        "/usr/local/lib/libtdjson.dylib",
    ].compactMap { $0 }
    for path in candidates {
        if FileManager.default.fileExists(atPath: path) {
            return dlopen(path, RTLD_NOW)
        }
    }
    return nil
}()

private typealias TdCreateClientId = @convention(c) () -> Int32
private typealias TdSend = @convention(c) (Int32, UnsafePointer<CChar>) -> Void
private typealias TdReceive = @convention(c) (Double) -> UnsafePointer<CChar>?
private typealias TdExecute = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?

private let _td_create: TdCreateClientId? = {
    guard let h = tdlibHandle, let s = dlsym(h, "td_create_client_id") else { return nil }
    return unsafeBitCast(s, to: TdCreateClientId.self)
}()
private let _td_send: TdSend? = {
    guard let h = tdlibHandle, let s = dlsym(h, "td_send") else { return nil }
    return unsafeBitCast(s, to: TdSend.self)
}()
private let _td_receive: TdReceive? = {
    guard let h = tdlibHandle, let s = dlsym(h, "td_receive") else { return nil }
    return unsafeBitCast(s, to: TdReceive.self)
}()
private let _td_execute: TdExecute? = {
    guard let h = tdlibHandle, let s = dlsym(h, "td_execute") else { return nil }
    return unsafeBitCast(s, to: TdExecute.self)
}()

// ─── JSON Helpers ───────────────────────────────────────────────────────────
// JSONSerialization wraps all integers as NSNumber. Direct `as? Int32` fails.

private func jsonInt32(_ val: Any?) -> Int32? {
    if let n = val as? NSNumber { return n.int32Value }
    return nil
}
private func jsonInt64(_ val: Any?) -> Int64? {
    if let n = val as? NSNumber { return n.int64Value }
    return nil
}
private func jsonString(_ val: Any?) -> String? {
    return val as? String
}

// ─── TelegramClient ─────────────────────────────────────────────────────────

/// Thread-safe TDLib wrapper. Designed for ONE client per app lifetime.
/// Uses a single background receive loop and dispatches all state to main.
class TelegramClient {

    // MARK: - Public API

    enum AuthState: String, CustomStringConvertible {
        case initializing
        case waitingForPhone
        case waitingForCode
        case waitingForPassword
        case ready
        case loggingOut
        case closed
        var description: String { rawValue }
    }

    /// Current auth state (main-thread only)
    private(set) var authState: AuthState = .initializing

    /// Callbacks (always called on main thread)
    var onAuthStateChanged: ((AuthState) -> Void)?
    var onError: ((String) -> Void)?

    var isLoggedIn: Bool { authState == .ready }

    static var isAvailable: Bool {
        tdlibHandle != nil && _td_create != nil && _td_send != nil && _td_receive != nil
    }

    // MARK: - Private State

    private let apiId: Int
    private let apiHash: String
    private var clientId: Int32 = -1

    /// Thread-safe pending callbacks: extra-string → handler
    private let callbackLock = NSLock()
    private var pendingCallbacks: [String: ([String: Any]) -> Void] = [:]

    /// One receive loop for the whole process
    private static let receiveQueue = DispatchQueue(label: "tdlib.receive", qos: .background)
    private static var receiveLoopRunning = false
    private static let registryLock = NSLock()
    private static var clients: [Int32: TelegramClient] = [:]

    // MARK: - Lifecycle

    init(apiId: Int, apiHash: String) {
        self.apiId = apiId
        self.apiHash = apiHash
    }

    /// Create the TDLib client and start the receive loop. Call once.
    func start() {
        guard TelegramClient.isAvailable else {
            log("❌ TDLib not available — dylib not found")
            return
        }
        guard apiId > 0, !apiHash.isEmpty else {
            log("❌ TDLib: invalid credentials (apiId=\(apiId))")
            return
        }

        // Configure logging once
        TelegramClient.configureLogging()

        // Create client
        guard let createFn = _td_create else { return }
        clientId = createFn()
        log("📋 TDLib client created (id=\(clientId))")

        // Register in global registry
        TelegramClient.registryLock.lock()
        TelegramClient.clients[clientId] = self
        TelegramClient.registryLock.unlock()
        log("📋 Client \(clientId) registered")

        // Start the shared receive loop (if not already running)
        if !TelegramClient.receiveLoopRunning {
            TelegramClient.receiveLoopRunning = true
            TelegramClient.receiveQueue.async {
                TelegramClient.receiveLoop()
            }
            log("🔄 Receive loop started")
        }

        log("🔑 TDLib starting — clientId=\(clientId), apiId=\(apiId)")

        // Proactively send setTdlibParameters in case we missed the initial
        // authorizationStateWaitTdlibParameters update (race with receive loop)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.authState == .initializing {
                log("⏳ TDLib still initializing after 0.5s — sending parameters proactively")
                self.tdSend([
                    "@type": "setTdlibParameters",
                    "database_directory": self.tdlibDataDir(),
                    "files_directory": self.tdlibDataDir() + "/files",
                    "database_encryption_key": "",
                    "use_file_database": true,
                    "use_chat_info_database": true,
                    "use_message_database": true,
                    "use_secret_chats": false,
                    "api_id": self.apiId,
                    "api_hash": self.apiHash,
                    "system_language_code": "en",
                    "device_model": "macOS",
                    "system_version": "",
                    "application_version": "1.4.0",
                ])
            }
        }
    }

    /// Log out (keeps the client alive for re-auth — no close/destroy needed)
    func logOut() {
        setAuthState(.loggingOut)
        tdSend(["@type": "logOut"])
        log("🔒 TDLib: logging out...")
    }

    // MARK: - Auth Commands

    func sendPhoneNumber(_ phone: String) {
        tdSend(["@type": "setAuthenticationPhoneNumber", "phone_number": phone])
    }

    func sendCode(_ code: String) {
        tdSend(["@type": "checkAuthenticationCode", "code": code])
    }

    func sendPassword(_ password: String) {
        tdSend(["@type": "checkAuthenticationPassword", "password": password])
    }

    // MARK: - Send Messages

    func sendVoiceNote(chatId: Int64, filePath: String, duration: Int, completion: @escaping (Bool) -> Void) {
        ensureChat(userId: chatId) { [weak self] tdChatId in
            guard let self = self, let tdChatId = tdChatId else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let extra = UUID().uuidString
            self.setCallback(extra: extra) { response in
                let ok = jsonString(response["@type"]) == "message"
                if !ok { log("❌ sendVoiceNote failed: \(jsonString(response["@type"]) ?? "?")") }
                DispatchQueue.main.async { completion(ok) }
            }
            self.tdSend([
                "@type": "sendMessage",
                "@extra": extra,
                "chat_id": tdChatId,
                "input_message_content": [
                    "@type": "inputMessageVoiceNote",
                    "voice_note": ["@type": "inputFileLocal", "path": filePath],
                    "duration": duration,
                ],
            ])
        }
    }

    func sendTextMessage(chatId: Int64, text: String, completion: @escaping (Bool) -> Void) {
        ensureChat(userId: chatId) { [weak self] tdChatId in
            guard let self = self, let tdChatId = tdChatId else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let extra = UUID().uuidString
            self.setCallback(extra: extra) { response in
                let ok = jsonString(response["@type"]) == "message"
                if !ok { log("❌ sendTextMessage failed: \(jsonString(response["@type"]) ?? "?") — \(jsonString(response["message"]) ?? "")") }
                else { log("✅ sendTextMessage accepted") }
                DispatchQueue.main.async { completion(ok) }
            }
            self.tdSend([
                "@type": "sendMessage",
                "@extra": extra,
                "chat_id": tdChatId,
                "input_message_content": [
                    "@type": "inputMessageText",
                    "text": ["@type": "formattedText", "text": text],
                ],
            ])
        }
    }

    func sendPhoto(chatId: Int64, photoPath: String, caption: String?, completion: @escaping (Bool) -> Void) {
        ensureChat(userId: chatId) { [weak self] tdChatId in
            guard let self = self, let tdChatId = tdChatId else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let extra = UUID().uuidString
            self.setCallback(extra: extra) { response in
                let ok = jsonString(response["@type"]) == "message"
                if !ok { log("❌ sendPhoto failed: \(jsonString(response["@type"]) ?? "?") — \(jsonString(response["message"]) ?? "")") }
                else { log("✅ sendPhoto accepted") }
                DispatchQueue.main.async { completion(ok) }
            }

            var content: [String: Any] = [
                "@type": "inputMessagePhoto",
                "photo": ["@type": "inputFileLocal", "path": photoPath],
            ]
            if let caption = caption, !caption.isEmpty {
                content["caption"] = ["@type": "formattedText", "text": caption]
            }
            self.tdSend([
                "@type": "sendMessage",
                "@extra": extra,
                "chat_id": tdChatId,
                "input_message_content": content,
            ])
        }
    }

    // MARK: - Chat Resolution

    /// Ensures a private chat exists for the given user ID. Returns the chat_id.
    private func ensureChat(userId: Int64, completion: @escaping (Int64?) -> Void) {
        let extra = "ensure_chat_\(userId)_\(UUID().uuidString.prefix(8))"
        setCallback(extra: extra) { response in
            let type = jsonString(response["@type"]) ?? ""
            if type == "chat", let cid = jsonInt64(response["id"]) {
                completion(cid)
            } else if type == "error" {
                log("❌ createPrivateChat(\(userId)): \(jsonString(response["message"]) ?? "?")")
                completion(nil)
            } else {
                completion(nil)
            }
        }
        tdSend([
            "@type": "createPrivateChat",
            "@extra": extra,
            "user_id": userId,
            "force": true,
        ])
    }

    // MARK: - Callback Management (thread-safe)

    private func setCallback(extra: String, handler: @escaping ([String: Any]) -> Void) {
        callbackLock.lock()
        pendingCallbacks[extra] = handler
        callbackLock.unlock()
    }

    private func popCallback(extra: String) -> (([String: Any]) -> Void)? {
        callbackLock.lock()
        let cb = pendingCallbacks.removeValue(forKey: extra)
        callbackLock.unlock()
        return cb
    }

    // MARK: - TDLib Send (thread-safe)

    private func tdSend(_ dict: [String: Any]) {
        guard let sendFn = _td_send, clientId >= 0 else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { sendFn(clientId, $0) }
    }

    // MARK: - Receive Loop (single thread, process-wide)

    private static func receiveLoop() {
        guard let receiveFn = _td_receive else {
            log("❌ td_receive unavailable")
            return
        }

        while true {
            guard let ptr = receiveFn(1.0) else { continue }
            let json = String(cString: ptr)

            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Route to the right client
            let cid = jsonInt32(dict["@client_id"]) ?? jsonInt32(dict["client_id"]) ?? -1

            registryLock.lock()
            let client = cid >= 0 ? clients[cid] : clients.values.first
            registryLock.unlock()

            guard let client = client else {
                let type = jsonString(dict["@type"]) ?? "?"
                if type != "updateOption" { // updateOption is noisy
                    log("⚠️ TDLib update for unknown client \(cid): \(type)")
                }
                // If this is an auth state update for a client we missed registering,
                // try again after a short delay
                if type == "updateAuthorizationState" {
                    log("🔄 Retrying auth update routing in 0.2s...")
                    let savedDict = dict
                    let savedCid = cid
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        registryLock.lock()
                        let retryClient = savedCid >= 0 ? clients[savedCid] : clients.values.first
                        registryLock.unlock()
                        if let retryClient = retryClient {
                            log("✅ Retry: routed auth update to client \(savedCid)")
                            retryClient.handleUpdate(savedDict)
                        } else {
                            log("❌ Retry: still no client for \(savedCid)")
                        }
                    }
                }
                continue
            }

            // Check for @extra callback
            if let extra = jsonString(dict["@extra"]), let cb = client.popCallback(extra: extra) {
                cb(dict)
            } else {
                client.handleUpdate(dict)
            }
        }
    }

    // MARK: - Update Handler

    private func handleUpdate(_ data: [String: Any]) {
        let type = jsonString(data["@type"]) ?? ""

        switch type {
        case "updateAuthorizationState":
            guard let state = data["authorization_state"] as? [String: Any],
                  let stateType = jsonString(state["@type"]) else { return }
            handleAuthUpdate(stateType)

        case "error":
            let msg = jsonString(data["message"]) ?? "Unknown error"
            let code = jsonInt32(data["code"]) ?? 0
            if msg.contains("setTdlibParameters") {
                // Timing artifact — ignore
            } else {
                log("❌ TDLib error (\(code)): \(msg)")
                DispatchQueue.main.async { self.onError?(msg) }
            }

        default:
            break
        }
    }

    private func handleAuthUpdate(_ stateType: String) {
        switch stateType {
        case "authorizationStateWaitTdlibParameters":
            log("📋 TDLib requesting parameters...")
            tdSend([
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
                "application_version": "1.4.0",
            ])

        case "authorizationStateWaitPhoneNumber":
            setAuthState(.waitingForPhone)

        case "authorizationStateWaitCode":
            setAuthState(.waitingForCode)

        case "authorizationStateWaitPassword":
            setAuthState(.waitingForPassword)

        case "authorizationStateReady":
            setAuthState(.ready)
            log("✅ TDLib: authenticated")

        case "authorizationStateLoggingOut":
            log("🔒 TDLib: logging out...")

        case "authorizationStateClosed":
            log("🔒 TDLib: session closed — will re-create client")
            setAuthState(.closed)
            // TDLib client is dead after close. Create a new one.
            recreateClient()

        default:
            log("📋 TDLib auth: \(stateType)")
        }
    }

    private func setAuthState(_ state: AuthState) {
        DispatchQueue.main.async {
            log("📋 Auth state: \(state)")
            self.authState = state
            self.onAuthStateChanged?(state)
        }
    }

    /// After TDLib reports `authorizationStateClosed`, the client ID is dead.
    /// Create a fresh one (keeps the same TelegramClient object).
    private func recreateClient() {
        guard let createFn = _td_create else { return }

        // Remove old client from registry
        TelegramClient.registryLock.lock()
        TelegramClient.clients.removeValue(forKey: clientId)
        TelegramClient.registryLock.unlock()

        // Create new client
        let oldId = clientId
        clientId = createFn()

        TelegramClient.registryLock.lock()
        TelegramClient.clients[clientId] = self
        TelegramClient.registryLock.unlock()

        log("📋 TDLib client recreated: \(oldId) → \(clientId)")

        // TDLib will immediately send authorizationStateWaitTdlibParameters
        // for the new client, which our receive loop will handle.
    }

    // MARK: - Paths

    private func tdlibDataDir() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TelegramVoiceHotkey/tdlib")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: - Logging Config (once per process)

    private static var loggingConfigured = false
    private static func configureLogging() {
        guard !loggingConfigured, let execFn = _td_execute else { return }
        loggingConfigured = true

        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TelegramVoiceHotkey")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let tdLogPath = logDir.appendingPathComponent("tdlib.log").path

        let logReq = "{\"@type\":\"setLogStream\",\"log_stream\":{\"@type\":\"logStreamFile\",\"path\":\"\(tdLogPath)\",\"max_file_size\":10485760,\"redirect_stderr\":false}}"
        logReq.withCString { _ = execFn($0) }

        let verbReq = "{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":1}"
        verbReq.withCString { _ = execFn($0) }

        log("📋 TDLib logs → \(tdLogPath)")
    }
}
