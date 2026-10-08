import AppKit
import NoteCore

// The note's text view. The text is plain Markdown; this draws it as you type: each edit restyles
// only the lines around it (the whole note only when a ``` fence comes or goes), so a long note
// types as fast as a short one. Bullets, task boxes, quote bars, rules and code blocks are drawn
// behind the text, where its marks have been made invisible; a click on a box ticks it.

extension NSAttributedString.Key {
    /// What's drawn behind a run: a bullet, a task's box, a quote's bar, a rule, or a code block.
    static let noteDecoration = NSAttributedString.Key("OnlyNoteDecoration")
}

enum Decoration: String {
    case bullet, taskOpen, taskDone, quote, rule, code
}

final class NoteTextView: NSTextView {
    var theme: Theme = .light
    var typography = Typography(typeface: .system, size: 15)
    var lineSpacing: CGFloat = 1.25
    var readableWidth = true
    /// Told after each change the user (or a command) makes.
    var onChange: ((String) -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?
    /// Esc, with nothing else to close.
    var onEscape: (() -> Void)?

    /// The text edited since the last restyle (in the text as it is now).
    fileprivate var pendingEdit: NSRange?
    fileprivate var fenceCount = 0
    private let relay = Relay()

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // MARK: Setting up

    static func make() -> (NSScrollView, NoteTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.findBarPosition = .aboveContent

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = NoteTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.drawsBackground = false
        tv.isRichText = true
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = true
        tv.smartInsertDeleteEnabled = false
        tv.allowsCharacterPickerTouchBarItem = true
        tv.textContainerInset = NSSize(width: 28, height: 10)
        tv.relay.view = tv
        storage.delegate = tv.relay
        tv.delegate = tv.relay
        scroll.documentView = tv
        return (scroll, tv)
    }

    // MARK: The text

    /// Puts in a whole new text (on open, or one from outside): undoable when `undoable`.
    func setText(_ text: String, undoable: Bool, caret: Int? = nil) {
        if undoable {
            replace(NSRange(location: 0, length: (string as NSString).length), with: text, select: false)
        } else {
            textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes()))
            restyleAll()
            undoManager?.removeAllActions()
        }
        if let caret {
            let at = min(caret, (string as NSString).length)
            setSelectedRange(NSRange(location: at, length: 0))
            scrollRangeToVisible(NSRange(location: at, length: 0))
        }
    }

    /// `range` replaced with `text`, as an edit (undoable, and saved): then `text` is selected when
    /// `select`, else the caret goes after it.
    func replace(_ range: NSRange, with text: String, select: Bool) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: baseAttributes()))
        didChangeText()
        let length = (text as NSString).length
        setSelectedRange(select ? NSRange(location: range.location, length: length) : NSRange(location: range.location + length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Look

    func apply(theme: Theme, typography: Typography, lineSpacing: CGFloat, readableWidth: Bool) {
        let changed = theme != self.theme || typography != self.typography || lineSpacing != self.lineSpacing
        self.theme = theme
        self.typography = typography
        self.lineSpacing = lineSpacing
        self.readableWidth = readableWidth
        appearance = theme.appearance
        insertionPointColor = theme.accent
        selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(theme.isDark ? 0.35 : 0.22)]
        linkTextAttributes = [.foregroundColor: theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .underlineColor: theme.accent.withAlphaComponent(0.4), .cursor: NSCursor.pointingHand]
        updateInsets()
        if changed { restyleAll() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    /// A comfortable column, centred, when the window is wide.
    private func updateInsets() {
        let side: CGFloat = 28
        var inset = side
        if readableWidth {
            let column = max(420, typography.size * 44)
            inset = max(side, ((enclosingScrollView?.contentSize.width ?? bounds.width) - column) / 2)
        }
        let want = NSSize(width: inset.rounded(), height: 10)
        if textContainerInset != want { textContainerInset = want }
    }

    private func paragraph(_ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineSpacing
        p.paragraphSpacing = (typography.size * 0.35).rounded()
        configure(p)
        return p
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: typography.font(), .foregroundColor: theme.ink, .paragraphStyle: paragraph()]
    }

    // MARK: Styling

    func restyleAll() {
        guard let storage = textStorage else { return }
        fenceCount = Self.countFences(storage.string as NSString)
        restyle(NSRange(location: 0, length: storage.length))
    }

    /// Restyles the lines `range` touches (as a whole), with the lines just before and after it.
    fileprivate func restyle(_ range: NSRange) {
        guard let storage = textStorage else { return }
        let s = storage.string as NSString
        var r = s.paragraphRange(for: NSRange(location: min(range.location, s.length), length: min(range.length, s.length - min(range.location, s.length))))
        if r.location > 0 { r = NSUnionRange(r, s.paragraphRange(for: NSRange(location: r.location - 1, length: 0))) }
        if NSMaxRange(r) < s.length { r = NSUnionRange(r, s.paragraphRange(for: NSRange(location: NSMaxRange(r), length: 0))) }

        // Whether the first line restyled is inside a code block: count the fences above it.
        var inCode = Self.countFences(s, before: r.location) % 2 == 1
        storage.beginEditing()
        var at = r.location
        repeat {
            let line = s.paragraphRange(for: NSRange(location: at, length: 0))
            var content = line
            if content.length > 0, s.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            let text = s.substring(with: content)
            let parsed = NoteMarkup.parse(text, inCode: inCode, first: line.location == 0)
            if parsed.kind == .fence { inCode.toggle() }
            style(line: line, content: content, parsed: parsed, in: storage)
            at = NSMaxRange(line)
        } while at < NSMaxRange(r)
        storage.endEditing()
        needsDisplay = true
    }

    private func style(line: NSRange, content: NSRange, parsed: MarkupLine, in storage: NSTextStorage) {
        let t = typography
        var font = t.font()
        var color = theme.ink
        var para = paragraph()
        storage.removeAttribute(.noteDecoration, range: line)
        storage.removeAttribute(.link, range: line)
        storage.removeAttribute(.strikethroughStyle, range: line)
        storage.removeAttribute(.backgroundColor, range: line)
        storage.removeAttribute(.cursor, range: line)
        storage.removeAttribute(.kern, range: line)

        let prefix = NSRange(location: content.location, length: min(parsed.prefix, content.length))
        let marker = NSRange(location: content.location + parsed.indent, length: max(0, prefix.length - parsed.indent))
        let rest = NSRange(location: NSMaxRange(prefix), length: content.length - prefix.length)
        /// Wrapped lines line up with the text, not the marker.
        func hang(_ font: NSFont) -> NSParagraphStyle {
            let width = (storage.attributedSubstring(from: prefix).string as NSString).size(withAttributes: [.font: font]).width
            return paragraph { $0.headIndent = width.rounded() }
        }

        switch parsed.kind {
        case .title:
            font = t.font(scale: 1.6, weight: .bold)
            para = paragraph { $0.paragraphSpacing = (t.size * 0.6).rounded(); $0.lineHeightMultiple = 1.05 }
        case .heading(let level):
            let scales: [CGFloat] = [1.45, 1.25, 1.1, 1.0, 1.0, 0.95]
            font = t.font(scale: scales[min(level, 6) - 1], weight: level <= 2 ? .bold : .semibold)
            para = paragraph {
                $0.paragraphSpacingBefore = line.location == 0 ? 0 : (t.size * 0.55).rounded()
                $0.lineHeightMultiple = 1.1
            }
        case .code, .fence:
            font = t.mono()
            para = paragraph { $0.lineHeightMultiple = 1.15; $0.paragraphSpacing = 0 }
        case .quote:
            font = t.font(italic: true)
            color = theme.secondary
            para = paragraph { $0.headIndent = (t.size * 1.1).rounded(); $0.firstLineHeadIndent = 0 }
        default:
            break
        }
        storage.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: line)

        switch parsed.kind {
        case .title, .plain, .blank:
            break
        case .heading:
            storage.addAttributes([.foregroundColor: theme.faint, .font: t.font(scale: 0.8, weight: .semibold)], range: prefix)
        case .bullet:
            storage.addAttributes([.foregroundColor: NSColor.clear, .noteDecoration: Decoration.bullet.rawValue], range: marker)
            storage.addAttribute(.paragraphStyle, value: hang(font), range: line)
        case .task(let done):
            let box = NSRange(location: marker.location, length: marker.length)
            storage.addAttributes([.foregroundColor: NSColor.clear,
                                   .noteDecoration: (done ? Decoration.taskDone : .taskOpen).rawValue,
                                   .cursor: NSCursor.pointingHand], range: box)
            storage.addAttribute(.paragraphStyle, value: hang(font), range: line)
            if done, rest.length > 0 {
                storage.addAttributes([.foregroundColor: theme.secondary,
                                       .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .strikethroughColor: theme.secondary.withAlphaComponent(0.6)], range: rest)
            }
        case .numbered:
            storage.addAttributes([.foregroundColor: theme.secondary,
                                   .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium)], range: marker)
            storage.addAttribute(.paragraphStyle, value: hang(font), range: line)
        case .quote:
            storage.addAttributes([.foregroundColor: NSColor.clear, .noteDecoration: Decoration.quote.rawValue], range: marker)
        case .rule:
            storage.addAttributes([.foregroundColor: NSColor.clear, .noteDecoration: Decoration.rule.rawValue], range: content)
        case .fence:
            storage.addAttributes([.foregroundColor: theme.faint, .noteDecoration: Decoration.code.rawValue], range: line)
            return
        case .code:
            storage.addAttribute(.noteDecoration, value: Decoration.code.rawValue, range: line)
            return
        }

        // Inline: **bold**, *italic*, `code`, ~~struck~~, ==marked==, and links.
        let s = storage.string as NSString
        for span in NoteMarkup.spans(in: s, range: rest) {
            switch span.kind {
            case .bold:
                storage.enumerateAttribute(.font, in: span.inner) { value, r, _ in
                    if let f = value as? NSFont { storage.addAttribute(.font, value: Typography.bold(f), range: r) }
                }
            case .italic:
                storage.enumerateAttribute(.font, in: span.inner) { value, r, _ in
                    if let f = value as? NSFont { storage.addAttribute(.font, value: Typography.italic(f), range: r) }
                }
            case .code:
                storage.addAttributes([.font: t.mono(scale: 0.88 * font.pointSize / t.size), .backgroundColor: theme.codeBackground], range: span.range)
            case .strike:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.secondary], range: span.inner)
            case .mark:
                storage.addAttribute(.backgroundColor, value: theme.markBackground, range: span.inner)
            }
            if span.kind != .code {
                let left = NSRange(location: span.range.location, length: span.inner.location - span.range.location)
                let right = NSRange(location: NSMaxRange(span.inner), length: NSMaxRange(span.range) - NSMaxRange(span.inner))
                storage.addAttribute(.foregroundColor, value: theme.faint, range: left)
                storage.addAttribute(.foregroundColor, value: theme.faint, range: right)
            }
        }
        if let detector = Self.linkDetector, rest.length > 0 {
            for match in detector.matches(in: s as String, range: rest) {
                if let url = match.url { storage.addAttribute(.link, value: url, range: match.range) }
            }
        }
    }

    static func countFences(_ s: NSString, before end: Int? = nil) -> Int {
        let limit = end ?? s.length
        var count = 0
        var at = 0
        while at < limit {
            let found = s.range(of: "```", options: [], range: NSRange(location: at, length: limit - at))
            if found.location == NSNotFound { break }
            // Only at the start of a line (after its indent).
            var i = found.location - 1
            while i >= 0, s.character(at: i) == 32 || s.character(at: i) == 9 { i -= 1 }
            if i < 0 || s.character(at: i) == 10 { count += 1 }
            let lineEnd = s.range(of: "\n", options: [], range: NSRange(location: found.location, length: s.length - found.location))
            at = lineEnd.location == NSNotFound ? limit : lineEnd.location + 1
        }
        return count
    }

    // MARK: Drawing what the marks stand for

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Code blocks first, a rounded panel behind each run of code lines.
        var codeRect: NSRect?
        func flushCode() {
            guard let r = codeRect else { return }
            let panel = NSRect(x: origin.x - 8, y: r.minY - 2, width: tc.size.width - 2 * tc.lineFragmentPadding + 16 + 2 * tc.lineFragmentPadding,
                               height: r.height + 4)
            theme.codeBackground.setFill()
            NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()
            codeRect = nil
        }
        storage.enumerateAttribute(.noteDecoration, in: chars) { value, range, _ in
            guard let raw = value as? String, let kind = Decoration(rawValue: raw) else { return }
            if kind == .code {
                lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { frag, _, _, _, _ in
                    let r = frag.offsetBy(dx: origin.x, dy: origin.y)
                    if let c = codeRect, abs(c.maxY - r.minY) < 1 { codeRect = c.union(r) } else { flushCode(); codeRect = r }
                }
                return
            }
            flushCode()
            draw(kind, range, lm: lm, tc: tc, origin: origin)
        }
        flushCode()
    }

    private func draw(_ kind: Decoration, _ range: NSRange, lm: NSLayoutManager, tc: NSTextContainer, origin: NSPoint) {
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        var box = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: origin.x, dy: origin.y)
        let frag = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
        let font = (textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? typography.font()
        // The middle of the text's x-height, on the line's baseline.
        let baseline = frag.minY + lm.typesetter.baselineOffset(in: lm, glyphIndex: glyphs.location)
        let midY = baseline - font.xHeight / 2
        switch kind {
        case .bullet:
            let d = max(4, (font.pointSize * 0.32).rounded())
            let level = max(0, Int((box.minX - frag.minX) / max(1, font.pointSize * 1.5)))
            let dot = NSRect(x: box.minX + 1, y: midY - d / 2, width: d, height: d)
            theme.secondary.setFill()
            theme.secondary.setStroke()
            if level % 2 == 1 {
                let p = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                p.lineWidth = 1.2
                p.stroke()
            } else {
                NSBezierPath(ovalIn: dot).fill()
            }
        case .taskOpen, .taskDone:
            let side = (font.pointSize * 0.95).rounded()
            box = NSRect(x: box.minX + 1, y: midY - side / 2, width: side, height: side)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: side * 0.28, yRadius: side * 0.28)
            if kind == .taskDone {
                theme.accent.setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + side * 0.26, y: box.minY + side * 0.52))
                tick.line(to: NSPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.70))
                tick.line(to: NSPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.32))
                tick.lineWidth = max(1.5, side * 0.12)
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                (theme.isDark ? theme.background : NSColor.white).setStroke()
                tick.stroke()
            } else {
                path.lineWidth = 1.4
                theme.secondary.withAlphaComponent(0.8).setStroke()
                path.stroke()
            }
        case .quote:
            let bar = NSRect(x: box.minX + 1, y: frag.minY + 2, width: 3, height: frag.height - 4)
            theme.accent.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        case .rule:
            let y = (frag.midY).rounded() + 0.5
            let line = NSRect(x: origin.x + tc.lineFragmentPadding, y: y, width: tc.size.width - 2 * tc.lineFragmentPadding, height: 1)
            theme.rule.setFill()
            line.fill()
        case .code:
            break
        }
    }

    /// The box a task's "[ ]" is drawn as, if `point` is on one: the range of its "[ ]".
    private func checkbox(at point: NSPoint) -> NSRange? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        guard let raw = storage.attribute(.noteDecoration, at: index, effectiveRange: &range) as? String,
              raw == Decoration.taskOpen.rawValue || raw == Decoration.taskDone.rawValue else { return nil }
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
        guard rect.insetBy(dx: -3, dy: -3).contains(p) else { return nil }
        return range
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, !event.modifierFlags.contains(.shift), let box = checkbox(at: point) {
            toggleTask(atLineOf: box.location, keepSelection: true)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Commands

    /// The line holding `location` (without its break).
    func lineRange(at location: Int) -> NSRange {
        let s = string as NSString
        var r = s.lineRange(for: NSRange(location: min(location, s.length), length: 0))
        if r.length > 0, s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return r
    }

    /// The lines the selection touches (without the last break; a selection ending at the start
    /// of a line doesn't take that line).
    func selectedLines() -> NSRange {
        let s = string as NSString
        var sel = selectedRange()
        if sel.length > 0, s.character(at: NSMaxRange(sel) - 1) == 10 { sel.length -= 1 }
        var r = s.lineRange(for: sel)
        if r.length > 0, s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return r
    }

    func toggleTask(atLineOf location: Int, keepSelection: Bool) {
        let line = lineRange(at: location)
        let old = (string as NSString).substring(with: line)
        let new = NoteEditing.toggledTask(old)
        let selection = selectedRange()
        replace(line, with: new, select: false)
        if keepSelection {
            setSelectedRange(selection)
        } else {
            // The caret stays where it was in the text, moved by what the marker added.
            let delta = (new as NSString).length - (old as NSString).length
            setSelectedRange(NSRange(location: max(line.location, selection.location + delta), length: 0))
        }
    }

    /// ⌘↩: ticks the task the caret is on (or every task selected), or makes the line one.
    @objc func toggleTasks(_ sender: Any?) {
        let lines = selectedLines()
        let s = string as NSString
        let text = s.substring(with: lines)
        if !text.contains("\n") {
            toggleTask(atLineOf: selectedRange().location, keepSelection: false)
            return
        }
        let out = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : NoteEditing.toggledTask($0) }
        replace(lines, with: out.joined(separator: "\n"), select: true)
    }

    /// Wraps the selection in `mark` ("**"), or takes it off when it's there; at a caret, puts in
    /// a pair with the caret between.
    func wrap(_ mark: String) {
        let s = string as NSString
        let sel = selectedRange()
        let m = (mark as NSString).length
        if sel.length == 0 {
            replace(sel, with: mark + mark, select: false)
            setSelectedRange(NSRange(location: sel.location + m, length: 0))
            return
        }
        let inner = s.substring(with: sel)
        if inner.hasPrefix(mark), inner.hasSuffix(mark), sel.length >= 2 * m {
            replace(sel, with: String(inner.dropFirst(mark.count).dropLast(mark.count)), select: true)
            return
        }
        if sel.location >= m, NSMaxRange(sel) + m <= s.length,
           s.substring(with: NSRange(location: sel.location - m, length: m)) == mark,
           s.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == mark {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: inner, select: true)
            return
        }
        replace(sel, with: mark + inner + mark, select: false)
        setSelectedRange(NSRange(location: sel.location + m, length: sel.length))
    }

    @objc func makeBold(_ sender: Any?) { wrap("**") }
    @objc func makeItalic(_ sender: Any?) { wrap("*") }
    @objc func makeCode(_ sender: Any?) { wrap("`") }
    @objc func makeStruck(_ sender: Any?) { wrap("~~") }
    @objc func makeMarked(_ sender: Any?) { wrap("==") }

    /// ⌘1 to ⌘3: the line a heading of that level (⌘0: plain text again); the same again takes it off.
    @objc func makeHeading(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 1
        let line = lineRange(at: selectedRange().location)
        let s = string as NSString
        let text = s.substring(with: line)
        let parsed = NoteMarkup.parse(text, inCode: false, first: false)
        let body = String(decoding: Array(text.utf16).dropFirst(parsed.prefix), as: UTF16.self)
        var new = body
        if case .heading(let current) = parsed.kind, current == level {
            new = body
        } else if level > 0 {
            new = String(repeating: "#", count: level) + " " + body
        }
        replace(line, with: new, select: false)
    }

    @objc func indentLines(_ sender: Any?) { shiftLines(deeper: true) }
    @objc func outdentLines(_ sender: Any?) { shiftLines(deeper: false) }

    private func shiftLines(deeper: Bool) {
        let lines = selectedLines()
        let s = string as NSString
        let text = s.substring(with: lines)
        let out = text.components(separatedBy: "\n").map { deeper ? NoteEditing.indented($0) : NoteEditing.outdented($0) }.joined(separator: "\n")
        guard out != text else { return }
        let sel = selectedRange()
        replace(lines, with: out, select: false)
        if sel.length > 0 || text.contains("\n") {
            setSelectedRange(NSRange(location: lines.location, length: (out as NSString).length))
        } else {
            let delta = (out as NSString).length - (text as NSString).length
            setSelectedRange(NSRange(location: max(lines.location, sel.location + delta), length: 0))
        }
    }

    // MARK: Keys

    /// Return carries a list on (or ends it); Tab and ⇧Tab nest list lines; Esc puts the note away.
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            guard !hasMarkedText(), selectedRange().length == 0 else { return false }
            let caret = selectedRange().location
            let line = lineRange(at: caret)
            let s = string as NSString
            // Not in a code block: there Return keeps the indent only.
            if Self.countFences(s, before: line.location) % 2 == 1 {
                let text = s.substring(with: line)
                let indent = String(text.prefix { $0 == " " || $0 == "\t" })
                insertText("\n" + indent, replacementRange: selectedRange())
                return true
            }
            let text = s.substring(with: line)
            let before = s.substring(with: NSRange(location: line.location, length: caret - line.location))
            switch NoteEditing.newline(line: text, before: before) {
            case .plain:
                return false
            case .continueWith(let prefix):
                insertText("\n" + prefix, replacementRange: selectedRange())
                return true
            case .endList(let replacement):
                replace(line, with: replacement, select: false)
                return true
            }
        case #selector(insertTab(_:)):
            guard !hasMarkedText() else { return false }
            let line = (string as NSString).substring(with: lineRange(at: selectedRange().location))
            if selectedRange().length > 0 || NoteMarkup.parse(line, inCode: false, first: false).kind.isListItem {
                shiftLines(deeper: true)
                return true
            }
            insertText(NoteEditing.indentUnit, replacementRange: selectedRange())
            return true
        case #selector(insertBacktab(_:)):
            shiftLines(deeper: false)
            return true
        case #selector(cancelOperation(_:)):
            if let scroll = enclosingScrollView, scroll.isFindBarVisible {
                scroll.isFindBarVisible = false
            } else {
                onEscape?()
            }
            return true
        default:
            return false
        }
    }

    // Only plain text comes in (pasted or dropped): the look is the note's own.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string, .URL, .fileURL] }

    // ⌘-click (or a plain click) on a link opens it.
    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Keeping track of edits

