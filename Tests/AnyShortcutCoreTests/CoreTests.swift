import Foundation
import ScriptingBridge
import Testing
@testable import AnyShortcutCore

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}

// Match the client's serialized Apple-event operations when exercising coercion.
@Suite(.serialized)
struct AppleEventInputTests {
    @Test func encodesExistingPathsAsAppleEventAliases() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let file = directory.url.appendingPathComponent("unicode é and spaces.txt")
        try Data("file contents".utf8).write(to: file)
        for url in [directory.url, file] {
            let encoded = try ShortcutInput.file(url).appleEventValue()
            let descriptor = try #require(encoded as? NSAppleEventDescriptor)
            #expect(descriptor.descriptorType == typeAlias)
            #expect(descriptor.fileURLValue?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
        }
        let text = "  Hello World  "
        #expect(try ShortcutInput.text(text).appleEventValue() as? NSString == text as NSString)
    }

    @Test func reportsPathsDeletedBeforeEncoding() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let missing = directory.url.appendingPathComponent("missing.txt")
        #expect(throws: ShortcutsError.fileUnavailable(missing.path)) {
            try ShortcutInput.file(missing).appleEventValue()
        }
    }
}

struct InputTests {
    @Test func preservesLiteralText() {
        for text in ["Hello World", " leading and trailing ", "Documents/file.txt", "https://example.com", "$HOME/file", "~", "\"/tmp/file\""] {
            #expect(InputResolver.resolve(text) == .text(text))
        }
    }

    @Test func resolvesFilesAndFoldersAtRunTime() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let file = directory.url.appendingPathComponent("hello world.txt")
        try Data("file contents".utf8).write(to: file)
        #expect(InputResolver.resolve(file.path) == .file(file))
        #expect(InputResolver.resolve(directory.url.path) == .file(directory.url))
        #expect(InputResolver.resolve("~/hello world.txt", homeDirectory: directory.url) == .file(file))
        #expect(InputResolver.resolve("~/", homeDirectory: directory.url) == .file(directory.url))

        let missingPath = directory.url.appendingPathComponent("missing.txt").path
        #expect(InputResolver.resolve(missingPath) == .text(missingPath))
        try FileManager.default.removeItem(at: file)
        #expect(InputResolver.resolve(file.path) == .text(file.path))
        #expect(InputResolver.resolve("~/hello world.txt", homeDirectory: directory.url) == .text("~/hello world.txt"))
    }

    @Test func validatesOneLineWithoutChangingWhitespace() {
        #expect(Snippet.isValid("  hello  "))
        for text in ["", " \t ", "one\ntwo", "one\rtwo", "one\u{2028}two"] {
            #expect(!Snippet.isValid(text))
        }
    }
}

@MainActor
struct PersistenceTests {
    @Test func roundTripRetainsOrderIdentityAndSelections() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let store = JSONStateStore(fileURL: directory.url.appendingPathComponent("nested/state.json"))
        #expect(try store.load() == AppState())
        let first = Snippet(text: "Hello World")
        let second = Snippet(text: " Hello World ")
        let state = AppState(
            snippets: [first, second],
            shortcuts: [SavedShortcut(id: "b", name: "Same", iconData: Data([1, 2, 3])), SavedShortcut(id: "a", name: "Same")],
            selectedSnippetID: second.id, selectedShortcutID: "a"
        )
        try store.save(state)
        #expect(try store.load() == state)
        var next = state
        next.snippets.removeFirst()
        try store.save(next)
        #expect(try store.load() == next)
    }

    @Test func clearsStaleSelections() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let store = JSONStateStore(fileURL: directory.url.appendingPathComponent("state.json"))
        try store.save(AppState(selectedSnippetID: UUID(), selectedShortcutID: "deleted"))
        #expect(try store.load() == AppState())
    }

    @Test func loadsSavedShortcutsWithoutCachedIcons() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let store = JSONStateStore(fileURL: directory.url.appendingPathComponent("state.json"))
        let data = Data(#"{"snippets":[],"shortcuts":[{"id":"one","name":"Original"}],"selectedShortcutID":"one"}"#.utf8)
        try data.write(to: store.fileURL)
        let state = try store.load()
        #expect(state.shortcuts == [SavedShortcut(id: "one", name: "Original")])
        #expect(state.selectedShortcutID == "one")
    }

    @Test func rejectsCorruptionWithoutReplacingIt() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let store = JSONStateStore(fileURL: directory.url.appendingPathComponent("state.json"))
        let data = Data("not json".utf8)
        try data.write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.fileURL) == data)

        let snippet = Snippet(text: "duplicate identity")
        try store.save(AppState(snippets: [snippet, snippet]))
        #expect(throws: CocoaError.self) { try store.load() }
    }
}

