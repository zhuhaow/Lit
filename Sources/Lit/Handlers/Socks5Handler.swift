import NIO

public enum Socks5HandlerError: Error {
    case unsupportedVersion
    case noAuthMethodSpecified
    case tooManyMethods
    case noSupportedMethod
    case unSupportedCommand
    case protocolError
    case invalidDomainLength
    case invalidAddressType
}

public enum Socks5Request {
    case method
    case connectToAddress(SocketAddress)
    case connectTo(host: String, port: Int)
}

public enum Socks5ResponseType: UInt8 {
    case succeeded
    case generalFailue
    case connectionNotAllowed
    case networkUnreachable
    case connectionRefused
    case ttlExpired
    case commandNotSupported
    case addressTypeNotSupported
}

public enum Socks5Response {
    case method
    case connected(Socks5ResponseType)
}

public final class Socks5Handler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = Socks5Request
    public typealias InboundOut = Never

    public typealias OutboundIn = Never
    public typealias OutboundOut = Socks5Response

    enum Socks5HandlerStatus {
        case readingVersionAndMethods
        case readingConnectHeader
    }

    let connector: Connector
    var status: Socks5HandlerStatus = .readingVersionAndMethods

    init(connector: Connector) {
        self.connector = connector
    }

    private static let encoderHandlerName = "LIT_SOCKS5_ENCODER"
    private static let decoderHandlerName = "LIT_SOCKS5_DECODER"

    public func addSelfAndCodec(to pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        pipeline.addHandler(ByteToMessageHandler(Socks5Decoder()), name: Socks5Handler.decoderHandlerName, position: .last)
            .flatMap {
                pipeline.addHandler(MessageToByteHandler(Socks5Encoder()), name: Socks5Handler.encoderHandlerName, position: .last)
            }
            .flatMap {
                pipeline.addHandler(self)
            }
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        context.read()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = unwrapInboundIn(data)

        let future: EventLoopFuture<Channel>
        switch request {
        case .method:
            context.write(wrapOutboundOut(.method)).whenSuccess {
                context.read()
            }
            return
        case let .connectToAddress(address):
            future = connector.connect(on: context.eventLoop, to: address)
        case let .connectTo(host: host, port: port):
            future = connector.connect(on: context.eventLoop, host: host, port: port)
        }

        future.whenComplete { result in
            switch result {
            case let .success(channel):
                context.writeAndFlush(self.wrapOutboundOut(.connected(.succeeded)), promise: nil)

                let (localGlue, peerGlue) = GlueHandler.matchedPair()
                // Note this all happens in the same event loop so the handlers are properly set up when this block is finished.
                // No need to worry if there will be any data coming in in the middle.
                context.channel.pipeline.addHandler(localGlue).and(channel.pipeline.addHandler(peerGlue))
                    .flatMap { _ in
                        context.pipeline.removeHandler(self)
                            .flatMap {
                                context.pipeline.removeHandler(name: Socks5Handler.decoderHandlerName)
                                    .flatMap {
                                        context.pipeline.removeHandler(name: Socks5Handler.encoderHandlerName)
                                    }
                            }
                    }
                    .whenComplete { result in
                        switch result {
                        case .success:
                            context.read()
                            channel.read()
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

private class Socks5Decoder: ByteToMessageDecoder {
    typealias InboundOut = Socks5Request

    enum Socks5HandlerStatus {
        case readingVersionAndMethods
        case readingConnectHeader
        case done
    }

    var status: Socks5HandlerStatus = .readingVersionAndMethods

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        switch status {
        case .readingVersionAndMethods:
            return try readVersionAndMethod(context: context, buffer: &buffer)
        case .readingConnectHeader:
            return try readConnectHeader(context: context, buffer: &buffer)
        case .done:
            throw Socks5HandlerError.protocolError
        }
    }

    func readVersionAndMethod(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= 3 else {
            return .needMoreData
        }

        guard buffer.readInteger(as: UInt8.self)! == 5 else {
            throw Socks5HandlerError.unsupportedVersion
        }

        guard let methodCount = buffer.readInteger(as: UInt8.self), methodCount > 0 else {
            throw Socks5HandlerError.noAuthMethodSpecified
        }

        guard buffer.readableBytes == methodCount else {
            if methodCount > buffer.readableBytes {
                throw Socks5HandlerError.tooManyMethods
            } else {
                buffer.moveReaderIndex(to: buffer.readerIndex - 2)
                return .needMoreData
            }
        }

        // Don't support any auth yet
        guard buffer.readBytes(length: Int(methodCount))!.reduce(false, { $1 == 0 }) else {
            throw Socks5HandlerError.noSupportedMethod
        }

        context.fireChannelRead(wrapInboundOut(.method))
        status = .readingConnectHeader
        return .needMoreData
    }

    private func readConnectHeader(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes > 6 else {
            return .needMoreData
        }

        guard buffer.readInteger(as: UInt8.self) == 5 else {
            throw Socks5HandlerError.unsupportedVersion
        }

        // Only TCP connect is supported.
        guard buffer.readInteger(as: UInt8.self) == 1 else {
            throw Socks5HandlerError.unSupportedCommand
        }

        guard buffer.readInteger(as: UInt8.self) == 0 else {
            throw Socks5HandlerError.protocolError
        }

        switch buffer.readInteger(as: UInt8.self) {
        case 1:
            guard buffer.readableBytes == 6 else {
                buffer.moveReaderIndex(to: buffer.readerIndex - 3)
                return .needMoreData
            }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr = buffer.readWithUnsafeReadableBytes {
                (4, $0.load(as: in_addr.self))
            }
            addr.sin_port = buffer.readInteger(endianness: .big, as: UInt16.self)!
            context.fireChannelRead(wrapInboundOut(.connectToAddress(SocketAddress(addr, host: ""))))
            status = .done
        case 3:
            guard let domainLength = buffer.readInteger(as: UInt8.self), domainLength > 0 else {
                throw Socks5HandlerError.invalidDomainLength
            }

            guard buffer.readableBytes == domainLength + 2 else {
                if buffer.readableBytes < domainLength + 2 {
                    buffer.moveReaderIndex(to: buffer.readerIndex - 4)
                    return .needMoreData
                } else {
                    throw Socks5HandlerError.protocolError
                }
            }

            let host = buffer.readString(length: Int(domainLength))!
            let port = buffer.readInteger(endianness: .big, as: UInt16.self)!
            context.fireChannelRead(wrapInboundOut(.connectTo(host: host, port: Int(port))))
            status = .done
        case 4:
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = buffer.readWithUnsafeReadableBytes {
                (16, $0.load(as: in6_addr.self))
            }
            addr.sin6_port = buffer.readInteger(endianness: .big, as: UInt16.self)!
            context.fireChannelRead(wrapInboundOut(.connectToAddress(SocketAddress(addr, host: ""))))
            status = .done
        default:
            throw Socks5HandlerError.invalidAddressType
        }

        return .needMoreData
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF _: Bool) throws -> DecodingState {
        // Generally this shouldn't be called with any data.
        try decode(context: context, buffer: &buffer)
    }
}

private class Socks5Encoder: MessageToByteEncoder {
    typealias OutboundIn = Socks5Response

    func encode(data: Socks5Response, out: inout ByteBuffer) throws {
        switch data {
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
    }
}
