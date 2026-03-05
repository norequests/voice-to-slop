import Foundation

/// Transcription via any OpenAI-compatible /v1/audio/transcriptions endpoint.
/// Works with: OpenAI Whisper API, Groq, local whisper-server, etc.
class CustomTranscriber {

    static func transcribe(
        audioPath: String,
        endpointUrl: String,
        apiKey: String,
        modelName: String,
        completion: @escaping (String?) -> Void
    ) {
        guard !endpointUrl.isEmpty else {
            log("⚠️ Custom transcription: endpoint URL not set")
            completion(nil)
            return
        }

        // Normalise URL — append /v1/audio/transcriptions if it looks like a base URL
        var urlString = endpointUrl
        if !urlString.hasSuffix("/transcriptions") && !urlString.hasSuffix("/transcriptions/") {
            if urlString.hasSuffix("/") { urlString += "v1/audio/transcriptions" }
            else if urlString.hasSuffix("/v1") || urlString.hasSuffix("/v1/") {
                urlString = urlString.hasSuffix("/") ? urlString + "audio/transcriptions"
                                                     : urlString + "/audio/transcriptions"
            } else {
                urlString += "/v1/audio/transcriptions"
            }
        }

        guard let url = URL(string: urlString) else {
            log("❌ Custom transcription: invalid URL '\(urlString)'")
            completion(nil)
            return
        }

        guard let audioData = FileManager.default.contents(atPath: audioPath) else {
            log("❌ Custom transcription: can't read audio file: \(audioPath)")
            completion(nil)
            return
        }

        let model = modelName.isEmpty ? "whisper-1" : modelName

        // Build multipart/form-data
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ string: String) { body.append(string.data(using: .utf8)!) }

        // model field
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        // response_format
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("text\r\n")

        // file field
        let ext = URL(fileURLWithPath: audioPath).pathExtension
        let mimeType: String
        switch ext.lowercased() {
        case "ogg":  mimeType = "audio/ogg"
        case "wav":  mimeType = "audio/wav"
        case "mp3":  mimeType = "audio/mpeg"
        case "webm": mimeType = "audio/webm"
        default:     mimeType = "audio/mp4"
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 60

        log("🌐 Custom transcription → \(urlString) (model: \(model), \(audioData.count / 1024)KB)")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                log("❌ Custom transcription request failed: \(error.localizedDescription)")
                completion(nil)
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data else {
                log("❌ Custom transcription: no data (status \(statusCode))")
                completion(nil)
                return
            }

            // response_format=text returns plain text
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, statusCode < 400 {
                // If the server returned JSON error despite text format, detect it
                if text.hasPrefix("{") {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errObj = json["error"] as? [String: Any],
                       let msg = errObj["message"] as? String {
                        log("❌ Custom transcription error: \(msg)")
                        completion(nil)
                    } else {
                        // Might still be a valid JSON text response, try "text" key
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let t = json["text"] as? String {
                            log("📝 Custom transcription: \(t.prefix(100))")
                            completion(t.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            log("❌ Custom transcription: unexpected JSON response")
                            completion(nil)
                        }
                    }
                } else {
                    log("📝 Custom transcription: \(text.prefix(100))")
                    completion(text)
                }
            } else {
                let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? "?"
                log("❌ Custom transcription: status \(statusCode) — \(preview)")
                completion(nil)
            }
        }.resume()
    }
}
