import AnyShortcutCore
import AppKit
import UniformTypeIdentifiers

@MainActor
enum PathDrop {
    static func accept(_ providers: [NSItemProvider], into model: AppModel) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard model.canEdit, !files.isEmpty else { return false }
        Task { await add(files, into: model) }
        return true
    }

    static func add(_ providers: [NSItemProvider], into model: AppModel) async {
        // Load in order so a multiple-item drop retains its insertion order.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard model.canEdit else { return }
            do {
                let data = try await fileURLData(from: provider)
                guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                    model.recordLog("Ignored a drop that did not contain a file or folder path.", level: .warning)
                    continue
                }
                _ = model.saveSnippet(text: url.path)
            } catch {
                model.recordLog("Couldn’t read a dropped path: \(error.localizedDescription)", level: .error)
            }
        }
    }

    private static func fileURLData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