@MainActor
private final class MemoryStore: StateStore {
    var saved: AppState
    var failsLoading = false
    var failsSaving = false

    init(_ state: AppState = AppState()) { saved = state }

    func load() throws -> AppState {
        if failsLoading { throw CocoaError(.fileReadCorruptFile) }
        return saved
    }

    func save(_ state: AppState) throws {
        if failsSaving { throw CocoaError(.fileWriteNoPermission) }
        saved = state
    }
}

private actor FakeShortcuts: ShortcutsClient {
    var shortcuts = [ShortcutDescriptor(id: "one", name: "Original")]
    var fetchError: ShortcutsError?
    var runError: ShortcutsError?
    var runs: [(id: String, input: ShortcutInput)] = []
    var holdRun = false
    private var completion: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func setShortcuts(_ shortcuts: [ShortcutDescriptor]) { self.shortcuts = shortcuts }
    func setFetchError(_ error: ShortcutsError?) { fetchError = error }
    func setRunError(_ error: ShortcutsError?) { runError = error }
    func holdNextRun() { holdRun = true }

    func fetchShortcuts() async throws -> [ShortcutDescriptor] {
        if let fetchError { throw fetchError }
        return shortcuts
    }

    func runShortcut(id: String, input: ShortcutInput) async throws {
        runs.append((id, input))
        if holdRun {
            await withCheckedContinuation { continuation in
                completion = continuation
                startWaiters.forEach { $0.resume() }
                startWaiters.removeAll()
            }
        }
        if let runError { throw runError }
    }

    func waitUntilRunning() async {
        guard completion == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishRun() {
        holdRun = false
        completion?.resume()
        completion = nil
    }
}

@MainActor
struct PathOnlyTests {
    @Test func acceptsFilesAndFoldersWhileKeepingSavedTextDormant() async throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let file = directory.url.appendingPathComponent("input.txt")
        try Data("contents".utf8).write(to: file)
        let text = Snippet(text: "Saved text")
        let store = MemoryStore(AppState(snippets: [text], selectedSnippetID: text.id))
        let client = FakeShortcuts()
        let model = AppModel(store: store, client: client, supportsPlainText: false)
        await model.refreshShortcuts()
        #expect(model.addShortcut(id: "one"))
        #expect(model.displayedSnippets.isEmpty)
        #expect(!model.canRun)
        #expect(!model.saveSnippet(text: "New text"))
        #expect(!model.saveSnippet(text: directory.url.appendingPathComponent("missing").path))
        #expect(model.saveSnippet(text: directory.url.path))
        #expect(model.saveSnippet(text: file.path))
        #expect(model.displayedSnippets.map(\.text) == [directory.url.path, file.path])
        await model.runSelectedShortcut()
        let runs = await client.runs
        #expect(runs.first?.input == .file(file))
        #expect(store.saved.snippets.contains(text))
        let textEnabled = AppModel(store: store, client: client)
        #expect(textEnabled.displayedSnippets.contains(text))
    }

    @Test func removesAndLogsPathsThatDisappearedBeforeStartup() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let file = directory.url.appendingPathComponent("gone.txt")
        try Data("contents".utf8).write(to: file)
        let path = Snippet(text: file.path)
        let text = Snippet(text: "Saved text")
        let store = MemoryStore(AppState(snippets: [text, path], selectedSnippetID: path.id))
        try FileManager.default.removeItem(at: file)
        let model = AppModel(store: store, client: FakeShortcuts(), supportsPlainText: false)
        #expect(model.state.snippets == [text])
        #expect(store.saved == model.state)
        #expect(model.state.selectedSnippetID == nil)
        #expect(model.logEntries.contains { $0.message.contains("Automatically removed") && $0.message.contains(file.path) })
        let count = model.logEntries.count
        model.rescanSnippetPaths()
        #expect(model.logEntries.count == count)
    }

    @Test func rechecksBeforeRunAndRemovesDisappearingFilesAndFolders() async throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let folder = directory.url.appendingPathComponent("folder", isDirectory: true)
        let file = directory.url.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("contents".utf8).write(to: file)
        let store = MemoryStore()
        let client = FakeShortcuts()
        let model = AppModel(store: store, client: client, supportsPlainText: false)
        await model.refreshShortcuts()
        #expect(model.addShortcut(id: "one"))
        #expect(model.saveSnippet(text: folder.path))
        #expect(model.saveSnippet(text: file.path))
        #expect(model.canRun)
        try FileManager.default.removeItem(at: file)
        await model.runSelectedShortcut()
        let runs = await client.runs
        #expect(runs.isEmpty)
        #expect(model.displayedSnippets.map(\.text) == [folder.path])
        #expect(model.state.selectedSnippetID == nil)
        try FileManager.default.removeItem(at: folder)
        model.rescanSnippetPaths()
        #expect(store.saved.snippets.isEmpty)
        #expect(model.logEntries.filter { $0.message.contains("Automatically removed") }.count == 2)
    }

    @Test func retriesFailedAutomaticRemovalWithoutClaimingSuccessOrRepeatingErrors() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let file = directory.url.appendingPathComponent("gone.txt")
        try Data("contents".utf8).write(to: file)
        let store = MemoryStore()
        let model = AppModel(store: store, client: FakeShortcuts(), supportsPlainText: false)
        #expect(model.saveSnippet(text: file.path))
        let before = store.saved
        store.failsSaving = true
        try FileManager.default.removeItem(at: file)
        model.rescanSnippetPaths()
        model.rescanSnippetPaths()
        #expect(store.saved == before)
        #expect(model.state == before)
        #expect(!model.logEntries.contains { $0.message.contains("Automatically removed") })
        #expect(model.logEntries.filter { $0.message.contains("Changes couldn’t be saved") }.count == 1)
        store.failsSaving = false
        model.rescanSnippetPaths()
        #expect(store.saved.snippets.isEmpty)
        #expect(model.logEntries.contains { $0.message.contains("Automatically removed") })
    }
}

