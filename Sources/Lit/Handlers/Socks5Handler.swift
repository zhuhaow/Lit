import NIO

public final class Socks5Handler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = Never

    public typealias OutboundIn = Never
    public typealias OutboundOut = ByteBuffer

    enum AddressType {
        case ipv4, domain, ipv6
    }

    enum Socks5HandlerStatus {
        case readingVersionAndMethods
        case readingConnectHeader
        case waitingConnection(AddressType)
    }

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

    enum Socks5ResponseType: UInt8 {
        case succeeded
        case generalFailue
        case connectionNotAllowed
        case networkUnreachable
        case connectionRefused
        case ttlExpired
        case commandNotSupported
        case addressTypeNotSupported
    }

    let connector: Connector
    var status: Socks5HandlerStatus = .readingVersionAndMethods
    var cache: ByteBuffer?

    init(connector: Connector) {
        self.connector = connector
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        buffer = consumeBuffer(buffer: &buffer)

        switch status {
        case .readingVersionAndMethods:
            readVersionAndMethod(context: context, buffer: &buffer)
        case .readingConnectHeader:
            readConnectHeader(context: context, buffer: &buffer)
        case .waitingConnection:
            context.fireErrorCaught(Socks5HandlerError.protocolError)
        }
    }

    private func readVersionAndMethod(context: ChannelHandlerContext, buffer: inout ByteBuffer) {
        guard buffer.readableBytes >= 3 else {
            cacheBuffer(buffer: &buffer)
            return
        }

        guard buffer.readInteger(as: UInt8.self)! == 5 else {
            context.fireErrorCaught(Socks5HandlerError.unsupportedVersion)
            return
        }

        guard let methodCount = buffer.readInteger(as: UInt8.self), methodCount > 0 else {
            context.fireErrorCaught(Socks5HandlerError.noAuthMethodSpecified)
            return
        }

        guard buffer.readableBytes == methodCount else {
            if methodCount > buffer.readableBytes {
                context.fireErrorCaught(Socks5HandlerError.tooManyMethods)
            } else {
                cacheBuffer(buffer: &buffer)
            }
            return
        }

        // Don't support any auth yet
        guard buffer.readBytes(length: Int(methodCount))!.reduce(false, { $1 == 0 }) else {
            context.fireErrorCaught(Socks5HandlerError.noSupportedMethod)
            return
        }

        buffer.clear()
        buffer.writeBytes([5, 0])
        context.write(wrapOutboundOut(buffer), promise: nil)
        status = .readingConnectHeader
    }

    private func readConnectHeader(context: ChannelHandlerContext, buffer: inout ByteBuffer) {
        guard buffer.readableBytes > 6 else {
            cacheBuffer(buffer: &buffer)
            return
        }

        guard buffer.readInteger(as: UInt8.self) == 5 else {
            context.fireErrorCaught(Socks5HandlerError.unsupportedVersion)
            return
        }

        // Only TCP connect is supported.
        guard buffer.readInteger(as: UInt8.self) == 1 else {
            context.fireErrorCaught(Socks5HandlerError.unSupportedCommand)
            return
        }

        guard buffer.readInteger(as: UInt8.self) == 0 else {
            context.fireErrorCaught(Socks5HandlerError.protocolError)
            return
        }

        let future: EventLoopFuture<Channel>
        switch buffer.readInteger(as: UInt8.self) {
        case 1:
            guard buffer.readableBytes == 6 else {
                cacheBuffer(buffer: &buffer)
                return
            }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr = buffer.readWithUnsafeReadableBytes {
                (4, $0.load(as: in_addr.self))
            }
            addr.sin_port = buffer.readInteger(endianness: .big, as: UInt16.self)!
            future = connector.connect(on: context.eventLoop, to: .init(addr, host: ""))
            status = .waitingConnection(.ipv4)
        case 3:
            guard let domainLength = buffer.readInteger(as: UInt8.self), domainLength > 0 else {
                context.fireErrorCaught(Socks5HandlerError.invalidDomainLength)
                return
            }

            guard buffer.readableBytes == domainLength + 2 else {
                if buffer.readableBytes < domainLength + 2 {
                    cacheBuffer(buffer: &buffer)
                    return
                } else {
                    context.fireErrorCaught(Socks5HandlerError.protocolError)
                    return
                }
            }

            let host = buffer.readString(length: Int(domainLength))!
            let port = buffer.readInteger(endianness: .big, as: UInt16.self)!
            future = connector.connect(on: context.eventLoop, host: host, port: Int(port))
            status = .waitingConnection(.domain)
        case 4:
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = buffer.readWithUnsafeReadableBytes {
                (16, $0.load(as: in6_addr.self))
            }
            addr.sin6_port = buffer.readInteger(endianness: .big, as: UInt16.self)!
            future = connector.connect(on: context.eventLoop, to: .init(addr, host: ""))
            status = .waitingConnection(.ipv6)
        default:
            context.fireErrorCaught(Socks5HandlerError.invalidAddressType)
            return
        }

        future.whenComplete { result in
            switch result {
            case let .success(channel):
                guard case let .waitingConnection(type) = self.status else {
                    return
                }

                let buffer = self.build(response: .succeeded, for: type, with: context.channel.allocator)
                context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)

                let (localGlue, peerGlue) = GlueHandler.matchedPair()
                context.channel.pipeline.addHandler(localGlue).and(channel.pipeline.addHandler(peerGlue)).whenComplete { _ in
                    context.pipeline.removeHandler(self, promise: nil)
                }
            case let .failure(error):
                context.fireErrorCaught(error)
            }
        }
    }

    private func consumeBuffer(buffer: inout ByteBuffer) -> ByteBuffer {
        if var cache = cache {
            // Avoid CoW
            self.cache = nil
            cache.writeBuffer(&buffer)
            return cache
        } else {
            return buffer
        }
    }

    private func cacheBuffer(buffer: inout ByteBuffer) {
        buffer.moveReaderIndex(to: 0)
        cache = buffer
    }

    private func build(response: Socks5ResponseType, for type: AddressType, with allocator: ByteBufferAllocator) -> ByteBuffer {
        guard case let .waitingConnection(type) = status else {
            preconditionFailure()
        }

        let length: Int
        let typeValue: UInt8
        switch type {
        case .ipv4, .domain:
            length = 4
            typeValue = 1
        case .ipv6:
            length = 16
            typeValue = 4
        }

        var buffer = allocator.buffer(capacity: 6 + length)

        buffer.writeInteger(5 as UInt8)
        buffer.writeInteger(response.rawValue)
        buffer.writeInteger(0 as UInt8)
        buffer.writeInteger(typeValue)
        buffer.writeBytes([UInt8](repeating: 0, count: buffer.writableBytes))

        return buffer
    }
}
