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

No accounts, no sync service, no database. To sync, put your notes folder in
iCloud Drive, Dropbox or a git repo.

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
