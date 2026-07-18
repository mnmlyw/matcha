import Foundation
import AppKit
import MatchaKit

/// Swift wrapper around the Zig config (matcha_config_t).
class MatchaConfig: ObservableObject {
    let handle: matcha_config_t?
    let fontFamily: String
    let loadFailed: Bool
    private static var didShowLoadFailure = false

    init() {
        let configHandle = matcha_config_new()
        handle = configHandle

        // Load config from standard paths
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/matcha/config")
        let configExists = FileManager.default.fileExists(atPath: configDir.path)
        loadFailed = configExists && !matcha_config_load_file(configHandle, configDir.path)

        // Sync appearance=auto with system dark mode
        let appearance = NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        matcha_config_set_system_dark(configHandle, isDark)

        if let h = configHandle,
           let cStr = matcha_config_get_string(h, "font-family") {
            fontFamily = String(cString: cStr)
            matcha_free_string(UnsafeMutablePointer(mutating: cStr))
        } else {
            fontFamily = "SF Mono"
        }

        if loadFailed && !Self.didShowLoadFailure {
            Self.didShowLoadFailure = true
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Matcha could not load its configuration"
                alert.informativeText = "Check that \(configDir.path) is readable, smaller than 1 MB, and contains valid settings. Defaults are being used."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    deinit {
        if let h = handle {
            matcha_config_free(h)
        }
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
