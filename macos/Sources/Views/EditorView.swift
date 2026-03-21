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
        // Reclaim focus when no other responder has it (e.g., after overlay dismissal)
        if let window = nsView.window,
           window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(nsView)
        }
        nsView.setNeedsDisplay(nsView.bounds)
    }
}