extension NoteTextView {
    /// The text storage's and text view's delegate: a separate object, so none of its methods can
    /// meet one of NSTextView's own.
    final class Relay: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
        weak var view: NoteTextView?

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            view?.noteEdit(editedRange, delta: delta)
        }

        func textDidChange(_ notification: Notification) { view?.afterChange() }

        func textViewDidChangeSelection(_ notification: Notification) { view?.afterSelectionChange() }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            view?.handle(commandSelector) ?? false
        }
    }

    fileprivate func noteEdit(_ editedRange: NSRange, delta: Int) {
        pendingEdit = pendingEdit.map { old in
            // The earlier edit, moved by this one when it's after it.
            let moved = old.location >= editedRange.location ? NSRange(location: max(0, old.location + delta), length: old.length) : old
            return NSUnionRange(moved, editedRange)
        } ?? editedRange
    }

    fileprivate func afterChange() {
        guard !hasMarkedText(), let storage = textStorage else {
            onChange?(string)
            return
        }
        let fences = Self.countFences(storage.string as NSString)
        if fences != fenceCount {
            fenceCount = fences
            restyle(NSRange(location: 0, length: storage.length))
        } else if let edit = pendingEdit {
            let clamped = NSIntersectionRange(edit, NSRange(location: 0, length: storage.length))
            restyle(NSRange(location: min(edit.location, storage.length), length: clamped.length))
        }
        pendingEdit = nil
        typingAttributes = baseAttributes()
        onChange?(string)
    }

    fileprivate func afterSelectionChange() {
        var attributes = baseAttributes()
        let at = selectedRange().location
        if let storage = textStorage, at > 0, at <= storage.length,
           storage.attribute(.noteDecoration, at: at - 1, effectiveRange: nil) == nil,
           let font = storage.attribute(.font, at: at - 1, effectiveRange: nil) as? NSFont {
            // Type on in the look of the text before the caret, but never invisible or a link.
            attributes[.font] = font
        }
        typingAttributes = attributes
        onSelectionChange?(selectedRange())
    }
}
