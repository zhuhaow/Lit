import XCTest

#if !canImport(ObjectiveC)
    public func allTests() -> [XCTestCaseEntry] {
        [
            testCase(Socks5HandlerTests.allTests),
        ]
    }
#endif
