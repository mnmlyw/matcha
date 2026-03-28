import SwiftUI
import AppKit

struct FileFinderView: View {
    @Binding var isVisible: Bool
    let rootPath: String
    let onOpen: (String) -> Void
    var bgColor: UInt32 = 0xF2F2EEFF
    var fgColor: UInt32 = 0x2A2A2AFF

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var eventMonitor: Any?
    @State private var allFiles: [String] = []
    @FocusState private var queryFocused: Bool

    private var filteredFiles: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return Array(allFiles.prefix(100)) }
        return allFiles.filter { fuzzyMatch(query: trimmed, target: $0.lowercased()) }
            .prefix(50)
            .sorted { a, b in
                // Prefer shorter paths and basename matches
                let aName = (a as NSString).lastPathComponent.lowercased()
                let bName = (b as NSString).lastPathComponent.lowercased()
                let aExact = aName.contains(trimmed)
                let bExact = bName.contains(trimmed)
                if aExact != bExact { return aExact }
                return a.count < b.count
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Open file...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($queryFocused)
                    .onSubmit { openSelected() }

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
                        if filteredFiles.isEmpty {
                            Text("No matching files")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                                .padding(14)
                        } else {
                            ForEach(Array(filteredFiles.enumerated()), id: \.element) { index, path in
                                Button(action: { open(path) }) {
                                    HStack {
                                        Text((path as NSString).lastPathComponent)
                                            .font(.system(size: 13))
                                            .foregroundColor(index == selectedIndex ? Color(hex: bgColor) : Color(hex: fgColor))
                                        Spacer()
                                        Text(path)
                                            .font(.system(size: 11))
                                            .foregroundColor(index == selectedIndex ? Color(hex: bgColor).opacity(0.7) : .secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(index == selectedIndex ? Color(hex: fgColor) : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .id(path)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: selectedIndex) {
                    let files = filteredFiles
                    if selectedIndex < files.count {
                        proxy.scrollTo(files[selectedIndex], anchor: .center)
                    }
                }
            }
        }
        .frame(width: 520)
        .background(Color(hex: bgColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.25), radius: 16, y: 8)
        .onAppear {
            queryFocused = true
            // Scan files off the main thread to avoid UI freeze on large directories
            DispatchQueue.global(qos: .userInitiated).async {
                let files = scanFiles(root: rootPath)
                DispatchQueue.main.async { allFiles = files }
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let count = filteredFiles.count
                switch Int(event.keyCode) {
                case 125: // Down
                    if count > 0 { selectedIndex = min(selectedIndex + 1, count - 1) }
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
        .onChange(of: query) { selectedIndex = 0 }
    }

    private func fuzzyMatch(query: String, target: String) -> Bool {
        var qi = query.startIndex
        var ti = target.startIndex
        while qi < query.endIndex && ti < target.endIndex {
            if query[qi] == target[ti] {
                qi = query.index(after: qi)
            }
            ti = target.index(after: ti)
        }
        return qi == query.endIndex
    }

    private func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func openSelected() {
        let files = filteredFiles
        guard selectedIndex < files.count else { return }
        open(files[selectedIndex])
    }

    private func open(_ relativePath: String) {
        removeMonitor()
        isVisible = false
        let fullPath = (rootPath as NSString).appendingPathComponent(relativePath)
        onOpen(fullPath)
    }

    private func close() {
        removeMonitor()
        isVisible = false
    }

    private func scanFiles(root: String) -> [String] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        var results: [String] = []

        let skipDirs: Set<String> = [
            ".git", ".hg", ".svn", "node_modules", ".zig-cache", "zig-out",
            ".build", "DerivedData", ".DS_Store", "__pycache__", ".venv",
            "target", ".claude", ".cache"
        ]

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skipDirs.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                let relative = url.path.replacingOccurrences(of: root + "/", with: "")
                results.append(relative)
            }
        }

        results.sort()
        return results
    }
}
