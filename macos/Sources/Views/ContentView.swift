import SwiftUI

struct ContentView: View {
    @StateObject private var editorState = EditorState()
    @State private var showFindBar = false
    @State private var showReplace = false

    var body: some View {
        VStack(spacing: 0) {
            if showFindBar {
                FindBarView(editor: editorState.editor,
                            isVisible: $showFindBar,
                            showReplace: $showReplace)
            }

            EditorView(editor: editorState.editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBarView(editor: editorState.editor)
        }
        .background(Color(hex: 0x16181AFF))
        .onReceive(NotificationCenter.default.publisher(for: .matchaNewFile)) { _ in
            editorState.editor.newFile()
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
            if !showFindBar { showReplace = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaFindNext)) { _ in
            // Handled via FindBarView binding
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaFindPrev)) { _ in
            // Handled via FindBarView binding
        }
        .onAppear {
            // Check command-line arguments for a file path
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
