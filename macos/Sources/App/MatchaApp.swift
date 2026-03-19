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
                        NotificationCenter.default.post(name: .matchaNewFile, object: nil)
                    } else {
                        NSApp.sendAction(#selector(AppDelegate.newWindowAction), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Tab") {
                    NotificationCenter.default.post(name: .matchaNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Open...") {
                    if !NSApp.windows.contains(where: { $0.isVisible }) {
                        NSApp.sendAction(#selector(AppDelegate.openFileAction), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .matchaOpenFile, object: nil)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .matchaCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Save") {
                    NotificationCenter.default.post(name: .matchaSaveFile, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As...") {
                    NotificationCenter.default.post(name: .matchaSaveAsFile, object: nil)
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
                    NotificationCenter.default.post(name: .matchaGoToLine, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Divider()

                Button("Next Tab") {
                    NotificationCenter.default.post(name: .matchaNextTab, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    NotificationCenter.default.post(name: .matchaPrevTab, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingFilePath: String? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        matcha_init()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if let editor = MatchaEditor.activeEditor {
            // If active tab is empty, open in it; otherwise new tab
            if editor.info.filename == nil && !editor.info.modified {
                NotificationCenter.default.post(name: .matchaOpenFilePath,
                                                object: nil,
                                                userInfo: ["path": filename])
            } else {
                NotificationCenter.default.post(name: .matchaOpenFilePath,
                                                object: nil,
                                                userInfo: ["path": filename])
            }
        } else {
            AppDelegate.pendingFilePath = filename
            newWindowAction()
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindowAction()
        }
        return true
    }

    @objc func newWindowAction() {
        if #available(macOS 13.0, *) {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
    }

    @objc func openFileAction() {
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
    static let matchaNewTab = Notification.Name("matchaNewTab")
    static let matchaCloseTab = Notification.Name("matchaCloseTab")
    static let matchaNextTab = Notification.Name("matchaNextTab")
    static let matchaPrevTab = Notification.Name("matchaPrevTab")
    static let matchaOpenFile = Notification.Name("matchaOpenFile")
    static let matchaSaveFile = Notification.Name("matchaSaveFile")
    static let matchaSaveAsFile = Notification.Name("matchaSaveAsFile")
    static let matchaToggleFind = Notification.Name("matchaToggleFind")
    static let matchaFindNext = Notification.Name("matchaFindNext")
    static let matchaFindPrev = Notification.Name("matchaFindPrev")
    static let matchaGoToLine = Notification.Name("matchaGoToLine")
    static let matchaOpenFilePath = Notification.Name("matchaOpenFilePath")
}
