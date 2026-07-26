import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Floating "add node" palette: live search over fal's full model registry
/// (1,300+ endpoints), category filters, a curated Utils section (ffmpeg +
/// workflow utilities), and local media import.
struct CreativeLibraryPanel: View {
    private var controller: CreativeCanvasController { .shared }

    @State private var searchText = ""
    @State private var category: LibraryCategory = .all
    @State private var results: [CreativeModelSummary] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var totalCount: Int?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    enum LibraryCategory: String, CaseIterable, Identifiable {
        case all, image, video, audio, text, utils

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .image: return "Image"
            case .video: return "Video"
            case .audio: return "Audio"
            case .text: return "Text"
            case .utils: return "Utils"
            }
        }

        /// fal registry category slugs; nil = the curated local list.
        var registryCategories: [String]? {
            switch self {
            case .all: return []
            case .image: return ["text-to-image", "image-to-image"]
            case .video: return ["text-to-video", "image-to-video", "video-to-video"]
            case .audio: return ["text-to-audio", "audio-to-audio", "text-to-speech", "speech-to-text"]
            case .text: return ["llm", "vision"]
            case .utils: return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
            categoryChips
            OttoDivider()
            resultsList
            OttoDivider()
            mediaFooter
        }
        .frame(width: 312)
        .background(Theme.Colors.bg1)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(Theme.Colors.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .onAppear { scheduleSearch(immediate: true) }
        .onChange(of: searchText) { _, _ in scheduleSearch() }
        .onChange(of: category) { _, _ in scheduleSearch(immediate: true) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.tertiaryText)
            TextField("Search fal.ai models…", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.text)
            if isLoading {
                ProgressView().controlSize(.mini)
            }
            Button {
                controller.showLibrary = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 10)
    }

    // MARK: - Category chips

    private var categoryChips: some View {
        // Horizontal scroll + fixedSize labels: six chips overflow the panel
        // width slightly, and SwiftUI would otherwise wrap "Image" mid-word.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(LibraryCategory.allCases) { item in
                    Button {
                        category = item
                    } label: {
                        Text(item.label)
                            .font(Theme.Typography.caption)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(category == item ? Theme.Colors.accentText : Theme.Colors.textDim)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.full)
                                    .fill(category == item ? Theme.Colors.selectTint : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                if category == .utils {
                    utilsHeader
                }
                ForEach(displayedResults) { model in
                    CreativeLibraryRow(model: model) {
                        add(model)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.red)
                        .padding(Theme.Spacing.md)
                }
                if displayedResults.isEmpty && !isLoading && errorMessage == nil {
                    Text("No models found")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .padding(Theme.Spacing.lg)
                }
                if hasMore, category != .utils {
                    Button {
                        loadMore()
                    } label: {
                        Text(isLoading ? "Loading…" : "Load more")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.accentText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if let totalCount, category != .utils {
                Text("\(totalCount)")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(6)
            }
        }
    }

    private var utilsHeader: some View {
        Text("fal utilities — merge, trim, extract, compose")
            .font(Theme.Typography.small)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
    }

    private var displayedResults: [CreativeModelSummary] {
        if category == .utils {
            let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return Self.utilityModels }
            return Self.utilityModels.filter {
                $0.id.lowercased().contains(q) || $0.title.lowercased().contains(q)
            }
        }
        return results
    }

    private func add(_ model: CreativeModelSummary) {
        let node = controller.addModelNode(model)
        controller.showToast("Added \(node.title)")
    }

    // MARK: - Search plumbing

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        guard category != .utils else {
            isLoading = false
            errorMessage = nil
            return
        }
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 320_000_000)
            }
            guard !Task.isCancelled else { return }
            await runSearch(page: 1)
        }
    }

    private func loadMore() {
        searchTask?.cancel()
        searchTask = Task { await runSearch(page: page + 1) }
    }

    @MainActor
    private func runSearch(page targetPage: Int) async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await FalWorkflowAPI.shared.searchModels(
                query: searchText,
                categories: category.registryCategories ?? [],
                page: targetPage
            )
            guard !Task.isCancelled else { return }
            if targetPage == 1 {
                results = result.items
            } else {
                let known = Set(results.map(\.id))
                results.append(contentsOf: result.items.filter { !known.contains($0.id) })
            }
            page = targetPage
            hasMore = result.hasMore
            totalCount = result.total
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    // MARK: - Media footer

    private var mediaFooter: some View {
        VStack(spacing: 6) {
            Button {
                pickMedia()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 11))
                    Text("Add image / video / audio…")
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Colors.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("or drop files anywhere on the canvas")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .padding(Theme.Spacing.md)
    }

    private func pickMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { @MainActor in
                await controller.addMediaNodes(fileURLs: urls)
            }
        }
    }

    // MARK: - Curated utils (fal's workflow utility endpoints)

    static let utilityModels: [CreativeModelSummary] = [
        .init(id: "fal-ai/ffmpeg-api/merge-videos", title: "Merge Videos", category: "video-to-video",
              shortDescription: "Concatenate multiple videos into one.", thumbnailUrl: nil),
        .init(id: "fal-ai/ffmpeg-api/merge-audio-video", title: "Merge Audio + Video", category: "video-to-video",
              shortDescription: "Lay an audio track over a video.", thumbnailUrl: nil),
        .init(id: "fal-ai/ffmpeg-api/merge-audios", title: "Merge Audios", category: "audio-to-audio",
              shortDescription: "Concatenate multiple audio files.", thumbnailUrl: nil),
        .init(id: "fal-ai/ffmpeg-api/images-to-video", title: "Images → Video", category: "image-to-video",
              shortDescription: "Turn an image sequence into a video.", thumbnailUrl: nil),
        .init(id: "fal-ai/ffmpeg-api/compose", title: "Compose Tracks", category: "video-to-video",
              shortDescription: "Timeline composition of video/audio tracks.", thumbnailUrl: nil),
        .init(id: "fal-ai/ffmpeg-api/extract-frame", title: "Extract Frame", category: "image-to-image",
              shortDescription: "Grab a frame from a video.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/extract-nth-frame", title: "Extract Nth Frame", category: "image-to-image",
              shortDescription: "Grab the nth frame of a video.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/trim-video", title: "Trim Video", category: "video-to-video",
              shortDescription: "Cut a video to a time range.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/scale-video", title: "Scale Video", category: "video-to-video",
              shortDescription: "Resize a video.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/reverse-video", title: "Reverse Video", category: "video-to-video",
              shortDescription: "Play a video backwards.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/blend-video", title: "Blend Videos", category: "video-to-video",
              shortDescription: "Blend two videos together.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/interleave-video", title: "Interleave Videos", category: "video-to-video",
              shortDescription: "Alternate segments from multiple videos.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/audio-compressor", title: "Audio Compressor", category: "audio-to-audio",
              shortDescription: "Dynamic-range compression for audio.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/impulse-response", title: "Impulse Response", category: "audio-to-audio",
              shortDescription: "Convolution reverb from an impulse response.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/pick-image-by-index", title: "Pick Image by Index", category: "image-to-image",
              shortDescription: "Select one image from a list by index.", thumbnailUrl: nil),
        .init(id: "fal-ai/workflow-utilities/auto-subtitle", title: "Auto Subtitle", category: "video-to-video",
              shortDescription: "Burn auto-generated subtitles into a video.", thumbnailUrl: nil),
        .init(id: "fal-ai/ffmpeg-api/loudnorm", title: "Loudness Normalize", category: "audio-to-audio",
              shortDescription: "EBU R128 loudness normalization.", thumbnailUrl: nil),
        .init(id: "fal-ai/ffmpeg-api/metadata", title: "Media Metadata", category: "json",
              shortDescription: "Probe duration, codecs, dimensions.", thumbnailUrl: nil),
        .init(id: "fal-ai/ffmpeg-api/waveform", title: "Waveform", category: "json",
              shortDescription: "Extract waveform data from audio.", thumbnailUrl: nil)
    ]
}

