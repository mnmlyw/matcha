import SwiftUI

struct ContentView: View {
    private static var didHandleLaunchFile = false

    @StateObject private var editorState = EditorState()
    @State private var showFindBar = false
    @State private var showReplace = false
    @State private var searchText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = true
    @State private var wholeWord = false

    var body: some View {
        VStack(spacing: 0) {
            if showFindBar {
                FindBarView(editor: editorState.editor,
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

            EditorView(editor: editorState.editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBarView(editor: editorState.editor)
        }
        .background(Color(hex: 0x16181AFF))
        .onReceive(NotificationCenter.default.publisher(for: .matchaNewFile, object: editorState.editor)) { _ in
            editorState.editor.newFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaOpenFile, object: editorState.editor)) { _ in
            openFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaSaveFile, object: editorState.editor)) { _ in
            saveFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaSaveAsFile, object: editorState.editor)) { _ in
            saveAsFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaToggleFind, object: editorState.editor)) { _ in
            showFindBar.toggle()
            if showFindBar {
                prefillSearchFromSelection()
            } else {
                showReplace = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaFindNext, object: editorState.editor)) { _ in
            if !showFindBar {
                showFindBar = true
                prefillSearchFromSelection()
            }
            findNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaFindPrev, object: editorState.editor)) { _ in
            if !showFindBar {
                showFindBar = true
                prefillSearchFromSelection()
            }
            findPrev()
        }
        .onAppear {
            editorState.editor.markActive()

            // Handle pending file from "Open..." menu when no window was open
            if let path = AppDelegate.pendingFilePath {
                AppDelegate.pendingFilePath = nil
                _ = editorState.editor.openFile(path: path)
                return
            }

            // Handle command-line arguments (first window only)
            guard !Self.didHandleLaunchFile else { return }
            Self.didHandleLaunchFile = true
            for arg in ProcessInfo.processInfo.arguments.dropFirst() {
                let path = arg.hasPrefix("/") ? arg
                    : FileManager.default.currentDirectoryPath + "/" + arg
                if FileManager.default.fileExists(atPath: path) {
                    _ = editorState.editor.openFile(path: path)
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
            _ = editorState.editor.openFile(path: url.path)
        }
    }

    private func saveFile() {
        if editorState.editor.info.filename != nil {
            _ = editorState.editor.save()
        } else {
            saveAsFile()
        }
    }

    private func saveAsFile() {
        let panel = NSSavePanel()
        if panel.runModal() == .OK, let url = panel.url {
            _ = editorState.editor.saveAs(path: url.path)
        }
    }

    private func prefillSearchFromSelection() {
        guard searchText.isEmpty,
              let sel = editorState.editor.getSelectionText(),
              !sel.isEmpty,
              !sel.contains("\n")
        else { return }
        searchText = sel
    }

    private func findNext() {
        guard !searchText.isEmpty else { return }
        _ = editorState.editor.findNext(query: searchText,
                                        caseSensitive: caseSensitive,
                                        wholeWord: wholeWord)
    }

    private func findPrev() {
        guard !searchText.isEmpty else { return }
        _ = editorState.editor.findPrev(query: searchText,
                                        caseSensitive: caseSensitive,
                                        wholeWord: wholeWord)
    }

    private func replaceNext() {
        guard !searchText.isEmpty else { return }
        _ = editorState.editor.replaceNext(query: searchText,
                                           replacement: replaceText,
                                           caseSensitive: caseSensitive,
                                           wholeWord: wholeWord)
    }

    private func replaceAll() {
        guard !searchText.isEmpty else { return }
        _ = editorState.editor.replaceAll(query: searchText,
                                          replacement: replaceText,
                                          caseSensitive: caseSensitive,
                                          wholeWord: wholeWord)
    }
}

/// Holds config + editor together so they share a lifetime.
class EditorState: ObservableObject {
    let config: MatchaConfig
    let editor: MatchaEditor

    init() {
        let cfg = MatchaConfig()
        self.config = cfg
        self.editor = MatchaEditor(config: cfg)
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
