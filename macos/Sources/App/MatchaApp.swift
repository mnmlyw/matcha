import SwiftUI
import Carbon.HIToolbox
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

                Button("Command Palette...") {
                    NotificationCenter.default.post(name: .matchaCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Open File by Name...") {
                    NotificationCenter.default.post(name: .matchaFileFinder, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Intercept "open documents" Apple Event BEFORE SwiftUI handles it
        // This prevents SwiftUI from creating extra windows for file opens
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        matcha_init()
    }

    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let descriptorList = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        for i in 1...descriptorList.numberOfItems {
            guard let descriptor = descriptorList.atIndex(i) else { continue }
            // Try to coerce to file URL
            if let urlDescriptor = descriptor.coerce(toDescriptorType: typeFileURL) {
                let urlData = urlDescriptor.data
                if let urlString = String(data: urlData, encoding: .utf8),
                   let url = URL(string: urlString) {
                    openFilePath(url.path)
                }
            }
        }
    }

    private func openFilePath(_ path: String) {
        // Delay slightly to ensure the window and editor are ready
        DispatchQueue.main.async {
            if MatchaEditor.activeEditor != nil {
                NotificationCenter.default.post(name: .matchaOpenFilePath,
                                                object: nil,
                                                userInfo: ["path": path])
            } else {
                AppDelegate.pendingFilePath = path
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let tabManager = TabManager.current else { return .terminateNow }
        let unsavedTabs = tabManager.tabs.filter { $0.isModified }
        if unsavedTabs.isEmpty { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "You have \(unsavedTabs.count) unsaved file\(unsavedTabs.count == 1 ? "" : "s")."
        alert.informativeText = "Your changes will be lost if you quit without saving."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
    static let matchaShowCompletion = Notification.Name("matchaShowCompletion")
    static let matchaDismissCompletion = Notification.Name("matchaDismissCompletion")
    static let matchaCompletionNavigate = Notification.Name("matchaCompletionNavigate")
    static let matchaCommandPalette = Notification.Name("matchaCommandPalette")
    static let matchaFileFinder = Notification.Name("matchaFileFinder")
    static let matchaSwitchToTab = Notification.Name("matchaSwitchToTab")
}
