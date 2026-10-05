import AnyShortcutCore
import SwiftUI

struct SnippetEditor: View {
    let snippet: Snippet?
    let save: (String) -> Bool
    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(snippet: Snippet?, save: @escaping (String) -> Bool) {
        self.snippet = snippet
        self.save = save
        _text = State(initialValue: snippet?.text ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(snippet == nil ? "Add Thing" : "Edit Thing").font(.headline)
            TextField("Text or file/folder path", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(saveAndDismiss)
                .accessibilityIdentifier("snippetText")
            Text("Enter one line of text, or an existing /path or ~/path.")
                .font(.caption).foregroundStyle(.secondary)
            if !text.isEmpty && !Snippet.isValid(text) {
                Text("Enter a nonblank single line.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: saveAndDismiss)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Snippet.isValid(text))
            }
        }
        .padding(20).frame(width: 460)
        .task { focused = true }
    }

    private func saveAndDismiss() {
        if Snippet.isValid(text), save(text) { dismiss() }
    }
}

struct ShortcutPicker: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    private var filteredShortcuts: [ShortcutDescriptor] {
        guard !search.isEmpty else { return model.availableShortcuts }
        return model.availableShortcuts.filter {
            $0.name.localizedStandardContains(search)
                || ($0.folderName?.localizedStandardContains(search) ?? false)
        }
    }

    private var canAdd: Bool {
        guard let selection else { return false }
        return !model.isRefreshing && model.canEdit
            && model.availableShortcuts.contains { $0.id == selection }
            && !model.state.shortcuts.contains { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("My Shortcuts").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.refreshShortcuts() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isRefreshing || model.isRunning)
                    .help("Refresh My Shortcuts").accessibilityLabel("Refresh My Shortcuts")
            }
            TextField("Search My Shortcuts", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("shortcutSearch")
            List(selection: $selection) {
                ForEach(filteredShortcuts) { shortcut in
                    HStack(spacing: 10) {
                        ShortcutIcon(data: shortcut.iconData)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.name).lineLimit(1)
                            if model.availableShortcuts.filter({ $0.name == shortcut.name }).count > 1 {
                                Text(shortcutDetail(folder: shortcut.folderName, id: shortcut.id))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if model.state.shortcuts.contains(where: { $0.id == shortcut.id }) {
                            Label("Added", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(shortcut.id)
                }
            }
            .listStyle(.inset).border(.quaternary)
            .accessibilityIdentifier("shortcutPickerList")
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { selected in
                if let id = selected.first { selection = id; addAndDismiss() }
            }
            .overlay {
                if filteredShortcuts.isEmpty && !model.isRefreshing {
                    Text(search.isEmpty ? "No shortcuts available" : "No matching shortcuts")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: addAndDismiss)
                    .keyboardShortcut(.defaultAction).disabled(!canAdd)
            }
        }
        .padding(20).frame(width: 480, height: 440)
        .task { await model.refreshShortcuts() }
    }

    private func addAndDismiss() {
        if canAdd, let selection, model.addShortcut(id: selection) { dismiss() }
    }
}
