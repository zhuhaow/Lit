import XCTest
@testable import nekit2

final class nekit2Tests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(nekit2().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
