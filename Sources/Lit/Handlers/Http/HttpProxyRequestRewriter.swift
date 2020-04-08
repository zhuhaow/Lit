import Foundation
import NIO
import NIOHTTP1

enum HttpProxyRewriteError: Error {
    case urlInvalid, hostMissing, endpointMismatch
}

class HttpProxyRequestRewriter {
    let checkEndpoingMatch: Bool
    let connector: Connector
    private var firstHeader = true
    private var connecting = false
    private let backlog = DataBacklog()
    private var host: String!
    private var port: Int!

    init(connector: Connector, checkEndpoingMatch: Bool = true) {
        self.connector = connector
        self.checkEndpoingMatch = checkEndpoingMatch
    }
}

extension HttpProxyRequestRewriter: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPClientRequestPart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case var .head(head):
            do {
                let (host_, port_) = try parseAndRewrite(head: &head)

                if firstHeader {
                    host = host_
                    port = port_
                } else if checkEndpoingMatch {
                    guard host_ == host, port_ == port else {
                        throw HttpProxyRewriteError.endpointMismatch
                    }
                }

                if firstHeader {
                    connecting = true
                    firstHeader = false
                    connector.connect(on: context.eventLoop, host: host_, port: port_).whenComplete { result in
                        switch result {
                        case let .success(channel):
                            self.glue(channel, context: context)
                        case let .failure(error):
                            context.fireErrorCaught(error)
                        }
                    }
                }

                passOnOrHold(context: context, data: wrapInboundOut(.head(head)))
            } catch {
                context.fireErrorCaught(error)
            }
        case let .body(buffer):
            passOnOrHold(context: context, data: wrapInboundOut(.body(.byteBuffer(buffer))))
        case let .end(header):
            passOnOrHold(context: context, data: wrapInboundOut(.end(header)))
        }
    }
}

extension HttpProxyRequestRewriter {
    func parseAndRewrite(head: inout HTTPRequestHead) throws -> (host: String, port: Int) {
        // Can't use stardard uri parser here since there are developers out there who
        // love to challenge the standards.
        let result = UrlParser.parse(url: head.uri)

        if result == UrlParser.ParseResult.nullResult {
            throw HttpProxyRewriteError.urlInvalid
        }

        let host_: String
        let port_: Int
        if result.host != nil {
            host_ = result.host!
            port_ = result.port ?? (result.scheme == .some("https") ? 443 : 80)
        } else {
            // Try to read from header field
            guard let hostHeader = head.headers.first(name: "host") else {
                throw HttpProxyRewriteError.hostMissing
            }

            let components = hostHeader.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            host_ = String(components.first!)
            port_ = components.last.flatMap { Int($0) } ?? 80
        }

        head.uri = result.path ?? "/"

        // Rewrite Proxy-Connection
        if let v = head.headers.first(name: "Proxy-Connection") {
            head.headers.remove(name: "Proxy-Connection")
            head.headers.add(name: "Connection", value: v)
        }

        // Remove all other proxy related header if exists
        head.headers.remove(name: "Proxy-Authorization")
        head.headers.remove(name: "Proxy-Authenticate")

        return (host: host_, port: port_)
    }

    private func glue(_ peerChannel: Channel, context: ChannelHandlerContext) {
        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        context.channel.pipeline.addHandler(localGlue)
            .and(peerChannel.pipeline.addHandler(HTTPRequestEncoder())
                .flatMap { peerChannel.pipeline.addHandler(peerGlue) })
            .whenComplete { _ in
                self.connecting = false

                self.backlog.flush(to: context)
            }
    }

    private func passOnOrHold(context: ChannelHandlerContext, data: NIOAny) {
        if connecting {
            backlog.add(data)
        } else {
            context.fireChannelRead(data)
        }
    }
}
