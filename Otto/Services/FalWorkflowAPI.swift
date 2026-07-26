import Foundation
import UniformTypeIdentifiers

/// Native fal.ai client for the Creative canvas: registry search, per-endpoint
/// OpenAPI schema fetch/parse, queue submit/poll/result/cancel, and CDN
/// uploads. Deliberately does NOT shell out to the genmedia CLI — the canvas
/// needs live queue positions, cancellation, minute-long video jobs, and
/// parallel branches, all of which want first-class HTTP.
///
/// Auth follows `FalAIService`: `Authorization: Key <FAL_KEY>` with the key
/// from UserDefaults (`fal_api_key`) / `FAL_API_KEY` env. Registry + schema
/// endpoints are public and need no key.
actor FalWorkflowAPI {
    static let shared = FalWorkflowAPI()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 3600   // large video uploads/downloads
        return URLSession(configuration: cfg)
    }()

    /// In-memory spec cache; disk cache (raw OpenAPI JSON) lives under
    /// `CreativePaths.schemasDir` so nodes render offline after first fetch.
    private var specCache: [String: CreativeNodeSpec] = [:]

    private init() {}

    // MARK: - Errors

    enum APIError: LocalizedError {
        case missingKey
        case http(Int, String)
        case badResponse(String)
        case schemaUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Add your fal.ai API key in Settings to run models."
            case .http(let code, let msg):
                return "fal.ai error \(code): \(msg)"
            case .badResponse(let what):
                return "Unexpected fal.ai response (\(what))."
            case .schemaUnavailable(let id):
                return "Couldn't load the schema for \(id)."
            }
        }
    }

    private func apiKey() throws -> String {
        let key = FalAIService.shared.getAPIKey()
        guard !key.isEmpty else { throw APIError.missingKey }
        return key
    }

    /// Extracts a readable message from fal error bodies, which are usually
    /// `{"detail": "..."}"` or `{"detail": [{"msg": "...", "loc": [...]}]}`.
    private static func errorMessage(from data: Data, status: Int) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            return raw.isEmpty ? "HTTP \(status)" : String(raw.prefix(300))
        }
        if let dict = obj as? [String: Any] {
            if let s = dict["detail"] as? String { return s }
            if let arr = dict["detail"] as? [[String: Any]] {
                let msgs = arr.compactMap { item -> String? in
                    guard let msg = item["msg"] as? String else { return nil }
                    if let loc = item["loc"] as? [Any], let field = loc.last {
                        return "\(field): \(msg)"
                    }
                    return msg
                }
                if !msgs.isEmpty { return msgs.joined(separator: " · ") }
            }
            if let s = dict["message"] as? String { return s }
            if let s = dict["error"] as? String { return s }
        }
        return "HTTP \(status)"
    }

    // MARK: - Registry search

    struct SearchPage {
        let items: [CreativeModelSummary]
        let total: Int
        let hasMore: Bool
    }

    /// Searches fal's public model registry. `categories` uses fal's slugs
    /// (e.g. "text-to-image"), comma-joined server-side as a union.
    func searchModels(query: String, categories: [String] = [], page: Int = 1) async throws -> SearchPage {
        var components = URLComponents(string: "https://fal.ai/api/models")!
        var items: [URLQueryItem] = [URLQueryItem(name: "page", value: String(page))]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "keywords", value: trimmed))
        }
        if !categories.isEmpty {
            items.append(URLQueryItem(name: "categories", value: categories.joined(separator: ",")))
        }
        components.queryItems = items

        let (data, resp) = try await session.data(from: components.url!)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse("registry") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, Self.errorMessage(from: data, status: http.statusCode))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = root["items"] as? [[String: Any]]
        else { throw APIError.badResponse("registry payload") }

        let total = root["total"] as? Int ?? rawItems.count
        let pages = root["pages"] as? Int ?? 1

        let summaries: [CreativeModelSummary] = rawItems.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            // Only runnable inference endpoints belong on the canvas.
            if let kind = item["kind"] as? String, kind != "inference" { return nil }
            if item["deprecated"] as? Bool == true { return nil }
            if item["removed"] as? Bool == true { return nil }
            return CreativeModelSummary(
                id: id,
                title: (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                category: item["category"] as? String ?? "unknown",
                shortDescription: item["shortDescription"] as? String ?? "",
                thumbnailUrl: (item["thumbnailUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return SearchPage(items: summaries, total: total, hasMore: page < pages)
    }

    // MARK: - Endpoint schema

    /// Returns the parsed node spec for an endpoint. Disk-cached raw OpenAPI
    /// under `CreativePaths.schemasDir`; refreshed in the background when the
    /// cached copy is older than a day.
    func nodeSpec(for endpointId: String, forceRefresh: Bool = false) async throws -> CreativeNodeSpec {
        if !forceRefresh, let cached = specCache[endpointId] {
            return cached
        }

        let cacheURL = CreativePaths.schemaCacheURL(for: endpointId)
        var rawData: Data?

        if !forceRefresh, let data = try? Data(contentsOf: cacheURL) {
            rawData = data
            // Stale-while-revalidate: kick a background refresh but serve the
            // cached spec immediately so adding nodes stays snappy.
            if let mtime = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date,
               Date().timeIntervalSince(mtime) > 86_400 {
                Task { try? await self.nodeSpec(for: endpointId, forceRefresh: true) }
            }
        }

        if rawData == nil {
            rawData = try await fetchRawSchema(endpointId: endpointId, cacheURL: cacheURL)
        }

        guard let rawData,
              let openapi = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let spec = Self.parseSpec(endpointId: endpointId, openapi: openapi)
        else {
            // A corrupt cache shouldn't wedge the endpoint forever.
            try? FileManager.default.removeItem(at: cacheURL)
            throw APIError.schemaUnavailable(endpointId)
        }
        specCache[endpointId] = spec
        return spec
    }

    private func fetchRawSchema(endpointId: String, cacheURL: URL) async throws -> Data {
        var components = URLComponents(string: "https://fal.ai/api/openapi/queue/openapi.json")!
        components.queryItems = [URLQueryItem(name: "endpoint_id", value: endpointId)]
        let (data, resp) = try await session.data(from: components.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.http(code, Self.errorMessage(from: data, status: code))
        }
        try? FileManager.default.createDirectory(at: CreativePaths.schemasDir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        return data
    }

    // MARK: - Queue API

    struct SubmitTicket {
        let requestId: String
        let statusURL: URL
        let responseURL: URL
        let cancelURL: URL
    }

    enum QueueStatus {
        case inQueue(position: Int?)
        case inProgress(lastLog: String?)
        case completed
    }

    func submit(endpointId: String, input: [String: JSONValue]) async throws -> SubmitTicket {
        let key = try apiKey()
        var req = URLRequest(url: URL(string: "https://queue.fal.run/\(endpointId)")!)
        req.httpMethod = "POST"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSONValue.object(input))

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse("submit") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, Self.errorMessage(from: data, status: http.statusCode))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = root["request_id"] as? String
        else { throw APIError.badResponse("submit payload") }

        // The submit response carries absolute URLs — use them verbatim.
        // (Nested endpoints like fal-ai/flux/dev route their request URLs at
        // the parent app level, so hand-building them is error-prone.)
        func url(_ field: String, fallback: String) -> URL {
            if let s = root[field] as? String, let u = URL(string: s) { return u }
            return URL(string: fallback)!
        }
        let base = "https://queue.fal.run/\(endpointId)/requests/\(requestId)"
        return SubmitTicket(
            requestId: requestId,
            statusURL: url("status_url", fallback: base + "/status"),
            responseURL: url("response_url", fallback: base),
            cancelURL: url("cancel_url", fallback: base + "/cancel")
        )
    }

    func status(of ticket: SubmitTicket) async throws -> QueueStatus {
        let key = try apiKey()
        var components = URLComponents(url: ticket.statusURL, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "logs", value: "1")]
        var req = URLRequest(url: components.url!)
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse("status") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, Self.errorMessage(from: data, status: http.statusCode))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["status"] as? String
        else { throw APIError.badResponse("status payload") }

        switch status {
        case "IN_QUEUE":
            return .inQueue(position: root["queue_position"] as? Int)
        case "IN_PROGRESS":
            let lastLog = (root["logs"] as? [[String: Any]])?
                .compactMap { $0["message"] as? String }
                .last
            return .inProgress(lastLog: lastLog)
        case "COMPLETED":
            return .completed
        default:
            return .inProgress(lastLog: nil)
        }
    }

    func result(of ticket: SubmitTicket) async throws -> JSONValue {
        let key = try apiKey()
        var req = URLRequest(url: ticket.responseURL)
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse("result") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, Self.errorMessage(from: data, status: http.statusCode))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data)
        else { throw APIError.badResponse("result payload") }
        return JSONValue.from(any: obj)
    }

    func cancel(_ ticket: SubmitTicket) async {
        guard let key = try? apiKey() else { return }
        var req = URLRequest(url: ticket.cancelURL)
        req.httpMethod = "PUT"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        // Best-effort: a 400 here just means the request already left the queue.
        _ = try? await session.data(for: req)
    }

    // MARK: - CDN upload / download

    /// Uploads a local file to fal's CDN and returns the public file URL.
    /// Flow (verified live): POST rest.fal.ai/storage/upload/initiate →
    /// `{file_url, upload_url}` → PUT the bytes to `upload_url`.
    func upload(fileURL: URL) async throws -> String {
        let key = try apiKey()
        let contentType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        var initiate = URLRequest(url: URL(string: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")!)
        initiate.httpMethod = "POST"
        initiate.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        initiate.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initiate.httpBody = try JSONSerialization.data(withJSONObject: [
            "content_type": contentType,
            "file_name": fileURL.lastPathComponent
        ])

        let (initData, initResp) = try await session.data(for: initiate)
        guard let initHTTP = initResp as? HTTPURLResponse, (200..<300).contains(initHTTP.statusCode) else {
            let code = (initResp as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.http(code, Self.errorMessage(from: initData, status: code))
        }
        guard let root = try JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let fileURLString = root["file_url"] as? String,
              let uploadURLString = root["upload_url"] as? String,
              let uploadURL = URL(string: uploadURLString)
        else { throw APIError.badResponse("upload initiate") }

        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (putData, putResp) = try await session.upload(for: put, fromFile: fileURL)
        guard let putHTTP = putResp as? HTTPURLResponse, (200..<300).contains(putHTTP.statusCode) else {
            let code = (putResp as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.http(code, Self.errorMessage(from: putData, status: code))
        }
        return fileURLString
    }

    /// Downloads a (usually fal CDN) URL to a temporary file and returns its
    /// location. Caller moves it into place.
    func download(from urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else { throw APIError.badResponse("download url") }
        let (tempURL, resp) = try await session.download(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.http(code, "download failed")
        }
        return tempURL
    }
}

// MARK: - OpenAPI → CreativeNodeSpec parsing

extension FalWorkflowAPI {

    /// Parses a fal queue OpenAPI document into the node-facing spec.
    /// Resilient by design: unknown shapes degrade to `.object` params
    /// (raw-JSON editor) rather than failing the endpoint.
    static func parseSpec(endpointId: String, openapi: [String: Any]) -> CreativeNodeSpec? {
        guard let components = openapi["components"] as? [String: Any],
              let schemas = components["schemas"] as? [String: Any]
        else { return nil }

        // Locate the Input/Output schemas. The paths section is authoritative
        // (the submit POST's requestBody and the result GET's 200 response) —
        // suffix scanning alone mispicks when nested types also end in
        // "…Input" (e.g. Kling v3's KlingV3ComboElementInput).
        var inputName: String?
        var outputName: String?

        if let paths = openapi["paths"] as? [String: Any] {
            for (_, rawMethods) in paths {
                guard let methods = rawMethods as? [String: Any] else { continue }
                if inputName == nil,
                   let post = methods["post"] as? [String: Any],
                   let body = post["requestBody"] as? [String: Any],
                   let ref = Self.jsonSchemaRef(in: body) {
                    inputName = ref
                }
                if outputName == nil,
                   let get = methods["get"] as? [String: Any],
                   let responses = get["responses"] as? [String: Any],
                   let ok = responses["200"] as? [String: Any],
                   let ref = Self.jsonSchemaRef(in: ok),
                   ref != "QueueStatus" {
                    outputName = ref
                }
            }
        }

        if inputName == nil {
            inputName = schemas.keys.filter { $0.hasSuffix("Input") }.sorted().first
        }
        if outputName == nil {
            outputName = schemas.keys.filter { $0.hasSuffix("Output") }.sorted().first
        }

        guard let inputName, let inputSchema = schemas[inputName] as? [String: Any] else { return nil }

        let inputs = parseInputs(schema: inputSchema, schemas: schemas)
        var outputs: [CreativePortSpec] = []
        if let outputName, let outputSchema = schemas[outputName] as? [String: Any] {
            outputs = parseOutputs(schema: outputSchema, schemas: schemas)
        }

        return CreativeNodeSpec(
            endpointId: endpointId,
            title: endpointId,
            inputs: inputs,
            outputs: outputs
        )
    }

    /// Digs `content.application/json.schema.$ref` out of a requestBody or
    /// response object and returns the bare schema name.
    private static func jsonSchemaRef(in container: [String: Any]) -> String? {
        guard let content = container["content"] as? [String: Any],
              let json = content["application/json"] as? [String: Any],
              let schema = json["schema"] as? [String: Any],
              let ref = schema["$ref"] as? String
        else { return nil }
        return ref.components(separatedBy: "/").last
    }

    private static func resolveRef(_ ref: String, schemas: [String: Any]) -> (name: String, schema: [String: Any])? {
        guard let name = ref.components(separatedBy: "/").last,
              let schema = schemas[name] as? [String: Any]
        else { return nil }
        return (name, schema)
    }

    /// Unwraps anyOf/allOf/$ref layers around a property schema. Returns the
    /// effective schema dict (with parent-level default/title/description/ui
    /// merged in), the referenced schema name if the chosen branch was a $ref,
    /// and whether null was an accepted variant.
    private static func unwrap(
        _ property: [String: Any],
        schemas: [String: Any]
    ) -> (schema: [String: Any], refName: String?, nullable: Bool) {
        var nullable = false
        var chosen = property
        var refName: String? = nil

        if let anyOf = property["anyOf"] as? [[String: Any]] {
            let variants = anyOf.filter { ($0["type"] as? String) != "null" }
            nullable = variants.count != anyOf.count
            // Preference order: enum string > plain primitive > $ref/object.
            // (e.g. flux `image_size` is anyOf[$ref ImageSize, enum string] —
            // the enum drives a picker; power users can still wire objects.)
            let pick = variants.first { $0["enum"] != nil }
                ?? variants.first { ($0["type"] as? String).map { ["string", "number", "integer", "boolean"].contains($0) } == true }
                ?? variants.first
            chosen = pick ?? [:]
        }

        if let allOf = chosen["allOf"] as? [[String: Any]], let first = allOf.first {
            chosen = first
        }

        if let ref = chosen["$ref"] as? String, let resolved = resolveRef(ref, schemas: schemas) {
            refName = resolved.name
            // Keep the resolved schema but remember where it came from — the
            // ref name ("Image", "File") is a strong media-kind signal.
            chosen = resolved.schema
        }

        // Merge property-level metadata that lives outside the chosen variant.
        for key in ["default", "title", "description", "examples", "ui", "minimum", "maximum"] {
            if chosen[key] == nil, let v = property[key] {
                chosen[key] = v
            }
        }
        return (chosen, refName, nullable)
    }

    /// Media-kind inference from a parameter/port name. fal media params are
    /// plain `string` URLs, so the name (plus occasional `ui.field` hints) is
    /// the signal: image_url, mask_url, video_url, audio_url, voice_url, …
    private static func mediaKind(forName rawName: String, uiField: String? = nil) -> CreativePortKind? {
        if let uiField {
            switch uiField {
            case "image": return .image
            case "video": return .video
            case "audio": return .audio
            case "file": return .file
            default: break
            }
        }
        let name = rawName.lowercased()
        guard name.contains("url") || name.contains("image") || name.contains("video")
                || name.contains("audio") || name.contains("mask") || name.contains("frame")
                || name.contains("thumbnail")
        else { return nil }

        if name.contains("image") || name.contains("mask") || name.contains("frame")
            || name.contains("thumbnail") { return .image }
        if name.contains("video") { return .video }
        if name.contains("audio") || name.contains("voice") || name.contains("music")
            || name.contains("speech") || name.contains("song") { return .audio }
        if name.contains("url") || name.contains("uri") { return .file }
        return nil
    }

    private static func orderedKeys(of schema: [String: Any], properties: [String: Any]) -> [String] {
        if let order = schema["x-fal-order-properties"] as? [String] {
            let known = order.filter { properties[$0] != nil }
            let leftovers = properties.keys.filter { !order.contains($0) }.sorted()
            return known + leftovers
        }
        // JSONSerialization loses key order — fall back to required-first.
        let required = Set(schema["required"] as? [String] ?? [])
        return properties.keys.sorted {
            let lr = required.contains($0), rr = required.contains($1)
            if lr != rr { return lr }
            return $0 < $1
        }
    }

    private static func parseInputs(schema: [String: Any], schemas: [String: Any]) -> [CreativeParamSpec] {
        guard let properties = schema["properties"] as? [String: Any] else { return [] }
        let required = Set(schema["required"] as? [String] ?? [])
        let order = orderedKeys(of: schema, properties: properties)

        var specs: [CreativeParamSpec] = []
        for (index, key) in order.enumerated() {
            guard let property = properties[key] as? [String: Any] else { continue }
            let (effective, refName, _) = unwrap(property, schemas: schemas)

            let uiField = (effective["ui"] as? [String: Any])?["field"] as? String
            let type = effective["type"] as? String
            let enumValues = (effective["enum"] as? [Any])?.compactMap { $0 as? String }

            var kind: CreativePortKind
            var isArrayInput = false
            var isInteger = false

            if let enumValues, !enumValues.isEmpty {
                kind = .enumeration
            } else if type == "boolean" {
                kind = .boolean
            } else if type == "integer" {
                kind = .number; isInteger = true
            } else if type == "number" {
                kind = .number
            } else if type == "array" {
                let items = (effective["items"] as? [String: Any]) ?? [:]
                let (itemSchema, itemRef, _) = unwrap(items, schemas: schemas)
                let itemType = itemSchema["type"] as? String
                if itemType == "string",
                   let media = mediaKind(forName: key, uiField: uiField), media.isMedia {
                    kind = media
                    isArrayInput = true
                } else if itemRef != nil || itemType == "object" || itemType == nil {
                    kind = .object     // arrays of structs (loras, tracks) → JSON editor
                } else {
                    kind = .object     // primitive arrays → JSON editor too (v1)
                }
            } else if type == "string" {
                if let media = mediaKind(forName: key, uiField: uiField) {
                    kind = media
                } else if (effective["format"] as? String) == "uri" {
                    kind = .file
                } else {
                    kind = .string
                }
            } else if refName != nil || type == "object" || type == nil {
                kind = .object
            } else {
                kind = .any
            }

            let title = (effective["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            let description = (effective["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let lowerKey = key.lowercased()
            let multiline = kind == .string && (
                lowerKey.contains("prompt") || lowerKey == "text" || lowerKey == "script"
                    || lowerKey == "lyrics" || lowerKey == "description"
            )

            specs.append(CreativeParamSpec(
                key: key,
                title: title,
                detail: (description?.isEmpty == true) ? nil : description,
                kind: kind,
                isArrayInput: isArrayInput,
                required: required.contains(key),
                defaultValue: effective["default"].map { JSONValue.from(any: $0) },
                enumValues: enumValues,
                minimum: (effective["minimum"] as? NSNumber)?.doubleValue,
                maximum: (effective["maximum"] as? NSNumber)?.doubleValue,
                isInteger: isInteger,
                multiline: multiline,
                featured: required.contains(key) || index < 5
            ))
        }
        return specs
    }

    private static func parseOutputs(schema: [String: Any], schemas: [String: Any]) -> [CreativePortSpec] {
        guard let properties = schema["properties"] as? [String: Any] else { return [] }
        let order = orderedKeys(of: schema, properties: properties)

        var specs: [CreativePortSpec] = []
        for key in order {
            guard let property = properties[key] as? [String: Any] else { continue }
            let (effective, refName, _) = unwrap(property, schemas: schemas)
            let type = effective["type"] as? String

            var isArray = false
            var elementRef = refName
            var elementSchema = effective
            if type == "array" {
                isArray = true
                let items = (effective["items"] as? [String: Any]) ?? [:]
                let (itemSchema, itemRef, _) = unwrap(items, schemas: schemas)
                elementRef = itemRef
                elementSchema = itemSchema
            }

            let kind = outputKind(name: key, refName: elementRef, schema: elementSchema)
            let title = (effective["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            specs.append(CreativePortSpec(key: key, title: title, kind: kind, isArray: isArray))
        }
        return specs
    }

    private static func outputKind(name: String, refName: String?, schema: [String: Any]) -> CreativePortKind {
        // $ref names are the strongest signal: fal's shared media schemas are
        // Image / File / Video / AudioFile / etc.
        if let refName {
            let lower = refName.lowercased()
            if lower.contains("image") { return .image }
            if lower.contains("video") { return .video }
            if lower.contains("audio") { return .audio }
            if lower.contains("file") {
                // Generic `File` — let the property name decide the media kind.
                return mediaKind(forName: name) ?? .file
            }
        }
        let type = schema["type"] as? String
        switch type {
        case "boolean": return .boolean
        case "integer", "number": return .number
        case "string":
            return mediaKind(forName: name) ?? .string
        case "object", nil:
            if refName != nil { return .object }
            return type == nil ? .any : .object
        default:
            return .object
        }
    }
}
