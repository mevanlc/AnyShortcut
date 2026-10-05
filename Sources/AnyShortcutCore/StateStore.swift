import Foundation

@MainActor
public protocol StateStore {
    func load() throws -> AppState
    func save(_ state: AppState) throws
}

public struct JSONStateStore: StateStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var standard: JSONStateStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONStateStore(
            fileURL: support.appendingPathComponent("AnyShortcut", isDirectory: true)
                .appendingPathComponent("state.json")
        )
    }

    public func load() throws -> AppState {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return AppState()
        }
        var state = try JSONDecoder().decode(AppState.self, from: data)
        guard Set(state.snippets.map(\.id)).count == state.snippets.count,
              state.snippets.allSatisfy({ Snippet.isValid($0.text) }),
              Set(state.shortcuts.map(\.id)).count == state.shortcuts.count,
              state.shortcuts.allSatisfy({ !$0.id.isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        state.clearInvalidSelections()
        return state
    }

    public func save(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
