import AppKit
import XCTest

// Standalone XCTest runner. We touch NSApplication.shared first so that
// any test-side code calling `NSApp.effectiveAppearance` (e.g. MatchaConfig
// during system-dark resolution) has a real application object — otherwise
// AppKit traps inside CFAutorelease.
_ = NSApplication.shared

let suite = XCTestSuite.default
suite.run()

let failures = suite.testRun?.totalFailureCount ?? 0
exit(failures == 0 ? 0 : 1)
