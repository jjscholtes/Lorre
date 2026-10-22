import Testing
@testable import Lorre

#if canImport(AppKit)
import AppKit

@Suite("PasteboardSnapshotTests")
struct PasteboardSnapshotTests {

    @Test
    func testRestoresOriginalClipboardWhenUntouched() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated", forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        XCTAssertTrue(snapshot.restore(to: pasteboard, ifChangeCountIs: insertedChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @Test
    func testKeepsClipboardCopiedDuringPasteWindow() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated", forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("copied by user", forType: .string)

        XCTAssertFalse(snapshot.restore(to: pasteboard, ifChangeCountIs: insertedChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "copied by user")
    }
}
#endif
