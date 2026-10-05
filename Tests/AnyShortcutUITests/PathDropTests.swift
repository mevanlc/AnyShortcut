import AnyShortcutCore
import AppKit
import Testing
import UniformTypeIdentifiers
@testable import AnyShortcut

private struct UnusedShortcuts: ShortcutsClient {
    func fetchShortcuts() async throws -> [ShortcutDescriptor] { [] }
    func runShortcut(id: String, input: ShortcutInput) async throws {}
}

@MainActor
struct PathDropTests {
    @Test func droppedFilesAndFoldersKeepTheirOrderAndPersistAsPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("unicode é and spaces.txt")
        try Data("The file contents are not the saved path.".utf8).write(to: file)
        let folder = directory.appendingPathComponent("a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = JSONStateStore(fileURL: directory.appendingPathComponent("state.json"))
        let model = AppModel(store: store, client: UnusedShortcuts(), supportsPlainText: false)

        await PathDrop.add([
            NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: folder.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier),
        ], into: model)

        #expect(model.displayedSnippets.map(\.text) == [file.path, folder.path])
        #expect(model.selectedSnippet?.text == folder.path)
        #expect(model.logEntries.filter { $0.message.hasPrefix("Added path:") }.count == 2)
        let restored = AppModel(store: store, client: UnusedShortcuts(), supportsPlainText: false)
        #expect(restored.state == model.state)
    }

    @Test func invalidDropsAreSkippedAndLoggedWithoutLosingOtherFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONStateStore(fileURL: directory.appendingPathComponent("state.json"))
        let model = AppModel(store: store, client: UnusedShortcuts(), supportsPlainText: false)
        let missing = directory.appendingPathComponent("missing.txt")
        let broken = NSItemProvider()
        broken.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadNoPermission))
            return nil
        }
        let text = NSItemProvider(item: "plain text" as NSString, typeIdentifier: UTType.plainText.identifier)
        #expect(!PathDrop.accept([text], into: model))

        await PathDrop.add([
            text,
            NSItemProvider(item: Data("https://example.com/tmp".utf8) as NSData, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: missing as NSURL, typeIdentifier: UTType.fileURL.identifier),
            broken,
            NSItemProvider(item: directory as NSURL, typeIdentifier: UTType.fileURL.identifier),
        ], into: model)

        #expect(model.displayedSnippets.map(\.text) == [directory.path])
        #expect(model.logEntries.filter { $0.level == .warning }.count == 2)
        #expect(model.logEntries.filter { $0.level == .error }.count == 1)
        #expect(try store.load() == model.state)
    }
}
