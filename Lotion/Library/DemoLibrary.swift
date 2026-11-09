//
//  DemoLibrary.swift
//  Lotion
//
//  A made-up library for screenshots and launch videos: folders of social
//  posts about Lotion's launch, a few devrel notes and side projects. The
//  "Lotion Demo" scheme turns it on with `-LotionDemo YES`; it lives in its own
//  folder with its own pins, so the real library is never touched. Pass
//  `-LotionDemoReset YES` to write it fresh.
//

import Foundation

enum DemoLibrary {
    /// Debug builds launched with `-LotionDemo YES`.
    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "LotionDemo")
        #else
        false
        #endif
    }

    static var root: URL {
        #if DEBUG
        // Test runs put it in a scratch folder.
        if let path = UserDefaults.standard.string(forKey: "LotionLibrary") { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        return URL.documentsDirectory.appending(path: "Lotion Demo", directoryHint: .isDirectory)
    }

    static let pinsKey = "demoPinnedNotes"

    struct DemoNote {
        let folder: String?
        let text: String
        /// Days before today it was written, and last edited.
        let created: Double
        let edited: Double
        var icon: String?
        var pinned = false
        /// What to search Unsplash for, for its cover.
        var photo: String = ""
        var title: String {
            text.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? "Untitled"
        }
        var path: String { [folder, title + ".md"].compactMap { $0 }.joined(separator: "/") }
    }

    /// Writes the demo notes when the folder is new, or when asked to reset.
    static func seedIfNeeded() {
        let fm = FileManager.default
        let reset = UserDefaults.standard.bool(forKey: "LotionDemoReset")
        let marker = root.appending(path: ".lotion/demo")
        if fm.fileExists(atPath: marker.path), !reset { return }
        if reset { clearKeepingCovers() }
        try? fm.createDirectory(at: root.appending(path: ".lotion", directoryHint: .isDirectory), withIntermediateDirectories: true)

        let now = Date.now
        func date(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        for folder in folders {
            try? fm.createDirectory(at: root.appending(path: folder.name, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        var icons: [String: String] = [:]
        for note in notes {
            let url = root.appending(path: note.path)
            try? note.text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.creationDate: date(note.created), .modificationDate: date(note.edited)], ofItemAtPath: url.path)
            if let icon = note.icon { icons[note.path] = icon }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let meta = root.appending(path: ".lotion", directoryHint: .isDirectory)
        try? encoder.encode(Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0.icon) })).write(to: meta.appending(path: "folders.json"))
        try? encoder.encode(icons).write(to: meta.appending(path: "notes.json"))
        UserDefaults.standard.set(notes.filter(\.pinned).map(\.path), forKey: pinsKey)

        // A few loose thoughts in the scratchpad.
        let scratchpad = root.appending(path: ".lotion/Scratchpad/Scratchpad.md")
        try? fm.createDirectory(at: scratchpad.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries = scratchpadEntries.map { Library.entryMarker(at: date($0.days)) + "\n" + $0.text }
        try? (entries.joined(separator: "\n\n") + "\n").write(to: scratchpad, atomically: true, encoding: .utf8)

        try? "".write(to: marker, atomically: true, encoding: .utf8)
    }

    /// Covers chosen before, so a reset doesn't search Unsplash again.
    private static var chosenCoversURL: URL { root.appending(path: ".lotion/demo-covers.json") }

    /// Empties the demo folder but keeps the downloaded photos and which note had which.
    private static func clearKeepingCovers() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != ".lotion" { try? fm.removeItem(at: item) }
        let meta = root.appending(path: ".lotion", directoryHint: .isDirectory)
        for item in (try? fm.contentsOfDirectory(at: meta, includingPropertiesForKeys: nil)) ?? []
        where !["covers", "demo-covers.json"].contains(item.lastPathComponent) {
            try? fm.removeItem(at: item)
        }
    }

    /// Gives every demo note without a cover an Unsplash photo that suits it:
    /// the one it had before if it's still on disk, otherwise the first fresh
    /// search result. Runs after the library loads; covers appear as they land.
    static func fetchCovers(into library: Library) async {
        let decoder = JSONDecoder()
        var chosen = (try? Data(contentsOf: chosenCoversURL)).flatMap { try? decoder.decode([String: NoteCover].self, from: $0) } ?? [:]
        var used = Set(chosen.values.map(\.file))
        for demo in notes where !demo.photo.isEmpty {
            let url = root.appending(path: demo.path).standardizedFileURL
            guard let note = library.notes.first(where: { $0.url.standardizedFileURL == url }), library.cover(for: note) == nil else { continue }
            if let cover = chosen[demo.path], FileManager.default.fileExists(atPath: cover.url(in: library).path) {
                library.setCover(cover, for: note)
                continue
            }
            guard UnsplashClient.accessKey != nil,
                  let page = try? await UnsplashClient.photos(query: demo.photo, page: 1),
                  let photo = page.photos.first(where: { !used.contains("Photo by \($0.user.name) (\($0.id)).jpg") }) ?? page.photos.first
            else { continue }
            await library.setUnsplashCover(photo, for: note)
            if let cover = library.cover(for: note) {
                chosen[demo.path] = cover
                used.insert(cover.file)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try? encoder.encode(chosen).write(to: chosenCoversURL)
            }
        }
    }

    static let folders: [(name: String, icon: String)] = [
        ("Launch", "paperplane"),
        ("Social", "bubble.left.and.bubble.right"),
        ("DevRel", "megaphone"),
        ("Side Projects", "hammer"),
    ]

    static let scratchpadEntries: [(days: Double, text: String)] = [
        (6, "Hook idea: “Your notes are just files. Lotion just makes them nice to look at.”"),
        (3.2, "Record the slash menu at 60fps — the scroll looks so much better now."),
        (1.1, "- [ ] Ask two friends to try the beta before Monday\n- [ ] Check the OG image on every network"),
        (0.15, "Thread opener is too long. Cut the second sentence."),
    ]

    // MARK: - Notes

    static let notes: [DemoNote] = [
        DemoNote(folder: nil, text: about, created: 35, edited: 0.1, icon: "book.pages", pinned: true, photo: "white paper texture minimal"),
        DemoNote(folder: "Launch", text: launchPlan, created: 18, edited: 0.2, icon: "flag.checkered", pinned: true, photo: "rocket launch night sky"),
        DemoNote(folder: "Launch", text: xThread, created: 9, edited: 0.4, icon: "text.bubble", pinned: true, photo: "minimal blue gradient"),
        DemoNote(folder: "Launch", text: linkedIn, created: 8, edited: 1.5, icon: "briefcase", photo: "modern office desk morning light"),
        DemoNote(folder: "Launch", text: blueskyMastodon, created: 8, edited: 2, photo: "blue sky clouds"),
        DemoNote(folder: "Launch", text: productHunt, created: 12, edited: 1, icon: "trophy", photo: "orange sunset abstract"),
        DemoNote(folder: "Launch", text: showHN, created: 7, edited: 3, photo: "vintage computer terminal"),
        DemoNote(folder: "Launch", text: videoScript, created: 10, edited: 0.8, icon: "video", photo: "film camera studio"),
        DemoNote(folder: "Launch", text: shotList, created: 11, edited: 2.5, icon: "camera", photo: "photography desk setup"),
        DemoNote(folder: "Social", text: postIdeas, created: 25, edited: 4, icon: "lightbulb", photo: "lightbulb dark background"),
        DemoNote(folder: "Social", text: featureSpotlights, created: 14, edited: 1.2, photo: "spotlight stage"),
        DemoNote(folder: "Social", text: replies, created: 6, edited: 0.6, icon: "questionmark.bubble", photo: "coffee conversation cafe"),
        DemoNote(folder: "Social", text: calendar, created: 15, edited: 0.9, icon: "calendar", photo: "autumn leaves november"),
        DemoNote(folder: "DevRel", text: talk, created: 30, edited: 5, icon: "person.wave.2", photo: "conference stage audience"),
        DemoNote(folder: "DevRel", text: cursorsDemo, created: 21, edited: 6, photo: "network lights city night"),
        DemoNote(folder: "DevRel", text: workshop, created: 16, edited: 7, icon: "checklist", photo: "workshop tools wood"),
        DemoNote(folder: "Side Projects", text: ideas, created: 40, edited: 9, icon: "sparkles", photo: "notebook sketches"),
        DemoNote(folder: "Side Projects", text: shortener, created: 27, edited: 11, photo: "chain links macro"),
        DemoNote(folder: nil, text: voice, created: 20, edited: 2, icon: "textformat", photo: "typewriter paper"),
        DemoNote(folder: nil, text: reading, created: 13, edited: 3, icon: "books.vertical", photo: "library books shelves"),
    ]

    static let about = #"""
    # About Lotion

    **Lotion is a quiet notes app for the Mac.** Every note is a plain Markdown file in a folder you own, and it's styled as you type — so you get a calm, beautiful page without giving up your files.

    [TOC]

    > [!NOTE]
    > This note is the whole app on one page. Everything described here is in this note somewhere — scroll and try it.

    ## Why Lotion

    - **Your files.** Notes are `.md` files. Folders in the sidebar are folders on disk. Open them in any editor, put them in git, sync them however you like.
    - **A page, not a text editor.** Markdown is styled live, in blocks, with real typography.
    - **Native.** AppKit and SwiftUI, fast with big notes, at home on macOS.
    - **Nothing hidden.** Covers, icons and link previews sit in a small `.lotion` folder beside your notes. Delete it and you lose nothing you wrote.

    ## How your notes are kept

    ```mermaid
    flowchart LR
      you[You<br>type in a note] --> editor[Block editor<br>styled as you type]
      editor --> file[note.md<br>plain Markdown]
      file --> folder[Your folder<br>synced however you like]
      editor --> media[Images and video<br>copied next to the note]
      editor --> meta[.lotion folder<br>covers, icons, previews]
    ```

    Blocks you don't touch are written back exactly as they were, so a note edited elsewhere stays byte for byte the same.

    ## Writing

    Type Markdown and it turns into the thing it describes: `#` for headings, `-` for lists, `[ ]` for checklists, `>` for quotes, `---` for a divider. Inline, use *italics*, **bold**, ~~strikethrough~~, `code` and [links](https://commonmark.org/help/).

    - [x] Checklists stay clickable
    - [ ] Drag blocks by their handle to reorder them
    - [ ] Select several blocks and move, copy or delete them together

    > [!TIP]
    > Type `/` on an empty line for the block menu. Start typing to filter it — `/dia` finds Diagram.

    ### Everything in the block menu

    | Block | Shortcut in Markdown |
    | --- | --- |
    | Headings 1–3 | `#`, `##`, `###` |
    | Bulleted, numbered and to-do lists | `-`, `1.`, `[ ]` |
    | Quote and callout | `>`, `> [!NOTE]` |
    | Code, with highlighting for 200+ languages | three backticks |
    | Table | rows and columns |
    | Diagram | three backticks + `mermaid` |
    | Image, video, audio, PDF, any file | from your Mac, or drop it in |
    | Embed | paste a link |
    | Embed another note | `![[Note name]]` |
    | Table of contents | `[TOC]` |
    | Divider | `---` |

    ## Code

    ```ts
    export default {
      async fetch(request: Request): Promise<Response> {
        return new Response("Hello from the edge");
      },
    };
    ```

    ## Diagrams

    Mermaid flowcharts and sequence diagrams are drawn natively — cards with icons, clean right-angled wires, and frames for loops and branches. Wide charts scroll sideways; Expand shows them full size. Double-click to edit the source and watch the drawing follow.

    ```mermaid
    sequenceDiagram
      actor You
      participant Lotion
      participant Web as The web
      You->>Lotion: paste a link
      Lotion->>Web: fetch title, image, icon
      Web-->>Lotion: page details
      Lotion-->>You: a card
      Note over Lotion,Web: Cached beside your notes
    ```

    ## Embeds

    Paste a link on an empty line and it becomes a card. Pages show their title, description and image; YouTube, Vimeo and Loom play in place; Spotify, Apple Music, Figma and CodePen show their players; GitHub repos, issues and pull requests get proper cards; X posts, Apple Maps and Google Maps links work too.

    https://github.com/cloudflare/workers-sdk

    https://developers.cloudflare.com/workers/

    ## Notes inside notes

    `![[Writing voice]]` shows another note in place, with a link to open it:

    ![[Writing voice]]

    ## The scratchpad

    One running page for thoughts that don't have a home yet. Press **⌘0** to open it from anywhere. Every entry is timestamped.

    ## Making it yours

    - **Themes** in Settings, each with light and dark. Your theme's accent tints the sidebar.
    - **Covers** from your Mac, the system wallpapers, or Unsplash — photographers are credited.
    - **Icons** for every note and folder.
    - **Fonts, size and line spacing**, and a readable width for the page.

    ## Finding things

    - The sidebar sorts by date created, date edited or title. Pin the notes you come back to.
    - **⌥⌘F** searches every note.
    - The inspector (**⌥⌘I**) shows the outline, word count and reading time, and the note's file.

    ## Shortcuts

    | Shortcut | Action |
    | --- | --- |
    | ⌘N | New note |
    | ⇧⌘N | New folder |
    | ⌘0 | Open the scratchpad |
    | ⌥⌘F | Search all notes |
    | ⌥⌘I | Show or hide the inspector |
    | ⌃⌘M | Switch between blocks and raw Markdown |
    | ⌥⌘R | Show in Finder |
    | ⇧⌘E | Export as Markdown |
    | ⌘B, ⌘I | Bold, italic |
    | ⌥⌘C | Inline code |
    | ⌘K | Link |
    | ⇧⌘L | Checklist item |
    | ⌘, | Settings |

    ---

    *Made with care for people who write things down.*
    """#

    static let launchPlan = #"""
    # Launch plan

    Lotion goes out on **Tuesday, 9am PT**. One clear story everywhere: *your notes are plain Markdown files, and they finally look good.*

    [TOC]

    > [!NOTE]
    > Everything below is a draft. Final copy lives in each channel's note.

    ## Timeline

    | When | What | Where |
    | --- | --- | --- |
    | Mon, evening | Schedule posts, final screenshots | Everywhere |
    | Tue, 9:00 | Product Hunt goes live | Product Hunt |
    | Tue, 9:05 | Launch thread | X, Bluesky, Mastodon |
    | Tue, 10:00 | Show HN | Hacker News |
    | Tue, 12:00 | Longer post | LinkedIn |
    | Wed | Feature spotlight: diagrams | X, Bluesky |
    | Thu | Feature spotlight: embeds | X, Bluesky |
    | Fri | Thank-you post with numbers | Everywhere |

    ## How a post turns into a download

    ```mermaid
    flowchart LR
      post[Launch thread<br>X, Bluesky, Mastodon] --> site[Website<br>Lotion landing page]
      ph[Product Hunt<br>launch day] --> site
      hn[Show HN<br>first comment] --> site
      li[LinkedIn<br>longer story] --> site
      site --> dl[Download<br>DMG, notarized]
      dl --> open[First note<br>Welcome to Lotion]
    ```

    ## Before launch

    - [x] Final icon and screenshots
    - [x] Notarized build
    - [x] Landing page copy
    - [ ] OG image checked on X, LinkedIn and Bluesky
    - [ ] Schedule the thread
    - [ ] Ask friends for honest first comments (no vote begging)

    ## On the day

    - [ ] Reply to every comment in the first three hours
    - [ ] Pin the thread
    - [ ] Post the 60-second video natively, not as a link
    - [ ] Write down every feature request in **Replies & FAQ**

    ## After

    - [ ] Thank-you post on Friday
    - [ ] Short write-up: what worked, what didn't
    """#

    static let xThread = #"""
    # X thread — Introducing Lotion

    Eight posts. Each one stands on its own if someone only sees that one.

    ## 1 / Opener

    I built a notes app for the Mac.

    It's called Lotion. Your notes are plain Markdown files in a folder you own — and they look *really* good while you write them. 🧵

    ## 2 / Files

    No database, no lock-in. Every note is a `.md` file. Folders in the sidebar are folders on disk. Open them in anything.

    ## 3 / Writing

    Type Markdown, see it styled as you go. Headings, checklists, tables, callouts, code with real syntax highlighting.

    ## 4 / Diagrams

    Mermaid flowcharts and sequence diagrams, drawn natively. No more grey boxes and spaghetti arrows. (video)

    ## 5 / Embeds

    Paste a link on an empty line and it becomes a card: pages, YouTube, GitHub, Spotify, maps, PDFs, audio.

    ## 6 / Scratchpad

    One running note for the thoughts that don't have a home yet. Every entry is timestamped.

    ## 7 / Themes

    A handful of themes, light and dark, and your accent colour follows you into the sidebar.

    ## 8 / Close

    Lotion is out today for macOS. I'd love to hear what you think → [link]

    ---

    > [!TIP]
    > Post 4 and 5 get native video. Everything else gets a single screenshot.
    """#

    static let linkedIn = #"""
    # LinkedIn post

    For the last few months I've been building something on nights and weekends: **Lotion**, a notes app for the Mac.

    I write a lot — talk outlines, demo scripts, blog drafts, the odd shopping list — and I wanted two things that are surprisingly hard to get together:

    1. My notes as plain files I own, that work with git, grep and every other tool.
    2. A writing experience that feels calm and looks beautiful.

    Lotion is that. Markdown in, a lovely page out. Diagrams are drawn natively, links turn into rich cards, and there's a scratchpad for half-formed thoughts.

    It's out today. If you write things down for a living, I'd really like to know what you think.

    #macOS #buildinpublic #productivity
    """#

    static let blueskyMastodon = #"""
    # Bluesky + Mastodon

    Same story, warmer tone, fewer emoji.

    ## Bluesky

    Lotion is out 🎉 A notes app for the Mac where every note is a plain Markdown file — and writing them actually feels nice. Diagrams, embeds, a scratchpad, themes. → [link]

    ## Mastodon

    I made a Mac notes app! Lotion keeps your notes as plain Markdown files in a folder you choose, and renders them beautifully as you type. No accounts, no sync service, no database.

    [link] #macOS #markdown
    """#

    static let productHunt = #"""
    # Product Hunt

    ## Tagline options

    - Beautiful notes that are just Markdown files
    - A calm Mac notes app for people who own their files ← **favourite**
    - Write in Markdown. See a page.

    ## Description

    Lotion is a native Mac notes app. Every note is a plain Markdown file in a folder you own, styled live as you type — with native Mermaid diagrams, rich link cards, a scratchpad and themes.

    ## First comment

    Hey Product Hunt 👋 I'm a developer advocate, which means I write *constantly* — talk outlines, demo scripts, threads like this one. I wanted my notes in plain files, but every editor that kept them as files felt like a text editor, not a notebook. So I built Lotion.

    A few things I'm proud of:

    - Mermaid diagrams drawn natively, so they look like they belong
    - Paste any link and get a proper card
    - It's fast with big notes

    I'll be here all day — ask me anything.

    ## Gallery

    1. Hero: a note with a cover and a diagram
    2. Embeds: link card, YouTube, GitHub
    3. Sequence diagram, dark mode
    4. Themes side by side
    5. Scratchpad
    """#

    static let showHN = #"""
    # Hacker News — Show HN

    ## Title

    Show HN: Lotion – a native Mac notes app where every note is a Markdown file

    ## First comment

    Hi HN. Lotion is a SwiftUI + AppKit notes app. Notes are `.md` files in a folder you pick; folders are folders. Nothing else is stored except a small hidden folder with covers and icons.

    Some implementation notes people might find interesting:

    - The editor is a block editor over plain text — unedited blocks round-trip byte for byte.
    - Mermaid flowcharts and sequence diagrams are parsed and laid out natively (layered layout, orthogonal routing), not rendered in a web view.
    - Link embeds are cached on disk next to your notes.

    Happy to answer questions about any of it.

    > [!WARNING]
    > Keep it factual. No marketing words in the title.
    """#

    static let videoScript = #"""
    # Launch video script

    60 seconds, no voiceover, captions only. Music: something soft with a beat at 0:20.

    | Time | On screen | Caption |
    | --- | --- | --- |
    | 0:00 | Empty note, cursor blinking | Notes that are just files. |
    | 0:04 | Type a heading and a checklist | Write Markdown. See a page. |
    | 0:12 | Paste a YouTube link → card | Links become cards. |
    | 0:20 | Type a mermaid flowchart | Diagrams, drawn natively. |
    | 0:32 | Swipe through themes | Make it yours. |
    | 0:42 | Finder window with the .md files | Your files. Your folder. |
    | 0:52 | Logo | Lotion. Out now for Mac. |

    ## The diagram we type on camera

    ```mermaid
    sequenceDiagram
      actor You
      participant Lotion
      participant Disk as Your folder
      You->>Lotion: type a note
      Lotion->>Disk: save note.md
      Disk-->>Lotion: saved
      Lotion-->>You: looks lovely
    ```
    """#

    static let shotList = #"""
    # Screenshot shot list

    All at 2× on a clean desktop, window 1440 × 900, wallpaper: default.

    - [x] Hero — **Launch plan** with cover, light mode
    - [x] Dark mode — **Launch video script** with the sequence diagram
    - [ ] Embeds — **Reading list**
    - [ ] Slash menu open, mid-scroll
    - [ ] Sidebar with folders, accent theme
    - [ ] Inspector open on a long note

    > [!TIP]
    > Run the Lotion Demo scheme with `-LotionDemoReset YES` before every session so dates look fresh.
    """#

    static let postIdeas = #"""
    # Post ideas backlog

    Short, specific, one idea per post.

    ## Build in public

    - Why I didn't use a web view for diagrams
    - The golden rule of padding and border radius (with before/after)
    - How the editor keeps unedited Markdown byte-for-byte identical
    - Making a slash menu scroll feel native

    ## Tips

    - `[TOC]` on its own line gives you a live table of contents
    - `![[Another note]]` embeds a note inside a note
    - Paste a map link → a map card

    ## Maybe

    - A "what's on my desk" post with the app open
    - Timelapse of writing a talk outline
    """#

    static let featureSpotlights = #"""
    # Feature spotlights

    One feature a day for the week after launch.

    ## Diagrams

    Mermaid, but beautiful. Flowcharts get cards, icons and clean right-angled wires. Sequence diagrams get lifelines, loops and alt blocks.

    ```mermaid
    flowchart LR
      idea[Idea<br>scratchpad] --> draft[Draft<br>a note per channel]
      draft --> review{Reads well?}
      review -- Yes --> post[Schedule<br>post it]
      review -- No --> draft
    ```

    ## Embeds

    Paste a link on an empty line:

    https://github.com/cloudflare/workers-sdk

    ## Scratchpad

    One page for everything that isn't a note yet. ⌘0 from anywhere; every entry gets a timestamp.

    ## Themes

    Every theme comes in light and dark, and tints the sidebar to match.
    """#

    static let replies = #"""
    # Replies & FAQ

    Canned answers, so launch day replies stay quick and consistent. **Check every [bracket] before posting.**

    ## Does it sync?

    Lotion doesn't run a sync service. Put your notes folder in iCloud Drive, Dropbox or a git repo and it syncs the way you already sync files.

    ## Is it open source?

    [decide before launch]

    ## Where are my notes stored?

    In the folder you choose — by default `~/Documents/Notes`. Every note is a `.md` file.

    ## Windows / iOS?

    Mac first. [Say nothing about timelines.]

    ## Feature requests so far

    | Request | Count | Notes |
    | --- | --- | --- |
    | iOS app | 3 | |
    | Vim mode | 2 | |
    | Math blocks | 1 | |
    """#

    static let calendar = #"""
    # Content calendar — November

    | Week | Mon | Wed | Fri |
    | --- | --- | --- | --- |
    | 1 | Teaser screenshot | Build-in-public: diagrams | — |
    | 2 | Teaser video | **Launch (Tue)** | Thank-you post |
    | 3 | Spotlight: embeds | Spotlight: scratchpad | Tips thread |
    | 4 | Blog: how the layout works | Community notes | Month recap |

    > [!NOTE]
    > Keep Fridays light. People are tired.
    """#

    static let talk = #"""
    # Talk — Ship a full-stack app in 20 minutes

    **Format:** 25 min + Q&A · **Level:** beginner–intermediate

    ## Abstract

    We'll start from an empty folder and end with a deployed app: an API on Workers, data in D1, files in R2, and a realtime feature with Durable Objects. No slides after the first five minutes — just code.

    ## Outline

    1. Why the edge, in one diagram (3 min)
    2. `npm create`, first deploy (3 min)
    3. Add a database (5 min)
    4. Uploads to object storage (4 min)
    5. Realtime presence (6 min)
    6. Recap + links (2 min)

    ```mermaid
    flowchart LR
      user[Browser<br>anywhere] --> worker[Worker<br>API routes]
      worker --> db[(D1<br>SQL)]
      worker --> files[R2<br>uploads]
      worker --> room[Durable Object<br>one per room]
    ```

    ## Things that go wrong live

    - Wi-Fi → have the deploy pre-recorded
    - Font size → 20pt minimum in the terminal
    """#

    static let cursorsDemo = #"""
    # Demo — Realtime cursors

    A small demo for the talk: everyone on the page sees everyone's cursor.

    ```mermaid
    sequenceDiagram
      participant A as Browser A
      participant W as Worker
      participant Room as Durable Object
      participant B as Browser B
      A->>W: open WebSocket
      W->>Room: forward to room
      B->>W: open WebSocket
      W->>Room: forward to room
      loop every mouse move
        A->>Room: cursor x, y
        Room-->>B: broadcast
      end
      B--xRoom: tab closed
      Room-->>A: B left
    ```

    ## To do

    - [x] Room per URL path
    - [x] Throttle to 30 updates a second
    - [ ] Colour per visitor
    - [ ] Show names on hover
    """#

    static let workshop = #"""
    # Workshop checklist

    ## A week before

    - [x] Room booked, projector checked
    - [x] Starter repo tagged
    - [ ] Send setup instructions

    ## On the day

    - [ ] Power strips
    - [ ] Hotspot as Wi-Fi backup
    - [ ] Printed QR code to the repo
    - [ ] Stickers 🧡

    ## Afterwards

    - [ ] Share slides and recording
    - [ ] Collect feedback (three questions, max)
    """#

    static let ideas = #"""
    # Ideas

    Small things to build when there's a free weekend.

    - **Link shortener** on Workers + D1 → started, see the next note
    - A tiny status page that pings my side projects every minute
    - Turn the Lotion scratchpad into a menu bar app
    - Photo-a-day site that reads from a folder
    - A "now playing" badge for my website

    > [!TIP]
    > If it can't ship in a weekend, it goes to the bottom.
    """#

    static let shortener = #"""
    # Weekend build — link shortener

    ## Shape

    ```mermaid
    flowchart LR
      visit[Visitor<br>short link] --> worker[Worker<br>lookup]
      worker --> kv[(D1<br>links table)]
      worker --> redirect[Redirect<br>301]
      admin[Admin page<br>create links] --> worker
    ```

    ## Schema

    ```sql
    create table links (
      slug text primary key,
      url text not null,
      created_at integer not null,
      hits integer not null default 0
    );
    ```

    ## Left to do

    - [x] Redirects
    - [x] Hit counter
    - [ ] Admin page behind Access
    - [ ] Custom domain
    """#

    static let voice = #"""
    # Writing voice

    How I want every post to sound.

    - **Plain words.** "Fast", not "blazingly performant".
    - **One idea per post.**
    - **Show, then tell.** Lead with the screenshot or the video.
    - **No hype.** Let the thing be good.
    - **Thank people by name** (with permission).

    ## Words to avoid

    | Instead of | Say |
    | --- | --- |
    | revolutionary | new |
    | leverage | use |
    | seamless | it just works — or say nothing |
    | game-changer | (delete) |
    """#

    static let reading = #"""
    # Reading list

    Things to read before writing the launch posts.

    https://developers.cloudflare.com/workers/

    https://www.apple.com/macos/

    https://github.com/mermaid-js/mermaid

    ## Notes

    - Mermaid's syntax docs are the reference for what Lotion should read.
    - Re-read the Writing voice note before every post.
    """#
}
