import Foundation

/// Local audio transcription via whisper-cpp (dynamically loaded).
/// Bundles libwhisper.dylib + model in .app/Contents/Resources/
class WhisperTranscriber {

    // MARK: - Dynamic loading

    private static let whisperHandle: UnsafeMutableRawPointer? = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("lib/libwhisper.dylib").path
        if let path = bundled, FileManager.default.fileExists(atPath: path) {
            return dlopen(path, RTLD_NOW)
        }
        for path in ["/opt/homebrew/lib/libwhisper.dylib", "/usr/local/lib/libwhisper.dylib"] {
            if FileManager.default.fileExists(atPath: path) {
                return dlopen(path, RTLD_NOW)
            }
        }
        return nil
    }()

    static var isAvailable: Bool {
        return whisperHandle != nil
    }

    /// Transcribe an audio file using the whisper-cli command-line tool.
    /// Falls back to CLI since the C API requires careful memory management.
    static func transcribe(audioPath: String, completion: @escaping (String?) -> Void) {
        // First try bundled whisper-cli, then system
        let bundledCLI = Bundle.main.resourceURL?.appendingPathComponent("whisper-cli").path
        let candidates = [bundledCLI, "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].compactMap { $0 }
        let whisperCLI = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

        // Also try whisper-cpp's whisper command
        let altCandidates = ["/opt/homebrew/bin/whisper", "/usr/local/bin/whisper"].compactMap { $0 }
        let altCLI = altCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }

        let cli = whisperCLI ?? altCLI

        guard let cliPath = cli else {
            log("⚠️ whisper-cli not found — skipping local transcription")
            completion(nil)
            return
        }

        // Find model: bundled first, then common locations
        // Prefer larger models for better accuracy (especially in noisy environments)
        let modelNames = ["ggml-small.en.bin", "ggml-base.en.bin"]
        let searchDirs = [
            Bundle.main.resourceURL?.appendingPathComponent("models").path,
            "\(NSHomeDirectory())/Library/Application Support/TelegramVoiceHotkey/models",
            "/opt/homebrew/share/whisper-cpp/models",
        ].compactMap { $0 }

        let modelCandidates = modelNames.flatMap { name in
            searchDirs.map { dir in "\(dir)/\(name)" }
        }
        let modelPath = modelCandidates.first { FileManager.default.fileExists(atPath: $0) }

        guard let model = modelPath else {
            log("⚠️ whisper model not found — skipping local transcription")
            completion(nil)
            return
        }

        // Convert to WAV first (whisper-cpp needs 16kHz WAV)
        let wavPath = audioPath.replacingOccurrences(of: ".m4a", with: ".wav")
        let ffmpegBundled = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path
        let ffmpegCandidates = [ffmpegBundled, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        let ffmpeg = ffmpegCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }

        guard let ffmpegPath = ffmpeg else {
            log("⚠️ ffmpeg not found — can't convert for whisper")
            completion(nil)
            return
        }

        // Convert to 16kHz mono WAV
        let convertProcess = Process()
        convertProcess.executableURL = URL(fileURLWithPath: ffmpegPath)
        convertProcess.arguments = ["-y", "-i", audioPath, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavPath]
        convertProcess.standardOutput = FileHandle.nullDevice
        convertProcess.standardError = FileHandle.nullDevice

        do {
            try convertProcess.run()
            convertProcess.waitUntilExit()
            guard convertProcess.terminationStatus == 0 else {
                log("⚠️ ffmpeg WAV conversion failed")
                completion(nil)
                return
            }
        } catch {
            log("⚠️ ffmpeg error: \(error)")
            completion(nil)
            return
        }

        // Run whisper
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["-m", model, "-f", wavPath, "--no-timestamps", "-l", "en"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let rawOutput = String(data: data, encoding: .utf8) ?? ""
            log("📝 Whisper raw output (\(rawOutput.count) chars): [\(rawOutput.prefix(200))]")

            // Strip whisper header lines and timestamp brackets, keep only text
            let lines = rawOutput.components(separatedBy: .newlines)
            let textLines = lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip empty lines and whisper header/info lines
                if trimmed.isEmpty { return nil }
                if trimmed.hasPrefix("whisper_") { return nil }
                if trimmed.hasPrefix("system_info") { return nil }
                // Remove timestamp brackets like [00:00:00.000 --> 00:00:02.000]
                if let range = trimmed.range(of: "\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s*-->\\s*\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\]\\s*", options: .regularExpression) {
                    let text = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    return text.isEmpty ? nil : text
                }
                return trimmed
            }
            let output = textLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            // Clean up temp WAV
            try? FileManager.default.removeItem(atPath: wavPath)

            if process.terminationStatus == 0 && !output.isEmpty {
                log("📝 Whisper transcription: \(output.prefix(100))...")
                completion(output)
            } else {
                log("⚠️ Whisper returned empty or failed (exit \(process.terminationStatus))")
                completion(nil)
            }
        } catch {
            log("⚠️ Whisper error: \(error)")
            try? FileManager.default.removeItem(atPath: wavPath)
            completion(nil)
        }
    }
}
