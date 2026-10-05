import AppKit
import Foundation
import ScriptingBridge

public protocol ShortcutsClient: Sendable {
    func fetchShortcuts() async throws -> [ShortcutDescriptor]
    func runShortcut(id: String, input: ShortcutInput) async throws
}

public enum ShortcutsError: Error, LocalizedError, Equatable, Sendable {
    case notAvailable
    case permissionDenied
    case missingShortcut
    case invalidResponse
    case fileUnavailable(String)
    case eventFailed(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            "Shortcuts Events is unavailable. Make sure the Shortcuts app is installed."
        case .permissionDenied:
            "Allow AnyShortcut to control Shortcuts Events in System Settings → Privacy & Security → Automation, then retry."
        case .missingShortcut:
            "This shortcut is no longer in My Shortcuts. Add its replacement using the + button."
        case .invalidResponse:
            "Shortcuts Events returned an incomplete response. Please retry."
        case let .fileUnavailable(path):
            "Couldn’t prepare the file or folder at \(path). Make sure it still exists and is accessible."
        case let .eventFailed(_, message):
            message
        }
    }
}

extension ShortcutInput {
    func appleEventValue() throws -> Any {
        switch self {
        case let .text(text):
            return text as NSString
        case let .file(url):
            // Shortcuts Events rejects file-URL ('furl') input. An AppleScript
            // alias ('alis') is recognized as a file or folder by its input parser.
            guard let alias = NSAppleEventDescriptor(fileURL: url).coerce(toDescriptorType: typeAlias) else {
                throw ShortcutsError.fileUnavailable(url.path)
            }
            return alias
        }
    }
}

@objc private protocol EventsApplication {
    @objc optional var shortcuts: SBElementArray { get }
}

@objc private protocol EventsShortcut: NSObjectProtocol {
    @objc optional var name: String { get }
    @objc optional var icon: NSImage { get }
    @objc optional func id() -> String
    @objc optional var folder: SBObject? { get }
    @objc(runWithInput:) optional func run(withInput input: Any?) -> Any?
}

@objc private protocol EventsFolder {
    @objc optional var name: String { get }
}

extension SBApplication: EventsApplication {}
extension SBObject: EventsShortcut, EventsFolder {}

private final class EventErrors: NSObject, SBApplicationDelegate {
    var error: NSError?

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        self.error = error as NSError
        return nil
    }

    func check() throws {
        guard let error else { return }
        let code = (error.userInfo["ErrorNumber"] as? NSNumber)?.intValue ?? error.code
        switch code {
        case -1743:
            throw ShortcutsError.permissionDenied
        case -1728:
            throw ShortcutsError.missingShortcut
        default:
            let message = (error.userInfo["ErrorString"] as? String)
                ?? (error.userInfo["ErrorBriefMessage"] as? String) ?? error.localizedDescription
            throw ShortcutsError.eventFailed(code: code, message: message)
        }
    }
}

// ScriptingBridge references and delegate state are used only on this serial queue.
// Only Sendable value types cross the asynchronous interface.
public final class ScriptingBridgeShortcutsClient: ShortcutsClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mevanlc.AnyShortcut.scripting", qos: .userInitiated)
    private let errors = EventErrors()
    private var application: SBApplication?

    public init() {}

    public func fetchShortcuts() async throws -> [ShortcutDescriptor] {
        try await perform { try self.readShortcuts() }
    }

    public func runShortcut(id: String, input: ShortcutInput) async throws {
        try await perform {
            let application = try self.connect()
            let bridge: EventsApplication = application
            guard let elements = bridge.shortcuts,
                  let shortcut = elements.object(withID: id) as? EventsShortcut else {
                try self.errors.check()
                throw ShortcutsError.missingShortcut
            }
            // object(withID:) can return a lazy reference even after deletion.
            let actualID = shortcut.id?()
            try self.errors.check()
            guard actualID == id else { throw ShortcutsError.missingShortcut }
            guard shortcut.responds(to: #selector(EventsShortcut.run(withInput:))) else {
                throw ShortcutsError.notAvailable
            }

            let previousTimeout = application.timeout
            application.timeout = Int(kNoTimeOut)
            defer { application.timeout = previousTimeout }
            _ = shortcut.run?(withInput: try input.appleEventValue())
            // A nil output is valid; only the delegate indicates a failed event.
            try self.errors.check()
        }
    }

    private func connect() throws -> SBApplication {
        errors.error = nil
        if let application { return application }
        guard let application = SBApplication(bundleIdentifier: "com.apple.shortcuts.events"),
              application.responds(to: #selector(getter: EventsApplication.shortcuts)) else {
            throw ShortcutsError.notAvailable
        }
        application.delegate = errors
        self.application = application
        return application
    }

    private func readShortcuts() throws -> [ShortcutDescriptor] {
        let application = try connect()
        let bridge: EventsApplication = application
        guard let elements = bridge.shortcuts else {
            try errors.check()
            throw ShortcutsError.invalidResponse
        }
        // Fetch names and IDs in bulk rather than sending two events per shortcut.
        let rawIDs = elements.array(byApplying: #selector(EventsShortcut.id))
        try errors.check()
        let rawNames = elements.array(byApplying: #selector(getter: EventsShortcut.name))
        try errors.check()
        guard let ids = rawIDs as? [String], let names = rawNames as? [String], ids.count == names.count,
              ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw ShortcutsError.invalidResponse
        }
        let rawIcons = elements.array(byApplying: #selector(getter: EventsShortcut.icon))
        try errors.check()
        let icons = rawIcons as? [NSImage] ?? []
        let duplicateNames = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }
        var result: [ShortcutDescriptor] = []
        for (index, (id, name)) in zip(ids, names).enumerated() {
            var folderName: String?
            if duplicateNames[name] != nil,
               let shortcut = elements.object(withID: id) as? EventsShortcut {
                if let folder = shortcut.folder ?? nil {
                    let bridgeFolder: EventsFolder = folder
                    folderName = bridgeFolder.name
                }
                try errors.check()
            }
            // Encode on the scripting queue; only value data crosses to the UI.
            let iconData = icons.indices.contains(index)
                ? icons[index].tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                    .representation(using: .png, properties: [:])
                : nil
            result.append(ShortcutDescriptor(id: id, name: name, folderName: folderName, iconData: iconData))
        }
        return result.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
