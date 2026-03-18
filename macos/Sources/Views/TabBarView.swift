import SwiftUI

struct TabBarView: View {
    @ObservedObject var tabManager: TabManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabItemView(
                        title: tab.title,
                        isModified: tab.isModified,
                        isActive: index == tabManager.activeIndex,
                        onSelect: { tabManager.selectTab(at: index) },
                        onClose: { tabManager.closeTab(at: index) }
                    )
                }
            }
        }
        .frame(height: 30)
        .background(Color(hex: 0x1A1C1EFF))
    }
}

private struct TabItemView: View {
    let title: String
    let isModified: Bool
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if isModified {
                Circle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 6, height: 6)
            }

            Text(title)
                .font(.system(size: 11))
                .foregroundColor(isActive ? .white : .gray)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.gray)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isActive ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 30)
        .background(isActive ? Color(hex: 0x16181AFF) : Color.clear)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color.white.opacity(0.08)),
            alignment: .trailing
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
    }
}
