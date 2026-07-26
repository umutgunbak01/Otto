import SwiftUI

/// State shown in the notch meeting control. Owned by
/// `MeetingBannerController`; the view renders it and writes prep fields back.
@Observable
final class MeetingBannerModel {
    enum Phase: Equatable {
        case hidden
        /// Collapsed pill by the notch: "Otto · [Başlat]".
        case prompt(appName: String, meetingTitle: String?)
        /// Expanded prep panel. `recording` flips the header between the
        /// "Start" affordance and the live recording indicator — the same
        /// fields stay editable either way.
        case expanded(recording: Bool, startedAt: Date?, systemAudioAvailable: Bool)
    }

    var phase: Phase = .hidden

    // MARK: Prep fields (bound by the expanded panel)

    var participants: [String] = []
    var draftName: String = ""
    var purpose: String = ""
    var focus: String = ""
    var noteStyle: MeetingNoteStyle = .general
    /// Once the user picks a template by hand, stop auto-suggesting from purpose.
    var styleTouched = false

    // MARK: Callbacks (wired by the coordinator)

    @ObservationIgnored var onStartNow: (() -> Void)?     // Başlat → start recording now + expand
    @ObservationIgnored var onOpenPrep: (() -> Void)?     // tap pill → expand without starting
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?
    @ObservationIgnored var onPrepChanged: (() -> Void)?  // a field changed → push to recorder

    /// Snapshot of the prep fields for handing to the recorder / analysis.
    var prep: MeetingPrep {
        MeetingPrep(participantNames: participants,
                    purpose: purpose,
                    focusPoints: focus,
                    noteStyle: noteStyle)
    }

    func commitDraftName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftName = ""
        guard !name.isEmpty, !participants.contains(name) else { return }
        participants.append(name)
        onPrepChanged?()
    }

    func removeParticipant(_ name: String) {
        participants.removeAll { $0 == name }
        onPrepChanged?()
    }

    /// Re-run the purpose→template suggestion unless the user already chose one.
    func refreshSuggestion() {
        guard !styleTouched else { return }
        noteStyle = MeetingNoteStyle.suggest(purpose: purpose)
    }

    /// Reset transient prep state when the control is dismissed / a new meeting
    /// is detected, so stale fields don't leak into the next capture.
    func resetPrep() {
        participants = []
        draftName = ""
        purpose = ""
        focus = ""
        noteStyle = .general
        styleTouched = false
    }
}

/// Notch-anchored meeting control shown over every app (including fullscreen
/// meetings). Collapsed it's a small pill; expanded it's the pre-meeting prep
/// panel that keeps its fields editable while recording.
struct MeetingBannerView: View {
    @Bindable var model: MeetingBannerModel

    var body: some View {
        Group {
            switch model.phase {
            case .hidden:
                EmptyView()
            case .prompt(let appName, let meetingTitle):
                collapsedPill(appName: appName, meetingTitle: meetingTitle)
            case .expanded(let recording, let startedAt, let systemAudioAvailable):
                prepPanel(recording: recording,
                          startedAt: startedAt,
                          systemAudioAvailable: systemAudioAvailable)
            }
        }
        .fixedSize()
    }

    // MARK: - Collapsed pill

    private func collapsedPill(appName: String, meetingTitle: String?) -> some View {
        HStack(spacing: 9) {
            // Tapping the label/body opens prep without starting.
            Button {
                model.onOpenPrep?()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textDim)
                    Text(meetingTitle ?? "Otto")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                        .frame(maxWidth: 180, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Button {
                model.onStartNow?()
            } label: {
                Text("Başlat")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.Colors.red))
            }
            .buttonStyle(.plain)

            Button {
                model.onDismiss?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.Colors.hoverTint))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Theme.Colors.bg1)
                .overlay(Capsule().stroke(Theme.Colors.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 3)
        )
    }

    // MARK: - Expanded prep panel

    private func prepPanel(recording: Bool, startedAt: Date?, systemAudioAvailable: Bool) -> some View {
        VStack(spacing: 0) {
            prepHeader(recording: recording, startedAt: startedAt, systemAudioAvailable: systemAudioAvailable)
            Divider().overlay(Theme.Colors.border)

            VStack(alignment: .leading, spacing: 12) {
                participantsField
                purposeField
                templateField
                focusField

                if !recording {
                    Button {
                        model.onStartNow?()
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(.white).frame(width: 7, height: 7)
                            Text("Transkripti Başlat")
                                .font(Theme.Typography.small)
                        }
                        .foregroundStyle(Theme.Colors.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.Colors.red))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.Colors.bg1)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Colors.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 6)
        )
    }

    private func prepHeader(recording: Bool, startedAt: Date?, systemAudioAvailable: Bool) -> some View {
        HStack(spacing: 8) {
            if recording, let startedAt {
                PulsingDot()
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(Self.elapsedString(from: startedAt, to: timeline.date))
                        .font(Theme.Typography.monoBody)
                        .foregroundStyle(Theme.Colors.text)
                }
                Text(systemAudioAvailable ? "kaydediliyor" : "kaydediliyor (yalnızca mikrofon)")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.onStop?()
                } label: {
                    Text("Durdur")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.Colors.tintRed))
                        .overlay(Capsule().stroke(Theme.Colors.red.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.cyan)
                Text("Toplantı Hazırlığı")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
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
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    // MARK: Fields

    private var participantsField: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Kimlerle")
            FlowRow(spacing: 6) {
                ForEach(model.participants, id: \.self) { name in
                    HStack(spacing: 5) {
                        Text(name).font(Theme.Typography.small).foregroundStyle(Theme.Colors.text)
                        Button { model.removeParticipant(name) } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Theme.Colors.border, lineWidth: 1))
                }
                TextField("+ isim", text: $model.draftName)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.small)
                    .frame(width: 90)
                    .onSubmit { model.commitDraftName() }
            }
        }
    }

    private var purposeField: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Amaç")
            TextField("Toplantı neyle ilgili?", text: $model.purpose, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1...3)
                .padding(8)
                .background(fieldBackground)
                .onChange(of: model.purpose) { _, _ in
                    model.refreshSuggestion()
                    model.onPrepChanged?()
                }
        }
    }

    private var templateField: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Şablon")
            HStack {
                Menu {
                    ForEach(MeetingNoteStyle.allCases, id: \.self) { style in
                        Button(style.displayName) {
                            model.noteStyle = style
                            model.styleTouched = true
                            model.onPrepChanged?()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.noteStyle.displayName)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.text)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if !model.styleTouched {
                    Text("Otto önerdi")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                Spacer()
            }
            .padding(8)
            .background(fieldBackground)
        }
    }

    private var focusField: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Dikkat et")
            TextField("Neye özellikle dikkat edilsin? (opsiyonel)", text: $model.focus, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1...3)
                .padding(8)
                .background(fieldBackground)
                .onChange(of: model.focus) { _, _ in model.onPrepChanged?() }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textDim)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Theme.Colors.bg0)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.border, lineWidth: 1))
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

/// Minimal wrapping HStack for the participant chips + input, so many names
/// flow onto multiple lines instead of overflowing the fixed-width panel.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
