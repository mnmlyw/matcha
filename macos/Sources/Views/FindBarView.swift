import SwiftUI

struct FindBarView: View {
    @ObservedObject var editor: MatchaEditor
    @Binding var isVisible: Bool
    @Binding var showReplace: Bool
    @State private var searchText = ""
    @State private var replaceText = ""
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            // Search row
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                TextField("Find", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($searchFieldFocused)
                    .onSubmit {
                        _ = editor.findNext(query: searchText)
                    }
                    .onChange(of: searchText) {
                        if !searchText.isEmpty {
                            _ = editor.findNext(query: searchText)
                        }
                    }

                Button(action: { _ = editor.findPrev(query: searchText) }) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button(action: { _ = editor.findNext(query: searchText) }) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("g", modifiers: .command)

                Button(action: { showReplace.toggle() }) {
                    Image(systemName: "arrow.2.squarepath")
                }
                .buttonStyle(.borderless)

                Button(action: { close() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
            }

            // Replace row (collapsible)
            if showReplace {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    TextField("Replace", text: $replaceText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit {
                            _ = editor.replaceNext(query: searchText, replacement: replaceText)
                        }

                    Button("Replace") {
                        _ = editor.replaceNext(query: searchText, replacement: replaceText)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))

                    Button("All") {
                        _ = editor.replaceAll(query: searchText, replacement: replaceText)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(hex: 0x1E2124FF)) // bg_alt
        .onAppear {
            searchFieldFocused = true
            // Pre-fill with selection if available
            if let sel = editor.getSelectionText(), !sel.isEmpty, !sel.contains("\n") {
                searchText = sel
            }
        }
    }

    private func close() {
        isVisible = false
        searchText = ""
    }
}
