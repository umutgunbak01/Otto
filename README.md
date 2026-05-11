# Otto

A local-first macOS AI assistant. SwiftUI app that keeps your todos, notes,
ideas, bookmarks, habits, meetings, emails, and files in one place, with a
chat interface that can read and write across all of them — powered by
either Claude Code or Codex (your choice in Settings).

All data lives on your machine in `~/Library/Application Support/Otto/otto_data.json`.
Nothing leaves your device unless you explicitly connect an integration.

## Features

- **Chat with Claude or Codex** over all your data — search, create, update,
  complete, delete across todos, notes, ideas, reminders, bookmarks, habits,
  meetings, emails, and calendar events
- **File import the agent can read** — drop in PDFs, CSVs, Excel sheets,
  images (PNG/JPG/HEIC, OCR'd at import via the Vision framework), and
  plain-text formats (txt/md/json/yaml/log). The chat agent can `search_items`
  + `read_file` to pull content into its context.
- **Custom Supabase project access** — register one or more of your own
  Supabase projects with a Personal Access Token; the agent gets full
  read/write SQL access through Supabase's official MCP server (list_tables,
  execute_sql, apply_migration, deploy_edge_function, and more) — no
  per-schema Swift glue.
- **Voice mode** — push-to-talk or wake-word, powered by fal.ai (Wizper for
  transcription, ElevenLabs v3 for speech)
- **Integrations** — Gmail, Google Calendar, Todoist (two-way sync), Notion,
  Fireflies, LinkedIn CSV import
- **Local persistence** — single JSON file you can back up, inspect, or move
- **Habits, ideas, bookmarks with link metadata, meeting transcripts**,
  PDF export, screen capture for context

## Requirements

- macOS 15.4 (Sequoia) or newer
- Xcode 16 or newer
- Either the **Claude Code CLI** or the **Codex CLI** installed and signed in
  (see [SETUP.md](SETUP.md) — Otto reads tokens directly from whichever CLI
  is configured; you don't paste keys into Otto itself)

## Build

1. Clone the repo
2. Open `Otto.xcodeproj` in Xcode
3. In the **Otto** target → **Signing & Capabilities**, set
   `Development Team` to your own Apple Developer team
4. (Optional) Change the bundle identifier from `com.example.Otto` to your own
5. Build and run

The app will launch with no data and no integrations connected. **Read
[SETUP.md](SETUP.md) for the full walkthrough** — it covers the minimum
setup (just signing into Claude Code or Codex), plus step-by-step
instructions for every optional integration (creating your own Google Cloud
OAuth client, getting a Supabase Personal Access Token, etc.) and where
your data and credentials live on disk.

## Project layout

- `Otto/` — the macOS app source
  - `Models/` — Codable data types
  - `Services/` — API clients, persistence, Claude tools, voice
  - `State/` — observable app state
  - `Views/` — SwiftUI views
  - `Utilities/` — helpers
- `Otto.xcodeproj` — Xcode project
- `OttoTests/`, `OttoUITests/` — test targets

## License

MIT — see [LICENSE](LICENSE).
