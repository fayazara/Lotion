//
//  WelcomeNote.swift
//  Lotion
//

enum WelcomeNote {
    static let text = #"""
# Welcome to Lotion

Lotion is a quiet place for notes. Everything you write is plain **Markdown**, saved as a file you own, and styled as you type.

## The basics

- The first line of a note is its title, and its file name.
- Folders in the sidebar are folders on disk.
- Pin the notes you come back to, from the note's menu or with a right click.
- Press ⌘N for a new note, and ⌥⌘I to show the inspector.

## Writing

Use *italics*, **bold**, ~~strikethrough~~ and `inline code`. Links look like [this](https://commonmark.org/help/), and ⌘-click opens them.

> A blockquote, for the things worth repeating.

Checklists stay clickable:

- [x] Write the first note
- [ ] Try a checklist
- [ ] Pick a theme in Settings

## Code

Fenced code is highlighted for more than two hundred languages.

```swift
struct Note: Identifiable {
    let id = UUID()
    var title: String
    var body: String

    var wordCount: Int {
        body.split(whereSeparator: \.isWhitespace).count
    }
}
```

```ts
export function slugify(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}
```

---

| Shortcut | Action          |
| -------- | --------------- |
| ⌘B       | Bold            |
| ⌘I       | Italic          |
| ⌥⌘C      | Inline code     |
| ⌘K       | Link            |
| ⇧⌘L      | Checklist item  |

"""#
}