@MainActor
struct ModelTests {
    @Test func rescansPathsWithoutChangingSavedSnippets() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let path = directory.url.appendingPathComponent("appearing.txt")
        let text = Snippet(text: "Hello World")
        let folder = Snippet(text: directory.url.path)
        let file = Snippet(text: path.path)
        let original = AppState(snippets: [text, folder, file], selectedSnippetID: text.id)
        let store = MemoryStore(original)
        let model = AppModel(store: store, client: FakeShortcuts())
        #expect(model.existingPathIDs == [folder.id])
        #expect(model.existingFolderIDs == [folder.id])

        try Data("contents".utf8).write(to: path)
        model.rescanSnippetPaths()
        #expect(model.existingPathIDs == [folder.id, file.id])
        #expect(model.existingFolderIDs == [folder.id])
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        model.rescanSnippetPaths()
        #expect(model.existingPathIDs == [folder.id, file.id])
        #expect(model.existingFolderIDs == [folder.id, file.id])
        try FileManager.default.removeItem(at: path)
        model.rescanSnippetPaths()
        #expect(model.existingPathIDs == [folder.id])
        #expect(model.existingFolderIDs == [folder.id])
        #expect(model.state == original)
        #expect(store.saved == original)

        #expect(model.saveSnippet(id: file.id, text: directory.url.path))
        #expect(model.existingPathIDs == [folder.id, file.id])
        #expect(model.existingFolderIDs == [folder.id, file.id])
        #expect(model.saveSnippet(id: file.id, text: "literal text"))
        #expect(model.existingPathIDs == [folder.id])
        #expect(model.existingFolderIDs == [folder.id])
        model.removeSnippet(id: folder.id)
        #expect(model.existingPathIDs.isEmpty)
        #expect(model.existingFolderIDs.isEmpty)
    }

    @Test func editsAndSelectionsPersistIndependently() async {
        let store = MemoryStore()
        let client = FakeShortcuts()
        let model = AppModel(store: store, client: client)
        await model.refreshShortcuts()
        #expect(model.saveSnippet(text: "  first  "))
        let firstID = model.state.selectedSnippetID!
        #expect(model.saveSnippet(text: "second"))
        #expect(model.addShortcut(id: "one"))
        #expect(!model.addShortcut(id: "one"))
        model.selectSnippet(firstID)
        #expect(model.state.selectedShortcutID == "one")
        #expect(model.saveSnippet(id: firstID, text: "edited"))
        #expect(model.state.snippets.map(\.text) == ["edited", "second"])
        #expect(model.canRun)
        let relaunched = AppModel(store: store, client: client)
        #expect(relaunched.state == model.state)
        model.removeShortcut(id: "one")
        #expect(model.state.selectedSnippetID == firstID)
        #expect(!model.canRun)
    }

    @Test func refreshUsesIDsAndPreservesMissingEntriesAndFailedCatalog() async {
        let store = MemoryStore(AppState(shortcuts: [SavedShortcut(id: "one", name: "Original")]))
        let client = FakeShortcuts()
        let model = AppModel(store: store, client: client)
        let iconData = Data([1, 2, 3])
        await client.setShortcuts([ShortcutDescriptor(id: "one", name: "Renamed", iconData: iconData)])
        await model.refreshShortcuts()
        #expect(model.state.shortcuts.first?.name == "Renamed")
        #expect(store.saved.shortcuts.first?.name == "Renamed")
        #expect(store.saved.shortcuts.first?.iconData == iconData)
        await client.setShortcuts([ShortcutDescriptor(id: "one", name: "Renamed", iconData: Data([4, 5, 6]))])
        await model.refreshShortcuts()
        #expect(store.saved.shortcuts.first?.iconData == Data([4, 5, 6]))
        await client.setShortcuts([ShortcutDescriptor(id: "one", name: "Renamed")])
        await model.refreshShortcuts()
        #expect(store.saved.shortcuts.first?.iconData == Data([4, 5, 6]))
        await client.setFetchError(.permissionDenied)
        await model.refreshShortcuts()
        #expect(model.availableShortcuts.first?.name == "Renamed")
        #expect(!model.isUnavailable(model.state.shortcuts[0]))
        #expect(model.needsAutomationPermission)
        await client.setFetchError(nil)
        await client.setShortcuts([])
        await model.refreshShortcuts()
        #expect(model.state.shortcuts.count == 1)
        #expect(model.isUnavailable(model.state.shortcuts[0]))
        #expect(!model.needsAutomationPermission)
    }

    @Test func storageFailuresPreservePriorDataAndBlockUnreadableState() async {
        let store = MemoryStore()
        let model = AppModel(store: store, client: FakeShortcuts())
        #expect(model.saveSnippet(text: "kept"))
        let before = model.state
        store.failsSaving = true
        #expect(!model.saveSnippet(text: "unsaved"))
        #expect(model.state == before)
        #expect(store.saved == before)
        #expect(model.logEntries.last?.level == .error)
        #expect(model.logEntries.last?.message.contains("Changes couldn’t be saved") == true)
        store.failsSaving = false
        store.failsLoading = true
        model.reloadState()
        #expect(!model.canEdit)
        #expect(!model.saveSnippet(text: "blocked"))
        await model.refreshShortcuts()
        #expect(store.saved == before)
        store.failsLoading = false
        model.reloadState()
        #expect(model.canEdit)
        #expect(model.state == before)
    }

    @Test func runCapturesSelectionAndPreventsOverlapWithoutBlockingEdits() async {
        let store = MemoryStore()
        let client = FakeShortcuts()
        let model = AppModel(store: store, client: client)
        await model.refreshShortcuts()
        #expect(model.saveSnippet(text: "original input"))
        #expect(model.addShortcut(id: "one"))
        await client.holdNextRun()
        let run = Task { await model.runSelectedShortcut() }
        await client.waitUntilRunning()
        #expect(model.isRunning)
        #expect(!model.canRun)
        #expect(model.saveSnippet(text: "another input"))
        await model.runSelectedShortcut()
        let runs = await client.runs
        #expect(runs.count == 1)
        #expect(runs.first?.input == .text("original input"))
        await client.finishRun()
        await run.value
        #expect(model.runStatus == .finished("Original"))
        #expect(!model.isRunning)
    }

    @Test func reportsRunFailuresAndMarksDeletedShortcutUnavailable() async {
        let client = FakeShortcuts()
        let model = AppModel(store: MemoryStore(), client: client)
        await model.refreshShortcuts()
        #expect(model.saveSnippet(text: "input"))
        #expect(model.addShortcut(id: "one"))
        await client.setRunError(.eventFailed(code: -1, message: "Expected failure"))
        await model.runSelectedShortcut()
        #expect(model.runStatus == .failed("Expected failure"))
        #expect(model.canRun)
        await client.setRunError(.missingShortcut)
        await model.runSelectedShortcut()
        #expect(model.isUnavailable(model.state.shortcuts[0]))
        #expect(!model.canRun)
        #expect(model.state.shortcuts.count == 1)
    }
}
