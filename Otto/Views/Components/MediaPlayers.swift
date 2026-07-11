import SwiftUI
import AVKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Shared inline media components. Used by the chat transcript's media cards
// (genmedia outputs and attached media files) and by FilePreviewPopup's
// video/audio previews — one player implementation, two surfaces.

// MARK: - Thumbnail loading

/// Downsampled image loading for inline previews. CGImageSource decodes
/// straight to the target pixel size, so a 12 MP genmedia render costs a
/// ~1000px bitmap instead of the full decode; generation outputs are shown
/// in a ~440pt card, so that's plenty.
enum MediaThumbnailLoader {
    static func load(url: URL, maxPixel: CGFloat) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}

// MARK: - Inline video player

/// AVKit player sized to the video's native aspect ratio (portrait genmedia
/// renders shouldn't letterbox inside a hardcoded 16:9 box). The player is
/// created lazily and paused when the view scrolls away — never autoplays.
struct InlineVideoPlayer: View {
    let url: URL
    var maxHeight: CGFloat

    @State private var player: AVPlayer?
    @State private var aspect: CGFloat = 16.0 / 9.0

    // Explicit init: private @State members would make the synthesized
    // memberwise init inaccessible outside this file.
    init(url: URL, maxHeight: CGFloat = 300) {
        self.url = url
        self.maxHeight = maxHeight
    }

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(aspect, contentMode: .fit)
            } else {
                ZStack {
                    Theme.Colors.bg1
                    ProgressView().controlSize(.small)
                }
                .aspectRatio(aspect, contentMode: .fit)
            }
        }
        .frame(maxHeight: maxHeight)
        .task(id: url) {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                let w = abs(rect.width)
                let h = abs(rect.height)
                if w > 0, h > 0 { aspect = w / h }
            }
            if player == nil {
                player = AVPlayer(url: url)
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - Inline audio player

/// AVPlayer wrapper owned by `InlineAudioPlayer`. A class (not view @State)
/// because AVPlayer must have its periodic time observer removed before the
/// player is released — deinit is the only deterministic hook a recycled
/// LazyVStack row gives us.
final class InlineAudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private(set) var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var preparedURL: URL?

    func prepare(url: URL) {
        guard preparedURL != url else { return }
        removeObservers()
        player?.pause()
        preparedURL = url
        isPlaying = false
        currentTime = 0
        duration = 0

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite { self.currentTime = seconds }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
            self?.currentTime = 0
            self?.player?.seek(to: .zero)
        }
        // item.duration stays indefinite until the asset is ready — load it
        // through the async API instead of polling.
        Task { [weak self] in
            let seconds = (try? await item.asset.load(.duration))?.seconds ?? 0
            await MainActor.run {
                if seconds.isFinite, seconds > 0 { self?.duration = seconds }
            }
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // Replay from the top when the last run finished.
            if duration > 0, currentTime >= duration - 0.05 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = min(max(fraction, 0), 1) * duration
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func removeObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    deinit {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player?.pause()
    }
}

/// Compact play/scrub bar for audio files: play-pause toggle, draggable
/// progress line, elapsed/total time in mono. Fits in a chat card row.
struct InlineAudioPlayer: View {
    let url: URL
    var accent: Color

    @StateObject private var model = InlineAudioPlayerModel()
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    // Explicit init: private @State/@StateObject members would make the
    // synthesized memberwise init inaccessible outside this file.
    init(url: URL, accent: Color = Theme.Colors.amber) {
        self.url = url
        self.accent = accent
    }

    private var progressFraction: Double {
        if isScrubbing { return scrubFraction }
        guard model.duration > 0 else { return 0 }
        return min(max(model.currentTime / model.duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                model.togglePlay()
            } label: {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.16))
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")

            VStack(spacing: 5) {
                scrubber

                HStack {
                    Text(Self.format(isScrubbing ? scrubFraction * model.duration : model.currentTime))
                    Spacer()
                    Text(Self.format(model.duration))
                }
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .task(id: url) {
            model.prepare(url: url)
        }
        .onDisappear {
            model.pause()
        }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Colors.borderStrong)
                Capsule()
                    .fill(accent)
                    .frame(width: max(4, geo.size.width * progressFraction))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        scrubFraction = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        model.seek(toFraction: fraction)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 14)
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Save-to-disk panel

/// NSSavePanel copy-out of a stored FileItem binary, then reveal the saved
/// file in Finder. Shared by the chat's file card and media card.
@MainActor
enum FileSavePanel {
    static func save(_ file: FileItem) {
        Task { @MainActor in
            let srcURL = await FileStorageService.shared.getFileURL(for: file)
            guard FileManager.default.fileExists(atPath: srcURL.path) else { return }

            let panel = NSSavePanel()
            if let contentType = UTType(filenameExtension: file.fileExtension) {
                panel.allowedContentTypes = [contentType]
            }
            panel.nameFieldStringValue = "\(file.name).\(file.fileExtension)"
            panel.canCreateDirectories = true
            panel.title = "Save \(file.name)"

            if panel.runModal() == .OK, let destURL = panel.url {
                try? FileManager.default.removeItem(at: destURL)
                do {
                    try FileManager.default.copyItem(at: srcURL, to: destURL)
                    NSWorkspace.shared.activateFileViewerSelecting([destURL])
                } catch {
                    NSLog("[Chat] save file failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
