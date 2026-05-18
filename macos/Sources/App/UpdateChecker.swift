import AppKit
import Foundation

/// Checks GitHub Releases for a newer version of Matcha.
/// Respects the `auto-update = false` config setting and checks at most once per day.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "mnmlyw/matcha"
    private let lastCheckKey = "UpdateChecker.lastCheckDate"
    private let dismissedVersionKey = "UpdateChecker.dismissedVersion"
    private let checkInterval: TimeInterval = 86400 // 24 hours

    func checkIfNeeded(config: MatchaConfig) {
        guard config.autoUpdate else { return }

        // Skip dev/pre-release builds (SemVer pre-release tag, e.g. "0.0.0-dev").
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if current.contains("-") { return }

        if let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < checkInterval {
            return
        }

        Task.detached(priority: .utility) {
            await self.check()
        }
    }

    private func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return }

        // Throttle after any completed request (retries on network failure)
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        guard http.statusCode == 200 else { return }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String else { return }

        let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        guard isNewer(remote: remote, local: current) else { return }

        // Don't prompt again for a version the user already dismissed
        if let dismissed = UserDefaults.standard.string(forKey: dismissedVersionKey),
           dismissed == remote { return }

        await showUpdateAlert(version: remote, url: htmlURL)
    }

    @MainActor
    private func showUpdateAlert(version: String, url: String) {
        let alert = NSAlert()
        alert.messageText = "Matcha v\(version) Available"
        alert.informativeText = "A new version of Matcha is available. Would you like to download it?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let downloadURL = URL(string: url) {
                NSWorkspace.shared.open(downloadURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: dismissedVersionKey)
        default:
            break
        }
    }

    /// Semver comparison: returns true if remote > local.
    /// Pre-release suffixes (`-rc.1`, `-beta`, `-dev`) are stripped before
    /// numeric comparison and treated as *older* than the base version per
    /// semver. Previously `compactMap { Int($0) }` silently dropped any
    /// segment containing a `-`, which produced wrong ordering for tags
    /// like `1.0.0-rc1` vs `1.0.0`.
    /// Internal (not private) so XCTest can exercise it directly.
    func isNewer(remote: String, local: String) -> Bool {
        let rRelease = remote.split(separator: "-", maxSplits: 1).first.map(String.init) ?? remote
        let lRelease = local.split(separator: "-", maxSplits: 1).first.map(String.init) ?? local
        let rPre = remote.contains("-")
        let lPre = local.contains("-")

        let r = rRelease.split(separator: ".").compactMap { Int($0) }
        let l = lRelease.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        // Numerically equal: pre-release loses to a non-pre-release.
        // e.g. remote=1.0.0-rc1 vs local=1.0.0 → false (don't prompt)
        //      remote=1.0.0 vs local=1.0.0-rc1 → true (prompt to update)
        if !rPre && lPre { return true }
        return false
    }
}
