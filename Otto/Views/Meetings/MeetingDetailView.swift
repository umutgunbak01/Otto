import SwiftUI

// MARK: - Local Models

private enum MobileTab: String, CaseIterable {
    case summary = "Summary"
    case transcript = "Transcript"
}

// MARK: - Meeting Detail View

struct MeetingDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let meeting: Meeting

    @State private var showingDeleteAlert = false
    @State private var selectedMobileTab: MobileTab = .summary
    @State private var transcriptSentences: [FirefliesSentence] = []
    @State private var isLoadingTranscript = false
    @State private var transcriptError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()

            GeometryReader { geometry in
                if geometry.size.width > 700 {
                    twoColumnLayout
                } else {
                    singleColumnLayout
                }
            }
        }
        #if os(macOS)
        .toolbar(.hidden, for: .windowToolbar)
        #else
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .alert("Delete Meeting?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await appState.deleteMeeting(meeting)
                    dismiss()
                }
            }
        } message: {
            Text("This will permanently delete this meeting. This action cannot be undone.")
        }
        .task {
            await loadTranscript()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                        Text("Meetings")
                            .font(Theme.Typography.body)
                    }
                    .foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showingDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.sm)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(meeting.title)
                    .font(Theme.Typography.largeTitle)

                HStack(spacing: Theme.Spacing.lg) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                        Text(meeting.formattedMeetingDate)
                    }

                    if meeting.duration > 0 {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "clock")
                                .font(.system(size: 11))
                            Text(meeting.formattedDuration)
                        }
                    }

                    if !meeting.organizer.isEmpty {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "person.circle")
                                .font(.system(size: 11))
                            Text(meeting.organizer)
                        }
                    }

                    if !meeting.participants.isEmpty {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "person.2")
                                .font(.system(size: 11))
                            Text("\(meeting.participants.count) participants")
                        }
                    }

                    if meeting.firefliesId != nil {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "waveform")
                                .font(.system(size: 11))
                            Text("Fireflies.ai")
                        }
                        .foregroundStyle(Theme.Colors.hobby)
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)

                // Tags inline
                if !meeting.domainTagIds.isEmpty {
                    FlowLayout(spacing: Theme.Spacing.xs) {
                        ForEach(appState.tags(for: meeting.domainTagIds)) { tag in
                            TagChipView(tag: tag, isCompact: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.lg)
        }
    }

    // MARK: - Two Column Layout (macOS / iPad)

    private var twoColumnLayout: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(minWidth: 300, maxWidth: .infinity)

            OttoDivider()

            rightPanel
                .frame(minWidth: 280, idealWidth: 400, maxWidth: .infinity)
        }
    }

    // MARK: - Single Column Layout (iPhone)

    private var singleColumnLayout: some View {
        VStack(spacing: 0) {
            mobileTabPicker
            OttoDivider()

            switch selectedMobileTab {
            case .summary:
                leftPanelContent
            case .transcript:
                transcriptView
            }
        }
    }

    private var mobileTabPicker: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(MobileTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedMobileTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(selectedMobileTab == tab ? Theme.Colors.bg0 : Theme.Colors.secondaryText)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            selectedMobileTab == tab
                                ? Theme.Colors.accent
                                : Theme.Colors.borderSubtle
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        leftPanelContent
    }

    private var leftPanelContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if !meeting.overview.isEmpty {
                    generalSummarySection
                }

                if !meeting.content.isEmpty {
                    notesSection
                }

                if !meeting.actionItems.isEmpty {
                    actionItemsSection
                }

                if !meeting.participants.isEmpty {
                    participantsSection
                }

                Spacer(minLength: Theme.Spacing.xl)
            }
            .padding(Theme.Spacing.xl)
        }
    }

    // MARK: - General Summary

    private var generalSummarySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.hobby)
                Label("General Summary", systemImage: "doc.text")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            MarkdownContent(meeting.overview)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.borderSubtle.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("Notes", systemImage: "note.text")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.secondaryText)

            MarkdownContent(meeting.content)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.borderSubtle.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    // MARK: - Action Items

    private var hasTodos: Bool {
        appState.hasTodosForMeeting(meeting)
    }

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Label("Action Items", systemImage: "checklist")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer()

                if hasTodos {
                    Label("Imported as To-Dos", systemImage: "checkmark.circle.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.personal)
                } else {
                    Button {
                        Task { await appState.createTodosFromMeeting(meeting) }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "arrow.down.circle")
                            Text("Import as To-Dos")
                        }
                        .font(Theme.Typography.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(appState.isProcessingInput)
                }
            }

            MarkdownContent(meeting.actionItems)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.priorityMedium.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    // MARK: - Participants

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("Participants", systemImage: "person.2")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.secondaryText)

            FlowLayout(spacing: Theme.Spacing.sm) {
                ForEach(meeting.participants, id: \.self) { participant in
                    Text(participant)
                        .font(Theme.Typography.caption)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Colors.work.opacity(0.1))
                        .foregroundStyle(Theme.Colors.work)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        transcriptView
    }

    // MARK: - Transcript View

    private var transcriptView: some View {
        Group {
            if isLoadingTranscript {
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Loading transcript...")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = transcriptError {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Theme.Spacing.lg)
            } else if transcriptSentences.isEmpty {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("No transcript available")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(Array(transcriptSentences.enumerated()), id: \.offset) { _, sentence in
                            transcriptSentenceView(sentence)
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
    }

    private func transcriptSentenceView(_ sentence: FirefliesSentence) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            // Timestamp
            Text(sentence.formattedTime)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: 44, alignment: .trailing)

            // Speaker + text
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = sentence.speaker_name, !speaker.isEmpty {
                    Text(speaker)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.work)
                        .fontWeight(.semibold)
                }
                if let text = sentence.text, !text.isEmpty {
                    Text(text)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - Load Transcript

    private func loadTranscript() async {
        guard let firefliesId = meeting.firefliesId, !firefliesId.isEmpty else {
            // No Fireflies ID — no transcript to fetch
            return
        }

        isLoadingTranscript = true
        transcriptError = nil

        do {
            let sentences = try await FirefliesService.shared.fetchTranscriptSentences(id: firefliesId)
            transcriptSentences = sentences
        } catch {
            transcriptError = "Could not load transcript: \(error.localizedDescription)"
        }

        isLoadingTranscript = false
    }

}

// MARK: - Preview

#Preview {
    NavigationStack {
        MeetingDetailView(
            meeting: Meeting(
                title: "Discovery Call",
                content: """
                Alice: Welcome everyone, give us a minute to let the others join.
                Bob: Sounds good. How have you been?
                Alice: Doing well — let's give it two more minutes.
                Bob: Same here. Anything interesting on your end this week?
                Alice: A few things — I'll share once everyone is here.
                """,
                overview: """
                - **Product Update:** New automation module is live with two pilot users; rollout depends on data integration.
                - **Market Position:** Top players control roughly 80% of the segment; speed is the main lever for new contracts.
                - **Opportunities:** Recurring contracts make up about half of revenue; faster delivery is a differentiator.
                """,
                actionItems: "- Schedule user research sessions\n- Create wireframes for new dashboard\n- Review competitor analysis",
                participants: ["Alice Doe", "Bob Smith", "Carol Lee", "Dan Park"],
                organizer: "alice@example.com",
                duration: 5236,
                meetingDate: Date(),
                firefliesId: "abc123"
            )
        )
    }
    .environment(AppState())
    .frame(width: 1000, height: 700)
}
