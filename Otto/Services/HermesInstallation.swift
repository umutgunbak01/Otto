import Foundation

/// Locates the local `hermes` binary that Otto will spawn for the Hermes
/// backend. Otto does *not* install Hermes itself — same posture as the
/// Claude / Codex CLIs. If `binaryPath()` returns nil, Settings surfaces
/// install instructions to the user.
///
/// Probed in order; first hit wins. `~/.local/bin` is included because
/// that's where `uv tool install` (Hermes's recommended install path)
/// puts binaries.
enum HermesInstallation {

    /// Common install locations, probed in order.
    private static var candidatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/hermes",   // uv tool install
            "/opt/homebrew/bin/hermes",    // Apple Silicon Homebrew
            "/usr/local/bin/hermes",       // Intel Homebrew / generic /usr/local
            "/usr/bin/hermes"
        ]
    }

    /// Returns the first executable `hermes` binary found, or nil if none.
    /// Result isn't cached — install state can change at runtime (user
    /// installs Hermes, clicks Refresh in Settings, etc.) and a cold
    /// probe across four paths is essentially free.
    static func binaryPath() -> String? {
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    static func isInstalled() -> Bool {
        return binaryPath() != nil
    }
}
