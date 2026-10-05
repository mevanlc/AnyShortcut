import Foundation

public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }

    public static func isValid(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.rangeOfCharacter(from: .newlines) == nil
    }
}

public struct SavedShortcut: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var folderName: String?
    public var iconData: Data?

    public init(id: String, name: String, folderName: String? = nil, iconData: Data? = nil) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.iconData = iconData
    }

    public init(_ shortcut: ShortcutDescriptor) {
        self.init(id: shortcut.id, name: shortcut.name, folderName: shortcut.folderName, iconData: shortcut.iconData)
    }
}

public struct ShortcutDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let folderName: String?
    public let iconData: Data?

    public init(id: String, name: String, folderName: String? = nil, iconData: Data? = nil) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.iconData = iconData
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var snippets: [Snippet]
    public var shortcuts: [SavedShortcut]
    public var selectedSnippetID: UUID?
    public var selectedShortcutID: String?

    public init(
        snippets: [Snippet] = [], shortcuts: [SavedShortcut] = [],
        selectedSnippetID: UUID? = nil, selectedShortcutID: String? = nil
    ) {
        self.snippets = snippets
        self.shortcuts = shortcuts
        self.selectedSnippetID = selectedSnippetID
        self.selectedShortcutID = selectedShortcutID
    }

    public mutating func clearInvalidSelections() {
        if !snippets.contains(where: { $0.id == selectedSnippetID }) {
            selectedSnippetID = nil
        }
        if !shortcuts.contains(where: { $0.id == selectedShortcutID }) {
            selectedShortcutID = nil
        }
    }
}

public enum ShortcutInput: Equatable, Sendable {
    case text(String)
    case file(URL)
}

public enum InputResolver {
    public static func pathURL(
        _ text: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        if text.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(text.dropFirst(2)))
        }
        return nil
    }

    public static func resolve(
        _ text: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ShortcutInput {
        guard let candidate = pathURL(text, homeDirectory: homeDirectory) else {
            return .text(text)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return .text(text)
        }
        return .file(URL(fileURLWithPath: candidate.path, isDirectory: isDirectory.boolValue))
    }
}
