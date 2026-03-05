import Foundation

/// Cloud transcription via Google Gemini API.
/// Faster than local whisper, requires an API key.
class GeminiTranscriber {

    static func transcribe(audioPath: String, apiKey: String, completion: @escaping (String?) -> Void) {
        guard !apiKey.isEmpty else {
            log("⚠️ Gemini API key not set")
            completion(nil)
            return
        }

        // Read audio file and base64 encode it
        guard let audioData = FileManager.default.contents(atPath: audioPath) else {
            log("❌ Can't read audio file: \(audioPath)")
            completion(nil)
            return
        }

        let base64Audio = audioData.base64EncodedString()

        // Determine MIME type
        let mimeType: String
        if audioPath.hasSuffix(".ogg") {
            mimeType = "audio/ogg"
        } else if audioPath.hasSuffix(".m4a") {
            mimeType = "audio/mp4"
        } else if audioPath.hasSuffix(".wav") {
            mimeType = "audio/wav"
        } else {
            mimeType = "audio/mp4"
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)")!

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    [
                        "inline_data": [
                            "mime_type": mimeType,
                            "data": base64Audio,
                        ]
                    ],
                    [
                        "text": "Transcribe this audio. Return ONLY the transcription text, nothing else. If no speech is detected, return '[no speech]'."
                    ],
                ]
            ]]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            log("❌ Failed to serialize Gemini request")
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        log("🌐 Gemini transcribing (\(audioData.count / 1024)KB)...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                log("❌ Gemini request failed: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("❌ Gemini: invalid response")
                completion(nil)
                return
            }

            // Parse response: candidates[0].content.parts[0].text
            if let candidates = json["candidates"] as? [[String: Any]],
               let first = candidates.first,
               let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == "[no speech]" {
                    log("📝 Gemini: no speech detected")
                    completion(nil)
                } else {
                    log("📝 Gemini transcription: \(trimmed.prefix(100))...")
                    completion(trimmed)
                }
            } else {
                log("❌ Gemini: unexpected response format — \(String(data: data, encoding: .utf8)?.prefix(200) ?? "?")")
                completion(nil)
            }
        }.resume()
    }
}
