import Foundation
import AppKit

/// Disk storage for images embedded in notes. Files live in a flat
/// `Documents/OttoNoteAssets/` folder (same convention as `OttoFiles`) and
/// notes reference them in markdown as `![alt](noteasset:<filename>)` —
/// image bytes NEVER go into otto_data.json.
///
/// Duplicated notes share asset files, so deletion garbage-collects: an
/// asset is removed only when no remaining note references it.
enum NoteAssetStore {
    static let scheme = "noteasset:"

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("OttoNoteAssets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Save image data and return the markdown source reference
    /// (`noteasset:<filename>`), or nil when the write fails.
    static func saveImageData(_ data: Data, fileExtension: String) -> String? {
        let ext = fileExtension.isEmpty ? "png" : fileExtension.lowercased()
        let filename = UUID().uuidString.lowercased() + "." + ext
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return scheme + filename
        } catch {
            return nil
        }
    }

    /// Save an NSImage as PNG.
    static func saveImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return saveImageData(png, fileExtension: "png")
    }

    /// Copy an image file from disk (drag & drop) into the asset store.
    static func importImageFile(at sourceURL: URL) -> String? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        return saveImageData(data, fileExtension: sourceURL.pathExtension)
    }

    /// Resolve a block's image source to a local file URL, if it is one of
    /// ours (remote http(s) sources return nil and render via AsyncImage).
    static func url(for source: String) -> URL? {
        guard source.hasPrefix(scheme) else {
            if source.hasPrefix("file://") { return URL(string: source) }
            if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
            return nil
        }
        let filename = String(source.dropFirst(scheme.count))
        // Basename only — a reference can't escape the assets folder.
        guard !filename.isEmpty, !filename.contains("/"), !filename.contains("..") else { return nil }
        return directory.appendingPathComponent(filename)
    }

    /// All `noteasset:` references inside a markdown string.
    static func assetReferences(in content: String) -> Set<String> {
        var refs: Set<String> = []
        var searchRange = content.startIndex..<content.endIndex
        while let range = content.range(of: #"noteasset:[A-Za-z0-9\-]+\.[A-Za-z0-9]+"#,
                                        options: .regularExpression,
                                        range: searchRange) {
            refs.insert(String(content[range]))
            searchRange = range.upperBound..<content.endIndex
        }
        return refs
    }

    /// Remove the assets a deleted note referenced — unless another surviving
    /// note still uses them (duplicates share files).
    static func purgeAssets(of note: Note, keeping remaining: [Note]) {
        let candidates = assetReferences(in: note.content)
        guard !candidates.isEmpty else { return }
        var stillUsed: Set<String> = []
        for other in remaining where other.id != note.id {
            guard other.content.contains(scheme) else { continue }
            stillUsed.formUnion(assetReferences(in: other.content))
        }
        for ref in candidates.subtracting(stillUsed) {
            if let url = url(for: ref) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
