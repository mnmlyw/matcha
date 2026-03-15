import SwiftUI

struct ContentView: View {
    @StateObject private var editorState = EditorState()

    var body: some View {
        VStack(spacing: 0) {
            EditorView(editor: editorState.editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBarView(editor: editorState.editor)
        }
        .background(Color(hex: 0x1E1E2EFF))
        .onReceive(NotificationCenter.default.publisher(for: .matchaOpenFile)) { _ in
            openFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaSaveFile)) { _ in
            saveFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaSaveAsFile)) { _ in
            saveAsFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matchaOpenFilePath)) { notification in
            if let path = notification.object as? String {
                _ = editorState.editor.openFile(path: path)
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
