import SwiftUI
import MatchaKit

@main
struct MatchaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    if NSApp.windows.contains(where: { $0.isVisible }) {
                        guard let editor = MatchaEditor.activeEditor else { return }
                        NotificationCenter.default.post(name: .matchaNewFile, object: editor)
                    } else {
                        // No window open — create one via SwiftUI's built-in action
                        NSApp.sendAction(#selector(AppDelegate.newWindowAction), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open...") {
                    if !NSApp.windows.contains(where: { $0.isVisible }) {
                        NSApp.sendAction(#selector(AppDelegate.openFileAction), to: nil, from: nil)
                    } else {
                        guard let editor = MatchaEditor.activeEditor else { return }
                        NotificationCenter.default.post(name: .matchaOpenFile, object: editor)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    guard let editor = MatchaEditor.activeEditor else { return }
                    NotificationCenter.default.post(name: .matchaSaveFile, object: editor)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As...") {
                    guard let editor = MatchaEditor.activeEditor else { return }
                    NotificationCenter.default.post(name: .matchaSaveAsFile, object: editor)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("Editor") {
                Button("Toggle Comment") {
                    MatchaEditor.activeEditor?.toggleComment()
                }
                .keyboardShortcut("/", modifiers: .command)

                Button("Duplicate Line") {
                    MatchaEditor.activeEditor?.duplicateLine()
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("Move Line Up") {
                    MatchaEditor.activeEditor?.moveLineUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

                Button("Move Line Down") {
                    MatchaEditor.activeEditor?.moveLineDown()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Divider()

                Button("Go to Line...") {
                    guard let editor = MatchaEditor.activeEditor else { return }
                    NotificationCenter.default.post(name: .matchaGoToLine, object: editor)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingFilePath: String? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        matcha_init()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindowAction()
        }
        return true
    }

    @objc func newWindowAction() {
        // Ask SwiftUI to open a new WindowGroup window
        if #available(macOS 13.0, *) {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
    }

    @objc func openFileAction() {
        // Show file dialog first, then open the file in a new window
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        AppDelegate.pendingFilePath = url.path
        newWindowAction()
    }
}

extension Notification.Name {
    static let matchaNewFile = Notification.Name("matchaNewFile")
    static let matchaOpenFile = Notification.Name("matchaOpenFile")
    static let matchaSaveFile = Notification.Name("matchaSaveFile")
    static let matchaSaveAsFile = Notification.Name("matchaSaveAsFile")
    static let matchaToggleFind = Notification.Name("matchaToggleFind")
    static let matchaFindNext = Notification.Name("matchaFindNext")
    static let matchaFindPrev = Notification.Name("matchaFindPrev")
    static let matchaGoToLine = Notification.Name("matchaGoToLine")
}
