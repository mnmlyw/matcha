import Foundation
import Combine
import MatchaKit

class TabManager: ObservableObject {
    let config: MatchaConfig
    private var cancellables = Set<AnyCancellable>()

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
        tabs.append(Tab(editor: editor))
        observeEditor(editor)
    }

    private func observeEditor(_ editor: MatchaEditor) {
        editor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    func newTab() {
        let editor = MatchaEditor(config: config)
        tabs.append(Tab(editor: editor))
        activeIndex = tabs.count - 1
        activeTab?.editor.markActive()
        observeEditor(editor)
    }

    func openInNewTab(path: String) {
        let editor = MatchaEditor(config: config)
        _ = editor.openFile(path: path)
        tabs.append(Tab(editor: editor))
        activeIndex = tabs.count - 1
        activeTab?.editor.markActive()
        observeEditor(editor)
    }

    func openInCurrentTab(path: String) {
        guard let editor = activeEditor else { return }
        _ = editor.openFile(path: path)
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1 else {
            activeEditor?.newFile()
            return
        }
        // If closing the active tab, adjust index first
        let wasActive = index == activeIndex
        tabs.remove(at: index)
        if activeIndex > index {
            activeIndex -= 1
        } else if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        }
        // Always update activeEditor ref after tab removal
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
