import Foundation

/// On-disk locations for the Creative canvas. Everything lives under
/// `~/Library/Application Support/Otto/Creative/`:
///   workflows/<uuid>.json   — one document per workflow
///   assets/<uuid>.<ext>     — imported media, original quality
///   schemas/<endpoint>.json — cached raw OpenAPI per fal endpoint
///   thumbs/                 — downsampled preview cache
enum CreativePaths {
    static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Otto", isDirectory: true)
            .appendingPathComponent("Creative", isDirectory: true)
    }

    static var workflowsDir: URL { baseDir.appendingPathComponent("workflows", isDirectory: true) }
    static var assetsDir: URL { baseDir.appendingPathComponent("assets", isDirectory: true) }
    static var schemasDir: URL { baseDir.appendingPathComponent("schemas", isDirectory: true) }
    static var thumbsDir: URL { baseDir.appendingPathComponent("thumbs", isDirectory: true) }

    static func schemaCacheURL(for endpointId: String) -> URL {
        let slug = endpointId.replacingOccurrences(of: "/", with: "__")
        return schemasDir.appendingPathComponent("\(slug).json")
    }

    static func assetURL(for asset: CreativeMediaAsset) -> URL {
        assetsDir.appendingPathComponent(asset.relativePath)
    }
}

/// Workflow document + asset persistence. One JSON file per workflow keeps
/// canvas autosaves cheap — this is intentionally separate from the
/// `OttoDataStore` monolith, whose whole-file-per-mutation writes are the
/// wrong grain for high-frequency canvas edits.
actor CreativeStore {
    static let shared = CreativeStore()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    func ensureDirectories() {
        for dir in [CreativePaths.workflowsDir, CreativePaths.assetsDir,
                    CreativePaths.schemasDir, CreativePaths.thumbsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Workflows

    /// Loads every workflow document, newest-updated first. Corrupt files are
    /// skipped rather than sinking the whole tab.
    func loadWorkflows() -> [CreativeWorkflow] {
        ensureDirectories()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: CreativePaths.workflowsDir,
            includingPropertiesForKeys: nil
        )) ?? []

        var workflows: [CreativeWorkflow] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let workflow = try? decoder.decode(CreativeWorkflow.self, from: data)
            else { continue }
            workflows.append(workflow)
        }
        return workflows.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ workflow: CreativeWorkflow) {
        ensureDirectories()
        let url = CreativePaths.workflowsDir.appendingPathComponent("\(workflow.id.uuidString).json")
        guard let data = try? encoder.encode(workflow) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func deleteWorkflow(id: UUID) {
        let url = CreativePaths.workflowsDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Assets

    /// Copies a user file into the assets directory (original bytes, original
    /// quality) and returns its descriptor. The canvas renders downsampled
    /// thumbnails; this copy is what uploads to fal and what "Save…" exports.
    func importAsset(from sourceURL: URL) throws -> CreativeMediaAsset {
        ensureDirectories()
        let ext = sourceURL.pathExtension
        let stored = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destination = CreativePaths.assetsDir.appendingPathComponent(stored)

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let byteSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil
        return CreativeMediaAsset(
            fileName: sourceURL.lastPathComponent,
            relativePath: stored,
            kind: .from(fileExtension: ext),
            byteSize: byteSize,
            falURL: nil
        )
    }

    func deleteAsset(_ asset: CreativeMediaAsset) {
        try? FileManager.default.removeItem(at: CreativePaths.assetURL(for: asset))
    }
}
