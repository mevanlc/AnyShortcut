import Foundation
import Observation

public enum RunStatus: Equatable {
    case idle
    case running(String)
    case finished(String)
    case failed(String)
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var state = AppState()
    public private(set) var existingPathIDs: Set<UUID> = []
    public private(set) var existingFolderIDs: Set<UUID> = []
    public private(set) var logEntries: [LogEntry] = []
    public let supportsPlainText: Bool
    public private(set) var availableShortcuts: [ShortcutDescriptor] = []
    public private(set) var hasLoadedLibrary = false
    public private(set) var isRefreshing = false
    public private(set) var isRunning = false
    public private(set) var libraryError: String?
    public private(set) var needsAutomationPermission = false
    public private(set) var loadError: String?
    public private(set) var runStatus: RunStatus = .idle

    @ObservationIgnored private let store: any StateStore
    @ObservationIgnored private let client: any ShortcutsClient

    public init(store: any StateStore, client: any ShortcutsClient, supportsPlainText: Bool = true) {
        self.store = store
        self.client = client
        self.supportsPlainText = supportsPlainText
        reloadState()
    }

    public var canEdit: Bool { loadError == nil }

    public var canRun: Bool {
        guard !isRunning, !isRefreshing, canEdit, let snippet = selectedSnippet,
              availableShortcuts.contains(where: { $0.id == state.selectedShortcutID }) else { return false }
        return supportsPlainText || existingPathIDs.contains(snippet.id)
    }

    public var displayedSnippets: [Snippet] {
        supportsPlainText ? state.snippets : state.snippets.filter { existingPathIDs.contains($0.id) }
    }

    public var selectedSnippet: Snippet? {
        state.snippets.first { $0.id == state.selectedSnippetID }
    }

    public func isUnavailable(_ shortcut: SavedShortcut) -> Bool {
        hasLoadedLibrary && !availableShortcuts.contains { $0.id == shortcut.id }
    }

    public func rescanSnippetPaths() {
        var paths: Set<UUID> = []
        var folders: Set<UUID> = []
        for snippet in state.snippets {
            if case let .file(url) = InputResolver.resolve(snippet.text) {
                paths.insert(snippet.id)
                if url.hasDirectoryPath { folders.insert(snippet.id) }
            }
        }
        if paths != existingPathIDs { existingPathIDs = paths }
        if folders != existingFolderIDs { existingFolderIDs = folders }
        guard !supportsPlainText, canEdit else { return }
        let missing = state.snippets.filter {
            InputResolver.pathURL($0.text) != nil && !paths.contains($0.id)
        }
        guard !missing.isEmpty else { return }
        let missingIDs = Set(missing.map(\.id))
        var next = state
        next.snippets.removeAll { missingIDs.contains($0.id) }
        next.clearInvalidSelections()
        if commit(next, rescanPaths: false) {
            for snippet in missing {
                recordLog("Automatically removed missing path: \(snippet.text)", level: .warning)
            }
        }
    }

    public func reloadState() {
        do {
            state = try store.load()
            loadError = nil
            recordLog("Loaded saved paths and shortcuts.")
            rescanSnippetPaths()
        } catch {
            loadError = "Saved lists couldn’t be opened: \(error.localizedDescription) Repair the saved data, then retry."
            recordLog(loadError!, level: .error)
        }
    }

    @discardableResult
    public func saveSnippet(id: UUID? = nil, text: String) -> Bool {
        guard canEdit, Snippet.isValid(text) else { return false }
        if !supportsPlainText, case .text = InputResolver.resolve(text) {
            recordLog("Couldn’t add path because it does not exist: \(text)", level: .warning)
            return false
        }
        var next = state
        if let id {
            guard let index = next.snippets.firstIndex(where: { $0.id == id }) else { return false }
            next.snippets[index].text = text
            next.selectedSnippetID = id
        } else {
            let snippet = Snippet(text: text)
            next.snippets.append(snippet)
            next.selectedSnippetID = snippet.id
        }
        guard commit(next) else { return false }
        recordLog("\(id == nil ? "Added" : "Updated") \(supportsPlainText ? "thing" : "path"): \(text)")
        return true
    }

