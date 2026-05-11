import Foundation
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreImage)
import CoreImage
#endif

/// Service for managing file storage and import
actor FileStorageService {
    static let shared = FileStorageService()

    private let fileManager = FileManager.default
    private let filesDirectory: URL

    private init() {
        // Create a Files directory in the app's document directory.
        // `urls(for:in:)` always returns at least one URL on macOS, but a
        // defensive fallback to the temp dir keeps a broken sandbox from
        // crashing the app at launch.
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        filesDirectory = documentsPath.appendingPathComponent("OttoFiles", isDirectory: true)

        if !fileManager.fileExists(atPath: filesDirectory.path) {
            try? fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - File Import

    /// Import a file from a URL and return a FileItem
    func importFile(from sourceURL: URL) async throws -> FileItem {
        // Get file info
        let fileName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension.lowercased()

        guard let fileType = FileType.from(extension: fileExtension) else {
            throw FileStorageError.unsupportedFileType(fileExtension)
        }

        // Get file size
        let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(resourceValues.fileSize ?? 0)

        // Create the FileItem
        let fileItem = FileItem(
            name: fileName,
            fileType: fileType,
            fileExtension: fileExtension,
            fileSize: fileSize
        )

        // Copy file to our storage directory
        let destinationURL = filesDirectory.appendingPathComponent(fileItem.storedFileName)

        // Start accessing security-scoped resource if needed
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Remove existing file if any
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        // Copy the file
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        // Extract text content for searchability (async task)
        var updatedFileItem = fileItem
        if let extractedText = await extractText(from: destinationURL, fileType: fileType) {
            updatedFileItem.extractedText = extractedText
        }

        return updatedFileItem
    }

    // MARK: - File Access

    /// Get the URL for a stored file
    func getFileURL(for fileItem: FileItem) -> URL {
        filesDirectory.appendingPathComponent(fileItem.storedFileName)
    }

    /// Check if a file exists
    func fileExists(_ fileItem: FileItem) -> Bool {
        fileManager.fileExists(atPath: getFileURL(for: fileItem).path)
    }

    /// Get file data
    func getFileData(for fileItem: FileItem) throws -> Data {
        let url = getFileURL(for: fileItem)
        return try Data(contentsOf: url)
    }

    // MARK: - File Deletion

    /// Delete a file from storage
    nonisolated func deleteFile(_ fileItem: FileItem) {
        guard let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = documents
            .appendingPathComponent("OttoFiles", isDirectory: true)
            .appendingPathComponent(fileItem.storedFileName)

        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Text Extraction

    /// Extract searchable text from a file
    private func extractText(from url: URL, fileType: FileType) async -> String? {
        switch fileType {
        case .csv:
            return extractTextFromUTF8(url: url)
        case .excel:
            // .xlsx is a zipped XML bundle; native extraction would need
            // ZIPFoundation + XML parsing. The agent can still see the
            // file metadata via list_files, and the binary is staged into
            // the CLI tmpDir so a future tool can read it.
            return nil
        case .pdf:
            return extractTextFromPDF(url: url)
        case .image:
            return await extractTextFromImage(url: url)
        case .text:
            return extractTextFromUTF8(url: url)
        case .video, .audio:
            // Genmedia outputs and other media — no text extraction; the
            // binary is staged in OttoFiles/ and surfaced by path.
            return nil
        }
    }

    /// Plain UTF-8 read with ISO-Latin-1 fallback. Used for CSV and the
    /// plain-text family (txt / md / json / yaml / log / html / xml / rtf).
    private func extractTextFromUTF8(url: URL) -> String? {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
            return content
        }
        return nil
    }

    private func extractTextFromPDF(url: URL) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return nil }

        var text = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        return text.isEmpty ? nil : text
        #else
        return nil
        #endif
    }

    /// OCR images via Vision (`VNRecognizeTextRequest`). Native, no deps. The
    /// recognition level is `.accurate` since import is a one-time cost; the
    /// recognized strings are concatenated in observation order which roughly
    /// preserves top-to-bottom reading.
    ///
    /// Threading: the request body runs on a background queue (Vision is CPU-
    /// heavy and we don't want to block the actor's executor). The continuation
    /// is resumed from that background queue, but Swift Concurrency restores
    /// the awaiting coroutine to its caller's isolation (this actor, or
    /// whichever MainActor caller awaited us) — so any code after the `await`
    /// runs back on the right thread automatically. We only build a string in
    /// the resume path, which is safe from any thread.
    private func extractTextFromImage(url: URL) async -> String? {
        #if canImport(Vision) && canImport(CoreImage)
        guard let ciImage = CIImage(contentsOf: url) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // Guard against double-resume — `VNRecognizeTextRequest`'s
            // completion handler will fire AND any `perform` throw will also
            // try to resume, so we need to make sure only one wins.
            let resumeOnce = ResumeOnce()
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty
                else {
                    resumeOnce.resume(continuation, with: nil)
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                resumeOnce.resume(continuation, with: joined.isEmpty ? nil : joined)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    resumeOnce.resume(continuation, with: nil)
                }
            }
        }
        #else
        return nil
        #endif
    }

    /// Tiny helper that ensures a CheckedContinuation is resumed at most once —
    /// `VNRecognizeTextRequest`'s callback + a `perform` throw can race, and
    /// `CheckedContinuation` traps on double-resume.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func resume<T>(_ continuation: CheckedContinuation<T, Never>, with value: T) {
            lock.lock()
            let shouldResume = !done
            done = true
            lock.unlock()
            if shouldResume { continuation.resume(returning: value) }
        }
    }

    // MARK: - Supported File Types

    /// Get all supported file extensions
    static var supportedExtensions: [String] {
        FileType.allCases.flatMap { $0.allowedExtensions }
    }

    /// Get UTTypes for file picker. Includes the full set Otto knows how to
    /// import — CSV, Excel, PDF, common image formats, and the plain-text
    /// family (txt / md / json / yaml / log / html / xml / rtf).
    static var supportedUTTypes: [UTType] {
        var types: [UTType] = [
            .commaSeparatedText,    // CSV
            .pdf,
            .png,
            .jpeg,
            .heic,
            .gif,
            .bmp,
            .tiff,
            .plainText,             // txt
            .json,
            .html,
            .xml,
            .rtf,
            .mpeg4Movie,            // mp4
            .quickTimeMovie,        // mov
            .audio,                 // wav/aac/aiff family
            .mp3
        ]
        // Extensions without first-class UTTypes — fall back by extension.
        let byExtension: [String] = [
            "xlsx", "xls",          // Excel
            "md", "markdown",
            "yaml", "yml",
            "log",
            "webm", "m4v",          // video
            "m4a", "flac", "ogg",   // audio
            "webp"                  // modern image format
        ]
        for ext in byExtension {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}

// MARK: - Errors

enum FileStorageError: Error, LocalizedError {
    case unsupportedFileType(String)
    case fileNotFound
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "Unsupported file type: .\(ext). Supported types: CSV, Excel (xlsx/xls), PDF, PNG, JPG."
        case .fileNotFound:
            return "File not found in storage."
        case .importFailed(let reason):
            return "Failed to import file: \(reason)"
        }
    }
}
