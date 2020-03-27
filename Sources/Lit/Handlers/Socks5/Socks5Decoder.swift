import NIO

class Socks5Decoder {
    enum Socks5HandlerStatus {
        case readingVersionAndMethods
        case readingConnectHeader
        case done
    }

    var status: Socks5HandlerStatus = .readingVersionAndMethods
}

extension Socks5Decoder: ByteToMessageDecoder {
    typealias InboundOut = Socks5Request

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

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF _: Bool) throws -> DecodingState {
        // Generally this shouldn't be called with any data.
        try decode(context: context, buffer: &buffer)
    }
}

extension Socks5Decoder {
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
            if methodCount < buffer.readableBytes {
                throw Socks5HandlerError.tooManyMethods
            } else {
                buffer.moveReaderIndex(to: buffer.readerIndex - 2)
                return .needMoreData
            }
        }

        // Don't support any auth yet
        guard buffer.readBytes(length: Int(methodCount))!.reduce(false, { $0 || $1 == 0 }) else {
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
                buffer.moveReaderIndex(to: buffer.readerIndex - 4)
                return .needMoreData
            }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr = buffer.readWithUnsafeReadableBytes {
                (4, $0.load(as: in_addr.self))
            }
            addr.sin_port = buffer.readInteger(endianness: .big, as: UInt16.self)!.bigEndian
            context.fireChannelRead(wrapInboundOut(.connectToAddress(SocketAddress(addr, host: ""))))
            status = .done
        case 3:
            guard let domainLength = buffer.readInteger(as: UInt8.self), domainLength > 0 else {
                throw Socks5HandlerError.invalidDomainLength
            }

            guard buffer.readableBytes == domainLength + 2 else {
                if buffer.readableBytes < domainLength + 2 {
                    buffer.moveReaderIndex(to: buffer.readerIndex - 5)
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
            guard buffer.readableBytes == 18 else {
                buffer.moveReaderIndex(to: buffer.readerIndex - 4)
                return .needMoreData
            }

            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = buffer.readWithUnsafeReadableBytes {
                (16, $0.load(as: in6_addr.self))
            }
            addr.sin6_port = buffer.readInteger(endianness: .big, as: UInt16.self)!.bigEndian
            context.fireChannelRead(wrapInboundOut(.connectToAddress(SocketAddress(addr, host: ""))))
            status = .done
        default:
            throw Socks5HandlerError.invalidAddressType
        }

        return .needMoreData
    }
}
