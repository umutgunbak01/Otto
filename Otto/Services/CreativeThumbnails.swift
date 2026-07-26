import Foundation
import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Preview pipeline for the Creative canvas. Canvas cards never render
/// original media — they get downsampled thumbnails (≤512px) from here, kept
/// in an NSCache plus a disk cache under `CreativePaths.thumbsDir` so result
/// previews survive relaunches. Originals stay untouched on disk / on the fal
/// CDN and are what downloads and uploads use.
actor CreativeThumbnails {
    static let shared = CreativeThumbnails()

    enum Source: Hashable {
        case local(URL)
        case remote(String)

        var cacheKey: String {
            switch self {
            case .local(let url):
                let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                    .map { String($0.timeIntervalSince1970) } ?? ""
                return "local:\(url.path):\(mtime)"
            case .remote(let s):
                return "remote:\(s)"
            }
        }
    }

    private let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    /// Coalesces concurrent requests for the same thumbnail.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Public

    func thumbnail(for source: Source, kind: CreativeMediaKind, maxPixel: CGFloat = 512) async -> NSImage? {
        let key = "\(source.cacheKey):\(Int(maxPixel))"
        if let hit = memory.object(forKey: key as NSString) { return hit }

        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task<NSImage?, Never> { [weak self] in
            await self?.build(source: source, kind: kind, maxPixel: maxPixel, cacheKey: key)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    // MARK: - Build

    private func build(source: Source, kind: CreativeMediaKind, maxPixel: CGFloat, cacheKey: String) async -> NSImage? {
        // Disk cache first (mainly for remote results).
        let diskURL = diskCacheURL(for: cacheKey)
        if let data = try? Data(contentsOf: diskURL), let image = NSImage(data: data) {
            return image
        }

        var image: NSImage?
        switch (kind, source) {
        case (.image, .local(let url)):
            image = downsampledImage(at: url, maxPixel: maxPixel)
        case (.image, .remote(let urlString)):
            if let data = await fetch(urlString) {
                image = downsampledImage(from: data, maxPixel: maxPixel)
            }
        case (.video, .local(let url)):
            image = await videoFrame(assetURL: url, maxPixel: maxPixel)
        case (.video, .remote(let urlString)):
            if let url = URL(string: urlString) {
                image = await videoFrame(assetURL: url, maxPixel: maxPixel)
            }
        default:
            image = nil   // audio/file: icon-based UI, no thumbnail
        }

        if let image, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: CreativePaths.thumbsDir, withIntermediateDirectories: true)
            try? png.write(to: diskURL, options: .atomic)
        }
        return image
    }

    private func diskCacheURL(for cacheKey: String) -> URL {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(40)
        return CreativePaths.thumbsDir.appendingPathComponent("\(name).png")
    }

    private func fetch(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    private func downsampledImage(at url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsample(source: source, maxPixel: maxPixel)
    }

    private func downsampledImage(from data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(source: source, maxPixel: maxPixel)
    }

    private func downsample(source: CGImageSource, maxPixel: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func videoFrame(assetURL: URL, maxPixel: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: assetURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Grab a frame slightly in — frame 0 is often black.
        let time = CMTime(seconds: 0.4, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        let cg = result.image
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
