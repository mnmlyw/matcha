import SwiftUI

struct EditorView: NSViewRepresentable {
    @ObservedObject var editor: MatchaEditor

    func makeNSView(context: Context) -> MetalEditorView {
        let view = MetalEditorView(editor: editor)
        return view
    }

    func updateNSView(_ nsView: MetalEditorView, context: Context) {
        if nsView.editor !== editor {
            nsView.swapEditor(editor)
        }
        // Reclaim focus when nothing else holds it (e.g., after overlay
        // dismissal), but only if the editor's window is currently key —
        // otherwise we'd yank focus away from a modal sheet (Save dialog,
        // NSAlert, NSOpenPanel) presented on top.
        if let window = nsView.window,
           window.isKeyWindow,
           window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(nsView)
        }
        nsView.setNeedsDisplay(nsView.bounds)
    }
}
