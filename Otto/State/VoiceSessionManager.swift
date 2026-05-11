import Foundation
import SwiftUI
import AVFoundation

/// Orchestrates the full voice-mode loop:
/// mic capture → VAD → Wizper STT → streaming Claude → sentence-chunked ElevenLabs TTS → playback.
///
/// Supports barge-in: while Claude's voice is playing, the VAD continues monitoring
/// the mic and triggers a hard interrupt if the user starts speaking (cancels TTS,
/// drops pending sentences, transitions back to listening).
@Observable
final class VoiceSessionManager {

    // MARK: - Public state (driven by UI)

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking
        case error(String)
    }

    var phase: Phase = .idle
    var liveTranscript: String = ""
    var lastResponse: String = ""
    var inputLevel: Float = 0
    var outputLevel: Float = 0

    // MARK: - Dependencies

    private weak var appState: AppState?
    private let mic = MicCapture()
    private let vad = VoiceActivityDetector()
    private let tts = TTSPlayer()
    private let falAI = FalAIService.shared

    // MARK: - Internal state

    /// Chat turns for the current voice session — mirrors OttoChatView's turn log.
    private var turns: [ChatTurn] = []

    /// Sentence chunker for the in-flight assistant reply (reset per user turn).
    private var chunker = SentenceChunker()

    /// Serial queue of TTS requests so spoken sentences stay in text order
    /// even though HTTP responses can return out-of-order.
    private var ttsSerialTask: Task<Void, Never>? = nil
    private var ttsQueue: [String] = []
    private var ttsContinuations: [CheckedContinuation<Void, Never>] = []

    /// Currently-running Claude streaming task — cancellable on barge-in or close.
    private var claudeTask: Task<Void, Never>? = nil

    /// True from the start of a turn until Claude finishes or is cancelled.
    /// Signals the TTS serial processor whether more sentences may arrive.
    /// Must be set independently of `claudeTask` to avoid a scheduling race where
    /// the processor runs before `claudeTask = Task { ... }` has executed.
    private var isClaudeStreaming: Bool = false

    /// Token text Claude has produced so far in the in-flight turn (for UI).
    private var inflightAssistantText: String = ""

    // MARK: - Lifecycle

    init() {
        configureVADCallbacks()
        configureMicCallback()
        configureTTSCallbacks()
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Start / stop

    /// Begin a voice session — request mic permission, start capture, enter .listening.
    func start(appState: AppState) async {
        self.appState = appState
        turns = []
        inflightAssistantText = ""
        liveTranscript = ""
        lastResponse = ""

        if !MicCapture.isAuthorized {
            let granted = await MicCapture.requestPermission()
            if !granted {
                setError("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
                return
            }
        }

        if !falAI.hasAPIKey() {
            setError("Set your fal.ai API key in Settings to use voice mode.")
            return
        }

        do {
            vad.reset()
            vad.setBargeInMode(false)
            try mic.start()
            // Three open paths, in priority order:
            //   1. Morning briefing — first clap of the day. A synthetic user
            //      turn runs through Claude (tools + web) and the response
            //      streams to TTS. beginClaudeTurn handles phase+barge-in.
            //   2. Plain greeting — speak a canned line before listening.
            //   3. Straight to listening — manual mic-button open.
            if appState.pendingBriefing {
                appState.pendingBriefing = false
                beginClaudeTurn(userText: MorningBriefingService.composeGreetingPrompt())
            } else if let greeting = appState.pendingVoiceGreeting {
                appState.pendingVoiceGreeting = nil
                phase = .speaking
                // Prevent any in-flight noise / TTS-echo tail from triggering
                // the VAD the moment we open.
                listeningCooldownUntil = Date().addingTimeInterval(1.5)
                enqueueTTS(greeting)
                startTTSSerialProcessor()
            } else {
                phase = .listening
            }
        } catch {
            setError(error.localizedDescription)
        }
    }

    /// Set the error phase and play the error chime in one place. All error
    /// paths funnel through here so the audio cue never drifts out of sync.
    /// Not `@MainActor` — the class itself isn't actor-isolated; existing
    /// phase writes happen from multiple contexts.
    private func setError(_ message: String) {
        phase = .error(message)
        Sounds.play(.error)
    }

    /// End the voice session cleanly.
    func stop() {
        cancelIdleTimer()
        mic.stop()
        tts.stop()
        isClaudeStreaming = false
        claudeTask?.cancel()
        claudeTask = nil
        ttsSerialTask?.cancel()
        ttsSerialTask = nil
        ttsQueue.removeAll()
        resumeAllTTSContinuations()
        phase = .idle
        inputLevel = 0
        outputLevel = 0
    }

    // MARK: - VAD / Mic wiring

    private func configureMicCallback() {
        mic.onBuffer = { [weak self] buf in
            // VAD is thread-agnostic; callbacks hop to main as needed.
            self?.vad.process(buffer: buf)
        }
    }

    private func configureVADCallbacks() {
        vad.onLevel = { [weak self] level in
            Task { @MainActor in self?.inputLevel = level }
        }
        vad.onUtterance = { [weak self] wav in
            Task { @MainActor in self?.handleUtterance(wav: wav) }
        }
        vad.onBargeIn = { [weak self] in
            Task { @MainActor in self?.handleBargeIn() }
        }
    }

    private func configureTTSCallbacks() {
        tts.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.outputLevel = level
                // Feed output level into the VAD so barge-in threshold scales
                // with how loud Claude is currently playing.
                self?.vad.setCurrentTTSLevel(level)
            }
        }
        tts.onChunkCompleted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // When the TTS queue fully drains and no more sentences are coming, flip
                // back to listening for the user's next turn.
                if !self.tts.isPlaying, self.ttsQueue.isEmpty, self.ttsSerialTask == nil,
                   !self.isClaudeStreaming, self.phase == .speaking {
                    self.enterListening()
                }
            }
        }
    }

    // MARK: - Utterance pipeline

    private func handleUtterance(wav: Data) {
        // Ignore utterances while we're mid-Claude-call — barge-in is the right path for that.
        guard phase == .listening else { return }
        // Ignore if we just flipped to listening — lets TTS echo tail dissipate.
        if Date() < listeningCooldownUntil { return }

        // Activity — keep the session alive.
        cancelIdleTimer()

        phase = .transcribing
        liveTranscript = ""
        let clipWav = wav

        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.falAI.transcribeWizper(wavData: clipWav)
                await MainActor.run { self.liveTranscript = text }
                // Apply any deterministic intent side-effects (may capture a
                // screenshot) before starting the Claude turn, so the context
                // note Claude sees references work the model can already see.
                let effective = await self.prepareTurnText(userText: text)
                await MainActor.run {
                    self.beginClaudeTurn(userText: effective)
                }
            } catch FalAIService.FalAIError.transcriptionEmpty {
                // Empty or hallucinated — silently drop back to listening. Don't
                // poke the UI with an error; this happens routinely on mic noise.
                await MainActor.run { self.enterListening() }
            } catch {
                await MainActor.run {
                    self.setError(error.localizedDescription)
                    // After an error, fall back to listening so the user can retry.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if case .error = self.phase { self.enterListening() }
                    }
                }
            }
        }
    }

    // MARK: - Claude streaming

    /// Intent detection + async side-effect application — hoisted out of
    /// `beginClaudeTurn` so `beginClaudeTurn` can stay synchronous (it's
    /// called from `await MainActor.run { ... }` and the briefing path).
    /// Returns the text to feed Claude (user text + optional context note).
    private func prepareTurnText(userText: String) async -> String {
        guard let appState else { return userText }
        guard let intent = IntentRouter.detect(userInput: userText) else { return userText }
        await IntentRouter.apply(intent, appState: appState)
        return userText + "\n" + IntentRouter.contextNote(for: intent)
    }

    private func beginClaudeTurn(userText: String) {
        guard let appState else { return }

        turns.append(ChatTurn(role: "user", blocks: [.text(userText)]))
        phase = .thinking
        chunker = SentenceChunker()
        inflightAssistantText = ""
        // CRITICAL: set the streaming flag BEFORE starting the TTS processor.
        // The processor's popNextSentence() reads this to know whether to park
        // awaiting more sentences vs. exit. If it read claudeTask directly there
        // would be a race where the processor runs before claudeTask is assigned
        // below, sees nil, and exits immediately.
        isClaudeStreaming = true
        // Arm barge-in now so the user can interrupt a long search/tool-call chain
        // without waiting for Claude to start speaking. Same stricter threshold
        // as speaking-phase barge-in, but no TTS echo to worry about here.
        vad.setBargeInMode(true)
        startTTSSerialProcessor()

        let currentTurns = turns
        let state = appState

        claudeTask = Task { [weak self] in
            guard let self else { return }
            let executor = await MainActor.run { OttoToolExecutor(appState: state) }
            let systemPrompt = state.claude.buildSystemPrompt(from: state)

            do {
                let updated = try await state.claude.streamChatWithTools(
                    turns: currentTurns,
                    systemPrompt: systemPrompt,
                    tools: OttoTools.all,
                    executor: executor,
                    onDelta: { [weak self] delta in
                        self?.handleAssistantDelta(delta)
                    },
                    onEvent: { _ in
                        // We don't render tool chips in voice mode; ignore.
                    }
                )
                await MainActor.run {
                    self.turns = updated
                    self.finishClaudeTurn()
                }
            } catch is CancellationError {
                // User-initiated barge-in or overlay dismissal cancelled the stream
                // — not an error. handleBargeIn()/stop() already transitioned phase.
                await MainActor.run {
                    self.isClaudeStreaming = false
                    self.claudeTask = nil
                    self.wakeTTSSerialProcessor()
                }
            } catch {
                // `URLError.cancelled` is also how URLSession surfaces task cancellation.
                if (error as? URLError)?.code == .cancelled {
                    await MainActor.run {
                        self.isClaudeStreaming = false
                        self.claudeTask = nil
                        self.wakeTTSSerialProcessor()
                    }
                    return
                }
                await MainActor.run {
                    self.setError(error.localizedDescription)
                    self.tts.stop()
                    self.isClaudeStreaming = false
                    self.claudeTask = nil
                    self.wakeTTSSerialProcessor()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        if case .error = self.phase { self.enterListening() }
                    }
                }
            }
        }
    }

    private func handleAssistantDelta(_ delta: String) {
        inflightAssistantText.append(delta)
        lastResponse = inflightAssistantText

        // First delta = TTS about to start. Keep barge-in armed but with a
        // very strict threshold that scales with TTS output level (see VAD's
        // ttsGateDb calculation). User speech louder than Claude's speaker
        // output + sustained for 500ms triggers interrupt; echo bleed-through
        // stays below.
        if phase != .speaking {
            phase = .speaking
            vad.setBargeInMode(true)
        }

        let sentences = chunker.push(delta)
        for sentence in sentences {
            enqueueTTS(sentence)
        }
    }

    private func finishClaudeTurn() {
        // Flush any trailing partial sentence.
        if let tail = chunker.flush() { enqueueTTS(tail) }
        isClaudeStreaming = false
        claudeTask = nil
        // Wake the serial processor so it can either pick up the flushed tail or
        // exit gracefully (queue empty + !isClaudeStreaming).
        wakeTTSSerialProcessor()
        // Persist to askHistory so this turn shows up in OttoChatView scrollback.
        persistCurrentTurnsToHistory()
        // Edge case: Claude completed without ever emitting a text delta (e.g. only
        // tool calls ran out to the loop cap, or silent completion). Phase would
        // stay at .thinking forever — drop back to listening so the user can retry.
        if phase == .thinking, ttsQueue.isEmpty, !tts.isPlaying {
            enterListening()
        }
        // Otherwise: TTS queue may still be draining — onChunkCompleted flips us
        // to .listening when audio is fully done.
    }

    private func persistCurrentTurnsToHistory() {
        guard let appState else { return }
        let flattened = flattenForHistory(turns)
        if flattened.isEmpty { return }
        Task.detached { [flattened, weak appState] in
            guard let appState else { return }
            await appState.addToAskHistory(messages: flattened)
        }
    }

    private func flattenForHistory(_ turns: [ChatTurn]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for turn in turns {
            var pieces: [String] = []
            for block in turn.blocks {
                if case .text(let s) = block,
                   !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    pieces.append(s)
                }
            }
            let combined = pieces.joined(separator: "\n\n")
            if !combined.isEmpty {
                out.append(ChatMessage(role: turn.role, content: combined, timestamp: turn.timestamp))
            }
        }
        return out
    }

    // MARK: - Serial TTS processor

    private func enqueueTTS(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ttsQueue.append(trimmed)
        // Wake the serial processor if it's parked.
        wakeTTSSerialProcessor()
    }

    private func startTTSSerialProcessor() {
        guard ttsSerialTask == nil else { return }
        ttsSerialTask = Task { [weak self] in
            guard let self else { return }
            let voiceId = self.falAI.getVoiceId()
            while !Task.isCancelled {
                let next: String? = await self.popNextSentence()
                guard let sentence = next else { break }
                do {
                    let audio = try await self.falAI.synthesizeElevenV3(text: sentence, voiceId: voiceId)
                    if Task.isCancelled { break }
                    try await self.tts.enqueue(audio)
                } catch is CancellationError {
                    break
                } catch {
                    if (error as? URLError)?.code == .cancelled { break }
                    await MainActor.run {
                        self.setError(error.localizedDescription)
                    }
                    break
                }
            }
            await MainActor.run {
                self.ttsSerialTask = nil
                // Final drain check — if everything is done, head back to listening.
                if !self.tts.isPlaying, !self.isClaudeStreaming, self.phase == .speaking {
                    self.enterListening()
                }
            }
        }
    }

    /// Awaits the next queued sentence, or returns nil if the Claude turn is finished
    /// AND the queue is empty (which means we should exit the serial loop).
    private func popNextSentence() async -> String? {
        while true {
            if Task.isCancelled { return nil }
            if !ttsQueue.isEmpty {
                return ttsQueue.removeFirst()
            }
            // Claude is done producing and the queue drained → exit.
            if !isClaudeStreaming {
                return nil
            }
            // Otherwise park until a new sentence arrives.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                ttsContinuations.append(cont)
            }
        }
    }

    private func wakeTTSSerialProcessor() {
        let conts = ttsContinuations
        ttsContinuations.removeAll()
        for c in conts { c.resume() }
    }

    private func resumeAllTTSContinuations() {
        let conts = ttsContinuations
        ttsContinuations.removeAll()
        for c in conts { c.resume() }
    }

    // MARK: - Barge-in

    private func handleBargeIn() {
        // Accept interrupt from both .thinking (abort search) and .speaking
        // (cut off Claude mid-reply). Threshold is scaled by current TTS level
        // inside the VAD so echo feedback stays below the bar.
        guard phase == .thinking || phase == .speaking else { return }
        // 1. Preserve any partial assistant text so Claude has context for the
        //    follow-up turn. Without this, Claude would reply to the new user
        //    utterance as if the previous reply never happened.
        let partial = inflightAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty {
            turns.append(ChatTurn(role: "assistant", blocks: [.text(partial)]))
        }
        // 2. Cancel Claude mid-stream.
        isClaudeStreaming = false
        claudeTask?.cancel()
        claudeTask = nil
        // 3. Stop TTS playback + cancel the serial task.
        tts.stop()
        ttsSerialTask?.cancel()
        ttsSerialTask = nil
        ttsQueue.removeAll()
        resumeAllTTSContinuations()
        // 4. Reset in-flight text buffers. `turns` retains the preserved partial.
        inflightAssistantText = ""
        chunker = SentenceChunker()
        // 5. Back to listening — VAD captures the user's new utterance, which is
        //    appended as a user turn in beginClaudeTurn. Claude sees the full
        //    context: prior turns + preserved partial assistant + new user.
        enterListening()
    }

    /// Earliest wall-clock time at which we'll accept a new utterance. Set after
    /// entering .listening to ignore TTS-echo-tail / noise for ~600 ms. Without an
    /// acoustic echo canceller we'd otherwise capture the speaker spillover and
    /// feed garbage to the STT (which tends to hallucinate on such audio).
    private var listeningCooldownUntil: Date = .distantPast

    private func enterListening() {
        vad.reset()
        vad.setBargeInMode(false)
        phase = .listening
        outputLevel = 0
        listeningCooldownUntil = Date().addingTimeInterval(0.6)
        armIdleTimer()
    }

    // MARK: - Idle auto-close

    /// After this many seconds in `.listening` with no user speech, the voice
    /// session closes itself. Keeps always-listening-feel from becoming
    /// always-capturing-ambient-audio when the user walks away.
    private let idleAutoStopSeconds: TimeInterval = 180
    private var idleTimer: Timer?

    private func armIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: idleAutoStopSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.idleTimeoutFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    @MainActor
    private func idleTimeoutFired() {
        // Only auto-close if we're still idle — activity may have arrived
        // between the timer firing and the MainActor hop.
        guard phase == .listening else { return }
        NSLog("[Voice] idle auto-stop after \(Int(idleAutoStopSeconds))s of silence")
        stop()
        appState?.showVoiceOverlay = false
    }
}
