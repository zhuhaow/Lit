import NIO

class RecordingHandler<In>: ChannelInboundHandler {
    typealias InboundIn = In
    typealias InboundOut = In

    let onRead: (In, ChannelHandlerContext) -> Void

    var inboundData: [In] = []

    init(onRead: @escaping (In, ChannelHandlerContext) -> Void) {
        self.onRead = onRead
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        inboundData.append(unwrapInboundIn(data))
        context.fireChannelRead(data)
        onRead(unwrapInboundIn(data), context)
    }
}
