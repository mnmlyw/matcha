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
                    NotificationCenter.default.post(name: .matchaNewFile, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open...") {
                    NotificationCenter.default.post(name: .matchaOpenFile, object: nil)
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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.isFileURL else { return }
        NotificationCenter.default.post(name: .matchaOpenFilePath, object: url.path)
    }
}

extension Notification.Name {
    static let matchaNewFile = Notification.Name("matchaNewFile")
    static let matchaOpenFile = Notification.Name("matchaOpenFile")
    static let matchaSaveFile = Notification.Name("matchaSaveFile")
    static let matchaSaveAsFile = Notification.Name("matchaSaveAsFile")
    static let matchaOpenFilePath = Notification.Name("matchaOpenFilePath")
}
