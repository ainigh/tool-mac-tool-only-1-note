# Only Note

One note, in the macOS menu bar, done well. Click the note icon (or press **⌥⌘N** anywhere) and the
note opens under it; click elsewhere and it goes away (unless it's pinned). The whole window is
the note. The footer under it holds everything else: the counts, plugins, history, the pin,
settings and updates.

Built for Apple silicon (an M1 Max with 64 GB is plenty), and the release also runs on Intel Macs.

## Install

```sh
gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool-only-1-note/contents/install.sh | bash
```

This takes the latest release GitHub built (or, if there isn't one, builds the source here with
Apple's command line tools), puts **Only Note** in `~/Applications` and opens it. It opens at
login from then on (a switch in Settings turns that off). If the new copy quits as soon as it
opens, the one you had goes back.

## Writing

The note is plain Markdown, drawn as you type:

- **The first line is the title.** `#`, `##`, `###` lines are headings (⌘1, ⌘2, ⌘3; ⌥⌘0 for plain text).
- `- ` lines are **bullets**, drawn as dots. **Tab** nests a line, **⇧Tab** brings it back.
- `- [ ] ` lines are **tasks**, drawn as boxes: **click a box to tick it**, or press **⌘↩** on
  its line (on any other line ⌘↩ makes it a task; on several selected lines, all of them). Done
  tasks fade and are struck through.
- `1. ` lines are **numbered**. **Return carries a list on** (the next number, a new bullet, an
  open task); Return on an empty item ends the list (or brings a nested one back a level).
- `> ` is a quote (a bar down its side), `---` a rule, and lines between ``` fences are code.
- Inline: `**bold**` (⌘B), `*italic*` (⌘I), `` `code` `` (⌘K), `~~struck~~` (⇧⌘X),
  `==marked==` (⇧⌘H). Each key wraps the selection, or unwraps it when it's already wrapped.
- Web addresses become links: click one to open it.
- **⌘F** finds, **⌥⌘F** finds and replaces, **⌘G** / **⇧⌘G** next and previous.
- **⌘+** / **⌘−** / **⌘0** change the size. Paste always comes in as plain text.
- **Esc** closes the find bar, or an open panel, or puts the note away.

Only the lines around each edit are restyled (the whole note only when a ``` fence comes or
goes), so a long note types as quickly as a short one. The caret is where you left it.

## Saving and history

The note is one file: `~/Library/Application Support/OnlyNote/Note.md`. It's saved a moment after
you stop typing, and whenever the note is put away, the app quits or updates. Every save is
atomic (written beside it, then swapped in), so a crash never leaves half a note. The dot at the
left of the footer is grey when saved, orange while saving, red if a save failed (click it to try
again).

Any editor can open the file; changes made there (or by a sync) show up in the note within a
couple of seconds. If you had unsaved changes at the time, yours win and the other version goes
into the history.

**History** (the clock in the footer, or ⌘Y): a copy of the note is kept at most every five
minutes while it changes, and before anything that rewrites it all (a plugin, a restore, a change
from outside). Pick one to read it, copy it, or **restore** it (the note as it was is kept too,
and ⌘Z undoes the restore). The history thins itself as it ages: every copy from the last day,
one a day for a month, then one a week, never more than 400.

## The footer

From the left: the save dot; what the plugins count (words, tasks done…), or a message for a few
seconds; then **Update** when there's one; the **puzzle piece** (plugins); the **clock**
(history); the **pin** (keep the note up over other windows while you work elsewhere, and
movable by its top strip); the **gear** (settings, updates, quit).

**Settings**: theme (Match the Mac, Light, Paper, Dark, Night), typeface (System, Rounded, Serif,
Mono), size, line spacing, readable width (lines kept to a comfortable column however wide the
window), spell check, pin, the ⌥⌘N shortcut, open at login, where the file is, the version and
updates, and Quit. The window remembers its size.

**Right-click the menu bar icon** for: show/hide, check for updates (or update), the version,
open at login, show the note's file, quit.

## Updates

The app checks GitHub at launch and every 6 hours; while there's an update, the menu bar icon
wears a **+** and the footer shows **Update**. Updating saves the note, takes GitHub's prebuilt
copy when there's a release from that exact commit (otherwise it downloads the source and
builds it on the Mac), swaps itself in and restarts. What it did is in
`~/Library/Logs/OnlyNote/update.log`. It talks to GitHub through `gh` when it's installed (so a
private repo works).

## Plugins

Fundamentally it's one note; plugins add to it without getting in its way. Two kinds, turned on
and off in **Manage plugins** (the puzzle piece):

- **Footer counts**: Word count and Task progress (on), Reading time and Character count (off).
- **Commands**, from the puzzle piece, the Plugins menu, or their key:
  - Insert date and time (⌃⌥D)
  - Make a checklist (⌃⌥C): the selected lines, or the paragraph at the caret, become tasks (or back)
  - Move done tasks down, in each checklist (with what's nested under each)
  - Clear done tasks
  - Sort lines (A to Z by their text, ignoring bullets and boxes; again for Z to A)
  - Remove duplicate lines
  - Renumber lists
  - Tidy up (spaces at line ends, runs of blank lines)

  Commands that rewrite the note keep a copy in the history first, and ⌘Z undoes any of them.

### Your own plugins

Any script in `~/Library/Application Support/OnlyNote/Plugins` is a command (two examples and a
README are put there the first time). It's given the selection on its standard input (the whole
note when nothing's selected), and what it prints replaces it. A few comment lines near its top
say how it works:

```sh
#!/bin/sh
# @name: Shout
# @summary: CAPITALS for the selection.
# @symbol: textformat.size.larger      (an SF Symbol)
# @input: selection                    (or: note)
# @output: replace                     (or: insert, append, message, none)
# @key: s                              (⌃⌥S runs it)
tr '[:lower:]' '[:upper:]'
```

Any language works (a `#!` line picks it; a file that isn't executable runs with `/bin/sh`). It
also gets `NOTE_FILE`, `NOTE_SELECTION` and `NOTE_INPUT` in its environment, and has 10 seconds.
If it fails, the end of what it printed on standard error shows in the footer. It runs off the
main thread; if the note changes while it runs, its result isn't applied. **Reload plugins** in
the puzzle piece picks up new or changed scripts.

## Building and testing

```sh
swift test                              # the note's logic (NoteCore); runs on Linux too
VERSION=0.1.0 scripts/build-app.sh      # build/OnlyNote.app and build/OnlyNote.zip (on a Mac)
```

- `Sources/NoteCore`: Foundation only. The markup (`Markup.swift`), what the keys do to lines
  (`Editing.swift`), counts (`Stats.swift`), saving and history (`Vault.swift`), plugins
  (`Plugins.swift`, `ScriptPlugin.swift`), settings, and GitHub's release and commit answers.
- `Sources/OnlyNote`: the app. The text view and its drawing (`NoteTextView.swift`), the model
  (`NoteModel.swift`), the window and footer (`NoteView.swift`), history, plugins and settings
  (`Overlays.swift`), the menu bar icon, window and menus (`App.swift`), the shortcut
  (`HotKey.swift`) and the updater (`Updater.swift`).

Every push runs the tests (Linux and macOS) and builds the app; a push to `main` also publishes
it as a GitHub release, which the app's updates and `install.sh` download.
