import NIO

class RecordingHandler<In>: ChannelInboundHandler {
    typealias InboundIn = In
    typealias InboundOut = In

    let onRead: (In, ChannelHandlerContext) -> Void

    var inboundData: [In] = []
    var error: Error?

    init(onRead: @escaping (In, ChannelHandlerContext) -> Void) {
        self.onRead = onRead
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        inboundData.append(unwrapInboundIn(data))
        context.fireChannelRead(data)
        onRead(unwrapInboundIn(data), context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.error = error
        context.fireErrorCaught(error)
    }
}
