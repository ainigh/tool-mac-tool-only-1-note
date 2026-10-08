import Foundation

/// How the note looks and behaves, kept in settings.json beside the note. Every field has a
/// default, so a file from an older (or newer) version still reads.
public struct NoteSettings: Codable, Equatable {
    public enum Theme: String, Codable, CaseIterable, Identifiable {
        case auto, light, paper, dark, night
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .auto: return "Match the Mac"
            case .light: return "Light"
            case .paper: return "Paper"
            case .dark: return "Dark"
            case .night: return "Night"
            }
        }
    }

    public enum Typeface: String, Codable, CaseIterable, Identifiable {
        case system, rounded, serif, mono
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: return "System"
            case .rounded: return "Rounded"
            case .serif: return "Serif"
            case .mono: return "Mono"
            }
        }
    }

    public var fontSize: Double = 15
    public var typeface: Typeface = .system
    public var theme: Theme = .auto
    public var lineSpacing: Double = 1.25
    /// Lines no wider than a comfortable column, centred, however wide the window.
    public var readableWidth = true
    public var spellCheck = true
    /// The panel stays up when you click elsewhere (and floats over other windows).
    public var pinned = false
    /// ⌥⌘N, anywhere, shows or hides the note.
    public var hotKey = true
    /// The panel's size.
    public var width: Double = 560
    public var height: Double = 640
    /// The plugins turned on or off by hand (by id); the rest are as they come (`onByDefault`).
    public var plugins: [String: Bool] = [:]

    public static let fontSizes: ClosedRange<Double> = 11...28
    public static let minSize = (width: 360.0, height: 320.0)

    public init() {}

    public func isOn(_ plugin: NotePlugin) -> Bool { plugins[plugin.id] ?? plugin.onByDefault }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NoteSettings()
        fontSize = min(max(c.value(.fontSize, or: d.fontSize), Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        typeface = c.value(.typeface, or: d.typeface)
        theme = c.value(.theme, or: d.theme)
        lineSpacing = min(max(c.value(.lineSpacing, or: d.lineSpacing), 1), 2)
        readableWidth = c.value(.readableWidth, or: d.readableWidth)
        spellCheck = c.value(.spellCheck, or: d.spellCheck)
        pinned = c.value(.pinned, or: d.pinned)
        hotKey = c.value(.hotKey, or: d.hotKey)
        width = max(c.value(.width, or: d.width), Self.minSize.width)
        height = max(c.value(.height, or: d.height), Self.minSize.height)
        plugins = c.value(.plugins, or: d.plugins)
    }

    public static func load(from url: URL) -> NoteSettings {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(NoteSettings.self, from: data) else {
            return NoteSettings()
        }
        return s
    }

    public func save(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(self).write(to: url, options: .atomic)
    }
}

private extension KeyedDecodingContainer {
    /// The value under `key`, or `fallback` when it's missing or isn't one.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
