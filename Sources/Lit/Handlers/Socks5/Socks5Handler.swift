import NIO

public final class Socks5Handler {
    enum Socks5HandlerStatus {
        case readingVersionAndMethods
        case readingConnectHeader
    }

    let connector: Connector
    var status: Socks5HandlerStatus = .readingVersionAndMethods
    var handshaking = true
    var backlog = DataBacklog()

    public init(connector: Connector) {
        self.connector = connector
    }
}

extension Socks5Handler: ChannelDuplexHandler {
    public typealias InboundIn = Socks5Request
    public typealias InboundOut = Never

    public typealias OutboundIn = Never
    public typealias OutboundOut = Socks5Response

    private static let encoderHandlerName = "LIT_SOCKS5_ENCODER"
    private static let decoderHandlerName = "LIT_SOCKS5_DECODER"

    public func addSelfAndCodec(to pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        pipeline
            .addHandler(ByteToMessageHandler(Socks5Decoder()), name: Socks5Handler.decoderHandlerName)
            .flatMap { pipeline.addHandler(Socks5EncoderHandler(), name: Socks5Handler.encoderHandlerName) }
            .flatMap { pipeline.addHandler(self) }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard handshaking else {
            backlog.add(data)
            return
        }

        let request = unwrapInboundIn(data)

        let future: EventLoopFuture<Channel>
        switch request {
        case .method:
            context.writeAndFlush(wrapOutboundOut(.method))
                .whenSuccess {
                    context.read()
                }
            return
        case let .connectToAddress(address):
            future = connector.connect(on: context.eventLoop, endpoint: .address(address))
        case let .connectTo(host: host, port: port):
            future = connector.connect(on: context.eventLoop, endpoint: .domain(host, port))
        }

        future.whenComplete { result in
            switch result {
            case let .success(channel):
                self.handshaking = false

                context.pipeline.removeHandler(name: Socks5Handler.decoderHandlerName)
                    .flatMap { context.writeAndFlush(self.wrapOutboundOut(.connected(.succeeded))) }
                    .flatMap { context.pipeline.removeHandler(name: Socks5Handler.encoderHandlerName) }
                    .flatMap {
                        let (localGlue, peerGlue) = GlueHandler.matchedPair()
                        return context.pipeline.addHandler(localGlue)
                            .and(channel.pipeline.addHandler(peerGlue)).map { _ in () }
                    }
                    .flatMap {
                        context.pipeline.removeHandler(self)
                    }
                    .whenComplete { result in
                        switch result {
                        case .success:
                            break
                        case let .failure(error):
                            context.fireErrorCaught(error)
                        }
                    }

            case let .failure(error):
                // TODO: write error back
                context.fireErrorCaught(error)
            }
        }
    }
}

extension Socks5Handler: RemovableChannelHandler {
    public func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        backlog.flush(to: context)

        context.leavePipeline(removalToken: removalToken)
    }
}
