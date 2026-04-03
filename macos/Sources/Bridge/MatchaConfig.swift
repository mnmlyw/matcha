import Foundation
import AppKit
import MatchaKit

/// Swift wrapper around the Zig config (matcha_config_t).
class MatchaConfig: ObservableObject {
    let handle: matcha_config_t?

    init() {
        handle = matcha_config_new()

        // Load config from standard paths
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/matcha/config")
        matcha_config_load_file(handle, configDir.path)

        // Sync appearance=auto with system dark mode
        let appearance = NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        matcha_config_set_system_dark(handle, isDark)
    }

    deinit {
        if let h = handle {
            matcha_config_free(h)
        }
    }

    var fontFamily: String {
        guard let h = handle,
              let cStr = matcha_config_get_string(h, "font-family") else {
            return "SF Mono"
        }
        let str = String(cString: cStr)
        matcha_editor_free_string(UnsafeMutablePointer(mutating: cStr))
        return str
    }

    var fontSize: CGFloat {
        guard let h = handle else { return 14 }
        return CGFloat(matcha_config_get_float(h, "font-size"))
    }

    var lineNumbers: Bool {
        guard let h = handle else { return true }
        return matcha_config_get_bool(h, "line-numbers")
    }

    var autoUpdate: Bool {
        guard let h = handle else { return true }
        return matcha_config_get_bool(h, "auto-update")
    }
}
