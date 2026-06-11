#if canImport(AppKit)
import AppKit
import Testing
@testable import Lorre

@Suite("CallWatcherPlatformServicesTests")
struct CallWatcherPlatformServicesTests {
    @Test
    @MainActor
    func testRunningApplicationIndexToleratesDuplicateProcessIdentifiers() {
        let currentApplication = NSRunningApplication.current

        let applicationsByProcessID = MacCallWatcherService.makeRunningApplicationsByProcessID([
            currentApplication,
            currentApplication
        ])

        XCTAssertEqual(applicationsByProcessID.count, 1)
        XCTAssertEqual(
            applicationsByProcessID[currentApplication.processIdentifier]?.processIdentifier,
            currentApplication.processIdentifier
        )
    }
}
#endif
