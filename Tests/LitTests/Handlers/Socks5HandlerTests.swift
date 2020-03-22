@testable import Lit
import NIO
import XCTest

class Socks5HandlerTests: XCTestCase {
    func createDecoderChannel() -> EmbeddedChannel {
        EmbeddedChannel(handler: ByteToMessageHandler(Socks5Decoder()))
    }

    func testHelloWith(authMethods: [UInt8], expect: Expectation<Socks5Request>) throws -> EmbeddedChannel {
        let channel = createDecoderChannel()
        var buffer = channel.allocator.buffer(capacity: 0)
        buffer.writeBytes([5, UInt8(authMethods.count)])
        buffer.writeBytes(authMethods)
        try dripFeed(to: channel, with: buffer, expect: expect)
        return channel
    }

    func testSocks5DecoderWithOneMethod() throws {
        _ = try testHelloWith(authMethods: [0], expect: .output(.method))
        for i in 1 ..< 10 {
            _ = try testHelloWith(authMethods: [UInt8(i)], expect: .error(Socks5HandlerError.noSupportedMethod))
        }
    }

    func testSocks5DecoderWithMethods() throws {
        for i in 1 ..< 10 {
            _ = try testHelloWith(authMethods: [UInt8(i), 0], expect: .output(.method))
            _ = try testHelloWith(authMethods: [0, UInt8(i)], expect: .output(.method))
        }
    }

    func testConnectWith(address: SocketAddress) throws {
        let channel = try testHelloWith(authMethods: [0], expect: .output(.method))
        var buffer = channel.allocator.buffer(capacity: 0)
        buffer.writeBytes([5, 1, 0])
        switch address.protocolFamily {
        case PF_INET:
            buffer.writeBytes([1])
            address.withSockAddr { addr, _ in
                var ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                _ = withUnsafeBytes(of: &ip) { buffer.writeBytes($0) }
            }
        case PF_INET6:
            buffer.writeBytes([4])
            address.withSockAddr { addr, _ in
                var ip = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                _ = withUnsafeBytes(of: &ip) { buffer.writeBytes($0) }
            }
        default:
            preconditionFailure()
        }
        buffer.writeInteger(UInt16(address.port!), endianness: .big)
        try dripFeed(to: channel, with: buffer, expect: .output(Socks5Request.connectToAddress(address)))
    }

    func testSocks5DecoderWithIpConnect() throws {
        try testConnectWith(address: SocketAddress(ipAddress: "127.0.0.1", port: 80))
        try testConnectWith(address: SocketAddress(ipAddress: "fe::01", port: 8080))
    }

    func testConnectWith(host: String, port: Int) throws {
        let channel = try testHelloWith(authMethods: [0], expect: .output(.method))
        var buffer = channel.allocator.buffer(capacity: 0)
        buffer.writeBytes([5, 1, 0, 3])
        buffer.writeInteger(UInt8(host.count))
        buffer.writeString(host)
        buffer.writeInteger(UInt16(port), endianness: .big)
        try dripFeed(to: channel, with: buffer, expect: .output(Socks5Request.connectTo(host: host, port: port)))
    }

    func testSocks5DecoderWithHost() throws {
        try testConnectWith(host: "localhost", port: 80)
        try testConnectWith(host: "google.com", port: 443)
    }

    func testSocks5Encoder() throws {
        let channel = EmbeddedChannel(handler: MessageToByteHandler(Socks5Encoder()))
        try channel.writeOutbound(Socks5Response.method)
        var buffer: ByteBuffer = try channel.readOutbound()!
        XCTAssertEqual(buffer.readBytes(length: buffer.readableBytes)!, [5, 0])

        try channel.writeOutbound(Socks5Response.connected(.succeeded))
        buffer = try channel.readOutbound()!
        XCTAssertEqual(buffer.readBytes(length: buffer.readableBytes)!, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    }
}
