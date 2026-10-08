// swift-tools-version:5.9
import PackageDescription

// NoteCore is the note's logic (its markup, lists, saving and history, plugins, updates): Foundation
// only, so `swift test` runs it on any machine. OnlyNote is the menu bar app around it (AppKit and
// SwiftUI), so it's only built on a Mac.
var targets: [Target] = [
    .target(name: "NoteCore"),
    .testTarget(name: "NoteCoreTests", dependencies: ["NoteCore"]),
]
#if os(macOS)
targets.append(.executableTarget(name: "OnlyNote", dependencies: ["NoteCore"]))
#endif

let package = Package(name: "OnlyNote", platforms: [.macOS(.v14)], targets: targets)
