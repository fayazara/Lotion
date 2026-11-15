# Lotion

A quiet, native notes app for the Mac. The name is a play on *local Notion*:
every note is a plain Markdown file in a folder you own, styled as you type.

https://github.com/user-attachments/assets/1491deae-30f4-4640-a196-278edd8c6d8e

## Features

- **Just files.** Notes are `.md` files, folders are folders. Covers, icons and
  link previews live in a small hidden `.lotion` folder beside your notes —
  delete it and you lose nothing you wrote.
- **A block editor for Markdown.** Headings, lists, checklists, quotes, tables
  and code, with syntax highlighting for 200+ languages.
- **Diagrams, drawn natively.** Mermaid flowcharts, sequence, state, class and ER
  diagrams and XY charts render in the note’s colors, with
  [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift).
- **Rich embeds.** Links become cards; YouTube, Spotify, Figma, posts, maps,
  PDFs, audio and files embed inline.
- **Covers and icons** for notes, with Unsplash search.
- **Tasks in your notes.** Any checklist line is a task. Give it a date and it
  shows up in **Today**, **Upcoming** and a live `[tasks]` list, without ever
  leaving the note it was written in. See [Tasks](#tasks).
- **Quick Add** from any app (⌃⌥T): “Call mum tomorrow 6pm #home p1” becomes a
  task in your Inbox.
- **A scratchpad** for half-formed thoughts, at the top of the sidebar.
- **Themes** — Lotion's own, plus dozens made from popular VS Code themes.
- **Publish to the web** on your own Cloudflare account, with
  [Lotion Share](https://github.com/fayazara/lotion-share). Copy the setup
  prompt from Settings → Cloud into your coding agent, and it deploys a worker
  with D1 and R2 for you.

No accounts, no sync service, no database. To sync, put your notes folder in
iCloud Drive, Dropbox or a git repo.

## Tasks

A task is a checklist line in any note. A little plain text after its words
says when it's due and how important it is, so the file still reads well in
any Markdown app:

```markdown
- [ ] Send Sam the revised mockups #design !1 @2026-11-16 10:00 ~45m
- [ ] Water the plants @2026-11-15 @every week
```

| Write | Means |
| --- | --- |
| `@tomorrow`, `@fri 3pm`, `@next week`, `@nov 20` | Due then. Turned into a date (`@2026-11-16`) as you type, so the file reads the same next week. |
| `@every week`, `@every monday`, `@every 2 months` | Repeats. Checking it off writes the next one above it. |
| `!1` `!2` `!3` | Priority, 1 highest. |
| `#tag` | A tag to filter by. |
| `~45m`, `~1h30m` | How long it takes. |

Lotion also reads [Obsidian Tasks](https://publish.obsidian.md/tasks/) emoji
(`📅 2026-11-16`, `🔁 every week`, `⏫`), so a vault shared with Obsidian keeps
its dates.

- **Today** (⌘1) lists what's overdue and due today.
- **Upcoming** (⌘2) shows the next two weeks by day. Drag a task onto a day to
  move it.
- **Inbox** (⌘3) is a note called “Inbox”. Quick Add writes there unless you
  pick another note.
- **`[tasks …]`** on a line of its own (or `/Task List`) shows a live list in
  any note: `[tasks #work due:week]`, `[tasks here]`, `[tasks folder:Home !1]`.

Nothing is stored apart from the Markdown: rescheduling or checking off a task
from any list edits its line in its note.

## Publishing to the web

Lotion doesn't run any servers. To publish notes, you deploy
[Lotion Share](https://github.com/fayazara/lotion-share), an open-source
Cloudflare Worker, to your own Cloudflare account. It fits within the free plan.

1. Open **Settings → Cloud** and click **Copy Setup Prompt**.
2. Paste the prompt into a coding agent (Claude Code, Codex, OpenCode, …). It
   forks or clones the template, then deploys it with a D1 database and an R2
   bucket.
3. Paste the Worker URL and token it gives you into Settings → Cloud, and
   click **Verify Connection**. The token is kept in your Keychain.

Then use the **Share** button in a note's toolbar to publish it. The page uses
the note's theme colors, cover and icon, and its images and files are uploaded
with it. You can update the page, copy or share its link, or unpublish it from
the same popover. Settings → Cloud lists everything you've published.

To update the worker, run the same prompt again. Verify Connection tells you
when there's a newer version.

## AI agents (MCP)

Lotion has a built-in MCP server, so coding agents like Claude Code and Codex
can work with your notes: read, search, create, edit, move and delete them,
organize folders, pin notes, set icons and covers, add attachments, write to
the scratchpad, change settings, and publish or unpublish notes when Lotion
Share is connected. It can also list, add, reschedule and check off tasks
(`list_tasks`, `add_task`, `update_task`). Changes show up in the Lotion
window as they happen.

Open **Settings → AI Agents** and copy the command for your agent, for example:

```bash
claude mcp add --scope user lotion -- '/Applications/Lotion.app/Contents/MacOS/Lotion' --mcp
```

The agent runs Lotion's own binary with `--mcp`. It relays to the running app
over a Unix socket in Lotion's sandbox container, and opens Lotion in the
background if it isn't running. Turn off **Allow AI agents** to stop the
server.

## Install

Download `Lotion.dmg` from the
[latest release](https://github.com/fayazara/Lotion/releases/latest), or with
Homebrew:

```bash
brew install --cask fayazara/tap/lotion
```

Lotion updates itself through [Sparkle](https://sparkle-project.org). Use
**Lotion → Check for Updates…**, or turn automatic checks on or off in
**Settings → Updates**.

## Building

Lotion runs on macOS 26 or later. Building it requires Xcode 27.

1. Clone [shiki-swift](https://github.com/fayazara/shiki-swift) next to this
   repo — the project uses it as a local package at `../shiki-swift`:

   ```bash
   git clone https://github.com/fayazara/Lotion.git
   git clone https://github.com/fayazara/shiki-swift.git
   ```

2. Open `Lotion.xcodeproj` and run the **Lotion** scheme.

### Unsplash covers (optional)

Cover search needs an Unsplash Access Key. Either enter your own in the app
when asked, or bundle one by creating `Lotion/Secrets.plist` (git-ignored):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>UnsplashAccessKey</key>
    <string>your-access-key</string>
</dict>
</plist>
```

### Icons

The app's icons are [Hugeicons](https://hugeicons.com) (free Stroke Rounded set,
MIT licensed, © Hugeicons), compiled into custom SF Symbols in
`Lotion/Assets.xcassets/Hugeicons`. Code names icons by their SF Symbol name;
`Scripts/hugeicons.tsv` says which Hugeicon draws each one, and any name not
listed falls back to the SF Symbol. The icon picker also searches the whole
free set by name, from `Lotion/Design/Hugeicons.txt`; icons picked there are
saved as `hugeicon:<name>`. To add or swap an icon, edit the table and
regenerate:

```bash
npm pack @hugeicons/core-free-icons && tar xzf hugeicons-core-free-icons-*.tgz
swift Scripts/hugeicons.swift package/dist/esm Scripts/hugeicons.tsv Lotion/Assets.xcassets/Hugeicons Lotion/Design/Hugeicons.swift Lotion/Design/Hugeicons.txt
```

Brand logos in the picker come from the icon variants (`*-icon.svg`) of
[gilbarbara/logos](https://github.com/gilbarbara/logos) (CC0; the marks remain
their owners' trademarks), made one-colour and sized to match the icons, into `Lotion/Design/Brands.txt` and
saved as `brand:<name>`. To refresh them:

```bash
git clone --depth 1 https://github.com/gilbarbara/logos.git
swift Scripts/brands.swift logos Lotion/Design/Brands.txt
```

### Demo library

The **Lotion Demo** scheme opens a separate library filled with sample notes,
handy for screenshots. Enable `-LotionDemoReset YES` in the scheme's arguments
to write it fresh.

### Self-tests

Debug builds run scripted checks when launched with `-LotionSelfTest YES`,
usually with `-LotionLibrary <scratch folder>`. Add `-LotionSelfTestOnly cloud`
to test publishing end to end against a worker, passing `-cloudURL <worker URL>`
and `-LotionCloudToken <token>`. A local worker works too: run `pnpm dev` in
lotion-share and use `http://localhost:3000` with `local-dev-token`.

## Releasing

Releases are published with a small Go tool that archives, notarizes, packages
and signs the app, then creates the GitHub release, updates `appcast.xml` (the
Sparkle feed) and the Homebrew cask:

```bash
go run ./cmd/lotion-release -build -yes -set-version 0.0.2 -set-build 2 \
  -notes "First change
Second change"
```

Without `-build`, it expects an already exported, notarized `Lotion.app` in
`~/Downloads`. See [the release skill](.agents/skills/release-lotion/SKILL.md)
for the full workflow and troubleshooting.

## Credits

- Icons: [Hugeicons](https://hugeicons.com) — the free
  Stroke Rounded set ([@hugeicons/core-free-icons](https://www.npmjs.com/package/@hugeicons/core-free-icons)), MIT
  licensed, © Hugeicons.
- Brand logos: [gilbarbara/logos](https://github.com/gilbarbara/logos) by
  Gil Barbara, CC0. The logos remain their owners' trademarks.
