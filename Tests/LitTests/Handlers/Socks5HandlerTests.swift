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
        let channel = EmbeddedChannel(handler: Socks5EncoderHandler())
        try channel.writeOutbound(Socks5Response.method)
        var buffer: ByteBuffer = try channel.readOutbound()!
        XCTAssertEqual(buffer.readBytes(length: buffer.readableBytes)!, [5, 0])

        try channel.writeOutbound(Socks5Response.connected(.succeeded))
        buffer = try channel.readOutbound()!
        XCTAssertEqual(buffer.readBytes(length: buffer.readableBytes)!, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    func testSocks5Handler() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer {
            try! group.syncShutdownGracefully()
        }

        let echoChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(EchoHandler())
            }
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()

        let socks5Channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                Socks5Handler(connector: TcpConnector()).addSelfAndCodec(to: channel.pipeline)
            }
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()

        enum State {
            case readAuthResponse
            case readConnectResponse
            case readData
        }

        var state = State.readAuthResponse
        let recordingHandler = RecordingHandler<ByteBuffer>() { _, context in
            switch state {
            case .readAuthResponse:
                var buffer = context.channel.allocator.buffer(capacity: 0)
                buffer.writeBytes([5, 1, 0, 1, 127, 0, 0, 1])
                buffer.writeInteger(UInt16(echoChannel.localAddress!.port!), endianness: .big)
                context.writeAndFlush(NIOAny(buffer), promise: nil)
                state = .readConnectResponse
            case .readConnectResponse:
                var buffer = context.channel.allocator.buffer(capacity: 0)
                buffer.writeBytes([1, 3, 5])
                context.writeAndFlush(NIOAny(buffer), promise: nil)
                state = .readData
            case .readData:
                context.close(promise: nil)
            }
        }

        let client = try TcpConnector().connect(on: group.next(), endpoint: .address(socks5Channel.localAddress!)).wait()
        try client.pipeline.addHandler(recordingHandler).wait()

        var buffer = client.allocator.buffer(capacity: 0)
        buffer.writeBytes([5, 1, 0])
        try client.writeAndFlush(buffer).wait()

        try client.closeFuture.wait()
        try echoChannel.syncCloseAcceptingAlreadyClosed()
        try socks5Channel.syncCloseAcceptingAlreadyClosed()

        var inboundData = recordingHandler.inboundData
        XCTAssertEqual(inboundData.count, 3)
        XCTAssertEqual(inboundData[0].readBytes(length: inboundData[0].readableBytes)!, [5, 0])
        XCTAssertEqual(inboundData[1].readBytes(length: inboundData[1].readableBytes)!, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(inboundData[2].readBytes(length: inboundData[2].readableBytes)!, [1, 3, 5])
    }
}
