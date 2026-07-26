import Foundation
import AppKit

/// Orchestrates the meeting-transcription flow:
///
///   detection (external app grabs the mic)
///     → floating banner prompt ("Start transcribing?")
///       → MeetingRecorder (mic + system audio → transcript)
///         → MeetingAnalysisService (background agent → meeting note + to-dos)
///
/// Held by `AppState` (like `MeetingPrepService`); `OttoApp` calls
/// `configure` + `setEnabled` and consults `isRecording` before starting the
/// wake-word listener.
///
/// Not `@MainActor`-annotated so `AppState.init` can instantiate it as a
/// stored property; all real work happens in @MainActor methods.
final class MeetingTranscriptionCoordinator: @unchecked Sendable {

    let recorder = MeetingRecorder()
    private let detection = MeetingDetectionService()
    private weak var appState: AppState?
    private var enabled = false
    /// App that grabbed the mic for the current detection — remembered so
    /// `startRecording()` can build the Context even after the banner has
    /// expanded past the `.prompt` phase (which used to carry the name).
    private var lastDetectedAppName: String?

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Wiring

    @MainActor
    func configure(appState: AppState) {
        self.appState = appState
        recorder.configure(appState: appState)

        detection.onExternalMicActive = { [weak self] appName in
            self?.handleMeetingDetected(appName: appName)
        }
        recorder.onStarted = { [weak self] in
            guard let self, let startedAt = self.recorder.startedAt else { return }
            // Recording began — expand the panel (fields stay editable live).
            MeetingBannerController.shared.showExpanded(
                recording: true,
                startedAt: startedAt,
                systemAudioAvailable: self.recorder.systemAudioAvailable
            )
        }
        detection.onExternalMicReleased = { [weak self] in
            self?.handleMicReleased()
        }

        let banner = MeetingBannerController.shared.model
        // Başlat → start recording immediately; the panel expands via onStarted.
        banner.onStartNow = { [weak self] in self?.startRecording() }
        // Tap the pill → open the prep panel first, without recording yet.
        banner.onOpenPrep = {
            MeetingBannerController.shared.showExpanded(
                recording: false, startedAt: nil, systemAudioAvailable: true
            )
        }
        banner.onStop = { [weak self] in self?.stopRecording(reason: .user) }
        banner.onDismiss = { MeetingBannerController.shared.hide() }
        // Fields edited while recording → keep the recorder's context in sync.
        banner.onPrepChanged = { [weak self] in
            self?.recorder.updatePrep(banner.prep)
        }
    }

    @MainActor
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            detection.start()
        } else {
            detection.stop()
            if recorder.isRecording {
                stopRecording(reason: .disabled)
            } else {
                MeetingBannerController.shared.hide()
            }
        }
    }

    // MARK: - Flow

    @MainActor
    private func handleMeetingDetected(appName: String) {
        guard enabled, !recorder.isRecording else { return }
        // Don't prompt over Otto's own voice mode.
        if appState?.showVoiceOverlay == true { return }
        lastDetectedAppName = appName
        let event = currentCalendarEvent()
        MeetingBannerController.shared.showPrompt(appName: appName, meetingTitle: event?.title)
    }

    @MainActor
    private func handleMicReleased() {
        if recorder.isRecording {
            stopRecording(reason: .micReleased)
        } else {
            // Meeting ended before the user reacted — retire the prompt.
            MeetingBannerController.shared.hideIfPrompt()
        }
    }

    @MainActor
    private func startRecording() {
        guard !recorder.isRecording else { return }
        let event = currentCalendarEvent()
        let appName = lastDetectedAppName ?? "meeting app"
        // Whatever the user has typed in the prep panel so far rides along; it
        // keeps updating live via banner.onPrepChanged → recorder.updatePrep.
        let prep = MeetingBannerController.shared.model.prep
        // Banner expands to the recording face via recorder.onStarted (start
        // can be async behind the first-run mic permission prompt).
        recorder.start(context: .init(appName: appName, calendarEvent: event, prep: prep))
    }

    @MainActor
    private func stopRecording(reason: MeetingRecorder.StopReason) {
        MeetingBannerController.shared.hide()
        Task { [recorder] in
            await recorder.stop(reason: reason)
        }
    }

    /// The calendar event happening right now (start −10 min … end), used to
    /// title the banner and enrich the analysis prompt. Closest start wins.
    @MainActor
    private func currentCalendarEvent() -> CalendarEvent? {
        guard let appState else { return nil }
        let now = Date()
        return appState.calendarEvents
            .filter { !$0.isAllDay
                && $0.startTime.addingTimeInterval(-10 * 60) <= now
                && now <= $0.endTime }
            .min { abs($0.startTime.timeIntervalSince(now)) < abs($1.startTime.timeIntervalSince(now)) }
    }
}
