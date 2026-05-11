import SwiftUI

struct FirefliesImportView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTranscriptId: String?

    var body: some View {
        HStack(spacing: 0) {
            // Transcript List
            transcriptList
                .frame(minWidth: 320, maxWidth: 380)

            Divider()

            // Detail/Preview Panel
            if let id = selectedTranscriptId,
               let transcript = appState.firefliesTranscripts.first(where: { $0.id == id }) {
                TranscriptPreviewView(transcript: transcript)
            } else {
                emptyDetailState
            }
        }
        .task {
            if appState.firefliesTranscripts.isEmpty {
                await appState.fetchFirefliesTranscripts()
            }
        }
    }

    private var transcriptList: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Meetings")
                        .font(Theme.Typography.headline)

                    Text("\(appState.firefliesTranscripts.count) meetings")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Spacer()

                Button {
                    Task { await appState.fetchFirefliesTranscripts() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .rotationEffect(.degrees(appState.isLoadingFireflies ? 360 : 0))
                        .animation(
                            appState.isLoadingFireflies ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: appState.isLoadingFireflies
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.secondaryText)
                .disabled(appState.isLoadingFireflies)
            }
            .padding(Theme.Spacing.lg)

            Divider()

            if appState.isLoadingFireflies && appState.firefliesTranscripts.isEmpty {
                loadingState
            } else if let error = appState.firefliesSyncError {
                errorState(error)
            } else if appState.firefliesTranscripts.isEmpty {
                emptyListState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(appState.firefliesTranscripts) { transcript in
                            TranscriptRowView(
                                transcript: transcript,
                                isSelected: selectedTranscriptId == transcript.id,
                                isImported: appState.isTranscriptImported(transcript.id)
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedTranscriptId = transcript.id
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.sm)
                }
            }
        }
        .background(Theme.Colors.background)
    }

    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            ProgressView()
                .scaleEffect(0.8)

            Text("Loading meetings...")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.secondaryText)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyListState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()

            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text("No meetings found")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.secondaryText)

            Text("Your Fireflies meeting transcripts will appear here")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Colors.priorityHigh)

            Text("Failed to load meetings")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.text)

            Text(error)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                Task { await appState.fetchFirefliesTranscripts() }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                }
            }
            .buttonStyle(GhostButtonStyle())
            .padding(.top, Theme.Spacing.sm)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyDetailState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text("Select a meeting to preview")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.secondaryText)

            Text("Choose a meeting from the list to see its details and import it to Otto")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
    }
}

#Preview {
    FirefliesImportView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
