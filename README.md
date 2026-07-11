# Otto

A local-first macOS AI assistant. SwiftUI app that keeps your todos, notes,
ideas, bookmarks, habits, meetings, emails, files, and your network of
people, companies, communities, and events in one place, with a chat
interface that can read and write across all of them — powered by
Claude Code, Codex, or Hermes (your choice in Settings).

All data lives on your machine in `~/Library/Application Support/Otto/otto_data.json`.
Nothing leaves your device unless you explicitly connect an integration.

## Features

- **Chat with Claude, Codex, or Hermes** over all your data — search, create, update,
  complete, delete across todos, notes, ideas, reminders, bookmarks, habits,
  meetings, emails, calendar events, people, companies, communities, and
  events. Redesigned chat surface with selectable message text and
  collapsible tool-call blocks.
- **Network Hub CRM** — track the people you meet: custom fields,
  configurable columns with inline table editing, and two-way links between
  people and companies
- **Companies, Communities & Events tabs** — with dedicated editors, all
  exposed to the chat agent's tools
- **Custom tabs** — define your own tables (reading list, job pipeline,
  wine cellar…) with typed fields and a choice of layouts: spreadsheet
  table, drag-and-drop kanban board, card gallery, or compact checklist;
  each tab automatically gets its own create/update tools in the chat
  agent's toolbox
- **Generative dashboards** — the agent can create whole tabs itself and
  compose live dashboard pages from blocks (stat tiles, charts, tables,
  markdown, progress bars, tickable checklists, timelines, plus an embedded
  view of the tab's own records), then keep them fresh over time — "make me
  a World Cup tab and update it daily" just works
- **Meeting transcription** — Otto notices when a meeting app (Zoom, Teams,
  Slack, Webex, FaceTime, browser calls…) starts using your microphone and
  offers to transcribe. It records both sides — your mic and the system
  audio of the other participants — transcribes locally-captured audio via
  fal.ai, then writes up the meeting and files the action items that are
  yours as todos.
- **Location map** — locations standardized to canonical cities across your
  network, companies, and events, plotted on a map with an inline-editable
  city table
- **Daily briefing** — an agent-written summary of your day (events, todos,
  follow-ups) in the Home right rail, regenerated once a day or on demand
- **Agent workspace snapshots** — each chat turn exports your tabs as
  grep-able CSV/JSONL files into the agent's per-turn sandbox, so bulk
  questions ("which funds am I connected to?") are a single `grep` instead
  of dozens of tool round trips
- **Block-based note editor** — slash-style blocks with drag handles,
  collapsible toggles, real clickable todo checkboxes, and smart list
  continuation
- **File import the agent can read** — drop in PDFs, CSVs, Excel sheets,
  images (PNG/JPG/HEIC, OCR'd at import via the Vision framework), and
  plain-text formats (txt/md/json/yaml/log). The chat agent can `search_items`
  + `read_file` to pull content into its context. CSVs open in an editable
  grid, and Excel sheets get an inline table preview.
- **Files the agent can create** — ask for a spreadsheet and the agent
  builds a real one: styled multi-sheet `.xlsx` (frozen filtered headers,
  banded rows), CSV, Markdown, or plain text, landing in your Files tab
  ready to open or share
- **Inline visualizations** — the agent can answer with live charts and
  tables rendered as cards right in the chat
- **Custom Supabase project access** — register one or more of your own
  Supabase projects with a Personal Access Token; the agent gets full
  read/write SQL access through Supabase's official MCP server (list_tables,
  execute_sql, apply_migration, deploy_edge_function, and more) — no
  per-schema Swift glue.
- **Custom MCP servers** — plug any MCP server into the agent from
  Integrations: local stdio commands or remote HTTP servers, with headers,
  env vars, and OAuth (dynamic client registration included) handled for
  you; secrets live in the macOS Keychain
- **Voice mode** — push-to-talk or wake-word, powered by fal.ai (Wizper for
  transcription, ElevenLabs Turbo v2.5 for speech), with voice turns
  mirrored into the chat history
- **Generative media (fal.ai genmedia)** — the agent can generate images,
  video, audio, music, and speech via fal's model catalog. Outputs land
  straight in your Files tab with the prompt saved on the file.
- **Integrations** — Gmail, Google Calendar, Google Calendar (live, via
  Google's official Calendar MCP server — agent can schedule, edit,
  suggest meeting times), Google Drive (read/search/create via Google's
  official Drive MCP server), Tally (manage forms + analyze submissions
  via Tally's official MCP server), Todoist (two-way sync), Notion,
  Fireflies, LinkedIn CSV import
- **Local persistence** — single JSON file you can back up, inspect, or move
- **Habits, ideas, bookmarks with link metadata, meeting transcripts**,
  PDF export, screen capture for context

## Requirements

- macOS 15.4 (Sequoia) or newer
- One of the agent backends installed: **Claude Code CLI**, **Codex CLI**, or
  **Hermes Agent** (Nous Research's open-source ACP-speaking agent) —
  signed in / configured per its own docs, **or** an Anthropic / OpenAI
  API key pasted into Settings (Claude / Codex paths). See
  [SETUP.md](SETUP.md) — Otto invokes each as a subprocess; the agent
  manages its own credentials and Otto never touches them.
- Xcode 16+ **only if building from source** (not needed for the prebuilt
  download below)

## Download (prebuilt)

Grab the latest `Otto.app.zip` from the
[Releases page](https://github.com/umutgunbak01/Otto/releases/latest):

1. Download `Otto.app.zip` and unzip it.
2. Drag `Otto.app` into `/Applications`.
3. Double-click to launch. Builds are Developer-ID-signed and notarized,
   so macOS opens them without the Gatekeeper warning.

After install, Otto checks for updates on launch (and once a day while
running) via [Sparkle](https://sparkle-project.org). New versions install
in-app — you won't need to redownload. To trigger a check manually:
right-click the Otto menu bar icon → **Check for Updates…**, or use
**Otto → Check for Updates…** in the menu bar.

Then jump to [SETUP.md](SETUP.md) to install Claude Code, Codex, or Hermes
and sign in.

## Build from source

1. Clone the repo
2. Open `Otto.xcodeproj` in Xcode
3. In the **Otto** target → **Signing & Capabilities**, set
   `Development Team` to your own Apple Developer team
4. (Optional) Change the bundle identifier from `com.umutgunbak.Otto` to your own
5. Build and run

To cut a new release:

1. In Xcode: **Product → Archive**.
2. In Organizer: **Distribute App → Developer ID**. Let Xcode upload to
   Apple, wait for the green "Ready to Distribute" / notarization-complete
   status, then **Export** to a folder. You'll have a stapled `Otto.app`
   on disk.
3. Run [`scripts/release.sh`](scripts/release.sh) with the version tag and
   the path to that exported app — it validates the notarization staple,
   zips with `ditto`, EdDSA-signs the zip for Sparkle, prepends a new
   `<item>` to `docs/appcast.xml`, publishes via `gh`, and pushes the
   updated feed:

   ```
   scripts/release.sh v1.0.1 ~/Desktop/Otto-1.0.1/Otto.app
   ```

One-time setup before the very first release: generate the Sparkle
update-signing keypair:

```
$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys | head -1)
```

and paste the printed public key into `Otto/Info.plist` under `SUPublicEDKey`.

The app will launch with no data and no integrations connected. **Read
[SETUP.md](SETUP.md) for the full walkthrough** — it covers the minimum
setup (just signing into Claude Code, Codex, or Hermes), plus step-by-step
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
