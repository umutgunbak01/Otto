import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Port styling

extension CreativePortKind {
    /// Pin colors follow Otto's semantic palette: strings amber, numbers
    /// green, booleans cyan, enums violet, media kinds get their own hues.
    var pinColor: Color {
        switch self {
        case .string:      return Theme.Colors.amber
        case .number:      return Theme.Colors.green
        case .boolean:     return Theme.Colors.cyan
        case .enumeration: return Theme.Colors.violet
        case .image:       return Theme.Colors.red
        case .video:       return Color(red: 0.545, green: 0.620, blue: 0.945)  // soft indigo
        case .audio:       return Color(red: 0.350, green: 0.780, blue: 0.700)  // muted teal
        case .file:        return Theme.Colors.textDim
        case .object:      return Theme.Colors.tertiaryText
        case .any:         return Theme.Colors.textDim
        }
    }
}

extension CreativeMediaKind {
    var iconName: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .file:  return "doc"
        }
    }

    var displayName: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .file:  return "File"
        }
    }
}

// MARK: - Thumbnails

/// Async downsampled thumbnail (canvas previews never load original media).
struct CreativeThumbView: View {
    let source: CreativeThumbnails.Source
    let kind: CreativeMediaKind
    var maxPixel: CGFloat = 512

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.Colors.bgInput
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: kind.iconName)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .task(id: taskKey) {
            image = await CreativeThumbnails.shared.thumbnail(for: source, kind: kind, maxPixel: maxPixel)
        }
    }

    private var taskKey: String { source.cacheKey }
}

// MARK: - Full-quality preview

/// What the preview sheet displays. Canvas thumbs are downsampled; this sheet
/// loads the original.
struct CreativeMediaPreviewItem: Identifiable {
    enum Location {
        case remote(String)
        case local(URL)
    }

    let id = UUID()
    let location: Location
    let kind: CreativeMediaKind
    let title: String

    var urlString: String {
        switch location {
        case .remote(let s): return s
        case .local(let u): return u.absoluteString
        }
    }

    var playbackURL: URL? {
        switch location {
        case .remote(let s): return URL(string: s)
        case .local(let u): return u
        }
    }
}

struct CreativeMediaPreviewSheet: View {
    let item: CreativeMediaPreviewItem
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var fullImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: item.kind.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textDim)
                Text(item.title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Spacer()
                Button("Save…") { CreativeMediaSaver.save(item: item) }
                    .buttonStyle(GhostButtonStyle())
                    .foregroundStyle(Theme.Colors.textDim)
                Button("Copy URL") { CreativeMediaSaver.copyURL(item.urlString) }
                    .buttonStyle(GhostButtonStyle())
                    .foregroundStyle(Theme.Colors.textDim)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GhostButtonStyle())
                .foregroundStyle(Theme.Colors.textDim)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)

            OttoDivider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.bgPage)
        }
        .frame(minWidth: 560, idealWidth: 760, minHeight: 420, idealHeight: 580)
        .background(Theme.Colors.bg1)
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            Group {
                if let fullImage {
                    Image(nsImage: fullImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(Theme.Spacing.lg)
            .task {
                switch item.location {
                case .local(let url):
                    fullImage = NSImage(contentsOf: url)
                case .remote(let s):
                    guard let url = URL(string: s),
                          let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                    fullImage = NSImage(data: data)
                }
            }
        case .video:
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .onAppear {
                if let url = item.playbackURL {
                    let p = AVPlayer(url: url)
                    player = p
                    p.play()
                }
            }
        case .audio:
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.Colors.textDim)
                if let url = item.playbackURL {
                    CreativeAudioPlayerRow(url: url)
                        .frame(width: 320)
                }
            }
        case .file:
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "doc")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text(item.urlString)
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .padding(Theme.Spacing.xl)
        }
    }
}

// MARK: - Audio player

struct CreativeAudioPlayerRow: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progressText = "0:00"

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Colors.accentText)
            }
            .buttonStyle(.plain)

            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text(progressText)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.textDim)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.bgInput)
        )
        .onReceive(ticker) { _ in
            guard let player else { return }
            let current = player.currentTime().seconds
            if current.isFinite {
                progressText = Self.format(current)
            }
            if let duration = player.currentItem?.duration.seconds, duration.isFinite,
               current >= duration - 0.25 {
                isPlaying = false
                player.pause()
                player.seek(to: .zero)
            }
        }
        .onDisappear { player?.pause() }
    }

    private func toggle() {
        if player == nil {
            player = AVPlayer(url: url)
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Saving / clipboard

@MainActor
enum CreativeMediaSaver {
    /// Exports the ORIGINAL media — remote items download from the fal CDN at
    /// full quality; local assets copy the imported original.
    static func save(item: CreativeMediaPreviewItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName(for: item)
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    switch item.location {
                    case .local(let source):
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: source, to: destination)
                    case .remote(let urlString):
                        let temp = try await FalWorkflowAPI.shared.download(from: urlString)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.moveItem(at: temp, to: destination)
                    }
                    CreativeCanvasController.shared.showToast("Saved \(destination.lastPathComponent)")
                } catch {
                    CreativeCanvasController.shared.showToast("Save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    static func copyURL(_ urlString: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        CreativeCanvasController.shared.showToast("URL copied")
    }

    private static func suggestedName(for item: CreativeMediaPreviewItem) -> String {
        switch item.location {
        case .local(let url):
            return url.lastPathComponent
        case .remote(let urlString):
            let last = URL(string: urlString)?.lastPathComponent ?? ""
            if !last.isEmpty, last.contains(".") { return last }
            let ext: String
            switch item.kind {
            case .image: ext = "png"
            case .video: ext = "mp4"
            case .audio: ext = "mp3"
            case .file:  ext = "bin"
            }
            return "fal-output.\(ext)"
        }
    }
}
