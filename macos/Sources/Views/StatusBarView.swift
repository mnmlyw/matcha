import SwiftUI

struct StatusBarView: View {
    @ObservedObject var editor: MatchaEditor
    var bgColor: UInt32 = 0xF2F2EEFF
    var fgColor: UInt32 = 0x2A2A2AFF
    var dimColor: UInt32 = 0x999990FF

    var body: some View {
        HStack(spacing: 16) {
            Text(editor.info.filename.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: fgColor))

            if editor.info.modified {
                Text("Modified")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: 0xC05620FF))
            }

            if let error = editor.lastError {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: 0xC05620FF))
            }

            Spacer()

            Text("Ln \(editor.info.cursorLine), Col \(editor.info.cursorCol)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: dimColor))

            Text("\(editor.info.totalLines) lines")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: dimColor))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(hex: bgColor))
    }
}
