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
                        // No window open — create one via SwiftUI's built-in action
                        NSApp.sendAction(#selector(AppDelegate.newWindowAction), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open...") {
                    if !NSApp.windows.contains(where: { $0.isVisible }) {
                        NSApp.sendAction(#selector(AppDelegate.openFileAction), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .matchaOpenFile, object: nil)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)

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
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
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
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }

    @objc func openFileAction() {
        // Open a new window first, then trigger file open after a brief delay
        newWindowAction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .matchaOpenFile, object: nil)
        }
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
}
