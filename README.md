# AnyShortcut

A small macOS app for running your shortcuts with saved files or folders as input.

The **Paths** panel stores existing file and folder paths. The **Shortcuts** panel stores shortcuts you choose from **My Shortcuts**. Select one item in each panel and click **Run**, or press **⌘R**. Running, completion, and error messages appear in the log; the shortcut handles its own output.

## Build and install

Requires macOS 14 or later and Xcode's Swift 6 toolchain. There are no third-party dependencies.

```sh
swift build
swift test
./macDeployToApplications
open /Applications/AnyShortcut.app
```

The deployment script builds a release app at `.build/AnyShortcut.app` and installs it in `/Applications`. Quit AnyShortcut before deploying an update. Signing uses the first available Apple Development identity, or ad hoc signing if none exists. Set `CODE_SIGN_IDENTITY` to choose another identity. Set `ANYSHORTCUT_APPLICATIONS_DIR` to install somewhere else.

On first use, allow AnyShortcut to control **Shortcuts Events**. If access is denied, enable it in **System Settings → Privacy & Security → Automation**, then click **Retry My Shortcuts** in the log drawer. The app runs shortcuts through ScriptingBridge without opening the Shortcuts editor. Individual shortcuts may show their own dialogs or permission requests.

## Using the lists

- Drag files or folders into the **Paths** list, or use the left **+** to browse for one. You can drop several items at once; their paths are saved and additions are logged. Double-click a path, press Return with it selected, or choose **Choose Replacement…** from its context menu to browse for a replacement.
- Folders show Finder folder icons; files show `doc.text.fill`. Paths and their icons are rescanned every second, at startup, when the app or a window gains or loses focus, and after editing the list. Missing paths are automatically removed from the saved list, their selection is cleared, and each removal is logged.
- Use the right **+** to search My Shortcuts and add a shortcut. Shortcut IDs prevent duplicate additions and preserve references across renames.
- Shortcut icons appear beside their names in the saved list and picker. Icons are cached with the saved shortcuts and updated when My Shortcuts refreshes.
- Use **−** to remove the selected list entry. Removing a path leaves the actual file or folder untouched; removing a saved shortcut leaves the shortcut in My Shortcuts.
- Lists retain insertion order. Missing shortcuts remain listed with a warning; add their replacements using **+**.

Shortcuts refresh on launch, when the app becomes active, and when the picker opens. A failed refresh preserves the last successfully loaded library. Only one shortcut can run at a time, and this version has no cancellation control.

The top bar always says “Select one path and one shortcut, then press Run.” The button at the bottom right shows or hides the scrollable log drawer. Drag the divider above the drawer to resize it. Messages are appended for additions, removals, runs, and errors. New messages scroll into view while the scrollbar is at the bottom. Scrolling up pauses following; scrolling back to the bottom resumes it. Errors automatically open the drawer and scroll to the bottom, even while reading earlier messages. Recovery buttons appear in the drawer when needed. The drawer’s visibility is remembered, and messages last for the current app session.

## Input rules

The app currently accepts only existing file and folder paths. They are passed as file references using Apple-event alias descriptors. Shortcuts Events rejects ordinary file-URL descriptors for this input. The selected path is checked again immediately before running, so a missing path cannot be sent as text. The app does not read file contents into text or expand shell variables, wildcards, or quotes. Shortcuts may interpret a text file’s contents as text when it imports the file.

A shortcut receiving file input must be configured to accept files or any input.

Plain-text addition, editing, icons, persistence, and execution remain implemented. `AnyShortcutApp` sets `supportsPlainText: false`; setting it to `true` re-enables the text editor and Things panel. Previously saved plain-text entries are retained but hidden in path-only mode. With text enabled, the resolver recognizes existing `/path` and `~/path` entries as files and sends other entries as their original text.

## Saved data

Both lists and current selections are saved automatically to:

```text
~/Library/Application Support/AnyShortcut/state.json
```

Writes are atomic. If saved data cannot be loaded, the app blocks editing and leaves the file untouched. Repair or restore that file, then click **Retry Loading** in the log drawer. If a change cannot be saved, the previous state stays in effect and the error is logged.

The Swift package separates the SwiftUI app from `AnyShortcutCore`, which contains persistence, input resolution, application state, and the asynchronous Shortcuts service.
