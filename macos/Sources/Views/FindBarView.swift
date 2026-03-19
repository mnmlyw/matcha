import SwiftUI

struct FindBarView: View {
    @ObservedObject var editor: MatchaEditor
    @Binding var isVisible: Bool
    @Binding var showReplace: Bool
    @Binding var searchText: String
    @Binding var replaceText: String
    @Binding var caseSensitive: Bool
    @Binding var wholeWord: Bool
    let onFindNext: () -> Void
    let onFindPrev: () -> Void
    let onReplaceNext: () -> Void
    let onReplaceAll: () -> Void
    var bgColor: UInt32 = 0xF2F2EEFF
    @FocusState private var searchFieldFocused: Bool
    @State private var liveSearchWorkItem: DispatchWorkItem?

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
                        onFindNext()
                    }
                    .onChange(of: searchText) {
                        scheduleLiveSearch()
                    }

                Button(action: onFindPrev) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button(action: onFindNext) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("g", modifiers: .command)

                Toggle("Aa", isOn: $caseSensitive)
                    .toggleStyle(.button)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .help("Case Sensitive")

                Toggle("Word", isOn: $wholeWord)
                    .toggleStyle(.button)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .help("Whole Word")

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
                            onReplaceNext()
                        }

                    Button("Replace") {
                        onReplaceNext()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))

                    Button("All") {
                        onReplaceAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(hex: bgColor)) // bg_alt
        .onAppear {
            searchFieldFocused = true
            // Pre-fill with selection if available
            if let sel = editor.getSelectionText(), !sel.isEmpty, !sel.contains("\n") {
                searchText = sel
            }
        }
        .onChange(of: caseSensitive) {
            scheduleLiveSearch()
        }
        .onChange(of: wholeWord) {
            scheduleLiveSearch()
        }
        .onDisappear {
            liveSearchWorkItem?.cancel()
        }
    }

    private func close() {
        liveSearchWorkItem?.cancel()
        isVisible = false
        showReplace = false
    }

    private func scheduleLiveSearch() {
        liveSearchWorkItem?.cancel()
        guard !searchText.isEmpty else { return }

        let workItem = DispatchWorkItem(block: onFindNext)
        liveSearchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: workItem)
    }
}
