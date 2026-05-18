import XCTest
import Foundation
import MatchaKit

/// MatchaConfig wraps the Zig matcha_config_t. These tests pull values
/// through the C ABI (font-family, font-size, line-numbers, auto-update,
/// bg-color) to verify the bridge survives across the FFI boundary, and
/// that user-set color overrides persist across the dark-resolution path.
final class MatchaConfigTests: XCTestCase {

    private func writeTempConfig(_ body: String) -> String {
        let path = "/tmp/matcha-test-config-\(UUID().uuidString).cfg"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testDefaultFontFamilyFallback() {
        let cfg = MatchaConfig()
        // matcha_config_get_string returns nil for "font-family" only if the
        // key is unknown — the Zig side allocates a dupeZ of the current
        // value, which defaults to "SF Mono".
        XCTAssertEqual(cfg.fontFamily, "SF Mono")
    }

    func testLoadFileAppliesFontSizeAndTabSize() {
        let path = writeTempConfig("font-size = 17\ntab-size = 2\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = MatchaConfig()
        XCTAssertTrue(matcha_config_load_file(cfg.handle, path))
        XCTAssertEqual(cfg.fontSize, 17)
        XCTAssertEqual(Int(matcha_config_get_int(cfg.handle, "tab-size")), 2)
    }

    func testTabSizeZeroRejectedAtParseTime() {
        let path = writeTempConfig("tab-size = 0\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = MatchaConfig()
        XCTAssertTrue(matcha_config_load_file(cfg.handle, path))
        // Must not have been clobbered to 0 — would divide-by-zero downstream.
        XCTAssertGreaterThan(Int(matcha_config_get_int(cfg.handle, "tab-size")), 0)
    }

    func testLineNumbersBoolParsesCaseInsensitively() {
        let path = writeTempConfig("line-numbers = FALSE\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = MatchaConfig()
        XCTAssertTrue(matcha_config_load_file(cfg.handle, path))
        XCTAssertFalse(cfg.lineNumbers)
    }

    func testBgColorHexShorthand() {
        let path = writeTempConfig("bg-color = #f0a\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = MatchaConfig()
        XCTAssertTrue(matcha_config_load_file(cfg.handle, path))
        // #f0a → 0xFF00AAFF (each digit doubled, alpha = FF).
        XCTAssertEqual(matcha_config_get_color(cfg.handle, "bg-color"), 0xFF00AAFF)
    }

    func testUserBgColorSurvivesSetSystemDark() {
        let path = writeTempConfig("bg-color = #1a1a1a\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = MatchaConfig()
        XCTAssertTrue(matcha_config_load_file(cfg.handle, path))
        XCTAssertEqual(matcha_config_get_color(cfg.handle, "bg-color"), 0x1a1a1aFF)

        // Resolving system-dark calls applyAppearance internally, which
        // wipes theme colors. The re-overlay step must restore the user's
        // explicit bg-color override.
        matcha_config_set_system_dark(cfg.handle, true)
        XCTAssertEqual(matcha_config_get_color(cfg.handle, "bg-color"), 0x1a1a1aFF)
    }

    func testUnknownKeyIgnoredSilently() {
        let path = writeTempConfig("nonsense-key = value\n")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = MatchaConfig()
        // Should not crash, should not affect parsing of subsequent runs.
        XCTAssertTrue(matcha_config_load_file(cfg.handle, path))
    }
}