// MARK: - Row

private struct CreativeLibraryRow: View {
    let model: CreativeModelSummary
    let onAdd: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: Theme.Spacing.sm) {
                thumb
                VStack(alignment: .leading, spacing: 1) {
                    // Registry titles are often too generic — six HeyGen
                    // endpoints are all titled "Heygen", and edit variants
                    // share their base model's name — so the display name
                    // folds in whatever id segments the title doesn't convey:
                    // "Heygen · Avatar4 Image To Video", "Nano Banana 2 · Edit".
                    Text(model.disambiguatedTitle)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Middle truncation keeps the variant tail visible —
                    // "fal-ai/nano-…-2/edit", not "fal-ai/nano-banana-…".
                    Text(model.id)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if hovering {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.accentText)
                } else {
                    Text(shortCategory)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(hovering ? Theme.Colors.hoverTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(model.shortDescription.isEmpty ? model.id : "\(model.id)\n\(model.shortDescription)")
    }

    private var shortCategory: String {
        model.category
            .replacingOccurrences(of: "text-to-", with: "t2")
            .replacingOccurrences(of: "image-to-", with: "i2")
            .replacingOccurrences(of: "video-to-", with: "v2")
            .replacingOccurrences(of: "audio-to-", with: "a2")
            .replacingOccurrences(of: "image", with: "img")
            .replacingOccurrences(of: "video", with: "vid")
            .replacingOccurrences(of: "audio", with: "aud")
    }

    @ViewBuilder
    private var thumb: some View {
        if let thumbURL = model.thumbnailUrl, let url = URL(string: thumbURL) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    fallbackThumb
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            fallbackThumb
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Colors.bgInput)
                )
        }
    }

    private var fallbackThumb: some View {
        Image(systemName: iconName)
            .font(.system(size: 11, weight: .light))
            .foregroundStyle(Theme.Colors.textDim)
    }

    private var iconName: String {
        let c = model.category.lowercased()
        if c.contains("video") { return "film" }
        if c.contains("image") { return "photo" }
        if c.contains("audio") || c.contains("speech") || c.contains("music") { return "waveform" }
        if c.contains("llm") || c.contains("vision") { return "text.alignleft" }
        if c.contains("json") { return "curlybraces" }
        return "cpu"
    }
}
