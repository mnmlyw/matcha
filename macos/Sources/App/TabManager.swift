import Foundation

class TabManager: ObservableObject {
    let config: MatchaConfig

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

    init() {
        let cfg = MatchaConfig()
        self.config = cfg
        let editor = MatchaEditor(config: cfg)
        editor.markActive()
        tabs.append(Tab(editor: editor))
    }

    func newTab() {
        let editor = MatchaEditor(config: config)
        tabs.append(Tab(editor: editor))
        activeIndex = tabs.count - 1
        activeTab?.editor.markActive()
    }

    func openInNewTab(path: String) {
        let editor = MatchaEditor(config: config)
        _ = editor.openFile(path: path)
        tabs.append(Tab(editor: editor))
        activeIndex = tabs.count - 1
        activeTab?.editor.markActive()
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
