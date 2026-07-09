import Foundation
import SwiftUI
import AVFoundation

/// Orchestrates the full voice-mode loop:
/// mic capture → VAD → Wizper STT → streaming Claude → sentence-chunked
/// ElevenLabs Turbo v2.5 TTS (prefetched up to 3 sentences ahead) → playback.
///
/// Every session also mirrors into a regular chat conversation (see
/// `chatController`): the normal chat UI streams the same turns — text,
/// tool chips, item previews — live behind the compact voice panel, and the
/// conversation persists into chat history like a typed one.
///
/// Interruption is MANUAL: the voice panel's stop button calls `interrupt()`,
/// which cancels the in-flight turn/TTS and returns to listening. VAD-driven
/// barge-in was removed — without an acoustic echo canceller, the built-in
/// mic + speakers setup kept tripping the threshold on Otto's own TTS audio
/// and the session interrupted itself.
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

    /// A sentence waiting to be spoken. `synth` is the eagerly-started synthesis
    /// request — `pumpSynthPrefetch` starts up to `maxConcurrentSynth` of these
    /// ahead of playback so sentence N+1's audio is already downloading while
    /// sentence N plays, and playback never gaps between sentences.
    private struct TTSItem {
        let text: String
        let previousText: String?
        var synth: Task<Data, Error>?
    }

    /// Ordered playback queue + prefetch bookkeeping. The serial processor pops
    /// items strictly in order, so speech order matches text order even though
    /// synthesis requests complete out of order.
    private var ttsSerialTask: Task<Void, Never>? = nil
    private var ttsQueue: [TTSItem] = []
    private var ttsContinuations: [CheckedContinuation<Void, Never>] = []
    /// Synthesis requests currently in flight (prefetch bound).
    private var ttsInFlightSynths = 0
    private let maxConcurrentSynth = 3
    /// The synth the serial processor is currently awaiting — cancelled on
    /// barge-in/stop so the HTTP request aborts instead of running to completion.
    private var currentSynth: Task<Data, Error>? = nil
    /// Text already handed to TTS this turn — becomes `previous_text` for later
    /// sentences so ElevenLabs keeps prosody continuous across requests.
    private var turnSpokenText = ""
    /// Guards ttsQueue / ttsContinuations / ttsInFlightSynths / currentSynth /
    /// turnSpokenText — touched from the Claude delta callback (network thread),
    /// the serial processor task, and MainActor paths (barge-in, stop).
    /// Always taken via `withTTSLock` so lock/unlock stay in synchronous code
    /// (NSLock is unavailable directly in async contexts under Swift 6).
    private let ttsLock = NSLock()

    private func withTTSLock<T>(_ body: () -> T) -> T {
        ttsLock.lock()
        defer { ttsLock.unlock() }
        return body()
    }

    /// Currently-running Claude streaming task — cancellable on barge-in or close.
    private var claudeTask: Task<Void, Never>? = nil
    /// Session key isolating voice-mode runs from text chats on the shared
    /// backends (per-run subprocess tracking / per-conversation ACP session).
    /// Regenerated per voice session — it doubles as the chat conversation id
    /// the session mirrors into, and each voice session is its own conversation.
    private var voiceSessionKey = UUID()
    /// Chat controller this voice session mirrors into so the regular chat UI
    /// shows the conversation live — user bubbles, streaming text, tool chips,
    /// preview cards — exactly like a typed run. The agent run stays here (we
    /// need per-token deltas for TTS); the controller only renders + persists.
    private var chatController: ChatRunController?

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
        resetPendingTurn()

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

        // Fire a tiny real Wizper request while the user is still speaking their
        // first utterance — pays all one-time client costs (proxy/DNS/TLS/HTTP2)
        // and boots a fal worker, so the first real transcription runs warm.
        // Then keep pinging while the session idles in .listening: the shared
        // wizper endpoint's workers go cold within minutes, and a cold hit
        // costs 10-20s (observed) on what is otherwise a ~1.5s transcription.
        Task { await falAI.warmUp() }
        keepWarmTask?.cancel()
        keepWarmTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.phase == .listening {
                    await self.falAI.warmUp()
                }
            }
        }

        do {
            vad.reset()
            vad.setBargeInMode(false)
            try mic.start()
            // Every voice session is a fresh chat conversation. The mirror
            // controller renders it in the normal chat UI (visible behind the
            // compact voice panel) and persists it into chat history.
            voiceSessionKey = UUID()
            chatController = await appState.chatRuns.openController(for: voiceSessionKey, appState: appState)
            appState.activeChatSessionId = voiceSessionKey
            // Three open paths, in priority order:
            //   1. Morning briefing — first clap of the day. A synthetic user
            //      turn runs through Claude (tools + web) and the response
            //      streams to TTS. beginClaudeTurn handles phase+barge-in.
            //   2. Plain greeting — speak a canned line before listening.
            //   3. Straight to listening — manual mic-button open.
            if appState.pendingBriefing {
                appState.pendingBriefing = false
                beginClaudeTurn(userText: MorningBriefingService.composeGreetingPrompt(),
                                displayText: "Morning briefing")
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

    /// Keep-warm pinger for the fal STT path while the session is open.
    private var keepWarmTask: Task<Void, Never>?

    /// End the voice session cleanly.
    func stop() {
        cancelIdleTimer()
        keepWarmTask?.cancel()
        keepWarmTask = nil
        resetPendingTurn()
        mic.stop()
        tts.stop()
        isClaudeStreaming = false
        claudeTask?.cancel()
        claudeTask = nil
        ttsSerialTask?.cancel()
        ttsSerialTask = nil
        clearTTSPipeline()
        wakeTTSSerialProcessor()
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
        // NOTE: vad.onBargeIn is deliberately not wired. Barge-in mode is still
        // used while Otto thinks/speaks — but only to SUPPRESS utterance
        // capture (TTS echo); interruption itself is the panel's stop button.
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
                if !self.tts.isPlaying, self.ttsQueueIsEmpty(), self.ttsSerialTask == nil,
                   !self.isClaudeStreaming, self.phase == .speaking {
                    self.enterListening()
                }
            }
        }
    }

    // MARK: - Utterance pipeline (chunked STT, merged turns)

    /// Transcribed utterance chunks awaiting commit, ordered by capture
    /// sequence (STT responses can land out of order). The VAD closes an
    /// utterance after only 500ms of silence — great as an STT boundary
    /// (chunks transcribe while the user keeps talking) but too eager as a
    /// TURN boundary: a thinking pause mid-sentence would ship a fragment to
    /// the agent. Chunks accumulate here and `tryCommitTurn` sends the merged
    /// text as ONE turn once the user has actually stopped speaking.
    private var pendingParts: [(seq: Int, text: String)] = []
    private var nextUtteranceSeq = 0
    /// STT requests in flight for chunks of the current (uncommitted) turn.
    private var pendingSTTCount = 0
    /// Wall-clock moment the most recent VAD utterance was emitted.
    private var lastUtteranceEndedAt: Date = .distantPast
    /// Extra silence required after the last chunk before the merged turn is
    /// committed. Total end-of-turn silence = VAD hangover (500ms) + this.
    /// Deliberately below typical STT time (~1.5s) so single-utterance turns
    /// commit the instant their transcription lands — the window only delays
    /// turns when the user pauses and might resume.
    private let utteranceMergeWindow: TimeInterval = 1.25
    /// Debounced commit check (see `scheduleCommitCheck`).
    private var commitTask: Task<Void, Never>?
    /// Bumped whenever pending state is reset — in-flight STT results from a
    /// previous generation (e.g. after an error reset) are dropped on arrival.
    private var turnGeneration = 0

    private func handleUtterance(wav: Data) {
        // Accept while listening OR while earlier chunks are transcribing /
        // awaiting commit — that's the "user kept talking" case we merge.
        // Anything later (thinking/speaking) is ignored — interrupting Otto
        // is the panel's stop button, not the mic.
        guard phase == .listening || phase == .transcribing else { return }
        // Ignore if we just flipped to listening — lets TTS echo tail dissipate.
        if Date() < listeningCooldownUntil { return }

        // Activity — keep the session alive.
        cancelIdleTimer()

        phase = .transcribing
        lastUtteranceEndedAt = Date()
        let seq = nextUtteranceSeq
        nextUtteranceSeq += 1
        pendingSTTCount += 1
        let gen = turnGeneration
        let clipWav = wav

        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.falAI.transcribeWizper(wavData: clipWav)
                await MainActor.run {
                    guard gen == self.turnGeneration else { return }
                    self.pendingSTTCount -= 1
                    self.pendingParts.append((seq: seq, text: text))
                    self.pendingParts.sort { $0.seq < $1.seq }
                    self.liveTranscript = self.pendingParts.map(\.text).joined(separator: " ")
                    if self.pendingSTTCount == 0, self.phase == .transcribing {
                        self.phase = .listening
                    }
                    self.tryCommitTurn()
                }
            } catch FalAIService.FalAIError.transcriptionEmpty {
                // Empty or hallucinated — this chunk contributes nothing, but it
                // must not block a turn built from earlier real chunks.
                await MainActor.run {
                    guard gen == self.turnGeneration else { return }
                    self.pendingSTTCount -= 1
                    if self.pendingParts.isEmpty, self.pendingSTTCount == 0 {
                        self.enterListening()
                    } else {
                        self.tryCommitTurn()
                    }
                }
            } catch {
                await MainActor.run {
                    guard gen == self.turnGeneration else { return }
                    self.resetPendingTurn()
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

    /// Commit the merged pending chunks as one agent turn — but only once the
    /// user has genuinely finished: every chunk transcribed, the VAD not
    /// mid-capture, and `utteranceMergeWindow` of extra silence elapsed.
    /// Re-schedules itself while any condition is unmet.
    private func tryCommitTurn() {
        guard phase == .listening || phase == .transcribing else { return }
        guard !pendingParts.isEmpty, pendingSTTCount == 0 else { return }
        // User resumed speaking — the chunk in progress re-triggers us when it
        // emits; poll as a fallback for captures the VAD ends up rejecting.
        if vad.isCapturingSpeech {
            scheduleCommitCheck(after: 0.3)
            return
        }
        let elapsed = Date().timeIntervalSince(lastUtteranceEndedAt)
        if elapsed < utteranceMergeWindow {
            scheduleCommitCheck(after: utteranceMergeWindow - elapsed + 0.05)
            return
        }

        let merged = pendingParts.map(\.text).joined(separator: " ")
        resetPendingTurn()
        liveTranscript = merged
        Task { [weak self] in
            guard let self else { return }
            // Apply any deterministic intent side-effects (may capture a
            // screenshot) before starting the Claude turn, so the context
            // note Claude sees references work the model can already see.
            let effective = await self.prepareTurnText(userText: merged)
            await MainActor.run {
                guard self.phase == .listening || self.phase == .transcribing else { return }
                self.beginClaudeTurn(userText: effective, displayText: merged)
            }
        }
    }

    private func scheduleCommitCheck(after delay: TimeInterval) {
        commitTask?.cancel()
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.tryCommitTurn()
        }
    }

    /// Drop all uncommitted chunk state (on commit, error, or session stop).
    private func resetPendingTurn() {
        turnGeneration += 1
        pendingParts.removeAll()
        pendingSTTCount = 0
        commitTask?.cancel()
        commitTask = nil
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

    /// `displayText` is what the mirrored chat bubble shows (raw transcript);
    /// `userText` is what the model receives (may carry an intent context note).
    private func beginClaudeTurn(userText: String, displayText: String? = nil) {
        guard let appState else { return }

        turns.append(ChatTurn(role: "user", blocks: [.text(userText)]))
        phase = .thinking
        chunker = SentenceChunker()
        inflightAssistantText = ""
        withTTSLock { turnSpokenText = "" }
        // CRITICAL: set the streaming flag BEFORE starting the TTS processor.
        // The processor's popNextSentence() reads this to know whether to park
        // awaiting more sentences vs. exit. If it read claudeTask directly there
        // would be a race where the processor runs before claudeTask is assigned
        // below, sees nil, and exits immediately.
        isClaudeStreaming = true
        // Barge-in mode here only SUPPRESSES utterance capture while the agent
        // works (and later speaks) — without an echo canceller the open mic
        // hears Otto's own TTS. Interruption is the panel's stop button.
        vad.setBargeInMode(true)
        startTTSSerialProcessor()

        let currentTurns = turns
        let state = appState
        let mirror = chatController
        let mirroredUserText = displayText ?? userText
        let turnText = userText

        claudeTask = Task { [weak self] in
            guard let self else { return }
            let executor = await MainActor.run { OttoToolExecutor(appState: state) }
            let systemPrompt = state.claude.buildSystemPrompt(from: state)
            // Mirror the user turn into the chat UI before events start flowing.
            await MainActor.run {
                mirror?.beginExternalTurn(displayText: mirroredUserText, turnText: turnText, appState: state)
            }

            do {
                let updated = try await state.claude.streamChatWithTools(
                    sessionKey: self.voiceSessionKey,
                    turns: currentTurns,
                    systemPrompt: systemPrompt,
                    tools: OttoTools.all,
                    executor: executor,
                    onDelta: { [weak self] delta in
                        self?.handleAssistantDelta(delta)
                    },
                    onEvent: { event in
                        // Feed the full event stream (streaming text, thinking,
                        // tool chips, preview cards) into the mirrored chat —
                        // identical rendering to a typed run.
                        mirror?.ingestExternalEvent(event, appState: state)
                    }
                )
                await MainActor.run {
                    self.turns = updated
                    mirror?.completeExternalTurn(canonicalTurns: updated, appState: state)
                    self.finishClaudeTurn()
                }
            } catch is CancellationError {
                // User-initiated interrupt, overlay dismissal, or the chat UI's
                // Stop button cancelled the stream — not an error.
                await MainActor.run {
                    self.isClaudeStreaming = false
                    self.claudeTask = nil
                    self.wakeTTSSerialProcessor()
                    mirror?.interruptExternalTurn(appState: state)
                    // Barge-in / stop already transitioned phase. A chat-side
                    // Stop while we were waiting on tools doesn't — recover.
                    if self.phase == .thinking { self.enterListening() }
                }
            } catch {
                // `URLError.cancelled` is also how URLSession surfaces task cancellation.
                if (error as? URLError)?.code == .cancelled {
                    await MainActor.run {
                        self.isClaudeStreaming = false
                        self.claudeTask = nil
                        self.wakeTTSSerialProcessor()
                        mirror?.interruptExternalTurn(appState: state)
                        if self.phase == .thinking { self.enterListening() }
                    }
                    return
                }
                await MainActor.run {
                    self.setError(error.localizedDescription)
                    self.tts.stop()
                    self.isClaudeStreaming = false
                    self.claudeTask = nil
                    self.wakeTTSSerialProcessor()
                    mirror?.error = error.localizedDescription
                    mirror?.interruptExternalTurn(appState: state)
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

        // First delta = TTS about to start. Keep the VAD in barge-in mode so
        // it captures no utterances while Otto's speech is on the speakers.
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
        // Persistence (chat session + askHistory) happens through the mirror
        // controller's completeExternalTurn — see beginClaudeTurn.
        // Edge case: Claude completed without ever emitting a text delta (e.g. only
        // tool calls ran out to the loop cap, or silent completion). Phase would
        // stay at .thinking forever — drop back to listening so the user can retry.
        if phase == .thinking, ttsQueueIsEmpty(), !tts.isPlaying {
            enterListening()
        }
        // Otherwise: TTS queue may still be draining — onChunkCompleted flips us
        // to .listening when audio is fully done.
    }

    // MARK: - Serial TTS processor

    private func enqueueTTS(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withTTSLock {
            // Only the tail of the spoken text — long previous_text adds synthesis
            // latency for marginal prosody gain.
            let prev = turnSpokenText.isEmpty ? nil : String(turnSpokenText.suffix(280))
            turnSpokenText += turnSpokenText.isEmpty ? trimmed : " " + trimmed
            ttsQueue.append(TTSItem(text: trimmed, previousText: prev, synth: nil))
        }
        pumpSynthPrefetch()
        // Wake the serial processor if it's parked.
        wakeTTSSerialProcessor()
    }

    /// Eagerly starts synthesis for queued sentences, bounded by
    /// `maxConcurrentSynth`. Called on enqueue and whenever a synth finishes,
    /// so the window slides forward as capacity frees up.
    private func pumpSynthPrefetch() {
        withTTSLock {
            var i = 0
            while i < ttsQueue.count, ttsInFlightSynths < maxConcurrentSynth {
                if ttsQueue[i].synth == nil {
                    ttsInFlightSynths += 1
                    ttsQueue[i].synth = startSynthTask(text: ttsQueue[i].text,
                                                       previousText: ttsQueue[i].previousText)
                }
                i += 1
            }
        }
    }

    private func startSynthTask(text: String, previousText: String?) -> Task<Data, Error> {
        let voiceId = falAI.getVoiceId()
        return Task { [falAI = self.falAI, weak self] in
            defer {
                if let self {
                    self.withTTSLock { self.ttsInFlightSynths -= 1 }
                    self.pumpSynthPrefetch()
                }
            }
            return try await falAI.synthesizeTurboV25(text: text, voiceId: voiceId,
                                                      previousText: previousText)
        }
    }

    private func startTTSSerialProcessor() {
        guard ttsSerialTask == nil else { return }
        ttsSerialTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let item = await self.popNextItem() else { break }
                // Prefetch may not have reached this sentence yet (concurrency
                // cap) — start it now; playback order is preserved regardless
                // because only this loop hands audio to the player.
                let synth: Task<Data, Error>
                if let started = item.synth {
                    synth = started
                } else {
                    self.withTTSLock { self.ttsInFlightSynths += 1 }
                    synth = self.startSynthTask(text: item.text, previousText: item.previousText)
                }
                self.withTTSLock { self.currentSynth = synth }
                do {
                    let audio = try await synth.value
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
            self.withTTSLock { self.currentSynth = nil }
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
    private func popNextItem() async -> TTSItem? {
        enum Next { case item(TTSItem), exit, park }
        while true {
            if Task.isCancelled { return nil }
            let next: Next = withTTSLock {
                if !ttsQueue.isEmpty { return .item(ttsQueue.removeFirst()) }
                if !isClaudeStreaming { return .exit }
                return .park
            }
            switch next {
            case .item(let item):
                return item
            case .exit:
                // Claude is done producing and the queue drained → exit.
                return nil
            case .park:
                // Park until a new sentence arrives. The re-check under the
                // lock closes the lost-wakeup window between the empty check
                // above and the continuation being registered. Cancellation
                // paths (stop / barge-in) flip isClaudeStreaming before waking,
                // so a cancelled processor never parks indefinitely.
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let parked: Bool = withTTSLock {
                        if !ttsQueue.isEmpty || !isClaudeStreaming { return false }
                        ttsContinuations.append(cont)
                        return true
                    }
                    if !parked { cont.resume() }
                }
            }
        }
    }

    private func wakeTTSSerialProcessor() {
        let conts: [CheckedContinuation<Void, Never>] = withTTSLock {
            let c = ttsContinuations
            ttsContinuations.removeAll()
            return c
        }
        for c in conts { c.resume() }
    }

    private func ttsQueueIsEmpty() -> Bool {
        withTTSLock { ttsQueue.isEmpty }
    }

    /// Drops all queued sentences and aborts every in-flight synthesis request
    /// (prefetched ones and the one playback is awaiting). Used by barge-in and stop.
    private func clearTTSPipeline() {
        withTTSLock {
            for item in ttsQueue { item.synth?.cancel() }
            ttsQueue.removeAll()
            currentSynth?.cancel()
            currentSynth = nil
            turnSpokenText = ""
        }
    }

    // MARK: - Interrupt

    /// Manually interrupt Otto mid-turn — wired to the voice panel's stop
    /// button. Cancels the in-flight Claude turn and TTS, preserves partial
    /// assistant text for follow-up context, and returns to listening.
    func interrupt() {
        // Accept interrupt from both .thinking (abort search) and .speaking
        // (cut off Claude mid-reply).
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
        // 3. Stop TTS playback, abort in-flight synthesis, cancel the serial task.
        tts.stop()
        ttsSerialTask?.cancel()
        ttsSerialTask = nil
        clearTTSPipeline()
        wakeTTSSerialProcessor()
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
