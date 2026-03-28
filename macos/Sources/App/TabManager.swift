import Foundation
import AppKit
import Combine
import MatchaKit

class TabManager: ObservableObject {
    private static var allInstances: [WeakTabRef] = []

    private final class WeakTabRef {
        weak var value: TabManager?
        init(_ v: TabManager) { value = v }
    }

    static var current: TabManager? {
        allInstances.first(where: { $0.value != nil })?.value
    }

    static var allHasUnsaved: Bool {
        allInstances.removeAll(where: { $0.value == nil })
        return allInstances.contains { ref in
            ref.value?.tabs.contains { $0.isModified } ?? false
        }
    }

    static var allUnsavedCount: Int {
        allInstances.removeAll(where: { $0.value == nil })
        return allInstances.reduce(0) { sum, ref in
            sum + (ref.value?.tabs.filter { $0.isModified }.count ?? 0)
        }
    }

    let config: MatchaConfig
    private var editorCancellables: [UUID: AnyCancellable] = [:]

    struct Tab: Identifiable {
        let id = UUID()
        let editor: MatchaEditor

        var title: String {
            if let name = editor.info.filename {
                return (name as NSString).lastPathComponent
            }
            return "Untitled"
        }

        var isModified: Bool { editor.info.modified }
    }

    @Published var tabs: [Tab] = []
    @Published var activeIndex: Int = 0

    var activeTab: Tab? {
        guard activeIndex >= 0 && activeIndex < tabs.count else { return nil }
        return tabs[activeIndex]
    }

    var activeEditor: MatchaEditor? { activeTab?.editor }

    var bgColor: UInt32 { matcha_config_get_color(config.handle, "bg-color") }
    var chromeBg: UInt32 { matcha_config_get_color(config.handle, "chrome-bg-color") }
    var chromeActiveBg: UInt32 { matcha_config_get_color(config.handle, "chrome-active-bg-color") }
    var chromeFg: UInt32 { matcha_config_get_color(config.handle, "chrome-fg-color") }
    var chromeDim: UInt32 { matcha_config_get_color(config.handle, "chrome-dim-color") }

    init() {
        let cfg = MatchaConfig()
        self.config = cfg
        let editor = MatchaEditor(config: cfg)
        editor.markActive()
        let tab = Tab(editor: editor)
        tabs.append(tab)
        observeEditor(editor, id: tab.id)
        TabManager.allInstances.append(WeakTabRef(self))
    }

    private func observeEditor(_ editor: MatchaEditor, id: UUID) {
        editorCancellables[id] = editor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func newTab() {
        let editor = MatchaEditor(config: config)
        let tab = Tab(editor: editor)
        tabs.append(tab)
        activeIndex = tabs.count - 1
        activeTab?.editor.markActive()
        observeEditor(editor, id: tab.id)
    }

    func openInNewTab(path: String) {
        let editor = MatchaEditor(config: config)
        guard editor.openFile(path: path) else {
            // Read error directly — openFile's updateInfo already consumed getLastError
            let alert = NSAlert()
            alert.messageText = "Could not open file"
            alert.informativeText = (path as NSString).lastPathComponent
            alert.runModal()
            return
        }
        let tab = Tab(editor: editor)
        tabs.append(tab)
        activeIndex = tabs.count - 1
        activeTab?.editor.markActive()
        observeEditor(editor, id: tab.id)
    }

    func openInCurrentTab(path: String) {
        guard let editor = activeEditor else { return }
        _ = editor.openFile(path: path)
    }

    func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        let tab = tabs[index]
        let tabId = tab.id

        // Prompt to save if modified
        if tab.isModified {
            let alert = NSAlert()
            alert.messageText = "Do you want to save changes to \"\(tab.title)\"?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Save — abort close if save fails
                if tab.editor.info.filename != nil {
                    if !tab.editor.save() { return }
                } else {
                    let panel = NSSavePanel()
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    if !tab.editor.saveAs(path: url.path) { return }
                }
            } else if response == .alertThirdButtonReturn {
                return // Cancel
            }
            // Don't Save falls through
        }

        guard tabs.count > 1 else {
            activeEditor?.newFile()
            return
        }
        let wasActive = index == activeIndex
        tabs.remove(at: index)
        editorCancellables.removeValue(forKey: tabId) // clean up subscription
        if activeIndex > index {
            activeIndex -= 1
        } else if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        }
        if wasActive || MatchaEditor.activeEditor == nil {
            activeTab?.editor.markActive()
        }
    }

    func closeCurrentTab() {
        closeTab(at: activeIndex)
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        activeIndex = index
        activeTab?.editor.markActive()
    }

    func moveTab(from: Int, to: Int) {
        guard from != to, from >= 0, from < tabs.count, to >= 0, to < tabs.count else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        if activeIndex == from {
            activeIndex = to
        } else if from < to {
            if activeIndex > from && activeIndex <= to { activeIndex -= 1 }
        } else {
            if activeIndex >= to && activeIndex < from { activeIndex += 1 }
        }
    }

    func selectNextTab() {
        if tabs.count > 1 {
            selectTab(at: (activeIndex + 1) % tabs.count)
        }
    }

    func selectPreviousTab() {
        if tabs.count > 1 {
            selectTab(at: (activeIndex - 1 + tabs.count) % tabs.count)
        }
    }
}
