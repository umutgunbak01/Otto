import Foundation

/// Transport for a user-added MCP server. `stdio` spawns a local command;
/// `http` (streamable HTTP) and `sse` (legacy Server-Sent Events) connect
/// to a remote URL. All three agent backends consume stdio and http; sse is
/// skipped on Codex, which has no SSE MCP client.
enum CustomMCPTransport: String, Codable, CaseIterable, Identifiable {
    case stdio
    case http
    case sse

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stdio: return "Local command"
        case .http:  return "Remote"
        case .sse:   return "Remote (legacy SSE)"
        }
    }
}

/// Curated one-tap connectors for the Add MCP Server sheet — official
/// hosted servers with stable URLs, mirroring the connector galleries on
/// Claude/ChatGPT. Tapping one fills the name + URL fields; whether the
/// server needs OAuth is discovered at connect time, so entries don't
/// carry auth config.
struct CustomMCPPreset: Identifiable {
    let name: String
    let url: String
    /// Servers still on the pre-streamable-HTTP SSE transport.
    var legacySSE: Bool = false

    var id: String { url }

    static let catalog: [CustomMCPPreset] = [
        CustomMCPPreset(name: "Notion", url: "https://mcp.notion.com/mcp"),
        CustomMCPPreset(name: "Linear", url: "https://mcp.linear.app/mcp"),
        CustomMCPPreset(name: "GitHub", url: "https://api.githubcopilot.com/mcp/"),
        CustomMCPPreset(name: "Figma", url: "https://mcp.figma.com/mcp"),
        CustomMCPPreset(name: "Sentry", url: "https://mcp.sentry.dev/mcp"),
        CustomMCPPreset(name: "Stripe", url: "https://mcp.stripe.com"),
        CustomMCPPreset(name: "Atlassian", url: "https://mcp.atlassian.com/v1/sse", legacySSE: true),
        CustomMCPPreset(name: "Asana", url: "https://mcp.asana.com/sse", legacySSE: true),
        CustomMCPPreset(name: "Todoist", url: "https://ai.todoist.net/mcp"),
        CustomMCPPreset(name: "Canva", url: "https://mcp.canva.com/mcp"),
        CustomMCPPreset(name: "Hugging Face", url: "https://huggingface.co/mcp"),
        CustomMCPPreset(name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp")
    ]
}

/// How a remote custom MCP server authenticates.
enum CustomMCPAuth: String, Codable {
    /// Static header values stored in Keychain (API keys, PATs). Default.
    case headers
    /// MCP authorization spec — browser sign-in with PKCE, tokens minted and
    /// refreshed by `CustomMCPOAuthService`, injected as a Bearer header per
    /// turn. Remote transports only.
    case oauth
}

/// One user-added MCP server (Settings → Integrations → Custom MCP Servers).
///
/// Non-secret fields live in UserDefaults via `CustomMCPServersStore`; env
/// values and header values — which routinely carry API tokens — live in
/// macOS Keychain as a single `CustomMCPServerSecrets` blob keyed by `id`.
/// Same split as `SupabaseProject` + its PAT.
struct CustomMCPServer: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String       // user-facing label, e.g. "GitHub"
    var slug: String       // MCP server key the agent sees, e.g. "github"
    var transport: CustomMCPTransport
    var enabled: Bool
    var createdAt: Date

    // stdio fields (empty for http/sse)
    var command: String    // e.g. "npx" or "/opt/homebrew/bin/uvx"
    var args: [String]     // e.g. ["-y", "@modelcontextprotocol/server-github"]

    // http/sse fields (empty for stdio)
    var url: String

    /// Optional so rows persisted before OAuth support decode cleanly;
    /// nil means `.headers`. Explicit nil defaults keep the memberwise init
    /// source-compatible with pre-OAuth call sites.
    var auth: CustomMCPAuth? = nil

    /// Pre-registered OAuth client ID. Empty/nil = register dynamically
    /// (RFC 7591) during sign-in. Only meaningful when `usesOAuth`.
    var oauthClientId: String? = nil

    var usesOAuth: Bool { auth == .oauth }

    /// Slug derivation matches `SupabaseProject.slugify`: lowercase, keep
    /// [a-z0-9_], fallback to `mcp_<id-prefix>` if empty. The slug is used as
    /// the MCP server key in all three backends, so it must satisfy the
    /// strictest charset (alphanumeric + underscore).
    static func slugify(_ name: String, fallbackId: UUID) -> String {
        let lower = name.lowercased()
        var out = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == "_" || ch == " " || ch == "-" {
                if !out.isEmpty && out.last != "_" { out.append("_") }
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty {
            return "mcp_" + fallbackId.uuidString.lowercased().prefix(8)
        }
        return out
    }

    /// Server keys Otto injects itself — a custom server must not shadow
    /// them. `supabase_` covers every user-registered Supabase project.
    static func isReservedSlug(_ slug: String) -> Bool {
        let reserved: Set<String> = ["otto", "drive", "calendar", "tally"]
        return reserved.contains(slug) || slug.hasPrefix("supabase_")
    }

    /// Short human-readable summary of what the server runs / connects to,
    /// shown in the Integrations list row.
    var endpointSummary: String {
        switch transport {
        case .stdio:
            return ([command] + args).joined(separator: " ")
        case .http, .sse:
            return url
        }
    }
}
