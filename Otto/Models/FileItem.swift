import Foundation

/// Supported file types for the Files category
enum FileType: String, Codable, CaseIterable {
    case csv = "csv"
    case excel = "excel"
    case image = "image"
    case pdf = "pdf"
    case text = "text"
    /// Generative-media outputs (genmedia) and any imported video. No text
    /// extraction; binary lives in OttoFiles/ and is referenced by path.
    case video = "video"
    /// Generative-media outputs (genmedia) and any imported audio. No text
    /// extraction; binary lives in OttoFiles/ and is referenced by path.
    case audio = "audio"

    var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .excel: return "Excel"
        case .image: return "Image"
        case .pdf: return "PDF"
        case .text: return "Text"
        case .video: return "Video"
        case .audio: return "Audio"
        }
    }

    var iconName: String {
        switch self {
        case .csv: return "tablecells"
        case .excel: return "tablecells.fill"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }

    var allowedExtensions: [String] {
        switch self {
        case .csv: return ["csv"]
        case .excel: return ["xlsx", "xls"]
        case .image: return ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tiff", "webp"]
        case .pdf: return ["pdf"]
        case .text: return ["txt", "md", "markdown", "json", "yaml", "yml", "log", "html", "xml", "rtf"]
        case .video: return ["mp4", "mov", "webm", "m4v"]
        case .audio: return ["mp3", "wav", "m4a", "aac", "flac", "ogg"]
        }
    }

    static func from(extension ext: String) -> FileType? {
        let lowercased = ext.lowercased()
        for type in FileType.allCases {
            if type.allowedExtensions.contains(lowercased) {
                return type
            }
        }
        return nil
    }
}

/// A file item stored in the Otto app
struct FileItem: Identifiable, Equatable {
    let id: UUID
    var name: String
    var fileType: FileType
    var fileExtension: String
    var fileSize: Int64  // Size in bytes
    var notes: String
    var tags: [String]
    var extractedText: String?  // Text extracted from PDF/CSV for search
    let createdAt: Date
    var updatedAt: Date

    // File data stored separately to avoid large JSON
    // The actual file is stored as: {id}.{extension} in the Files directory

    init(
        id: UUID = UUID(),
        name: String,
        fileType: FileType,
        fileExtension: String,
        fileSize: Int64,
        notes: String = "",
        tags: [String] = [],
        extractedText: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fileType = fileType
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.notes = notes
        self.tags = tags
        self.extractedText = extractedText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Returns the filename for storing the actual file data
    var storedFileName: String {
        "\(id.uuidString).\(fileExtension)"
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, name, fileType, fileExtension, fileSize, notes, tags
        case extractedText, createdAt, updatedAt, storedFileName
    }
}

extension FileItem: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(fileType, forKey: .fileType)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(notes, forKey: .notes)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(extractedText, forKey: .extractedText)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(storedFileName, forKey: .storedFileName)
    }
}

extension FileItem: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fileType = try container.decode(FileType.self, forKey: .fileType)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        extractedText = try container.decodeIfPresent(String.self, forKey: .extractedText)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        // storedFileName is computed, we don't need to decode it
    }

    /// Human-readable file size
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}
