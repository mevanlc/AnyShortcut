import AnyShortcutCore
import AppKit
import Testing
@testable import AnyShortcut

@MainActor
struct LogDrawerTests {
    @Test func followsTheBottomPausesWhileReadingAndResumesAtTheBottom() throws {
        let scroll = LogDrawer.makeScrollView()
        scroll.frame.size = NSSize(width: 420, height: 100)
        scroll.layoutSubtreeIfNeeded()
        let text = try #require(scroll.documentView as? NSTextView)
        let coordinator = LogDrawer.Coordinator()
        var entries = (1...60).map { LogEntry(message: "Message \($0)") }
        coordinator.append(entries, to: scroll)
        #expect(text.bounds.height > scroll.contentView.bounds.height)
        #expect(scroll.contentView.bounds.maxY >= text.bounds.maxY - 2)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        let readingPosition = scroll.contentView.bounds.origin
        entries.append(LogEntry(message: "Appended while reading earlier messages"))
        coordinator.append(entries, to: scroll)
        #expect(abs(scroll.contentView.bounds.origin.y - readingPosition.y) < 1)
        #expect(scroll.contentView.bounds.maxY < text.bounds.maxY - 2)

        text.scrollToEndOfDocument(nil)
        entries.append(LogEntry(message: "Appended after returning to the bottom"))
        coordinator.append(entries, to: scroll)
        #expect(scroll.contentView.bounds.maxY >= text.bounds.maxY - 2)
        #expect(text.string.contains("Message 1\n"))
        #expect(text.string.contains("Appended after returning to the bottom"))

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        entries.append(LogEntry(message: "Warning while reading", level: .warning))
        coordinator.append(entries, to: scroll)
        #expect(abs(scroll.contentView.bounds.origin.y - 100) < 1)
        entries.append(LogEntry(message: "Error while reading", level: .error))
        entries.append(LogEntry(message: "Information after the error"))
        coordinator.append(entries, to: scroll)
        #expect(scroll.contentView.bounds.maxY >= text.bounds.maxY - 2)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        entries.append(LogEntry(message: "Reading again after the error"))
        coordinator.append(entries, to: scroll)
        #expect(abs(scroll.contentView.bounds.origin.y - 100) < 1)
    }
}
