# Otto setup guide

Otto is a local-first macOS AI assistant. This guide walks you through everything
you need to know to set it up for your personal use — from the minimum-viable
install (just an agent backend) all the way through every optional integration
(Gmail, Calendar, voice mode, Todoist, Notion, Fireflies, X, LinkedIn, and your
own Supabase databases).

If you only do one thing: complete **Step 1 (pick an agent backend)** and the
app is usable. Everything else is optional and can be added later.

---

## Quick links

- [Where your data lives](#where-your-data-lives)
- [Prerequisites](#prerequisites)
- [Step 1: Pick an agent backend (required)](#step-1-pick-an-agent-backend-required)
- [Step 2: Optional integrations](#step-2-optional-integrations)
  - [Gmail & Google Calendar](#gmail--google-calendar)
  - [Google Drive](#google-drive)
  - [Voice mode (fal.ai)](#voice-mode-falai)
  - [GenMedia (fal.ai)](#genmedia-falai)
  - [Todoist](#todoist)
  - [Notion](#notion)
  - [Fireflies (meeting transcripts)](#fireflies-meeting-transcripts)
  - [X (Twitter)](#x-twitter)
  - [LinkedIn](#linkedin)
  - [Custom Supabase project access](#custom-supabase-project-access)
- [Step 3: Things to try once it's running](#step-3-things-to-try-once-its-running)
- [Troubleshooting](#troubleshooting)
- [Privacy & security model](#privacy--security-model)

---

## Where your data lives

Before you paste any credentials, know where they go.

| Data | Where it lives | Who can read it |
|---|---|---|
| Your chat history, todos, notes, ideas, reminders, bookmarks, habits, meetings, emails, calendar events, files metadata, X data | `~/Library/Application Support/Otto/otto_data.json` (a single JSON file on disk) | Only the Otto app + you |
| Imported file binaries (PDFs, CSVs, images, etc.) | `~/Documents/OttoFiles/` | Only the Otto app + you |
| Agent (Claude / Codex) credentials | Owned by the CLI — `Claude Code-credentials` Keychain entry or `~/.codex/auth.json`. Otto invokes the CLI as a subprocess and never reads or writes those entries; it only checks whether they exist to show a sign-in badge. You manage them via `claude` or `codex login`. | macOS Keychain / file (signed in user) |
| Anthropic / OpenAI API keys (optional, set in Settings) | macOS Keychain under `com.otto.anthropic.apikey` and `com.otto.openai.apikey`. Passed to the CLI subprocess as `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` when set. | macOS Keychain (signed in user) |
| API keys for fal.ai, Fireflies, Todoist, Notion | `UserDefaults` for the per-app preferences scope (which lives at `~/Library/Preferences/com.example.Otto.plist`). Not synced to iCloud. | macOS Keychain-like protection on this user account |
| Google OAuth Client ID + access/refresh tokens | UserDefaults (client id, non-secret) + macOS Keychain (tokens) | macOS Keychain (signed in user) |
| X (Twitter) Client ID + OAuth tokens | macOS Keychain under `com.otto.x.*` | macOS Keychain (signed in user) |
| Supabase Personal Access Tokens | macOS Keychain under `com.otto.supabase` — one entry per registered project | macOS Keychain (signed in user) |

**No credential is ever sent to any server other than the official endpoint it's
intended for** (anthropic.com, openai.com, googleapis.com, fal.run,
fireflies.ai, todoist.com, notion.com, x.com, mcp.supabase.com). Otto itself
has no backend — no telemetry, no analytics, no phone-home.

---

## Prerequisites

- **macOS 15.4 (Sequoia) or newer** — Otto uses some 15.x SwiftUI APIs.
- **Xcode 16+** — only if you're building from source. If you just want to
  run Otto, grab the prebuilt `Otto.app.zip` from the
  [Releases page](https://github.com/umutgunbak01/Otto/releases/latest)
  (see the Download section in the [README](README.md) for the Gatekeeper
  bypass on first launch).
- **An Apple Developer ID** to sign the build — only needed when building
  from source. The repo ships with `DEVELOPMENT_TEAM = ""` and bundle id
  `com.example.Otto`. You'll change these in Xcode's Signing & Capabilities
  tab before your first build.
- **`/usr/bin/nc` (BSD netcat)** — ships with macOS by default. Otto uses it
  internally to bridge its in-process MCP server to the agent CLI subprocess
  so Claude/Codex can call Otto's tools (create todo, search notes, etc.).
  You shouldn't have to do anything here unless someone removed it.
- **One of the two agent backends below** — required for the chat feature.

### Building from source

1. Clone the repo.
2. Open `Otto.xcodeproj` in Xcode.
3. Select the **Otto** target → **Signing & Capabilities** tab.
4. Set **Development Team** to your own Apple Developer team.
5. Optionally change the bundle identifier from `com.example.Otto` to something
   unique to you (if you want to distribute the build outside your machine).
6. Hit ⌘R to build and run.

The first launch will be quiet — no integrations connected, no data — and the
chat will show a banner pointing you at Settings → Agent.

---

## Step 1: Pick an agent backend (required)

Otto's chat is powered by either **Claude Code** (Anthropic) or **Codex**
(OpenAI). The two are functionally interchangeable — same tool surface, same
chat UX, same voice mode — but they cost different things, run different
models, and have different latency profiles. Pick whichever you're already
paying for (or both, and switch in Settings).

For each backend, Otto supports two auth paths:

- **CLI login** — you sign in with `claude` or `codex login` and the CLI
  stores its own credentials. Otto invokes the CLI as a subprocess; the CLI
  uses its own credentials and handles its own token rotation. Otto never
  reads, writes, or refreshes those credentials. Usage is billed against
  your Claude / ChatGPT subscription (Pro / Max / Plus / Business).
- **API key** — you paste an Anthropic or OpenAI API key into Otto's
  Settings. Otto stores it in macOS Keychain (`com.otto.anthropic.apikey`
  / `com.otto.openai.apikey`) and passes it to the CLI subprocess as
  `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`. The CLI uses the env-var key
  instead of its stored OAuth credentials. Usage is billed against your
  API account at console.anthropic.com / platform.openai.com, not your
  subscription.

When both are set for a given backend, the API key wins.

### Option A — Claude Code (default)

Recommended if you have a Claude Max or Pro subscription, or you've added
credits at console.anthropic.com.

1. **Install the CLI:**
   ```sh
   npm install -g @anthropic-ai/claude-code
   ```
2. **Sign in:**
   ```sh
   claude
   ```
   This opens a browser tab for OAuth. After signing in, the CLI stores the
   credentials in macOS Keychain (service: `Claude Code-credentials`).
   Otto never touches that entry — it only checks that it exists.
3. **Launch Otto.** Chat should work immediately. The chat-empty-state banner
   ("No agent backend signed in") should disappear.

To verify Otto sees the sign-in: open **Settings → Agent → Claude Code**.
You should see "Connected via Claude Code CLI."

**Token refresh:** the `claude` CLI rotates its own tokens automatically
each time Otto invokes it. If chat fails with an auth error, re-run
`claude` in Terminal to force a re-login.

**Model picker:** the default is `claude-opus-4-6`. Settings has a dropdown
with the current preset list (Opus, Sonnet, Haiku variants) and accepts any
custom model id you type. Append `[1m]` to opt into Anthropic's 1M-token
context window (e.g. `claude-opus-4-7[1m]`).

### Option B — Codex

Recommended if you have a ChatGPT Plus/Pro subscription that includes Codex.

1. **Install:** the easiest path is the **Codex desktop app** from
   <https://openai.com/codex>. It ships a CLI inside its bundle at
   `/Applications/Codex.app/Contents/Resources/codex`. Alternatives:
   ```sh
   brew install codex                # Homebrew
   npm install -g codex-cli          # npm
   ```
2. **Sign in:** in Terminal:
   ```sh
   codex login
   ```
   Credentials go to `~/.codex/auth.json` (mode 0600). Otto only checks
   that the file exists — it never reads its contents.
3. **Switch Otto to Codex:** Settings → Agent → toggle the segmented picker
   from "Claude Code" to "Codex".

Otto looks for the binary in this order: `/Applications/Codex.app/Contents/Resources/codex`,
`/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `/usr/bin/codex`. First
match wins.

**Model picker:** default is `gpt-5.5`. Settings lists `gpt-5`, `gpt-5-codex`,
`o3`, `o4` as presets and accepts any custom Codex model id.

**Token refresh:** the `codex` CLI rotates its own tokens automatically
each time Otto invokes it. If chat fails with an auth error, re-run
`codex login` in Terminal to force a re-login.

### Option C — Paste an API key (either backend)

If you'd rather pay by API usage than route through a subscription, or
you want a hard guarantee that Otto isn't touching your CLI's stored
credentials at all:

1. Get an API key:
   - Anthropic: <https://console.anthropic.com/> → API Keys → Create Key
     (`sk-ant-…`).
   - OpenAI: <https://platform.openai.com/api-keys> → Create new secret key
     (`sk-…`).
2. Open Otto → **Settings → Agent**, pick the right backend, and paste the
   key into the "API key (optional)" field. Click **Save key**.
3. Settings will show "Using stored Anthropic API key" /
   "Using stored OpenAI API key" instead of the CLI-login status.

The CLI still has to be installed locally (Otto needs the binary to
subprocess into) but it does **not** need to be signed in. To revert to
CLI auth, click **Clear stored key** in Settings.

You can switch backends mid-session — flip the picker, the next chat message
routes through the new CLI. Voice mode follows the same setting.

---

## Step 2: Optional integrations

Everything below is optional. You can use Otto as a local todo/notes/habits
app without any of them.

The general pattern: open **Integrations** (sidebar → LINKS button, or via
the bottom of the sidebar in the sys block), click the row for the integration
you want, and follow the connect button. Some integrations also need keys
pasted into **Settings** first — those are called out below.

### Gmail & Google Calendar

**What this unlocks:** the agent can search your email, summarize unread,
draft replies; calendar events show up in the HUD, the sidebar's "Next Event"
panel, and are queryable by the chat ("what's on my schedule tomorrow").

You need your **own Google Cloud OAuth client** — Otto can't ship a shared
one because Google requires per-app OAuth registration. The free tier covers
this easily.

#### Step-by-step: create a Google OAuth Client ID

1. Go to <https://console.cloud.google.com/>. Sign in with the Google
   account whose Gmail/Calendar you want Otto to access.

2. **Create or pick a project.** Top bar → project picker → "New Project".
   Name it anything (e.g. "Otto"). Hit Create.

3. **Enable the APIs:**
   - In the search bar, type "Gmail API" → click it → **Enable**.
   - Repeat for "Google Calendar API".

4. **Configure the OAuth consent screen** (only required once per project):
   - Left sidebar → **APIs & Services** → **OAuth consent screen**.
   - User type: **External** (unless you have a Google Workspace, then
     Internal is simpler). Click Create.
   - Fill in:
     - App name: "Otto" (or whatever — only you see it)
     - User support email: your email
     - Developer contact: your email
   - **Scopes** screen: click "Add or Remove Scopes". Add:
     - `https://www.googleapis.com/auth/gmail.readonly`
     - `https://www.googleapis.com/auth/calendar.readonly`
   - **Test users** screen: add your own Google email as a test user. As
     long as the app is in "Testing" mode, only test users can sign in —
     this is fine for personal use.
   - Save and continue through the rest.

5. **Create the OAuth Client ID:**
   - Left sidebar → **APIs & Services** → **Credentials**.
   - Click **+ Create Credentials** → **OAuth client ID**.
   - **Application type: Desktop app** (this is important — picking "Web
     application" won't work).
   - Name: "Otto Desktop" (any name).
   - Click Create.
   - A dialog shows your **Client ID**. It looks like
     `1234567890-abc….apps.googleusercontent.com`. Copy it.

6. **Paste into Otto:**
   - In Otto, open **Integrations** → click **Connect** on **Gmail**
     (or **Google Calendar** — they share the same OAuth client).
   - A sheet opens asking for the Google OAuth Client ID. Paste it. Hit
     Save & Connect.
   - An ephemeral Safari window opens for the OAuth grant. Sign in with the
     same Google account, approve the readonly scopes. Safari closes.
   - You should see "Connected" in the row. Calendar uses the same token
     automatically.

**If you get an error like "Access blocked: Otto's request is invalid":**
your OAuth consent screen is still missing scopes, or you didn't add yourself
as a test user. Step 4 above fixes both.

### Google Drive

**What this unlocks:** the agent can search, list, read, and create files
in your Google Drive via [Google's official Drive MCP server][drive-mcp]
at `https://drivemcp.googleapis.com/mcp/v1`. Ask the chat "find my Q3 OKRs
doc and summarise it" — it'll call `drive__search_files` and
`drive__read_file_content` end-to-end without you copying anything in.

[drive-mcp]: https://developers.google.com/workspace/drive/api/guides/configure-mcp-server

This shares the OAuth client you already set up for Gmail / Calendar.
You only need a small one-time Google Cloud add-on:

1. Go back to your Google Cloud project (the one from the Gmail / Calendar
   step above).
2. **APIs & Services → Library** — search for and **enable** *both*:
   - `Google Drive API` (`drive.googleapis.com`)
   - `Google Drive MCP API` (`drivemcp.googleapis.com`)
3. **APIs & Services → OAuth consent screen → Edit** — under Scopes, add:
   - `https://www.googleapis.com/auth/drive.readonly`
   - `https://www.googleapis.com/auth/drive.file`
4. In Otto: **Integrations** → click **Connect** on **Google Drive**.
   An ephemeral Safari window opens with a fresh consent screen that now
   lists the two Drive scopes alongside the Gmail / Calendar ones. Approve.
5. The card flips to "Connected — Drive scopes granted." From this point
   on, every chat turn injects the Drive MCP server into the agent's tool
   list (`drive__search_files`, `drive__read_file_content`, etc.).

**Where Drive content lives:** never in `otto_data.json`. The agent fetches
contents on-demand through the MCP server; they stay in chat-turn context
only. Disconnect at any time via Integrations → Google Drive → Disconnect
Drive — Gmail and Calendar keep working unaffected.

### Voice mode (fal.ai)

**What this unlocks:** push-to-talk (hold the mic button) and wake-word ("Hey
Otto") to chat with Otto by voice. Wizper handles speech-to-text, ElevenLabs
v3 handles text-to-speech, both routed through fal.ai's API.

1. Sign up at <https://fal.ai/>.
2. Dashboard → **API Keys** → **+ Create new key**. Give it a name.
3. Copy the key (starts with `fal_…`).
4. In Otto: **Settings** → **Voice Mode (fal.ai)** → paste the key.
5. Pick a voice from the dropdown below (Adam, Charlotte, etc.).

Costs: roughly a few cents per minute of conversation depending on model.

### GenMedia (fal.ai)

**What this unlocks:** the agent can generate images, video, audio, music, and
speech via fal.ai's full model catalog. Ask the chat to "generate a logo for
Nimbus" or "make a 5-second clip of waves at sunset" and the result lands as a
file in Otto's Files tab, with a clickable preview attached to the reply.

Otto reuses the same fal API key as voice mode, so if you already did the
Voice mode step above you only need to install the `genmedia` CLI on top.

1. **Set your fal API key first** (see Voice mode above).
2. **Install the CLI** — open Terminal and paste:
   ```sh
   curl https://genmedia.sh/install -fsS | bash
   ```
   The script writes the binary to `~/.genmedia/bin/genmedia` and updates
   your shell rc so subsequent terminal sessions can call it directly.
3. **Verify in Otto** — open **Integrations** → **GenMedia (fal.ai)** →
   click **Setup** → **Verify**. The status row should flip to "genmedia
   CLI installed" with the binary path. Hit **Test connection** to confirm
   the key + binary can reach fal.

Once both are green, ask the chat to generate something. Otto picks an
appropriate fal model, fills in the inputs, runs the generation
synchronously, and imports the output into your Files tab with the prompt
saved in the file's notes.

Costs: fal bills your account directly. Image generations are typically a
few cents each; video is more. Check pricing for a given model at
<https://fal.ai/models> before kicking off heavy jobs.

### Todoist

**What this unlocks:** two-way sync with your Todoist account. Tasks you
create in Otto appear in Todoist (with priority, due date, labels) and
vice-versa. Completion / deletion / edits propagate both ways.

1. Open <https://app.todoist.com/app/settings/integrations/developer>.
2. Copy your **API token**.
3. In Otto: **Integrations** → click **Connect** on **Todoist** → paste the
   token. Hit Save.

After the first sync, every new todo you create in Otto's UI or via the chat
agent will also be created in Todoist's Inbox. Same for completions and
deletes. If you don't want this, leave Todoist disconnected — Otto's todos
work fine purely local.

### Notion

**What this unlocks:** sync Notion pages into Otto as notes. The agent can
search them like any other notes via `search_items`.

1. Create an internal integration at
   <https://www.notion.so/profile/integrations> (button: "+ New integration").
2. Internal vs Public: pick **Internal** — easier and fine for personal use.
3. After creation, copy the **Internal Integration Token** (starts with
   `secret_…` or `ntn_…`).
4. In Otto: **Integrations** → click **Connect** on **Notion** → paste the
   token.
5. **Important:** Notion integrations only see pages you explicitly share
   with them. In Notion, for each page/database you want Otto to see, click
   the `…` menu (top right) → **Connect to** → pick your Otto integration.
   Children of shared pages are included automatically.

### Fireflies (meeting transcripts)

**What this unlocks:** auto-import meeting transcripts from your Fireflies
account into Otto's Meetings tab. The agent can search them, summarize,
extract action items.

1. Get your API key from
   <https://app.fireflies.ai/integrations/api>. Click "Generate API key".
2. In Otto: **Integrations** → click **Connect** on **Fireflies**.
3. Paste the API key.
4. Fill in **Your email** — this is the email Fireflies has on file for you.
   Otto uses it to filter for meetings where you were actually an attendee
   (vs. meetings on your workspace that were recorded by other people).
5. (Optional) Toggle **Daily auto-sync** to have Otto pull new meetings
   every 24 hours automatically.

### X (Twitter)

**What this unlocks:** import your tweets, DMs, followers, and bookmarks for
the agent to query.

You need your own X Developer app — X requires per-app registration just
like Google.

**Heads-up on cost:** as of 2026, X removed all free read access. Connecting
the OAuth flow is free, but actually pulling any data requires either
pay-per-use billing (the new default — ~$0.001 per bookmark, ~$0.005 per
post read) or a legacy paid tier (Basic at $200/mo, Pro at $5,000/mo for
DM access). Otto will connect successfully on a free-only developer app,
but every sync will return tier errors. Enable pay-per-use at
<https://developer.x.com/en/account/billing> if you actually want to
pull data.

1. Apply for a free developer account at <https://developer.x.com/>.
2. Once approved, create a **Project + App**.
3. App Settings → **User authentication settings** → set up OAuth 2.0:
   - Type of App: **Native App**
   - **Callback URI / Redirect URL**: `otto://x-callback`
     (Otto registers the `otto://` URL scheme in `Info.plist`.)
   - Website URL: anything (e.g. your GitHub profile).
4. Save. X gives you a **Client ID** (different from API key).
5. In Otto: **Integrations** → click **Connect** on **X (Twitter)** →
   paste the Client ID. The OAuth flow opens Safari for authorization.

### LinkedIn

**What this unlocks:** import your connections list to make people queryable
("who do I know at Stripe?", "what's Sarah's email?").

LinkedIn doesn't expose a stable consumer API, so the import is CSV-based.
No keys needed.

1. Go to <https://www.linkedin.com/mypreferences/d/download-my-data>.
2. Request the **Connections** archive. LinkedIn emails you a link when
   it's ready (usually a few minutes).
3. Download the ZIP, extract the `Connections.csv` file.
4. In Otto: **Integrations** → **LinkedIn** → click **Import CSV** and pick
   the file.

### Custom Supabase project access

**What this unlocks:** the agent gets full read/write SQL access to any
Supabase project(s) you own — for CRMs, app databases, log stores, analytics,
whatever you've built. It uses Supabase's **official MCP server**, so the
agent gets a comprehensive tool set (list_tables, execute_sql, apply_migration,
get_logs, deploy_edge_function, generate_typescript_types, and more) without
any per-schema Swift code on Otto's side.

You can register **multiple projects** — each becomes an independent MCP
server in the agent's tool list, namespaced by slug (e.g.
`supabase_crm__list_tables`, `supabase_logs__execute_sql`).

#### Step-by-step

1. **Create a Personal Access Token (PAT):**
   - Go to <https://supabase.com/dashboard/account/tokens>
   - Click **Generate new token**
   - Give it a descriptive name like "Otto on my Mac"
   - **Copy the token immediately** — Supabase only shows it once.
2. **Find your project_ref:**
   - Open the project in the Supabase dashboard.
   - Your project's URL is `https://<ref>.supabase.co` — the `<ref>` part
     is the project_ref (a 20-character alphanumeric string).
   - Or: Project Settings → API → the **Reference ID** field is the same value.
3. **Register in Otto:**
   - **Integrations** → expand **Custom Database** → click **Add your
     first Supabase project**.
   - Fill in:
     - **Name** — any label you want (e.g. "CRM", "Production DB"). Used as
       the MCP server slug, so prefer short alphanumeric.
     - **project_ref** — paste the 20-char ref. Otto validates it's
       lowercase alphanumeric + `-`/`_` only (1–64 chars).
     - **PAT** — paste the token from step 1.
     - **Schema notes (optional)** — a sentence or two describing your tables
       (e.g. "users, accounts, deals, deal_history — soft-delete pattern with
       `deleted_at`"). Otto includes this in the agent's system prompt so it
       knows the schema on turn 1 without burning tokens on `list_tables`.
   - Save.
4. **Repeat per project.** Each gets its own MCP server slug.

The PAT lives in macOS Keychain (service `com.otto.supabase`). It only
leaves your machine when the agent CLI talks to `mcp.supabase.com` —
authenticated by a `Authorization: Bearer <PAT>` header.

**Security notes:**

- PATs grant the same access your Supabase account has — broad. If you want
  to scope tighter, set up Row-Level Security on your tables and use the
  anon key approach via your own custom MCP wrapper. PAT is the simplest
  path and what Supabase's docs recommend.
- Otto validates the project_ref charset to prevent URL-injection attacks
  (e.g. pasting `validref&redirect=evil.com` won't work).
- The MCP config file containing the PAT header is written to a 0600-mode
  temp file inside each chat-turn's working directory, then passed to the
  agent CLI by **file path** — so the PAT never appears in `ps auxww` output.

**Example questions to ask once connected:**

- "What tables are in my CRM project?"
- "How many users signed up last week? Run the SQL against my Production DB."
- "Compare the deals table schema between CRM and Staging."
- "Apply this migration to add a `priority` column to the todos table."

---

## Step 3: Things to try once it's running

A few prompts that exercise different features:

- **Plain chat:** "What's my schedule tomorrow?" (uses calendar events)
- **Tool calling:** "Add a todo to renew my passport by August."
- **Search:** "What did we discuss in the last Fireflies meeting with Alice?"
- **Files:** drop a PDF into the Files tab, then ask "summarize the PDF I
  just uploaded".
- **Supabase:** "What tables are in my CRM database?" (after registering a
  Supabase project)
- **Voice mode:** click the mic button (or say the wake word if enabled),
  speak naturally. Otto replies aloud.
- **Cross-source synthesis:** "Who did I talk to about pricing this month?"
  — the agent searches emails + meetings + notes + connections in one pass.

---

## Troubleshooting

**Chat is empty / banner says "No agent backend signed in"**
- Did you run `claude` (or `codex login`) in Terminal first? Open Settings
  → Agent → check both tabs for the "Connected" badge. Alternatively, paste
  an Anthropic / OpenAI API key into the "API key (optional)" field.

**Chat returns 401 / auth errors**
- Re-run `claude` (or `codex login`) in Terminal to refresh the CLI's
  stored credentials, or paste a fresh API key into Settings → Agent.
  Otto doesn't refresh tokens itself — that's the CLI's job.

**"Your Anthropic / OpenAI API key was rejected"**
- The pasted key is invalid, revoked, or for the wrong product. Verify it
  at console.anthropic.com / platform.openai.com, then paste a working key
  into Settings → Agent. Clearing the stored key falls back to CLI login.

**Gmail/Calendar "Access blocked: this app's request is invalid"**
- Your Google Cloud OAuth consent screen needs the right scopes and your
  account as a test user. Re-do Step 4 of the Gmail walkthrough above.

**Todoist Connect says "The data couldn't be read because it isn't in the
correct format"**
- This was a bug fixed earlier — make sure your build is current. If you
  still hit it, please file an issue with the response body Todoist returned
  (you can find it in `log stream --predicate 'process == "Otto"'`).

**Supabase project Save errors**
- "project_ref must be lowercase letters, digits, hyphens, or underscores
  only (1–64 chars)" — copy ONLY the 20-char reference, not the full URL.
- "Not signed in to Supabase" via the agent — the PAT was deleted from
  Keychain or never saved. Re-add the project.

**The agent doesn't seem to see my X / Notion / Todoist data**
- Each integration syncs on demand. After connecting, give it a few seconds
  to do the first pull, or open the relevant tab in the sidebar and hit the
  refresh icon if there is one.

**HUD widget disappeared and I can't get it back**
- The HUD is dismissed via the hover × button (top-right of the widget).
  To re-open it: quit Otto (⌘Q) and relaunch. A future version will likely
  add a menu-bar item to re-open without relaunching.

**Voice mode doesn't transcribe my speech**
- Check fal.ai key in Settings. Also check microphone permissions in System
  Settings → Privacy & Security → Microphone → Otto should be enabled.

---

## Privacy & security model

- **No telemetry, no analytics, no phone-home.** Otto has no backend.
- **All your content (todos, notes, etc.) stays in `otto_data.json`** on
  your Mac unless you sync it to an external service via an integration.
- **API keys + OAuth tokens live in macOS Keychain** (or per-app UserDefaults
  for non-secret config). Nothing is committed to disk in plaintext outside
  the app sandbox or Keychain.
- **Agent CLIs (Claude/Codex)** have their own auth in their own Keychain
  / `~/.codex/auth.json` entries; Otto invokes the CLI as a subprocess and
  never reads, writes, or refreshes those credentials. If you paste an
  Anthropic / OpenAI API key into Otto's Settings, it's stored in macOS
  Keychain under `com.otto.anthropic.apikey` / `com.otto.openai.apikey`
  and passed to the CLI subprocess via `ANTHROPIC_API_KEY` /
  `OPENAI_API_KEY` so the CLI bypasses its stored OAuth credentials.
- **Imported file binaries** stay in `~/Documents/OttoFiles/`; they're
  never uploaded anywhere unless you ask the agent to (e.g. "post this PDF
  to Notion").
- **Custom Supabase access** — the PAT travels only to `mcp.supabase.com`
  via TLS. Supabase's MCP server is the gate; if you want to revoke access,
  delete the PAT at supabase.com/dashboard/account/tokens.
- **Source code:** open. You can audit everything that touches credentials
  by grepping `kSec` (Keychain), `UserDefaults`, `Authorization`, etc.
