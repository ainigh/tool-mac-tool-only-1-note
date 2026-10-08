import AppKit
import NoteCore
import SwiftUI

/// The note's colors and type, from the settings (and, for "Match the Mac", the Mac's appearance).
struct Theme: Equatable {
    var background: NSColor
    var ink: NSColor
    /// Labels, the footer, done tasks.
    var secondary: NSColor
    /// Markdown's marks ("#", "**"), dimmed.
    var faint: NSColor
    var accent: NSColor
    var codeBackground: NSColor
    var markBackground: NSColor
    var rule: NSColor
    var isDark: Bool

    static func resolve(_ choice: NoteSettings.Theme, appearance: NSAppearance = NSApp.effectiveAppearance) -> Theme {
        switch choice {
        case .auto:
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? .dark : .light
        case .light: return .light
        case .paper: return .paper
        case .dark: return .dark
        case .night: return .night
        }
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static let light = Theme(
        background: rgb(0.995, 0.995, 0.99), ink: rgb(0.11, 0.11, 0.12), secondary: rgb(0.45, 0.45, 0.48),
        faint: rgb(0.70, 0.70, 0.73), accent: rgb(0.16, 0.42, 0.92), codeBackground: rgb(0.94, 0.94, 0.95),
        markBackground: rgb(1.0, 0.89, 0.40, 0.55), rule: rgb(0.86, 0.86, 0.88), isDark: false)

    static let paper = Theme(
        background: rgb(0.98, 0.962, 0.915), ink: rgb(0.18, 0.15, 0.12), secondary: rgb(0.50, 0.45, 0.39),
        faint: rgb(0.74, 0.69, 0.61), accent: rgb(0.78, 0.40, 0.12), codeBackground: rgb(0.94, 0.91, 0.84),
        markBackground: rgb(1.0, 0.82, 0.35, 0.5), rule: rgb(0.86, 0.82, 0.74), isDark: false)

    static let dark = Theme(
        background: rgb(0.118, 0.118, 0.13), ink: rgb(0.90, 0.90, 0.91), secondary: rgb(0.60, 0.60, 0.63),
        faint: rgb(0.40, 0.40, 0.43), accent: rgb(0.40, 0.62, 1.0), codeBackground: rgb(0.17, 0.17, 0.19),
        markBackground: rgb(0.95, 0.75, 0.20, 0.35), rule: rgb(0.25, 0.25, 0.28), isDark: true)

    static let night = Theme(
        background: rgb(0.055, 0.067, 0.094), ink: rgb(0.80, 0.84, 0.89), secondary: rgb(0.50, 0.56, 0.64),
        faint: rgb(0.30, 0.35, 0.42), accent: rgb(0.36, 0.80, 0.76), codeBackground: rgb(0.09, 0.11, 0.15),
        markBackground: rgb(0.36, 0.80, 0.76, 0.25), rule: rgb(0.17, 0.20, 0.26), isDark: true)

    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

/// The note's fonts in the chosen typeface.
struct Typography: Equatable {
    var typeface: NoteSettings.Typeface
    var size: CGFloat

    func font(scale: CGFloat = 1, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let size = (self.size * scale).rounded()
        var font: NSFont
        switch typeface {
        case .mono:
            font = .monospacedSystemFont(ofSize: size, weight: weight)
        case .system:
            font = .systemFont(ofSize: size, weight: weight)
        case .rounded, .serif:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let design: NSFontDescriptor.SystemDesign = typeface == .rounded ? .rounded : .serif
            font = base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
        if italic {
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: d, size: size) ?? font
        }
        return font
    }

    /// The same font, bold (keeping its size and italics).
    static func bold(_ font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.bold))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    static func italic(_ font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    func mono(scale: CGFloat = 0.9) -> NSFont {
        .monospacedSystemFont(ofSize: (size * scale).rounded(), weight: .regular)
    }
}
