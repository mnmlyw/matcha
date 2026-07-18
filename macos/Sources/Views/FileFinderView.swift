import SwiftUI
import AppKit

struct FileFinderView: View {
    private struct IndexedFile: Sendable {
        let path: String
        let lowercasedPath: String
        let lowercasedBasename: String
    }

    @Binding var isVisible: Bool
    let rootPath: String
    let onOpen: (String) -> Void
    var bgColor: UInt32 = 0xF2F2EEFF
    var fgColor: UInt32 = 0x2A2A2AFF

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var eventMonitor: Any?
    @State private var indexedFiles: [IndexedFile] = []
    @State private var filteredFiles: [String] = []
    @State private var filterWorkItem: DispatchWorkItem?
    @FocusState private var queryFocused: Bool

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
                let indexed = files.map {
                    IndexedFile(path: $0,
                                lowercasedPath: $0.lowercased(),
                                lowercasedBasename: ($0 as NSString).lastPathComponent.lowercased())
                }
                DispatchQueue.main.async {
                    indexedFiles = indexed
                    scheduleFilter()
                }
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
            filterWorkItem?.cancel()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
        .onChange(of: query) {
            selectedIndex = 0
            scheduleFilter()
        }
    }

    private static func fuzzyMatch(query: String, target: String) -> Bool {
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

    private static func filter(_ files: [IndexedFile], query: String) -> [String] {
        guard !query.isEmpty else { return Array(files.prefix(100).map(\.path)) }
        return Array(files.lazy
            .filter { fuzzyMatch(query: query, target: $0.lowercasedPath) }
            .sorted { a, b in
                let aExact = a.lowercasedBasename.contains(query)
                let bExact = b.lowercasedBasename.contains(query)
                if aExact != bExact { return aExact }
                return a.path.count < b.path.count
            }
            .prefix(50)
            .map(\.path))
    }

    private func scheduleFilter() {
        filterWorkItem?.cancel()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let files = indexedFiles
        let item = DispatchWorkItem {
            let result = Self.filter(files, query: normalizedQuery)
            DispatchQueue.main.async {
                guard query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedQuery else { return }
                filteredFiles = result
                selectedIndex = min(selectedIndex, max(result.count - 1, 0))
            }
        }
        filterWorkItem = item
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + .milliseconds(80), execute: item)
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
        // Refuse to enumerate roots that would explode the search space (root
        // filesystem, user home, /Applications, etc.). Without an open file
        // the previous behavior could try to walk millions of paths.
        let normalizedRoot = (root as NSString).standardizingPath
        let dangerousRoots: Set<String> = [
            "/", "/Users", "/Applications", "/Library", "/System", "/private",
            NSHomeDirectory()
        ]
        if dangerousRoots.contains(normalizedRoot) { return [] }

        let rootURL = URL(fileURLWithPath: root)
        var results: [String] = []
        // Hard cap on results so a misconfigured root can't OOM the app.
        let maxFiles = 50_000

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
                // Strip only the leading root prefix, not every occurrence
                // of it -- replacingOccurrences would also remove any later
                // substring matching the root path (e.g. a file at
                // "<root>/mirror/<root>/x.txt" would wrongly collapse to
                // "mirror/x.txt", so selecting it would open/create the
                // wrong file).
                let prefix = root + "/"
                let relative = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
                results.append(relative)
                if results.count >= maxFiles { break }
            }
        }

        results.sort()
        return results
    }
}
