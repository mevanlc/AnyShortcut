import AnyShortcutCore
import AppKit
import SwiftUI
import Testing
@testable import AnyShortcut

private struct LogTestShortcuts: ShortcutsClient {
    func fetchShortcuts() async throws -> [ShortcutDescriptor] { [] }
    func runShortcut(id: String, input: ShortcutInput) async throws {}
}

@MainActor
private final class LogTestStore: StateStore {
    func load() throws -> AppState { AppState() }
    func save(_ state: AppState) throws {}
}

@MainActor
struct LogPresentationTests {
    @Test func newErrorsRevealAClosedDrawerButInformationAndWarningsDoNot() async throws {
        let suite = "AnyShortcut-log-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "showsLogDrawer")
        let model = AppModel(store: LogTestStore(), client: LogTestShortcuts())
        let host = NSHostingView(rootView: ContentView(model: model).defaultAppStorage(defaults))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(logScroll(in: host) == nil)

        model.recordLog("Information")
        model.recordLog("Warning", level: .warning)
        try await Task.sleep(for: .milliseconds(50))
        #expect(logScroll(in: host) == nil)
        model.recordLog("An error opens the log", level: .error)
        let scroll = try #require(await waitForLog(in: host))
        #expect((scroll.documentView as? NSTextView)?.string.contains("An error opens the log") == true)
        #expect(defaults.bool(forKey: "showsLogDrawer"))
    }

    @Test func startupErrorsRevealADrawerThatWasPreviouslyHidden() async throws {
        let suite = "AnyShortcut-log-startup-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "showsLogDrawer")
        let model = AppModel(store: LogTestStore(), client: LogTestShortcuts())
        for index in 1...60 { model.recordLog("Earlier message \(index)") }
        model.recordLog("Startup error", level: .error)
        let host = NSHostingView(rootView: ContentView(model: model).defaultAppStorage(defaults))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let scroll = try #require(await waitForLog(in: host))
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(text.string.contains("Startup error"))
        #expect(scroll.contentView.bounds.maxY >= text.bounds.maxY - 2)
    }

    private func waitForLog(in host: NSView) async throws -> NSScrollView? {
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if let scroll = logScroll(in: host), let text = scroll.documentView as? NSTextView, !text.string.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
                return scroll
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func logScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.accessibilityIdentifier() == "logDrawer" { return scroll }
        return view.subviews.lazy.compactMap { logScroll(in: $0) }.first
    }
}
