import Foundation

/// Buffers streaming text deltas from Claude and emits chunks to TTS as soon as
/// a natural speech boundary is reached. Aggressively tuned for low first-audio
/// latency: emits at CLAUSE boundaries (comma, colon, semicolon, em-dash) once
/// the buffer is at least `minClauseChars`, and at full SENTENCE boundaries
/// (`.` `!` `?`) immediately. Falls back to a whitespace break after
/// `softFlushAt` chars if the model writes a run-on without punctuation.
///
/// Tuning: emitting too early yields unnatural phrasing ("Hello, … "); too late
/// yields perceptible silence before TTS starts. 25 chars + clause boundary is
/// a good sweet spot for conversational prose.
struct SentenceChunker {
    private var buffer: String = ""

    /// Hard fallback — if the model writes this many chars with no punctuation,
    /// break on the last whitespace so we don't balloon memory / block TTS.
    private let softFlushAt: Int = 120

    /// Minimum buffered chars before we accept a clause-boundary emit.
    /// Stops us from speaking "To," or "Hi," on their own.
    private let minClauseChars: Int = 25

    /// Terminal punctuation — always ends a chunk regardless of length.
    private let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// Mid-sentence punctuation — ends a chunk only once buffer ≥ minClauseChars.
    private let clauseTerminators: Set<Character> = [",", ":", ";"]

    mutating func push(_ delta: String) -> [String] {
        buffer.append(delta)
        var emitted: [String] = []
        while let next = extractNextChunk() {
            emitted.append(next)
        }
        return emitted
    }

    /// Flush any trailing non-empty buffer when the stream ends.
    mutating func flush() -> String? {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private mutating func extractNextChunk() -> String? {
        let chars = Array(buffer)
        var boundary: Int? = nil

        var i = 0
        while i < chars.count {
            let c = chars[i]

            // Paragraph break (two newlines).
            if c == "\n", i + 1 < chars.count, chars[i + 1] == "\n" {
                boundary = i + 2
                break
            }

            // Em-dash " — " or hyphen-dash " - " acts as a clause break.
            if (c == "—" || c == "–") && i >= minClauseChars {
                if i + 1 < chars.count, chars[i + 1] == " " {
                    boundary = i + 1
                    break
                }
            }

            // Sentence terminators: always emit when followed by whitespace.
            if sentenceTerminators.contains(c),
               i + 1 < chars.count,
               chars[i + 1].isWhitespace {
                boundary = i + 1
                break
            }

            // Clause terminators: emit only once buffer is large enough to
            // avoid speaking tiny fragments.
            if clauseTerminators.contains(c),
               i >= minClauseChars,
               i + 1 < chars.count,
               chars[i + 1].isWhitespace {
                boundary = i + 1
                break
            }

            i += 1
        }

        if let b = boundary {
            let chunk = String(chars[0..<b]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(chars[b..<chars.count])
            return chunk.isEmpty ? nil : chunk
        }

        // Soft flush for run-on text with no punctuation.
        if buffer.count >= softFlushAt,
           let idx = buffer.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            let chunk = String(buffer[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: idx)...])
            return chunk.isEmpty ? nil : chunk
        }
        return nil
    }
}
