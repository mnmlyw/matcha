import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    @ObservedObject var tabManager: TabManager
    let chromeBg: UInt32
    let chromeActiveBg: UInt32
    let chromeFg: UInt32
    let chromeDim: UInt32

    @State private var draggedTabId: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabItemView(
                        title: tab.title,
                        isModified: tab.isModified,
                        isActive: index == tabManager.activeIndex,
                        onSelect: { tabManager.selectTab(at: index) },
                        onClose: { tabManager.closeTab(at: index) },
                        activeBg: chromeActiveBg,
                        fgColor: chromeFg,
                        dimColor: chromeDim
                    )
                    .onDrag {
                        draggedTabId = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(
                        tabManager: tabManager,
                        targetIndex: index,
                        draggedTabId: $draggedTabId
                    ))
                }
            }
        }
        .frame(height: 30)
        .background(Color(hex: chromeBg))
    }
}

private struct TabDropDelegate: DropDelegate {
    let tabManager: TabManager
    let targetIndex: Int
    @Binding var draggedTabId: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggedTabId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedId = draggedTabId,
              let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedId }),
              fromIndex != targetIndex else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            tabManager.moveTab(from: fromIndex, to: targetIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct TabItemView: View {
    let title: String
    let isModified: Bool
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let activeBg: UInt32
    let fgColor: UInt32
    let dimColor: UInt32

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if isModified {
                Circle()
                    .fill(Color(hex: fgColor))
                    .frame(width: 6, height: 6)
            }

            Text(title)
                .font(.system(size: 11))
                .foregroundColor(isActive ? Color(hex: fgColor) : Color(hex: dimColor))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(hex: dimColor))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isActive ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 30)
        .background(isActive ? Color(hex: activeBg) : Color.clear)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color.black.opacity(0.06)),
            alignment: .trailing
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
    }
}
