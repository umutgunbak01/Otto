import SwiftUI

/// State shown in the floating meeting banner. Owned by
/// `MeetingBannerController`; the view just renders it.
@Observable
final class MeetingBannerModel {
    enum BannerState {
        case hidden
        /// "Meeting detected — start transcribing?"
        case prompt(appName: String, meetingTitle: String?)
        /// Recording pill with a live elapsed timer.
        case recording(startedAt: Date, systemAudioAvailable: Bool)
    }

    var state: BannerState = .hidden

    // Wired by the coordinator.
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onDismiss: (() -> Void)?
}

/// Top-of-screen pill shown over every app (including fullscreen meetings).
/// Two faces: the detection prompt and the recording indicator.
struct MeetingBannerView: View {
    let model: MeetingBannerModel

    var body: some View {
        Group {
            switch model.state {
            case .hidden:
                EmptyView()
            case .prompt(let appName, let meetingTitle):
                promptFace(appName: appName, meetingTitle: meetingTitle)
            case .recording(let startedAt, let systemAudioAvailable):
                recordingFace(startedAt: startedAt, systemAudioAvailable: systemAudioAvailable)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Theme.Colors.bg1)
                .overlay(Capsule().stroke(Theme.Colors.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
        )
        .fixedSize()
    }

    // MARK: - Prompt

    private func promptFace(appName: String, meetingTitle: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.cyan)

            VStack(alignment: .leading, spacing: 1) {
                Text(meetingTitle ?? "Meeting detected")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Text(meetingTitle == nil
                     ? "\(appName) is using your microphone"
                     : "Detected via \(appName)")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)
            }
            .frame(maxWidth: 280, alignment: .leading)

            Button {
                model.onStart?()
            } label: {
                Text("Start transcribing")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.Colors.cyan))
            }
            .buttonStyle(.plain)

            Button {
                model.onDismiss?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.Colors.hoverTint))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recording

    private func recordingFace(startedAt: Date, systemAudioAvailable: Bool) -> some View {
        HStack(spacing: 10) {
            PulsingDot()

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(Self.elapsedString(from: startedAt, to: timeline.date))
                    .font(Theme.Typography.monoBody)
                    .foregroundStyle(Theme.Colors.text)
            }

            Text(systemAudioAvailable ? "Transcribing" : "Transcribing (mic only)")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.textDim)

            Button {
                model.onStop?()
            } label: {
                Text("Stop")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.Colors.tintRed))
                    .overlay(Capsule().stroke(Theme.Colors.red.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    static func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// Soft-pulsing red recording dot.
private struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.Colors.red)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
