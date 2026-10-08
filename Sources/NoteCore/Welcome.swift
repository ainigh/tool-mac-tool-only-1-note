/// The note the first time the app opens: what it can do, written the way it does it.
public enum Welcome {
    public static let text = """
    Your note
    One note, always a click away in the menu bar. Everything here is yours to change or delete.

    # Write the way you think
    The first line is the title. Lines starting # are headings. Text can be **bold**, *italic*, `code`, ~~struck out~~ or ==marked==, and web addresses like https://github.com become links.

    - Lines starting with a dash are bullets
        - Tab nests one, Shift-Tab brings it back
    1. Numbers carry on when you press Return
    2. Return on an empty item ends the list

    # Tasks
    - [ ] Click a box to tick it (or press ⌘↩ on its line)
    - [x] Done tasks fade and are struck through
    - [ ] The puzzle piece below can move done tasks down, or clear them

    > Quotes stand out, and three dashes make a rule:

    ---

    ```
    Code goes between three backticks,
    and keeps its spacing.
    ```

    # Good to know
    - ⌥⌘N, anywhere, shows or hides this note
    - ⌘F finds (and replaces), ⌘+ and ⌘− change the size
    - It saves as you type, to a plain Markdown file
    - The clock below keeps a history: go back to any earlier version
    - The pin keeps the note up while you work in other apps
    - Plugins (the puzzle piece) add commands and footer counts; add your own scripts too
    """
}
