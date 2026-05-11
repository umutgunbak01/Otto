import SwiftUI

struct TranscriptPreviewView: View {
    @Environment(AppState.self) private var appState
    let transcript: FirefliesTranscript

    private var isImported: Bool {
        appState.isTranscriptImported(transcript.id)
    }

    private var isWithin7Days: Bool {
        appState.isTranscriptWithinDays(transcript, days: 7)
    }

    private var hasTodos: Bool {
        appState.hasTodosForImportedMeeting(transcript.id)
    }

    private var canCreateTodos: Bool {
        isImported && !hasTodos && transcript.summary?.action_items != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(transcript.title ?? "Untitled Meeting")
                            .font(Theme.Typography.title)

                        HStack(spacing: Theme.Spacing.md) {
                            if transcript.date != nil {
                                HStack(spacing: Theme.Spacing.xs) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 11))
                                    Text(transcript.formattedDate)
                                }
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)
                            }

                            if transcript.duration != nil {
                                HStack(spacing: Theme.Spacing.xs) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 11))
                                    Text(transcript.formattedDuration)
                                }
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        }
                    }

                    Spacer()

                    if isImported {
                        HStack(spacing: Theme.Spacing.sm) {
                            // Create To-Dos button for older meetings without todos
                            if canCreateTodos {
                                Button {
                                    Task { await appState.createTodosFromImportedMeeting(transcript) }
                                } label: {
                                    HStack(spacing: Theme.Spacing.xs) {
                                        Image(systemName: "checklist")
                                        Text("Create To-Dos")
                                    }
                                }
                                .buttonStyle(GhostButtonStyle())
                                .disabled(appState.isProcessingInput)
                            }

                            Label(hasTodos ? "Imported with To-Dos" : "Imported", systemImage: "checkmark.circle.fill")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.personal)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(Theme.Colors.personal.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    } else {
                        Button {
                            Task { await appState.importFirefliesMeeting(transcript) }
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "arrow.down.circle")
                                Text("Import")
                            }
                        }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(appState.isProcessingInput)
                    }
                }

                Divider()

                // Organizer
                if let organizer = transcript.organizer_email, !organizer.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("Organizer", systemImage: "person.circle")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        Text(organizer)
                            .font(Theme.Typography.body)
                    }
                }

                // Participants
                if let participants = transcript.participants, !participants.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("Participants", systemImage: "person.2")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        FlowLayout(spacing: Theme.Spacing.sm) {
                            ForEach(participants, id: \.self) { participant in
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

                // Summary Preview
                if let overview = transcript.summary?.overview, !overview.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            Label("Overview", systemImage: "doc.text")
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.secondaryText)

                            Spacer()

                            Text("will become Note")
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .italic()
                        }

                        Text(overview)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.02))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    }
                }

                // Action Items Preview
                if let actionItems = transcript.summary?.action_items, !actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            Label("Action Items", systemImage: "checklist")
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.secondaryText)

                            Spacer()

                            // Show different hint text based on context
                            if isImported {
                                if hasTodos {
                                    Text("imported as To-Dos")
                                        .font(Theme.Typography.small)
                                        .foregroundStyle(Theme.Colors.personal)
                                        .italic()
                                } else {
                                    Text("click 'Create To-Dos' to import")
                                        .font(Theme.Typography.small)
                                        .foregroundStyle(Theme.Colors.hobby)
                                        .italic()
                                }
                            } else if isWithin7Days {
                                Text("will become To-Dos")
                                    .font(Theme.Typography.small)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .italic()
                            } else {
                                Text("use 'Create To-Dos' after import")
                                    .font(Theme.Typography.small)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .italic()
                            }
                        }

                        Text(actionItems)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.Colors.priorityMedium.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    }
                }

                // Keywords Preview
                if let keywords = transcript.summary?.keywords, !keywords.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            Label("Keywords", systemImage: "tag")
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.secondaryText)

                            Spacer()

                            Text("will become tags")
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .italic()
                        }

                        FlowLayout(spacing: Theme.Spacing.sm) {
                            ForEach(keywords, id: \.self) { keyword in
                                Text(keyword.trimmingCharacters(in: .whitespaces))
                                    .font(Theme.Typography.caption)
                                    .padding(.horizontal, Theme.Spacing.sm)
                                    .padding(.vertical, Theme.Spacing.xs)
                                    .background(Theme.Colors.accent.opacity(0.1))
                                    .foregroundStyle(Theme.Colors.accent)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                // Notes
                if let notes = transcript.summary?.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("Meeting Notes", systemImage: "note.text")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        Text(notes)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.02))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    }
                }

                Spacer(minLength: Theme.Spacing.xl)
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
    }
}

#Preview {
    TranscriptPreviewView(
        transcript: FirefliesTranscript(
            id: "1",
            title: "Product Strategy Meeting",
            date: 1705744800000, // Jan 20, 2025 10:00 UTC in milliseconds
            duration: 45, // 45 minutes
            organizer_email: "alice@company.com",
            participants: ["Alice", "Bob", "Charlie", "Diana"],
            summary: FirefliesSummary(
                overview: "We discussed Q1 product roadmap priorities and decided to focus on mobile experience improvements.",
                action_items: "- Schedule user research sessions\n- Create wireframes for new dashboard\n- Review competitor analysis",
                outline: nil,
                shorthand_bullet: nil,
                keywords: ["product", "roadmap", "mobile", "Q1", "dashboard"],
                notes: "Key decisions: Mobile-first approach for Q1. Budget approved for user research."
            )
        )
    )
    .environment(AppState())
    .frame(width: 500, height: 600)
}
