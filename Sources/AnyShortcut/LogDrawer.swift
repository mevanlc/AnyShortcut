import AnyShortcutCore
import AppKit
import SwiftUI

struct LogDrawer: NSViewRepresentable {
    let entries: [LogEntry]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView()
    }

    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityIdentifier("logDrawer")
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 12, height: 8)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("Log messages")
        text.setAccessibilityIdentifier("logMessages")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.append(entries, to: scroll)
    }

    @MainActor
    final class Coordinator {
        private var renderedCount = 0
        private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        func append(_ entries: [LogEntry], to scroll: NSScrollView) {
            guard entries.count > renderedCount, let text = scroll.documentView as? NSTextView,
                  let storage = text.textStorage else { return }
            // Inspect the position before appending so a reader who scrolled up
            // stays there; reaching the bottom naturally enables following again.
            let previousOrigin = scroll.contentView.bounds.origin
            let newEntries = entries.dropFirst(renderedCount)
            let followsTail = renderedCount == 0 || newEntries.contains { $0.level == .error }
                || scroll.contentView.bounds.maxY >= text.bounds.maxY - 2
            storage.beginEditing()
            for entry in newEntries {
                let color: NSColor
                switch entry.level {
                case .info: color = .labelColor
                case .warning: color = .systemOrange
                case .error: color = .systemRed
                }
                storage.append(NSAttributedString(
                    string: "[\(timeFormatter.string(from: entry.timestamp))] \(entry.message)\n",
                    attributes: [.font: font, .foregroundColor: color]
                ))
            }
            storage.endEditing()
            renderedCount = entries.count
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
            text.sizeToFit()
            if followsTail {
                text.scrollToEndOfDocument(nil)
                // SwiftUI can resize a newly opened drawer after this update.
                // Repeat after that layout so the newest entry remains visible.
                DispatchQueue.main.async { [weak scroll] in
                    guard let scroll, let text = scroll.documentView as? NSTextView else { return }
                    scroll.layoutSubtreeIfNeeded()
                    text.scrollToEndOfDocument(nil)
                }
            } else {
                scroll.contentView.scroll(to: previousOrigin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
}