    public func removeSnippet(id: UUID) {
        guard let snippet = state.snippets.first(where: { $0.id == id }) else { return }
        var next = state
        next.snippets.removeAll { $0.id == id }
        next.clearInvalidSelections()
        if commit(next) { recordLog("Removed \(supportsPlainText ? "thing" : "path"): \(snippet.text)") }
    }

    @discardableResult
    public func addShortcut(id: String) -> Bool {
        guard let shortcut = availableShortcuts.first(where: { $0.id == id }),
              !state.shortcuts.contains(where: { $0.id == id }) else { return false }
        var next = state
        next.shortcuts.append(SavedShortcut(shortcut))
        next.selectedShortcutID = id
        guard commit(next) else { return false }
        recordLog("Added shortcut: \(shortcut.name)")
        return true
    }

    public func removeShortcut(id: String) {
        guard let shortcut = state.shortcuts.first(where: { $0.id == id }) else { return }
        var next = state
        next.shortcuts.removeAll { $0.id == id }
        next.clearInvalidSelections()
        if commit(next) { recordLog("Removed shortcut: \(shortcut.name)") }
    }

    public func selectSnippet(_ id: UUID?) {
        var next = state
        next.selectedSnippetID = id
        next.clearInvalidSelections()
        if next != state { _ = commit(next) }
    }

    public func selectShortcut(_ id: String?) {
        var next = state
        next.selectedShortcutID = id
        next.clearInvalidSelections()
        if next != state { _ = commit(next) }
    }

    public func refreshShortcuts() async {
        guard !isRefreshing, !isRunning else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let shortcuts = try await client.fetchShortcuts()
            let shouldLogLoad = !hasLoadedLibrary || libraryError != nil
            availableShortcuts = shortcuts
            hasLoadedLibrary = true
            libraryError = nil
            needsAutomationPermission = false
            let byID = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })
            var next = state
            next.shortcuts = state.shortcuts.map { saved in
                guard let current = byID[saved.id] else { return saved }
                var updated = SavedShortcut(current)
                updated.iconData = current.iconData ?? saved.iconData
                return updated
            }
            if next != state { _ = commit(next) }
            if shouldLogLoad { recordLog("Loaded \(shortcuts.count) shortcuts from My Shortcuts.") }
        } catch {
            if libraryError != error.localizedDescription {
                recordLog("Couldn’t load My Shortcuts: \(error.localizedDescription)", level: .error)
            }
            libraryError = error.localizedDescription
            needsAutomationPermission = (error as? ShortcutsError) == .permissionDenied
        }
    }

    public func runSelectedShortcut() async {
        guard canRun, let snippet = selectedSnippet,
              let shortcut = state.shortcuts.first(where: { $0.id == state.selectedShortcutID }) else { return }
        let input = InputResolver.resolve(snippet.text)
        if !supportsPlainText, case .text = input {
            rescanSnippetPaths()
            return
        }
        isRunning = true
        runStatus = .running(shortcut.name)
        recordLog("Running \(shortcut.name) with \(snippet.text)")
        defer { isRunning = false }
        do {
            try await client.runShortcut(id: shortcut.id, input: input)
            runStatus = .finished(shortcut.name)
            recordLog("Finished \(shortcut.name).")
        } catch {
            runStatus = .failed(error.localizedDescription)
            recordLog("\(shortcut.name) failed: \(error.localizedDescription)", level: .error)
            if (error as? ShortcutsError) == .missingShortcut {
                availableShortcuts.removeAll { $0.id == shortcut.id }
            } else if (error as? ShortcutsError) == .permissionDenied {
                needsAutomationPermission = true
                libraryError = error.localizedDescription
            }
        }
    }

    public func recordLog(_ message: String, level: LogLevel = .info) {
        logEntries.append(LogEntry(message: message, level: level))
    }

    @discardableResult
    private func commit(_ next: AppState, rescanPaths: Bool = true) -> Bool {
        guard canEdit else { return false }
        do {
            try store.save(next)
            let snippetsChanged = next.snippets != state.snippets
            state = next
            if snippetsChanged && rescanPaths { rescanSnippetPaths() }
            return true
        } catch {
            let message = "Changes couldn’t be saved: \(error.localizedDescription)"
            if logEntries.last?.message != message { recordLog(message, level: .error) }
            return false
        }
    }
}
