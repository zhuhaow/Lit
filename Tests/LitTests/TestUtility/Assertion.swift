import XCTest

struct NilError: Error {}

func assertNil<T>(_ body: @autoclosure () throws -> T?, message: String? = nil, file: StaticString = #file, line: UInt = #line) throws {
    if let value = try body() {
        XCTFail("\(message.map { $0 + ": " } ?? "") expect nil, but got \(value)", file: file, line: line)
        throw NilError()
    }
}

struct NotNilError: Error {}

func assertNotNil<T>(_ body: @autoclosure () throws -> T?, message _: String? = nil, file: StaticString = #file, line: UInt = #line) throws -> T {
    if let value = try body() {
        return value
    }

    XCTFail("Expect non nil, but got nil.", file: file, line: line)
    throw NotNilError()
}
