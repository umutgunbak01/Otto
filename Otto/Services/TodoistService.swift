import Foundation

actor TodoistService {
    static let shared = TodoistService()

    // Todoist retired `/rest/v2` (returns 410 Gone) and moved everything to the
    // unified `/api/v1` base. Endpoint paths (/tasks, /projects, /tasks/{id}/close,
    // /tasks/{id}/reopen) are unchanged — only the base URL was updated.
    private let baseURL = "https://api.todoist.com/api/v1"
    private let userDefaultsKey = "todoist_api_token"

    private var apiToken: String {
        UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
    }

    private init() {}

    // MARK: - API Token Management

    nonisolated func setAPIToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "todoist_api_token")
    }

    nonisolated func getAPIToken() -> String {
        UserDefaults.standard.string(forKey: "todoist_api_token") ?? ""
    }

    nonisolated func hasAPIToken() -> Bool {
        if let token = UserDefaults.standard.string(forKey: "todoist_api_token"), !token.isEmpty {
            return true
        }
        return false
    }

    nonisolated func clearAPIToken() {
        UserDefaults.standard.removeObject(forKey: "todoist_api_token")
    }

    // MARK: - API Requests

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard !apiToken.isEmpty else {
            throw TodoistError.noAPIToken
        }

        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw TodoistError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TodoistError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...204:
            return data
        case 401:
            throw TodoistError.unauthorized
        case 403:
            throw TodoistError.forbidden
        case 429:
            throw TodoistError.rateLimited
        default:
            throw TodoistError.apiError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Fetch Tasks

    /// Fetch all active tasks from Todoist
    func fetchTasks() async throws -> [TodoistTask] {
        try await fetchAllPages(path: "/tasks")
    }

    // MARK: - Fetch Projects

    /// Fetch all projects from Todoist
    func fetchProjects() async throws -> [TodoistProject] {
        try await fetchAllPages(path: "/projects")
    }

    // MARK: - Pagination

    /// Todoist's `/api/v1` endpoints return a paginated envelope
    /// (`{results: [...], next_cursor: "..."}`) instead of the bare arrays
    /// that REST v2 used. To stay compatible with older Todoist responses too
    /// (and any future endpoint that goes back to a flat shape), we try to
    /// decode the envelope first and fall back to a bare array.
    private func fetchAllPages<T: Decodable>(path: String) async throws -> [T] {
        let decoder = JSONDecoder()
        var collected: [T] = []
        var cursor: String? = nil
        let separator = path.contains("?") ? "&" : "?"

        repeat {
            let pagedPath: String = {
                guard let cursor else { return path }
                let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
                return "\(path)\(separator)cursor=\(encoded)"
            }()
            let data = try await makeRequest(path: pagedPath)

            if let envelope = try? decoder.decode(PaginatedResponse<T>.self, from: data) {
                collected.append(contentsOf: envelope.results)
                cursor = envelope.nextCursor?.isEmpty == false ? envelope.nextCursor : nil
            } else {
                // Older / non-paginated endpoint — bare array.
                let bare = try decoder.decode([T].self, from: data)
                collected.append(contentsOf: bare)
                cursor = nil
            }
        } while cursor != nil

        return collected
    }

    // MARK: - Task Actions

    /// Close (complete) a task in Todoist
    func closeTask(id: String) async throws {
        _ = try await makeRequest(path: "/tasks/\(id)/close", method: "POST")
    }

    /// Reopen a task in Todoist
    func reopenTask(id: String) async throws {
        _ = try await makeRequest(path: "/tasks/\(id)/reopen", method: "POST")
    }

    /// Create a task in Todoist. Returns the full task (including the
    /// server-assigned `id`) so the caller can persist the link.
    func createTask(from todo: Todo, projectId: String? = nil) async throws -> TodoistTask {
        var body: [String: Any] = [
            "content": todo.title,
            "priority": todo.priority.rawValue
        ]
        if !todo.description.isEmpty { body["description"] = todo.description }
        if let dueDate = todo.dueDate {
            applyDueDate(dueDate, to: &body)
        }
        if let projectId { body["project_id"] = projectId }

        let data = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await makeRequest(path: "/tasks", method: "POST", body: data)
        return try JSONDecoder().decode(TodoistTask.self, from: responseData)
    }

    /// Update a task in Todoist with all writable fields from the local todo.
    /// Sends `due_string: ""` when the local todo has no due date, to clear
    /// any existing due date on the remote.
    func updateTask(id: String, from todo: Todo) async throws {
        var body: [String: Any] = [
            "content": todo.title,
            "description": todo.description,
            "priority": todo.priority.rawValue
        ]
        if let dueDate = todo.dueDate {
            applyDueDate(dueDate, to: &body)
        } else {
            body["due_string"] = ""
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await makeRequest(path: "/tasks/\(id)", method: "POST", body: data)
    }

    /// Permanently delete a task in Todoist.
    func deleteTask(id: String) async throws {
        _ = try await makeRequest(path: "/tasks/\(id)", method: "DELETE")
    }

    /// Encode a Swift Date for Todoist's `due_date` (date-only) or
    /// `due_datetime` (timestamp) field. Date-only is detected by a
    /// midnight local time-of-day — matches how Otto stores "no specific
    /// time" reminders.
    private func applyDueDate(_ date: Date, to body: inout [String: Any]) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let timeOfDayIsMidnight = (comps.hour ?? 0) == 0
            && (comps.minute ?? 0) == 0
            && (comps.second ?? 0) == 0
        if timeOfDayIsMidnight {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = TimeZone.current
            body["due_date"] = fmt.string(from: date)
        } else {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            body["due_datetime"] = iso.string(from: date)
        }
    }

    // MARK: - Validate Token

    /// Validate the API token by attempting to fetch projects
    func validateToken() async throws -> Bool {
        _ = try await fetchProjects()
        return true
    }

    // MARK: - Convert to Otto Todos

    /// Convert Todoist tasks to Otto Todo models
    func convertToTodos(_ tasks: [TodoistTask], projects: [TodoistProject], labelMap: [String: UUID] = [:]) -> [Todo] {
        let projectMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })

        return tasks.map { task in
            let dueDate = parseDueDate(task.due)
            let priority = mapPriority(task.priority ?? 1)
            let projectName = task.projectId.flatMap { projectMap[$0] }
            let tagIds = (task.labels ?? []).compactMap { labelMap[$0.lowercased()] }

            return Todo(
                title: task.content,
                description: task.todoistDescription ?? "",
                dueDate: dueDate,
                priority: priority,
                todoistId: task.id,
                todoistProjectName: projectName,
                domainTagIds: tagIds
            )
        }
    }

    // MARK: - Helpers

    /// Parse Todoist due date object into a Swift Date
    private func parseDueDate(_ due: TodoistDue?) -> Date? {
        guard let due = due else { return nil }

        // Try datetime first (has time component)
        if let datetime = due.datetime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: datetime) {
                return date
            }
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: datetime)
        }

        // Fall back to date-only
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: due.date)
    }

    /// Map Todoist priority (inverted: 4=most urgent) to Otto priority
    /// Todoist API: priority 4 = p1 (urgent), 3 = p2, 2 = p3, 1 = p4 (low/no priority)
    private func mapPriority(_ todoistPriority: Int) -> Todo.Priority {
        switch todoistPriority {
        case 4: return .urgent
        case 3: return .high
        case 2: return .medium
        default: return .low
        }
    }
}

