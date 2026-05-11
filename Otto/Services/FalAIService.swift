import Foundation

/// fal.ai client — speech-to-text via Wizper, text-to-speech via ElevenLabs v3.
/// Auth: `Authorization: Key <FAL_KEY>` header. Key is stored in UserDefaults
/// (same simple storage as Fireflies / Todoist); can be overridden via
/// `FAL_API_KEY` environment variable for development.
actor FalAIService {
    static let shared = FalAIService()

    private let wizperURL = URL(string: "https://fal.run/fal-ai/wizper")!
    private let scribeURL = URL(string: "https://fal.run/fal-ai/elevenlabs/speech-to-text")!
    private let ttsURL    = URL(string: "https://fal.run/fal-ai/elevenlabs/tts/eleven-v3")!
    private let uploadInitiateURL = URL(string: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")!

    /// UserDefaults key for the fal.ai API key.
    static let apiKeyDefaultsKey = "fal_api_key"
    /// UserDefaults key for the selected ElevenLabs voice id.
    static let voiceIdDefaultsKey = "voice.elevenlabs.voiceId"

    /// Preset list of common ElevenLabs voices. Keeps the picker simple —
    /// advanced users can still override via env var if they want a custom id.
    struct Voice: Hashable {
        let id: String
        let displayName: String
    }
    static let presetVoices: [Voice] = [
        .init(id: "Rachel",  displayName: "Rachel (F, warm)"),
        .init(id: "Bella",   displayName: "Bella (F, soft)"),
        .init(id: "Elli",    displayName: "Elli (F, young)"),
        .init(id: "Adam",    displayName: "Adam (M, deep)"),
        .init(id: "Antoni",  displayName: "Antoni (M, friendly)"),
        .init(id: "Domi",    displayName: "Domi (F, confident)")
    ]
    static let defaultVoiceId = "Adam"

    private init() {}

    // MARK: - Key / voice management (nonisolated — simple UserDefaults shims)

    nonisolated func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: Self.apiKeyDefaultsKey)
    }

    nonisolated func getAPIKey() -> String {
        if let env = ProcessInfo.processInfo.environment["FAL_API_KEY"], !env.isEmpty {
            return env
        }
        return UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey) ?? ""
    }

    nonisolated func hasAPIKey() -> Bool {
        !getAPIKey().isEmpty
    }

    nonisolated func getVoiceId() -> String {
        let stored = UserDefaults.standard.string(forKey: Self.voiceIdDefaultsKey) ?? ""
        return stored.isEmpty ? Self.defaultVoiceId : stored
    }

    nonisolated func setVoiceId(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.voiceIdDefaultsKey)
    }

    // MARK: - Errors

    enum FalAIError: LocalizedError {
        case missingKey
        case httpError(Int, String)
        case badResponse
        case transcriptionEmpty

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Set your fal.ai API key in Settings to use voice mode."
            case .httpError(let code, let msg): return "fal.ai error \(code): \(msg)"
            case .badResponse: return "fal.ai returned an unexpected response."
            case .transcriptionEmpty: return "No speech detected."
            }
        }
    }

    // MARK: - CDN upload

    /// Uploads raw bytes to fal's CDN and returns the public URL to use as `*_url`
    /// input for any model. Two-step flow: POST /storage/upload/initiate → PUT to signed URL.
    private func uploadToFalCDN(data: Data, fileName: String, contentType: String, key: String) async throws -> String {
        // Step 1 — initiate.
        var initReq = URLRequest(url: uploadInitiateURL)
        initReq.httpMethod = "POST"
        initReq.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "file_name": fileName,
            "content_type": contentType
        ])
        initReq.timeoutInterval = 30

        let (initData, initResp) = try await URLSession.shared.data(for: initReq)
        guard let initHTTP = initResp as? HTTPURLResponse else { throw FalAIError.badResponse }
        guard (200..<300).contains(initHTTP.statusCode) else {
            let msg = String(data: initData, encoding: .utf8) ?? "no body"
            throw FalAIError.httpError(initHTTP.statusCode, "upload initiate: \(msg)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let fileURL = obj["file_url"] as? String,
              let uploadURLStr = obj["upload_url"] as? String,
              let uploadURL = URL(string: uploadURLStr)
        else { throw FalAIError.badResponse }

        // Step 2 — PUT the bytes to the signed URL. No auth header here; the signature is in the URL.
        var putReq = URLRequest(url: uploadURL)
        putReq.httpMethod = "PUT"
        putReq.setValue(contentType, forHTTPHeaderField: "Content-Type")
        putReq.timeoutInterval = 60
        let (putData, putResp) = try await URLSession.shared.upload(for: putReq, from: data)
        guard let putHTTP = putResp as? HTTPURLResponse else { throw FalAIError.badResponse }
        guard (200..<300).contains(putHTTP.statusCode) else {
            let msg = String(data: putData, encoding: .utf8) ?? "no body"
            throw FalAIError.httpError(putHTTP.statusCode, "upload PUT: \(msg)")
        }

        return fileURL
    }

    // MARK: - STT

    /// Transcribes 16 kHz mono WAV audio. Uses fal.ai's ElevenLabs Scribe endpoint
    /// which — unlike Wizper — accepts base64 data URIs directly, saving the
    /// CDN-upload round-trip. For short utterances this is noticeably faster
    /// (~400–800ms savings) with similar accuracy on English.
    func transcribeWizper(wavData: Data, language: String = "en") async throws -> String {
        let key = getAPIKey()
        guard !key.isEmpty else { throw FalAIError.missingKey }

        let b64 = wavData.base64EncodedString()
        let dataURL = "data:audio/wav;base64,\(b64)"

        let body: [String: Any] = [
            "audio_url": dataURL,
            "language_code": language,
            "tag_audio_events": false,
            "diarize": false
        ]

        var req = URLRequest(url: scribeURL)
        req.httpMethod = "POST"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FalAIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw FalAIError.httpError(http.statusCode, msg)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String
        else { throw FalAIError.badResponse }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw FalAIError.transcriptionEmpty }
        if Self.looksLikeHallucination(trimmed) { throw FalAIError.transcriptionEmpty }
        return trimmed
    }

    /// Heuristic to detect common Whisper/Scribe hallucinations. These models
    /// fabricate plausible speech when given near-silent or TTS-echo-bleed audio.
    /// Returns true for obvious junk so the caller can silently ignore it.
    static func looksLikeHallucination(_ text: String) -> Bool {
        let lower = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stripped = lower.trimmingCharacters(in: .punctuationCharacters)

        // Classic canned hallucinations from Whisper/Scribe training data.
        let canned: Set<String> = [
            "thanks for watching",
            "thank you for watching",
            "please subscribe",
            "like and subscribe",
            "subscribe to my channel",
            "see you next time",
            "see you in the next one",
            "see you next video",
            "thank you",
            "thanks",
            "bye",
            "bye bye",
            "goodbye",
            "hello",
            "hi",
            "okay",
            "ok",
            "yeah",
            "yes",
            "no",
            "mhm",
            "mm",
            "uh",
            "um",
            "hmm",
            "oh"
        ]
        if canned.contains(stripped) { return true }

        let tokens = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // Repeated-token pattern (e.g. "whoah whoah whoah", "ha ha ha", "oh oh oh").
        if tokens.count >= 3 {
            let unique = Set(tokens)
            if unique.count <= 2 && tokens.count >= 3 { return true }
        }

        // Reject any transcription shorter than 2 tokens unless the user clearly
        // said something meaningful. Very short outputs on low-volume audio are
        // almost always hallucinations.
        if tokens.count < 2 { return true }

        return false
    }

    // MARK: - ElevenLabs v3 (TTS)

    /// Synthesizes audio for the given text and returns MP3 bytes.
    /// fal.ai returns `{"audio": {"url": "..."}}` — we fetch that URL to obtain the binary.
    func synthesizeElevenV3(text: String, voiceId: String) async throws -> Data {
        let key = getAPIKey()
        guard !key.isEmpty else { throw FalAIError.missingKey }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Data() }

        let body: [String: Any] = [
            "text": trimmed,
            "voice": voiceId,
            "stability": 0.5,
            "similarity_boost": 0.75
        ]

        var req = URLRequest(url: ttsURL)
        req.httpMethod = "POST"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FalAIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw FalAIError.httpError(http.statusCode, msg)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audio = root["audio"] as? [String: Any],
              let urlStr = audio["url"] as? String,
              let audioURL = URL(string: urlStr)
        else { throw FalAIError.badResponse }

        let (audioBytes, audioResp) = try await URLSession.shared.data(from: audioURL)
        guard let audioHTTP = audioResp as? HTTPURLResponse,
              (200..<300).contains(audioHTTP.statusCode)
        else {
            throw FalAIError.badResponse
        }
        return audioBytes
    }
}
