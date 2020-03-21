@testable import Lit
import NIO
import XCTest

class Socks5HandlerTests: XCTestCase {
    func createDecoderChannel() -> EmbeddedChannel {
        EmbeddedChannel(handler: ByteToMessageHandler(Socks5Decoder()))
    }

    func testHelloWith(authMethod: UInt8, expect: Expectation<Socks5Request>) throws -> EmbeddedChannel {
        let channel = createDecoderChannel()
        var buffer = channel.allocator.buffer(capacity: 0)
        buffer.writeBytes([5, 1, authMethod])
        try dripFeed(to: channel, with: buffer, expect: expect)
        return channel
    }

    func testSocks5DecoderWithOneMethod() throws {
        _ = try testHelloWith(authMethod: 0, expect: .output(.method))
        for i in 1 ..< 10 {
            _ = try testHelloWith(authMethod: UInt8(i), expect: .error(Socks5HandlerError.noSupportedMethod))
        }
    }
}
