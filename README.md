# Lotion

A quiet, native notes app for the Mac. The name is a play on *local Notion*:
every note is a plain Markdown file in a folder you own, styled as you type.

## Features

- **Just files.** Notes are `.md` files, folders are folders. Covers, icons and
  link previews live in a small hidden `.lotion` folder beside your notes —
  delete it and you lose nothing you wrote.
- **A block editor for Markdown.** Headings, lists, checklists, quotes, tables
  and code, with syntax highlighting for 200+ languages.
- **Diagrams, drawn natively.** Mermaid flowcharts and sequence diagrams render
  as real diagrams.
- **Rich embeds.** Links become cards; YouTube, Spotify, Figma, posts, maps,
  PDFs, audio and files embed inline.
- **Covers and icons** for notes, with Unsplash search.
- **A scratchpad** for half-formed thoughts, at the top of the sidebar.
- **Themes** — Lotion's own, plus dozens made from popular VS Code themes.
- **Publish to the web** on your own Cloudflare account, with
  [Lotion Share](https://github.com/fayazara/lotion-share). Copy the setup
  prompt from Settings → Cloud into your coding agent, and it deploys a worker
  with D1 and R2 for you.

No accounts, no sync service, no database. To sync, put your notes folder in
iCloud Drive, Dropbox or a git repo.

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

## Building

Requires macOS 27 and Xcode 27.

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
