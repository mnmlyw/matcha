import SwiftUI

struct StatusBarView: View {
    @ObservedObject var editor: MatchaEditor

    var body: some View {
        HStack(spacing: 16) {
            // Filename
            Text(editor.info.filename.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: 0xFFFFFFFF))

            if editor.info.modified {
                Text("Modified")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: 0xFF6E5EFF)) // red
            }

            if let error = editor.lastError {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: 0xFF6E5EFF))
            }

            Spacer()

            // Line:Col
            Text("Ln \(editor.info.cursorLine), Col \(editor.info.cursorCol)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: 0x7B8496FF)) // grey

            // Total lines
            Text("\(editor.info.totalLines) lines")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: 0x7B8496FF)) // grey
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(hex: 0x16181AFF)) // bg
    }
}
