import NIO
import NIOHTTP1

class HttpProxyHandler {
    let connector: Connector
    var backlog = DataBacklog()
    var readHeader = false

    init(connector: Connector) {
        self.connector = connector
    }
}

extension HttpProxyHandler {
    private static let decoderHandlerName = "LIT_HTTP_RPOXY_DECODER"
    private static let encoderHandlerName = "LIT_HTTP_PROXY_ENCODER"

    public func addSelfAndCodec(to pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        pipeline
            .addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)), name: HttpProxyHandler.decoderHandlerName)
            .flatMap { pipeline.addHandler(HTTPResponseEncoder(), name: HttpProxyHandler.encoderHandlerName) }
            .flatMap { pipeline.addHandler(self) }
    }
}

extension HttpProxyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        backlog.add(data)

        guard !readHeader else {
            return
        }

        readHeader = true

        let request = unwrapInboundIn(data)
        guard case let .head(header) = request else {
            // TODO: Can't happen, this should be reported as a 500 error in prod and
            // crash in debug.
            preconditionFailure()
        }

        switch header.method {
        case .CONNECT:
            resignForConnectHandler(context: context)
        default:
            resignForHttpProxyRewriteHandler(context: context)
        }
    }

    private func resignForConnectHandler(context: ChannelHandlerContext) {
        context.pipeline
            .addHandler(HttpConnectHandler(connector: connector,
                                           decoderHandlerName: HttpProxyHandler.decoderHandlerName,
                                           encoderHandlerName: HttpProxyHandler.encoderHandlerName),
                        name: nil,
                        position: .after(self))
            .flatMap { context.pipeline.removeHandler(self) }
            .whenFailure { error in context.fireErrorCaught(error) }
    }

    private func resignForHttpProxyRewriteHandler(context _: ChannelHandlerContext) {}
}

extension HttpProxyHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        backlog.flush(to: context)

        context.leavePipeline(removalToken: removalToken)
    }
}
