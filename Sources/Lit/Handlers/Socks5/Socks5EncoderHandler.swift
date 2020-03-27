import NIO

class Socks5EncoderHandler: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = Socks5Response
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var out = context.channel.allocator.buffer(capacity: 0)
        switch unwrapOutboundIn(data) {
        case .method:
            out.writeBytes([5, 0])
        case let .connected(response):
            switch response {
            case .succeeded:
                out.writeInteger(5 as UInt8)
                out.writeInteger(Socks5ResponseType.succeeded.rawValue)
                out.writeInteger(0 as UInt8)
                // Write back ipv4 address 0.0.0.0 back as it's useless.
                out.writeInteger(1 as UInt8)
                out.writeBytes([UInt8](repeating: 0, count: 6))

            default:
                out.writeInteger(5 as UInt8)
                out.writeInteger(Socks5ResponseType.generalFailue.rawValue)
                out.writeInteger(0 as UInt8)
                out.writeInteger(1)
                out.writeBytes([UInt8](repeating: 0, count: 6))
            }
        }

        context.write(wrapOutboundOut(out), promise: promise)
    }
}
