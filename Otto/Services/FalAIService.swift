import Foundation

/// fal.ai client — speech-to-text via Wizper (Whisper large v3), text-to-speech
/// via ElevenLabs Turbo v2.5 (the low-latency ElevenLabs tier).
/// Auth: `Authorization: Key <FAL_KEY>` header. Key is stored in UserDefaults
/// (same simple storage as Fireflies / Todoist); can be overridden via
/// `FAL_API_KEY` environment variable for development.
actor FalAIService {
    static let shared = FalAIService()

    private let wizperURL = URL(string: "https://fal.run/fal-ai/wizper")!
    private let ttsURL    = URL(string: "https://fal.run/fal-ai/elevenlabs/tts/turbo-v2.5")!

    /// Dedicated session so voice-mode requests share a warm connection pool to
    /// fal.run (see `warmUp()`), and so parallel TTS prefetch has connection
    /// headroom instead of competing with every other client on `.shared`.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg, delegate: SlowRequestLogger(), delegateQueue: nil)
    }()

    /// Logs connection-phase timings for any fal request slower than 3s, so a
    /// slow transcription can be attributed (DNS vs connect vs TLS vs server
    /// time vs a cold fal worker) from Console instead of guesswork.
    private final class SlowRequestLogger: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didFinishCollecting metrics: URLSessionTaskMetrics) {
            let totalMs = Int(metrics.taskInterval.duration * 1000)
            guard totalMs > 3000, let t = metrics.transactionMetrics.last else { return }
            func ms(_ a: Date?, _ b: Date?) -> Int {
                guard let a, let b else { return -1 }
                return Int(b.timeIntervalSince(a) * 1000)
            }
            NSLog("[FalAI] slow request host=%@ total=%dms dns=%dms connect=%dms tls=%dms ttfb=%dms reusedConn=%@",
                  t.request.url?.host ?? "?", totalMs,
                  ms(t.domainLookupStartDate, t.domainLookupEndDate),
                  ms(t.connectStartDate, t.connectEndDate),
                  ms(t.secureConnectionStartDate, t.secureConnectionEndDate),
                  ms(t.requestEndDate, t.responseStartDate),
                  t.isReusedConnection ? "yes" : "no")
        }
    }

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

    // MARK: - Connection warm-up

    /// 0.5s of 16 kHz mono 16-bit silence in a WAV container — the cheapest
    /// possible real Wizper request, used by `warmUp()`.
    private static let warmUpWav: Data = {
        let sampleRate = 16_000
        let dataSize = sampleRate / 2 * 2   // 0.5s × 2 bytes/sample
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: dataSize))
        return d
    }()

    /// Fires a minimal REAL Wizper request (half a second of silence) when a
    /// voice session opens. A plain HEAD isn't enough: the 10s+ first-utterance
    /// stalls seen in the wild come from one-time client costs (proxy/PAC
    /// evaluation, DNS, TLS, HTTP/2 setup on a fresh URLSession) plus a
    /// possibly-cold fal worker — a real request pays all of it up front, while
    /// the user is still speaking. Also pre-connects to the fal CDN host that
    /// TTS audio downloads come from. Result/status intentionally ignored.
    func warmUp() async {
        let key = getAPIKey()
        guard !key.isEmpty else { return }
        let started = Date()

        async let cdn: Void = {
            var req = URLRequest(url: URL(string: "https://v3b.fal.media/")!)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 5
            _ = try? await session.data(for: req)
        }()

        var req = URLRequest(url: wizperURL)
        req.httpMethod = "POST"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "audio_url": "data:audio/x-wav;base64,\(Self.warmUpWav.base64EncodedString())",
            "task": "transcribe",
            "language": "en",
            "version": "3"
        ])
        req.timeoutInterval = 20
        _ = try? await session.data(for: req)
        await cdn
        NSLog(String(format: "[FalAI] warm-up completed in %.0fms",
                     Date().timeIntervalSince(started) * 1000))
    }

    // MARK: - STT (Wizper)

    /// Transcribes 16 kHz mono WAV audio via fal.ai's Wizper (Whisper large v3).
    /// The clip is sent inline as a base64 data URI so short utterances skip a
    /// CDN-upload round-trip entirely. NOTE: the MIME must be `audio/x-wav` —
    /// Wizper's data-URL allowlist rejects `audio/wav` with a 400
    /// "Unsupported data URL" (verified empirically 2026-07).
    func transcribeWizper(wavData: Data, language: String = "en") async throws -> String {
        let key = getAPIKey()
        guard !key.isEmpty else { throw FalAIError.missingKey }

        let started = Date()
        let body: [String: Any] = [
            "audio_url": "data:audio/x-wav;base64,\(wavData.base64EncodedString())",
            "task": "transcribe",
            "language": language,
            "version": "3"
        ]

        var req = URLRequest(url: wizperURL)
        req.httpMethod = "POST"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FalAIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw FalAIError.httpError(http.statusCode, msg)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String
        else { throw FalAIError.badResponse }

        NSLog(String(format: "[FalAI] wizper STT %.0fms (%dKB audio)",
                     Date().timeIntervalSince(started) * 1000, wavData.count / 1024))

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

    // MARK: - ElevenLabs Turbo v2.5 (TTS)

    /// Synthesizes speech for the given text and returns MP3 bytes. Turbo v2.5 is
    /// ElevenLabs' low-latency tier — a few hundred ms for a short sentence vs.
    /// 1s+ on eleven-v3, which is what makes per-sentence streaming TTS feel live.
    /// `previousText` carries the already-spoken part of the reply so prosody
    /// stays continuous across the per-sentence requests of one answer.
    /// fal.ai returns `{"audio": {"url": "..."}}` — we fetch that URL to obtain the binary.
    func synthesizeTurboV25(text: String, voiceId: String, previousText: String? = nil) async throws -> Data {
        let key = getAPIKey()
        guard !key.isEmpty else { throw FalAIError.missingKey }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Data() }

        let started = Date()
        var body: [String: Any] = [
            "text": trimmed,
            "voice": voiceId,
            "stability": 0.5,
            "similarity_boost": 0.75
        ]
        if let previousText, !previousText.isEmpty {
            body["previous_text"] = previousText
        }

        var req = URLRequest(url: ttsURL)
        req.httpMethod = "POST"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, resp) = try await session.data(for: req)
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

        let (audioBytes, audioResp) = try await session.data(from: audioURL)
        guard let audioHTTP = audioResp as? HTTPURLResponse,
              (200..<300).contains(audioHTTP.statusCode)
        else {
            throw FalAIError.badResponse
        }

        NSLog(String(format: "[FalAI] turbo TTS %.0fms (%d chars)",
                     Date().timeIntervalSince(started) * 1000, trimmed.count))
        return audioBytes
    }
}
