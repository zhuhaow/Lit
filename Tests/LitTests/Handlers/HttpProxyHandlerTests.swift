@testable import Lit
import NIO
import XCTest

class HttpProxyHandlerTests: XCTestCase {
    func testHttpConnectHandler() throws {
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

        let httpChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                HttpProxyHandler(connector: TcpConnector()).addSelfAndCodec(to: channel.pipeline)
            }
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()

        var connected = false
        let recordingHandler = RecordingHandler<ByteBuffer>() { _, context in
            if connected {
                context.close(promise: nil)
                return
            }
            var buffer = context.channel.allocator.buffer(capacity: 0)
            buffer.writeString("hello")
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            connected = true
        }

        let client = try TcpConnector().connect(on: group.next(), to: httpChannel.localAddress!).wait()
        try client.pipeline.addHandler(recordingHandler).wait()

        var buffer = client.allocator.buffer(capacity: 0)
        buffer.writeString("CONNECT 127.0.0.1:\(echoChannel.localAddress!.port!) HTTP/1.1\r\n\r\n")
        try client.writeAndFlush(buffer).wait()

        try client.closeFuture.wait()
        try echoChannel.syncCloseAcceptingAlreadyClosed()
        try httpChannel.syncCloseAcceptingAlreadyClosed()

        var inboundData = recordingHandler.inboundData
        XCTAssertEqual(inboundData.count, 2)
        let response = inboundData[0].readString(length: inboundData[0].readableBytes)!
        XCTAssert(response.hasPrefix("HTTP/1.1 200"), response)
        XCTAssertEqual(inboundData[1].readString(length: inboundData[1].readableBytes)!, "hello")
    }
}
