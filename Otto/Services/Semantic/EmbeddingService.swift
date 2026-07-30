import Foundation
import NaturalLanguage

/// On-device sentence embeddings via Apple's `NLContextualEmbedding`
/// (Latin-script contextual transformer — covers English, Turkish, and most
/// European languages; 512-dim vectors; model assets are downloaded and
/// managed by the OS, nothing ships in the app bundle).
///
/// A sentence vector is the mean of the token vectors, L2-normalized so
/// cosine similarity reduces to a dot product at query time.
///
/// Actor-isolated: the underlying model isn't documented as thread-safe and
/// each call is CPU-bound, so serializing keeps the embedder from starving
/// the cooperative pool while a bulk index runs.
actor EmbeddingService {
    static let shared = EmbeddingService()

    enum EmbeddingError: LocalizedError {
        case modelUnavailable
        case assetsUnavailable

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "This Mac doesn't provide the contextual embedding model."
            case .assetsUnavailable:
                return "The embedding model assets aren't downloaded yet (network required once)."
            }
        }
    }

    /// Longest text we hand to the model. The model itself caps input at
    /// `maximumSequenceLength` tokens (256 for the current Latin model,
    /// roughly 1 000–1 300 chars of prose) — the chunker stays under that,
    /// this is just a hard safety bound.
    private static let maxInputChars = 4_000

    private var embedding: NLContextualEmbedding?
    private var loadState: LoadState = .idle

    private enum LoadState {
        case idle
        case ready
        case failed(String)
    }

    /// Vector length of the loaded model. 0 until `ensureReady()` succeeds.
    private(set) var dimension: Int = 0

    // MARK: - Lifecycle

    /// Load the model, requesting the OS asset download on first ever use.
    /// Cheap after the first success. Throws when the model can't be used.
    func ensureReady() async throws {
        switch loadState {
        case .ready: return
        case .failed, .idle: break
        }

        guard let model = embedding ?? NLContextualEmbedding(script: .latin) else {
            loadState = .failed("model unavailable")
            throw EmbeddingError.modelUnavailable
        }
        embedding = model

        if !model.hasAvailableAssets {
            let result: NLContextualEmbedding.AssetsResult =
                await withCheckedContinuation { continuation in
                    model.requestAssets { result, _ in
                        continuation.resume(returning: result)
                    }
                }
            guard result == .available else {
                loadState = .failed("assets unavailable")
                throw EmbeddingError.assetsUnavailable
            }
        }

        do {
            try model.load()
        } catch {
            loadState = .failed(error.localizedDescription)
            throw EmbeddingError.modelUnavailable
        }

        dimension = model.dimension
        loadState = .ready
    }

    /// True once the model is loaded (used for cheap status checks).
    var isReady: Bool {
        if case .ready = loadState { return true }
        return false
    }

    // MARK: - Embedding

    /// Embed one text. Returns a unit-length Float32 vector, or nil for
    /// blank input / model hiccups on a single item (bulk callers skip nils
    /// rather than aborting a whole index pass).
    func vector(for text: String) async -> [Float]? {
        guard (try? await ensureReady()) != nil, let model = embedding else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clipped = String(trimmed.prefix(Self.maxInputChars))

        guard let result = try? model.embeddingResult(for: clipped, language: detectLanguage(of: clipped)) else {
            return nil
        }

        var sum = [Double](repeating: 0, count: dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            if vector.count == sum.count {
                for i in 0..<vector.count { sum[i] += vector[i] }
                tokenCount += 1
            }
            return true
        }
        guard tokenCount > 0 else { return nil }

        var mean = sum.map { Float($0 / Double(tokenCount)) }
        var norm: Float = 0
        for v in mean { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 1e-6 else { return nil }
        for i in 0..<mean.count { mean[i] /= norm }
        return mean
    }

    /// The model tokenizes better with a language hint. Only hint when the
    /// recognizer is confident and the language is one the model supports;
    /// otherwise let it auto-detect (mixed-language chunks are common here).
    private let recognizer = NLLanguageRecognizer()

    private func detectLanguage(of text: String) -> NLLanguage? {
        recognizer.reset()
        recognizer.processString(String(text.prefix(400)))
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[language],
              confidence > 0.7,
              embedding?.languages.contains(language) == true
        else { return nil }
        return language
    }
}
