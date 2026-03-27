import SwiftUI
import AppKit

struct PaletteCommandItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let keywords: String
    let action: () -> Void
}

struct CommandPaletteView: View {
    @Binding var isVisible: Bool
    let commands: [PaletteCommandItem]
    var bgColor: UInt32 = 0xF2F2EEFF
    var fgColor: UInt32 = 0x2A2A2AFF

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var eventMonitor: Any?
    @FocusState private var queryFocused: Bool

    private var filteredCommands: [PaletteCommandItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
                $0.keywords.localizedCaseInsensitiveContains(trimmed) ||
                ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Type a command...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($queryFocused)
                    .onSubmit { runSelected() }

                Button(action: close) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if filteredCommands.isEmpty {
                            Text("No matching commands")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                                .padding(14)
                        } else {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                                Button(action: { run(command) }) {
                                    HStack {
                                        Text(command.title)
                                            .font(.system(size: 13))
                                            .foregroundColor(index == selectedIndex ? Color(hex: bgColor) : Color(hex: fgColor))
                                        Spacer()
                                        if let subtitle = command.subtitle {
                                            Text(subtitle)
                                                .font(.system(size: 11))
                                                .foregroundColor(index == selectedIndex ? Color(hex: bgColor).opacity(0.7) : .secondary)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(index == selectedIndex ? Color(hex: fgColor) : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .id(command.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: selectedIndex) {
                    if selectedIndex < filteredCommands.count {
                        proxy.scrollTo(filteredCommands[selectedIndex].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 440)
        .background(Color(hex: bgColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.25), radius: 16, y: 8)
        .onAppear {
            queryFocused = true
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch Int(event.keyCode) {
                case 125: // Down
                    if !filteredCommands.isEmpty {
                        selectedIndex = min(selectedIndex + 1, filteredCommands.count - 1)
                    }
                    return nil
                case 126: // Up
                    selectedIndex = max(selectedIndex - 1, 0)
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
        .onChange(of: query) {
            selectedIndex = 0
        }
    }

    private func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func runSelected() {
        guard selectedIndex < filteredCommands.count else { return }
        run(filteredCommands[selectedIndex])
    }

    private func run(_ command: PaletteCommandItem) {
        removeMonitor()
        isVisible = false
        command.action()
    }

    private func close() {
        removeMonitor()
        isVisible = false
    }
}
