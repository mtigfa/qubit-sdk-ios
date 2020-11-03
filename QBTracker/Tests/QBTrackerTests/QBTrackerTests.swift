import XCTest
@testable import QBTracker

final class QBTrackerTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(QBTracker().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
