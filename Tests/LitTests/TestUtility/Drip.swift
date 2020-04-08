import NIO
import XCTest

enum Expectation<T> {
    case output(T)
    case error(Error?)
}

func dripFeed<T: Equatable>(to channel: EmbeddedChannel, with buffer: ByteBuffer, expect: Expectation<T>) throws {
    let length = buffer.readableBytes

    for (ind, c) in buffer.readableBytesView.enumerated() {
        var buffer = channel.allocator.buffer(capacity: 1)
        buffer.writeInteger(c)
        do {
            try channel.writeInbound(buffer)
        } catch {
            switch expect {
            case .output:
                XCTFail("Expect to get \(expect), but got \(error) instead.")
            case let .error(expectError):
                if let expectError = expectError {
                    XCTAssertEqual(error.localizedDescription, expectError.localizedDescription)
                }
                return
            }
        }

        if ind != length - 1 {
            try assertNil(try assertNoThrowWithValue(channel.readInbound()) as T?)
        }
    }

    let output: T = try assertNotNil(try assertNoThrowWithValue(channel.readInbound()))

    switch expect {
    case let .error(error):
        XCTFail("Expect to get \(String(describing: error)), but got \(output) instead.")
    case let .output(out):
        XCTAssertEqual(output, out)
    }
}
