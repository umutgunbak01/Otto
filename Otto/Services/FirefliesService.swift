import Foundation

actor FirefliesService {
    private let baseURL = URL(string: "https://api.fireflies.ai/graphql")!

    private var apiKey: String {
        if let envKey = ProcessInfo.processInfo.environment["FIREFLIES_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        if let storedKey = UserDefaults.standard.string(forKey: "fireflies_api_key"), !storedKey.isEmpty {
            return storedKey
        }
        return ""
    }

    static let shared = FirefliesService()

    private init() {}

    // MARK: - API Key Management

    nonisolated func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "fireflies_api_key")
    }

    nonisolated func getAPIKey() -> String {
        if let envKey = ProcessInfo.processInfo.environment["FIREFLIES_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        return UserDefaults.standard.string(forKey: "fireflies_api_key") ?? ""
    }

    nonisolated func hasAPIKey() -> Bool {
        if let envKey = ProcessInfo.processInfo.environment["FIREFLIES_API_KEY"], !envKey.isEmpty {
            return true
        }
        if let storedKey = UserDefaults.standard.string(forKey: "fireflies_api_key"), !storedKey.isEmpty {
            return true
        }
        return false
    }

    // MARK: - Fetch Transcripts

    /// Fetch all transcripts with pagination, filtered by participant email
    func fetchTranscripts(participantEmail: String) async throws -> [FirefliesTranscript] {
        guard !apiKey.isEmpty else {
            throw FirefliesServiceError.invalidAPIKey
        }

        var allTranscripts: [FirefliesTranscript] = []
        let batchSize = 50 // Fireflies API limit is 50 max
        var skip = 0

        while true {
            let variables = FirefliesVariables(
                participants: [participantEmail],
                limit: batchSize,
                skip: skip
            )
            let response: FirefliesGraphQLResponse<TranscriptsData> = try await sendGraphQLRequest(
                query: FirefliesQueries.transcriptsFiltered,
                variables: variables
            )

            if let errors = response.errors, !errors.isEmpty {
                throw FirefliesServiceError.apiError(errors.first?.message ?? "Unknown error")
            }

            guard let data = response.data else {
                break
            }

            let transcripts = data.transcripts
            if transcripts.isEmpty {
                break // No more transcripts
            }

            allTranscripts.append(contentsOf: transcripts)
            skip += transcripts.count

            // Safety limit to prevent infinite loops (max 1000 meetings)
            if allTranscripts.count >= 1000 || transcripts.count < batchSize {
                break
            }
        }

        return allTranscripts
    }

    /// Fetch transcripts with filters (for auto-sync)
    func fetchTranscripts(
        fromDate: Date? = nil,
        toDate: Date? = nil,
        participantEmail: String? = nil,
        limit: Int? = 50
    ) async throws -> [FirefliesTranscript] {
        guard !apiKey.isEmpty else {
            throw FirefliesServiceError.invalidAPIKey
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var variables = FirefliesVariables(limit: limit)

        if let fromDate = fromDate {
            variables.fromDate = formatter.string(from: fromDate)
        }

        if let toDate = toDate {
            variables.toDate = formatter.string(from: toDate)
        }

        if let email = participantEmail, !email.isEmpty {
            variables.participants = [email]
        }

        let response: FirefliesGraphQLResponse<TranscriptsData> = try await sendGraphQLRequest(
            query: FirefliesQueries.transcriptsFiltered,
            variables: variables
        )

        if let errors = response.errors, !errors.isEmpty {
            throw FirefliesServiceError.apiError(errors.first?.message ?? "Unknown error")
        }

        guard let data = response.data else {
            throw FirefliesServiceError.emptyResponse
        }

        return data.transcripts
    }

    func fetchTranscript(id: String) async throws -> FirefliesTranscript {
        guard !apiKey.isEmpty else {
            throw FirefliesServiceError.invalidAPIKey
        }

        let variables = FirefliesVariables(transcriptId: id)

        let response: FirefliesGraphQLResponse<TranscriptData> = try await sendGraphQLRequest(
            query: FirefliesQueries.transcriptDetail,
            variables: variables
        )

        if let errors = response.errors, !errors.isEmpty {
            throw FirefliesServiceError.apiError(errors.first?.message ?? "Unknown error")
        }

        guard let transcript = response.data?.transcript else {
            throw FirefliesServiceError.transcriptNotFound
        }

        return transcript
    }

    /// Fetch raw transcript sentences (timestamped speaker lines)
    func fetchTranscriptSentences(id: String) async throws -> [FirefliesSentence] {
        guard !apiKey.isEmpty else {
            throw FirefliesServiceError.invalidAPIKey
        }

        let variables = FirefliesVariables(transcriptId: id)

        let response: FirefliesGraphQLResponse<TranscriptSentencesData> = try await sendGraphQLRequest(
            query: FirefliesQueries.transcriptSentences,
            variables: variables
        )

        if let errors = response.errors, !errors.isEmpty {
            throw FirefliesServiceError.apiError(errors.first?.message ?? "Unknown error")
        }

        return response.data?.transcript?.sentences ?? []
    }

    // MARK: - Private Methods

    private func sendGraphQLRequest<T: Decodable>(
        query: String,
        variables: FirefliesVariables? = nil
    ) async throws -> FirefliesGraphQLResponse<T> {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = FirefliesGraphQLRequest(query: query, variables: variables)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FirefliesServiceError.requestFailed
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("Fireflies API Error (\(httpResponse.statusCode)): \(errorBody)")
            throw FirefliesServiceError.httpError(httpResponse.statusCode)
        }

        // Debug: print raw response to understand the format
        #if DEBUG
        if let jsonString = String(data: data, encoding: .utf8) {
            print("Fireflies API Response: \(jsonString.prefix(2000))")
        }
        #endif

        do {
            return try JSONDecoder().decode(FirefliesGraphQLResponse<T>.self, from: data)
        } catch {
            print("Fireflies JSON Decode Error: \(error)")
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Raw response: \(jsonString.prefix(2000))")
            }
            throw error
        }
    }
}

enum FirefliesServiceError: Error, LocalizedError {
    case invalidAPIKey
    case requestFailed
    case httpError(Int)
    case emptyResponse
    case transcriptNotFound
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "No Fireflies API key configured. Add your key in Settings."
        case .requestFailed:
            return "Failed to connect to Fireflies API. Check your internet connection."
        case .httpError(let code):
            return "Fireflies API error: HTTP \(code)"
        case .emptyResponse:
            return "Empty response from Fireflies API."
        case .transcriptNotFound:
            return "Transcript not found."
        case .apiError(let message):
            return "Fireflies error: \(message)"
        }
    }
}
