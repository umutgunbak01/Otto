import Foundation

actor LinkedInImportService {

    enum ImportError: Error, LocalizedError {
        case fileNotFound
        case invalidFormat
        case parseError(String)
        case noDataFound

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return "CSV file not found"
            case .invalidFormat:
                return "Invalid CSV format. Please export your connections from LinkedIn."
            case .parseError(let message):
                return "Parse error: \(message)"
            case .noDataFound:
                return "No connections found in the CSV file"
            }
        }
    }

    // LinkedIn CSV column headers (as of 2024)
    private enum Column: String, CaseIterable {
        case firstName = "First Name"
        case lastName = "Last Name"
        case emailAddress = "Email Address"
        case company = "Company"
        case position = "Position"
        case connectedOn = "Connected On"
        case url = "URL"

        // Alternative header names LinkedIn might use
        var alternatives: [String] {
            switch self {
            case .firstName: return ["first name", "firstname"]
            case .lastName: return ["last name", "lastname"]
            case .emailAddress: return ["email address", "email", "emailaddress"]
            case .company: return ["company", "organization"]
            case .position: return ["position", "title", "job title", "headline"]
            case .connectedOn: return ["connected on", "connectedon", "connection date"]
            case .url: return ["url", "profile url", "linkedin url"]
            }
        }
    }

    func importFromCSV(url: URL) async throws -> [Connection] {
        // Start accessing the security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            throw ImportError.fileNotFound
        }
        defer { url.stopAccessingSecurityScopedResource() }

        var content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try other encodings
            do {
                content = try String(contentsOf: url, encoding: .isoLatin1)
            } catch {
                throw ImportError.fileNotFound
            }
        }

        // Remove BOM (Byte Order Mark) if present
        if content.hasPrefix("\u{FEFF}") {
            content = String(content.dropFirst())
        }

        return try parseCSV(content)
    }

    private func parseCSV(_ content: String) throws -> [Connection] {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            throw ImportError.noDataFound
        }

        // Find the header row (LinkedIn sometimes adds notes at the top)
        var headerRowIndex = 0
        var columnIndices: [Column: Int] = [:]

        for (index, line) in lines.enumerated() {
            let potentialHeaders = parseCSVRow(line)
            let potentialIndices = mapColumnIndices(potentialHeaders)

            // Check if this row contains the expected column headers
            if potentialIndices[.firstName] != nil || potentialIndices[.lastName] != nil {
                headerRowIndex = index
                columnIndices = potentialIndices
                break
            }
        }

        // Validate required columns exist
        guard columnIndices[.firstName] != nil || columnIndices[.lastName] != nil else {
            // Log the first row for debugging
            let firstRow = parseCSVRow(lines[0])
            print("LinkedIn Import: Headers found: \(firstRow)")
            throw ImportError.invalidFormat
        }

        var connections: [Connection] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd MMM yyyy" // LinkedIn format: "01 Jan 2024"

        // Alternative date formats LinkedIn might use
        let altDateFormatter = DateFormatter()
        altDateFormatter.dateFormat = "yyyy-MM-dd"

        let altDateFormatter2 = DateFormatter()
        altDateFormatter2.dateFormat = "MM/dd/yyyy"

        // Parse data rows (starting after header row)
        for i in (headerRowIndex + 1)..<lines.count {
            let row = parseCSVRow(lines[i])

            let firstName = getValue(from: row, column: .firstName, indices: columnIndices)
            let lastName = getValue(from: row, column: .lastName, indices: columnIndices)

            // Skip rows without names
            guard !firstName.isEmpty || !lastName.isEmpty else { continue }

            let email = getValue(from: row, column: .emailAddress, indices: columnIndices)
            let company = getValue(from: row, column: .company, indices: columnIndices)
            let position = getValue(from: row, column: .position, indices: columnIndices)
            let connectedOnStr = getValue(from: row, column: .connectedOn, indices: columnIndices)
            let profileUrl = getValue(from: row, column: .url, indices: columnIndices)

            // Parse connection date
            var connectionDate: Date? = nil
            if !connectedOnStr.isEmpty {
                connectionDate = dateFormatter.date(from: connectedOnStr)
                    ?? altDateFormatter.date(from: connectedOnStr)
                    ?? altDateFormatter2.date(from: connectedOnStr)
            }

            let connection = Connection(
                firstName: firstName,
                lastName: lastName,
                headline: position,
                company: company,
                location: "", // LinkedIn CSV doesn't include location
                email: email.isEmpty ? nil : email,
                profileUrl: profileUrl.isEmpty ? nil : profileUrl,
                connectionDate: connectionDate,
                notes: "",
                tags: []
            )

            connections.append(connection)
        }

        guard !connections.isEmpty else {
            throw ImportError.noDataFound
        }

        return connections
    }

    private func parseCSVRow(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex

        while i < line.endIndex {
            let char = line[i]

            if char == "\"" {
                if inQuotes {
                    // Check for escaped quote
                    let nextIndex = line.index(after: i)
                    if nextIndex < line.endIndex && line[nextIndex] == "\"" {
                        current.append("\"")
                        i = nextIndex
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if char == "," && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }

            i = line.index(after: i)
        }

        // Add last field
        result.append(current.trimmingCharacters(in: .whitespaces))

        return result
    }

    private func mapColumnIndices(_ headers: [String]) -> [Column: Int] {
        var indices: [Column: Int] = [:]

        for (index, header) in headers.enumerated() {
            let normalizedHeader = header.lowercased().trimmingCharacters(in: .whitespaces)

            for column in Column.allCases {
                if column.rawValue.lowercased() == normalizedHeader ||
                   column.alternatives.contains(normalizedHeader) {
                    indices[column] = index
                    break
                }
            }
        }

        return indices
    }

    private func getValue(from row: [String], column: Column, indices: [Column: Int]) -> String {
        guard let index = indices[column], index < row.count else {
            return ""
        }
        return row[index].trimmingCharacters(in: .whitespaces)
    }
}
