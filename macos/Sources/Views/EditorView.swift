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
        nsView.setNeedsDisplay(nsView.bounds)
    }
}
