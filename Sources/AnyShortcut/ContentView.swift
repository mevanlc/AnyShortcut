import AnyShortcutCore
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private struct SnippetDraft: Identifiable {
    let id = UUID()
    let snippet: Snippet?
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var snippetDraft: SnippetDraft?
    @State private var showsShortcutPicker = false
    @State private var isPathsDropTargeted = false
    @AppStorage("showsLogDrawer") private var showsLogDrawer = true
    private let pathRescanTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Select one path and one shortcut, then press Run.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button {
                    Task { await model.runSelectedShortcut() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(minWidth: 76)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canRun)
                .accessibilityIdentifier("runShortcut")
            }
            .padding(14)
            .frame(minHeight: 64)

            Divider()
            VSplitView {
                HSplitView {
                    thingsPanel.frame(minWidth: 250)
                    shortcutsPanel.frame(minWidth: 250)
                }
                .frame(minHeight: 210)
                if showsLogDrawer {
                    logPanel
                        .frame(minHeight: 100, idealHeight: 160, maxHeight: 300)
                }
            }
        }
        .sheet(item: $snippetDraft) { draft in
            SnippetEditor(snippet: draft.snippet) { text in
                model.saveSnippet(id: draft.snippet?.id, text: text)
            }
        }
        .sheet(isPresented: $showsShortcutPicker) {
            ShortcutPicker(model: model)
        }
        .onChange(of: model.logEntries.last(where: { $0.level == .error })?.id, initial: true) { _, errorID in
            if errorID != nil { showsLogDrawer = true }
        }
        .task { await model.refreshShortcuts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.rescanSnippetPaths()
            Task { await model.refreshShortcuts() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.rescanSnippetPaths()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.rescanSnippetPaths()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            model.rescanSnippetPaths()
        }
        .onReceive(pathRescanTimer) { _ in model.rescanSnippetPaths() }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.loadError != nil {
                    Button("Retry Loading") { model.reloadState() }
                }
                if model.libraryError != nil {
                    Button("Retry My Shortcuts") { Task { await model.refreshShortcuts() } }
                        .disabled(model.isRefreshing || model.isRunning)
                }
                if model.needsAutomationPermission {
                    Button("Open Automation Settings", action: openAutomationSettings)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 6)
            LogDrawer(entries: model.logEntries)
        }
    }

    private var thingsPanel: some View {
        VStack(spacing: 0) {
            panelHeading(model.supportsPlainText ? "Things" : "Paths")
            List(selection: Binding(get: { model.state.selectedSnippetID }, set: model.selectSnippet)) {
                ForEach(model.displayedSnippets) { snippet in
                    HStack(spacing: 10) {
                        SnippetIcon(isFolder: model.existingFolderIDs.contains(snippet.id))
                        Text(snippet.text).lineLimit(1)
                    }
                    .help(snippet.text)
                    .tag(snippet.id)
                    .accessibilityIdentifier("path-\(snippet.id)")
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier(model.supportsPlainText ? "thingsList" : "pathsList")
            .contextMenu(forSelectionType: UUID.self) { selection in
                if let id = selection.first {
                    Button(model.supportsPlainText ? "Edit…" : "Choose Replacement…") { editSnippet(id: id) }
                        .disabled(!model.canEdit)
                    Button("Remove") { model.removeSnippet(id: id) }.disabled(!model.canEdit)
                }
            } primaryAction: { selection in
                if let id = selection.first { editSnippet(id: id) }
            }
            .onKeyPress(.return) {
                guard let id = model.state.selectedSnippetID else { return .ignored }
                editSnippet(id: id)
                return .handled
            }
            .overlay {
                if model.displayedSnippets.isEmpty {
                    Text(model.supportsPlainText
                         ? "Add a thing using +, or drop files and folders here."
                         : "Use + or drop files and folders here.")
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .allowsHitTesting(false)
                }
                if isPathsDropTargeted && model.canEdit {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) }
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isPathsDropTargeted) { providers in
                PathDrop.accept(providers, into: model)
            }
            panelControls(
                addLabel: model.supportsPlainText ? "Add Thing" : "Add Path",
                removeLabel: model.supportsPlainText ? "Remove Thing" : "Remove Path",
                canRemove: model.canEdit && model.displayedSnippets.contains { $0.id == model.state.selectedSnippetID },
                add: {
                    if model.supportsPlainText { snippetDraft = SnippetDraft(snippet: nil) }
                    else { choosePath() }
                },
                remove: {
                    if let id = model.state.selectedSnippetID { model.removeSnippet(id: id) }
                }
            )
        }
    }

    private var shortcutsPanel: some View {
        VStack(spacing: 0) {
            panelHeading("Shortcuts")
            List(selection: Binding(get: { model.state.selectedShortcutID }, set: model.selectShortcut)) {
                ForEach(model.state.shortcuts) { shortcut in
                    HStack(spacing: 10) {
                        ShortcutIcon(data: shortcut.iconData)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.name).lineLimit(1)
                            if model.state.shortcuts.filter({ $0.name == shortcut.name }).count > 1 {
                                Text(shortcutDetail(folder: shortcut.folderName, id: shortcut.id))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if model.isUnavailable(shortcut) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .help("This shortcut is no longer in My Shortcuts.")
                        }
                    }
                    .tag(shortcut.id)
                    .help(shortcut.name)
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("shortcutsList")
            .contextMenu(forSelectionType: String.self) { selection in
                if let id = selection.first {
                    Button("Remove") { model.removeShortcut(id: id) }.disabled(!model.canEdit)
                }
            }
            .overlay {
                if model.state.shortcuts.isEmpty {
                    Text("Add a shortcut using +").foregroundStyle(.tertiary).allowsHitTesting(false)
                }
            }
            panelControls(
                addLabel: "Add Shortcut", removeLabel: "Remove Shortcut",
                canRemove: model.canEdit && model.state.selectedShortcutID != nil,
                showsLogToggle: true,
                add: { showsShortcutPicker = true },
                remove: {
                    if let id = model.state.selectedShortcutID { model.removeShortcut(id: id) }
                }
            )
        }
    }

    private func panelHeading(_ title: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func panelControls(
        addLabel: String, removeLabel: String, canRemove: Bool, showsLogToggle: Bool = false,
        add: @escaping () -> Void, remove: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button(action: add) { Image(systemName: "plus").frame(width: 36, height: 30) }
                    .disabled(!model.canEdit)
                    .help(addLabel).accessibilityLabel(addLabel)
                Divider().frame(height: 20)
                Button(action: remove) { Image(systemName: "minus").frame(width: 36, height: 30) }
                    .disabled(!canRemove)
                    .help(removeLabel).accessibilityLabel(removeLabel)
                Spacer(minLength: 0)
                if showsLogToggle {
                    Divider().frame(height: 20)
                    Button { showsLogDrawer.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showsLogDrawer ? "chevron.up" : "chevron.down")
                            Image(systemName: "text.alignleft")
                        }
                        .frame(width: 48, height: 30)
                    }
                    .help(showsLogDrawer ? "Hide Log" : "Show Log")
                    .accessibilityLabel(showsLogDrawer ? "Hide Log" : "Show Log")
                    .accessibilityIdentifier("toggleLogDrawer")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
    }

    private func editSnippet(id: UUID) {
        guard model.canEdit, let snippet = model.state.snippets.first(where: { $0.id == id }) else { return }
        if model.supportsPlainText { snippetDraft = SnippetDraft(snippet: snippet) }
        else { choosePath(replacing: id) }
    }

    private func choosePath(replacing id: UUID? = nil) {
        guard model.canEdit else { return }
        let panel = NSOpenPanel()
        panel.title = id == nil ? "Add Path" : "Replace Path"
        panel.message = "Choose an existing file or folder."
        panel.prompt = id == nil ? "Add" : "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if let id, let snippet = model.state.snippets.first(where: { $0.id == id }),
           let url = InputResolver.pathURL(snippet.text) {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            _ = model.saveSnippet(id: id, text: url.path)
        }
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct SnippetIcon: View {
    let isFolder: Bool

    var body: some View {
        Group {
            if isFolder {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.text.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

struct ShortcutIcon: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

func shortcutDetail(folder: String?, id: String) -> String {
    let suffix = String(id.suffix(8))
    return folder.map { "\($0) · \(suffix)" } ?? suffix
}