// MARK: - Todoist API Models

/// Paginated envelope for Todoist `/api/v1` list endpoints.
private struct PaginatedResponse<T: Decodable>: Decodable {
    let results: [T]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case nextCursor = "next_cursor"
    }
}

struct TodoistTask: Codable {
    let id: String
    let content: String
    // Non-essential fields kept optional so a single missing/changed field
    // from `/api/v1` doesn't fail the decode for the whole sync.
    let todoistDescription: String?
    let projectId: String?
    let priority: Int?
    let due: TodoistDue?
    let isCompleted: Bool?
    let createdAt: String?
    let url: String?
    let labels: [String]?

    enum CodingKeys: String, CodingKey {
        case id, content, priority, due, url, labels
        case todoistDescription = "description"
        case projectId = "project_id"
        case isCompleted = "is_completed"
        case createdAt = "created_at"
    }
}

struct TodoistDue: Codable {
    let date: String
    let datetime: String?
    let isRecurring: Bool
    let string: String

    enum CodingKeys: String, CodingKey {
        case date, datetime, string
        case isRecurring = "is_recurring"
    }
}

struct TodoistProject: Codable {
    let id: String
    let name: String
    // Todoist's `/api/v1` returns omits some of these on Inbox / shared
    // projects, and may add fields without notice. Keep everything past
    // (id, name) optional so a single missing field doesn't fail the whole
    // decode and break Connect.
    let color: String?
    let order: Int?
    let isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, color, order
        case isFavorite = "is_favorite"
    }
}

// MARK: - Errors

enum TodoistError: LocalizedError {
    case noAPIToken
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden
    case rateLimited
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .noAPIToken:
            return "No Todoist API token configured. Add your token in Settings."
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from Todoist"
        case .unauthorized:
            return "Invalid API token. Please check your Todoist API token in Settings."
        case .forbidden:
            return "Access forbidden. Please check your Todoist API token permissions."
        case .rateLimited:
            return "Too many requests. Please wait a moment and try again."
        case .apiError(let statusCode):
            return "Todoist API error (status: \(statusCode))"
        }
    }
}
