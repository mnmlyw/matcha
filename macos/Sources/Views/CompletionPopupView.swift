import SwiftUI

struct CompletionPopupView: View {
    let words: [String]
    let selectedIndex: Int
    let bgColor: UInt32
    let fgColor: UInt32
    let dimColor: UInt32
    let cursorX: CGFloat
    let cursorY: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(words.prefix(10).enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: index == selectedIndex ? bgColor : fgColor))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == selectedIndex ? Color(hex: fgColor) : Color.clear)
            }
        }
        .frame(width: 200)
        .background(Color(hex: bgColor))
        .cornerRadius(4)
        .shadow(radius: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.black.opacity(0.15), lineWidth: 1)
        )
    }
}
