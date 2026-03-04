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

/// Wraps TDLib JSON client for sending messages as the authenticated user.
/// Loaded dynamically — if TDLib isn't available, isAvailable returns false.
class TelegramClient {
    private var clientId: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "tdlib.receive", qos: .background)

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

    init(apiId: Int, apiHash: String) {
        self.apiId = apiId
        self.apiHash = apiHash
        if let create = _td_create_client_id {
            self.clientId = create()
        }
    }

    func start() {
        guard TelegramClient.isAvailable, clientId >= 0 else {
            log("❌ TDLib not available")
            return
        }
        guard apiId > 0, !apiHash.isEmpty else {
            log("❌ TDLib: invalid API credentials")
            return
        }

        running = true

        send([
            "@type": "setTdlibParameters",
            "database_directory": tdlibDataDir(),
            "use_message_database": true,
            "use_secret_chats": false,
            "api_id": apiId,
            "api_hash": apiHash,
            "system_language_code": "en",
            "device_model": "macOS",
            "application_version": "1.0.0",
        ])

        queue.async { [weak self] in
            self?.receiveLoop()
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
        let requestId = UUID().uuidString
        send([
            "@type": "sendMessage",
            "@extra": requestId,
            "chat_id": chatId,
            "input_message_content": [
                "@type": "inputMessageVoiceNote",
                "voice_note": [
                    "@type": "inputFileLocal",
                    "path": filePath,
                ],
                "duration": duration,
            ],
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            completion(true)
        }
    }

    var isLoggedIn: Bool { authState == .ready }

    // MARK: - Internal

    private func send(_ dict: [String: Any]) {
        guard let sendFn = _td_send else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { sendFn(clientId, $0) }
    }

    private func receiveLoop() {
        guard let receiveFn = _td_receive else { return }
        while running {
            guard let resultPtr = receiveFn(1.0) else { continue }
            let json = String(cString: resultPtr)

            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = dict["@type"] as? String else { continue }

            handleUpdate(type: type, data: dict)
        }
    }

    private func handleUpdate(type: String, data: [String: Any]) {
        switch type {
        case "updateAuthorizationState":
            guard let authState = data["authorization_state"] as? [String: Any],
                  let stateType = authState["@type"] as? String else { return }

            switch stateType {
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
                break
            }

        case "error":
            let msg = data["message"] as? String ?? "Unknown error"
            log("❌ TDLib error: \(msg)")
            DispatchQueue.main.async { self.onError?(msg) }

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
