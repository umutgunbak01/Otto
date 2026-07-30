import Foundation
import AppKit

/// Runs the user's recurring tasks (Automations tab). Anacron-style: Otto
/// only executes while the app is open, so every task persists a `nextDueAt`
/// and the scheduler sweeps for overdue tasks at launch, on wake from sleep,
/// and every minute — a 9:00 task on a Mac opened at 10:00 runs at 10:00.
///
/// Each run is a real background chat session (`ChatRunController.send` with
/// `background: true`): pinned title, no focus steal, no IntentRouter side
/// effects, full transcript in the history sidebar, completion notification
/// deep-linking into the session.
///
/// Lifecycle mirrors `MeetingPrepService`: `configure(appState:)` from
/// `AppState.init`, `start()` from the end of `AppState.loadData()` once the
/// task list is hydrated. Observers live on this singleton-ish service (owned
/// by AppState), not the SwiftUI scene, so they survive window close.
@MainActor
@Observable
final class TaskSchedulerService {

    /// Tasks with an agent run currently in flight — drives row spinners.
    private(set) var runningTaskIds: Set<UUID> = []

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    /// Re-entrancy guard for the sweep — ticks that land mid-pass are dropped
    /// (the pass re-evaluates dueness after every run anyway).
    @ObservationIgnored private var isProcessing = false

    static let tickInterval: TimeInterval = 60

    /// Nonisolated so AppState can create the service in its own (nonisolated)
    /// stored-property initializer; every stored property has a default.
    nonisolated init() {}

    func configure(appState: AppState) {
        self.appState = appState
    }

