import SwiftUI

struct GoToLineView: View {
    @Binding var text: String
    @Binding var isVisible: Bool
    let onGo: (Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Go to Line:")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            TextField("line number", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 80)
                .focused($focused)
                .onSubmit {
                    if let num = Int(text), num > 0 {
                        onGo(num)
                    }
                    isVisible = false
                }

            Button(action: { isVisible = false }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(hex: 0x1E2124FF))
        .cornerRadius(6)
        .shadow(radius: 4)
        .onAppear { focused = true }
    }
}
