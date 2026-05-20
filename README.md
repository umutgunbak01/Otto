# Otto

A local-first macOS AI assistant. SwiftUI app that keeps your todos, notes,
ideas, bookmarks, habits, meetings, emails, and files in one place, with a
chat interface that can read and write across all of them — powered by
Claude Code, Codex, or Hermes (your choice in Settings).

All data lives on your machine in `~/Library/Application Support/Otto/otto_data.json`.
Nothing leaves your device unless you explicitly connect an integration.

## Features

- **Chat with Claude, Codex, or Hermes** over all your data — search, create, update,
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