    /// Idempotent. Flips stale `.running` run records to `.interrupted`
    /// (the app died mid-run), then performs the catch-up sweep.
    func start() {
        guard !started else { return }
        started = true

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            })
        }
        let center = NotificationCenter.default
        // Clock jumped (NTP correction, manual change): don't recompute —
        // an overdue `nextDueAt` is a pending catch-up we must not discard —
        // just sweep with the new "now".
        observers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        })
        // Timezone changed: schedules are wall-clock-local, so future due
        // dates are re-anchored; overdue ones are kept so catch-up still fires.
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.reanchorFutureDueDates()
                self?.tick()
            }
        })

        let t = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        Task { @MainActor in
            await self.cleanupInterruptedRuns()
            self.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        started = false
    }

    /// Nudge the scheduler outside its timer cadence (task created/edited).
    func tickSoon() {
        Task { @MainActor in self.tick() }
    }

    func isRunning(_ taskId: UUID) -> Bool {
        runningTaskIds.contains(taskId)
    }

    var isPaused: Bool {
        UserDefaults.standard.bool(forKey: AutomationSettings.pausedKey)
    }

    /// True when `task` is overdue but can't run because no agent backend is
    /// signed in — the Automations tab shows "waiting for backend".
    func isWaitingForBackend(_ task: ScheduledTask) -> Bool {
        guard task.isEnabled, let due = task.nextDueAt else { return false }
        return due <= Date() && Self.usableBackend() == nil
    }

    // MARK: - Decision engine (pure, unit-tested)

    enum Action: Equatable {
        /// Not due (or disabled) — nothing to do.
        case wait
        /// Move `nextDueAt` forward without running (occurrence already
        /// satisfied today, skip policy, or missing due date to seed).
        case advance(to: Date)
        /// Run now, satisfying the occurrence that was scheduled for the
        /// associated date (== `nextDueAt`; earlier than now for catch-ups).
        case run(scheduledFor: Date)
    }

    /// The anacron rule. All schedule frequencies have at most one occurrence
    /// per calendar day, so "run when overdue" + "at most one scheduled run
    /// per calendar day" yields: fire on time when the app is up, fire once
    /// at the first opportunity when it wasn't, and never stack a catch-up
    /// on top of the same day's regular fire.
    nonisolated static func evaluate(
        task: ScheduledTask,
        now: Date,
        calendar: Calendar = .current
    ) -> Action {
        guard task.isEnabled else { return .wait }
        guard let due = task.nextDueAt else {
            // Enabled but never seeded (imported/legacy data) — seed forward.
            return .advance(to: task.schedule.nextOccurrence(after: now, calendar: calendar))
        }
        guard now >= due else { return .wait }
        // Once-per-day guard: an earlier run today (usually a pre-dawn
        // catch-up of yesterday's missed occurrence) already covers today.
        if let last = task.lastRunAt, calendar.isDate(last, inSameDayAs: now) {
            return .advance(to: task.schedule.nextOccurrence(after: now, calendar: calendar))
        }
        // Skip policy: this task only makes sense on its scheduled day.
        if task.catchUpPolicy == .skipToNext, !calendar.isDate(due, inSameDayAs: now) {
            return .advance(to: task.schedule.nextOccurrence(after: now, calendar: calendar))
        }
        return .run(scheduledFor: due)
    }

    // MARK: - Sweep

    private func tick() {
        guard started, appState != nil else { return }
        guard !isPaused, !isProcessing else { return }
        isProcessing = true
        Task { @MainActor in
            defer { self.isProcessing = false }
            await self.sweep()
        }
    }

    private func sweep() async {
        guard let appState else { return }
        let now = Date()

        // Pure advances first (seeding, satisfied-today, skip policy).
        for task in appState.scheduledTasks {
            if case .advance(let to) = Self.evaluate(task: task, now: now) {
                var updated = task
                updated.nextDueAt = to
                await appState.updateScheduledTask(updated)
            }
        }

        // Overdue tasks wait (nextDueAt untouched) until a backend is usable,
        // then run FIFO by dueness, one at a time. Re-evaluate after every
        // run — running advances the task's own due date, edits may have
        // landed, and the backend can sign out mid-pass.
        var safety = appState.scheduledTasks.count * 2 + 4
        while safety > 0 {
            safety -= 1
            guard Self.usableBackend() != nil else { return }
            let candidate = appState.scheduledTasks
                .filter { !runningTaskIds.contains($0.id) }
                .compactMap { task -> (ScheduledTask, Date)? in
                    if case .run(let scheduledFor) = Self.evaluate(task: task, now: Date()) {
                        return (task, scheduledFor)
                    }
                    return nil
                }
                .min { $0.1 < $1.1 }
            guard let (task, scheduledFor) = candidate else { return }

            // Consume the occurrence at run START: `lastRunAt` drives the
            // once-per-day guard, and the advanced `nextDueAt` makes a crash
            // mid-run a missed run — never a rerun loop.
            var updated = task
            updated.lastRunAt = Date()
            updated.nextDueAt = task.schedule.nextOccurrence(after: Date())
            await appState.updateScheduledTask(updated)

            await execute(updated, scheduledFor: scheduledFor, wasManual: false)
        }
    }

    // MARK: - Execution

    /// Manual "Run now". Normally leaves the schedule alone (an 8:50 manual
    /// run doesn't swallow the 9:00 fire) — EXCEPT when the task is already
    /// overdue: then the manual run satisfies the pending occurrence, so the
    /// sweep doesn't fire a near-duplicate catch-up run right after it.
    func runNow(_ task: ScheduledTask) {
        guard !runningTaskIds.contains(task.id) else { return }
        Task { @MainActor in
            var target = task
            if let appState = self.appState,
               target.isEnabled,
               let due = target.nextDueAt, due <= Date() {
                target.lastRunAt = Date()
                target.nextDueAt = target.schedule.nextOccurrence(after: Date())
                await appState.updateScheduledTask(target)
            }
            await self.execute(target, scheduledFor: Date(), wasManual: true)
        }
    }

    private func execute(_ task: ScheduledTask, scheduledFor: Date, wasManual: Bool) async {
        guard let appState else { return }
        guard Self.usableBackend() != nil else {
            // Scheduled runs are gated before this point; a manual run with
            // no backend gets a failed record so the click isn't silent.
            if wasManual {
                var record = TaskRunRecord(scheduledFor: scheduledFor, wasManual: true)
                record.status = .failed
                record.finishedAt = Date()
                record.errorMessage = "No agent backend signed in."
                if var fresh = appState.scheduledTasks.first(where: { $0.id == task.id }) {
                    fresh.appendRun(record)
                    await appState.updateScheduledTask(fresh)
                }
            }
            return
        }

        runningTaskIds.insert(task.id)
        defer { runningTaskIds.remove(task.id) }

        // Pinned-title session shell first, so the run's eager persist finds
        // (and keeps) the title instead of deriving one from the prompt.
        let sessionId = UUID()
        let title = "\(task.name) — \(Self.titleDateFormatter.string(from: Date()))"
        await appState.upsertChatSession(
            ChatSession(id: sessionId, title: title, turns: [], titlePinned: true)
        )

        let record = TaskRunRecord(
            scheduledFor: scheduledFor,
            status: .running,
            chatSessionId: sessionId,
            wasManual: wasManual
        )
        if var fresh = appState.scheduledTasks.first(where: { $0.id == task.id }) {
            fresh.appendRun(record)
            await appState.updateScheduledTask(fresh)
        }

        // Per-task auto-approve: while this run is in flight, every tool
        // permission request in its session resolves to "allow" (no card).
        // Registration is scoped to the run — a later manual chat in the
        // same session gets normal approval behavior.
        if task.autoApproveTools {
            ToolApprovalPolicy.shared.beginAutoApprovingSession(sessionId)
        }
        defer {
            if task.autoApproveTools {
                ToolApprovalPolicy.shared.endAutoApprovingSession(sessionId)
            }
        }

        let controller = appState.chatRuns.openController(for: sessionId, appState: appState)
        let errorMessage: String? = await withCheckedContinuation { continuation in
            controller.send(
                text: task.prompt,
                attachments: [],
                appState: appState,
                background: true
            ) { error in
                continuation.resume(returning: error)
            }
        }

        if var fresh = appState.scheduledTasks.first(where: { $0.id == task.id }),
           let idx = fresh.runs.firstIndex(where: { $0.id == record.id }) {
            fresh.runs[idx].finishedAt = Date()
            fresh.runs[idx].status = errorMessage == nil ? .succeeded : .failed
            fresh.runs[idx].errorMessage = errorMessage
            await appState.updateScheduledTask(fresh)
        }

        if task.notifyOnCompletion {
            let body = errorMessage == nil
                ? "Finished — open to see the result."
                : "Failed: \(errorMessage ?? "unknown error")"
            try? await NotificationService.shared.notifyTaskComplete(
                taskName: task.name,
                chatSessionId: sessionId,
                body: body
            )
        }
    }

    // MARK: - Maintenance

    /// Run records left `.running` by a mid-run quit become `.interrupted`.
    /// The chat session keeps whatever partial transcript was checkpointed.
    private func cleanupInterruptedRuns() async {
        guard let appState else { return }
        for var task in appState.scheduledTasks {
            var changed = false
            for idx in task.runs.indices where task.runs[idx].status == .running {
                task.runs[idx].status = .interrupted
                task.runs[idx].finishedAt = task.runs[idx].finishedAt ?? task.runs[idx].startedAt
                changed = true
            }
            if changed {
                await appState.updateScheduledTask(task)
            }
        }
    }

    /// After a timezone change, future due dates re-anchor to the new local
    /// wall clock. Overdue ones are pending catch-ups and stay put.
    private func reanchorFutureDueDates() async {
        guard let appState else { return }
        let now = Date()
        for task in appState.scheduledTasks where task.isEnabled {
            if let due = task.nextDueAt, due <= now { continue }
            var updated = task
            updated.nextDueAt = task.schedule.nextOccurrence(after: now)
            await appState.updateScheduledTask(updated)
        }
    }

    // MARK: - Backend availability

    /// Same gate the daily briefing uses: the user's selected backend, but
    /// only if it's actually signed in / installed.
    static func usableBackend() -> AgentBackend? {
        switch AgentBackend.current {
        case .claude:
            return ClaudeAuthService.shared.effectiveAuthMode() != .none ? .claude : nil
        case .codex:
            return CodexAuthService.shared.effectiveAuthMode() != .none ? .codex : nil
        case .hermes:
            return HermesInstallation.binaryPath() != nil ? .hermes : nil
        }
    }

    private static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
