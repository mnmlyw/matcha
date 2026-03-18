import SwiftUI

struct ContentView: View {
    private static var didHandleLaunchFile = false

    @StateObject private var tabManager = TabManager()
    @State private var showFindBar = false
    @State private var showReplace = false
    @State private var searchText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = true
    @State private var wholeWord = false
    @State private var showGoToLine = false
    @State private var goToLineText = ""

    private var editor: MatchaEditor? { tabManager.activeEditor }

    var body: some View {
        VStack(spacing: 0) {
            if tabManager.tabs.count > 1 {
                TabBarView(tabManager: tabManager)
            }

            if showFindBar, let ed = editor {
                FindBarView(editor: ed,
                            isVisible: $showFindBar,
                            showReplace: $showReplace,
                            searchText: $searchText,
                            replaceText: $replaceText,
                            caseSensitive: $caseSensitive,
                            wholeWord: $wholeWord,
                            onFindNext: findNext,
                            onFindPrev: findPrev,
                            onReplaceNext: replaceNext,
                            onReplaceAll: replaceAll)
            }

            ZStack(alignment: .top) {
                if let ed = editor {
                    EditorView(editor: ed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(tabManager.activeTab?.id)
                }

                if showGoToLine {
                    GoToLineView(text: $goToLineText, isVisible: $showGoToLine) { lineNum in
                        editor?.goToLine(UInt32(lineNum))
                    }
                    .padding(.top, 40)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            if let ed = editor {
                StatusBarView(editor: ed)
            }
        }
        .background(Color(hex: 0x16181AFF))
        // Tab notifications (not tied to a specific editor)
        .onReceive(NotificationCenter.default.publisher(for: .matchaNewTab)) { _ in
            tabManager.newTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaCloseTab)) { _ in
            tabManager.closeCurrentTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaNextTab)) { _ in
            tabManager.selectNextTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaPrevTab)) { _ in
            tabManager.selectPreviousTab()
        }
        // Editor notifications (use active editor)
        .onReceive(NotificationCenter.default.publisher(for: .matchaNewFile)) { _ in
            editor?.newFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaOpenFile)) { _ in
            openFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaSaveFile)) { _ in
            saveFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaSaveAsFile)) { _ in
            saveAsFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaToggleFind)) { _ in
            showFindBar.toggle()
            if showFindBar {
                prefillSearchFromSelection()
            } else {
                showReplace = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaFindNext)) { _ in
            if !showFindBar {
                showFindBar = true
                prefillSearchFromSelection()
            }
            findNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaFindPrev)) { _ in
            if !showFindBar {
                showFindBar = true
                prefillSearchFromSelection()
            }
            findPrev()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaGoToLine)) { _ in
            goToLineText = ""
            showGoToLine = true
        }
        .onAppear {
            editor?.markActive()

            // Handle pending file from "Open..." menu when no window was open
            if let path = AppDelegate.pendingFilePath {
                AppDelegate.pendingFilePath = nil
                tabManager.openInCurrentTab(path: path)
                return
            }

            // Handle command-line arguments (first window only)
            guard !Self.didHandleLaunchFile else { return }
            Self.didHandleLaunchFile = true
            for arg in ProcessInfo.processInfo.arguments.dropFirst() {
                let path = arg.hasPrefix("/") ? arg
                    : FileManager.default.currentDirectoryPath + "/" + arg
                if FileManager.default.fileExists(atPath: path) {
                    tabManager.openInCurrentTab(path: path)
                    break
                }
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            // If current tab is untitled and unmodified, open in it; otherwise new tab
            if let ed = editor, ed.info.filename == nil && !ed.info.modified {
                tabManager.openInCurrentTab(path: url.path)
            } else {
                tabManager.openInNewTab(path: url.path)
            }
        }
    }

    private func saveFile() {
        guard let ed = editor else { return }
        if ed.info.filename != nil {
            _ = ed.save()
        } else {
            saveAsFile()
        }
    }

    private func saveAsFile() {
        guard let ed = editor else { return }
        let panel = NSSavePanel()
        if panel.runModal() == .OK, let url = panel.url {
            _ = ed.saveAs(path: url.path)
        }
    }

    private func prefillSearchFromSelection() {
        guard searchText.isEmpty,
              let sel = editor?.getSelectionText(),
              !sel.isEmpty,
              !sel.contains("\n")
        else { return }
        searchText = sel
    }

    private func findNext() {
        guard !searchText.isEmpty else { return }
        _ = editor?.findNext(query: searchText,
                             caseSensitive: caseSensitive,
                             wholeWord: wholeWord)
    }

    private func findPrev() {
        guard !searchText.isEmpty else { return }
        _ = editor?.findPrev(query: searchText,
                             caseSensitive: caseSensitive,
                             wholeWord: wholeWord)
    }

    private func replaceNext() {
        guard !searchText.isEmpty else { return }
        _ = editor?.replaceNext(query: searchText,
                                replacement: replaceText,
                                caseSensitive: caseSensitive,
                                wholeWord: wholeWord)
    }

    private func replaceAll() {
        guard !searchText.isEmpty else { return }
        _ = editor?.replaceAll(query: searchText,
                               replacement: replaceText,
                               caseSensitive: caseSensitive,
                               wholeWord: wholeWord)
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 24) & 0xFF) / 255.0
        let g = Double((hex >> 16) & 0xFF) / 255.0
        let b = Double((hex >> 8) & 0xFF) / 255.0
        let a = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
