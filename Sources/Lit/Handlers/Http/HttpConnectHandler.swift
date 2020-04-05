//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1

class HttpConnectHandler {
    let connector: Connector
    let decoderHandlerName: String
    let encoderHandlerName: String
    private var upgradeState: State = .idle

    init(connector: Connector, decoderHandlerName: String, encoderHandlerName: String) {
        self.connector = connector
        self.decoderHandlerName = decoderHandlerName
        self.encoderHandlerName = encoderHandlerName
    }
}

extension HttpConnectHandler {
    fileprivate enum State {
        case idle
        case beganConnecting
        case awaitingEnd(connectResult: Channel)
        case awaitingConnection(pendingBytes: [NIOAny])
        case upgradeComplete(pendingBytes: [NIOAny])
        case upgradeFailed
    }
}

extension HttpConnectHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch upgradeState {
        case .idle:
            handleInitialMessage(context: context, data: unwrapInboundIn(data))

        case .beganConnecting:
            // We got .end, we're still waiting on the connection
            if case .end = unwrapInboundIn(data) {
                self.upgradeState = .awaitingConnection(pendingBytes: [])
                self.removeDecoder(context: context)
            }

        case let .awaitingEnd(peerChannel):
            if case .end = unwrapInboundIn(data) {
                // Upgrade has completed!
                self.upgradeState = .upgradeComplete(pendingBytes: [])
                self.removeDecoder(context: context)
                self.glue(peerChannel, context: context)
            }

        case var .awaitingConnection(pendingBytes):
            // We've seen end, this must not be HTTP anymore. Danger, Will Robinson! Do not unwrap.
            upgradeState = .awaitingConnection(pendingBytes: [])
            pendingBytes.append(data)
            upgradeState = .awaitingConnection(pendingBytes: pendingBytes)

        case var .upgradeComplete(pendingBytes: pendingBytes):
            // We're currently delivering data, keep doing so.
            upgradeState = .upgradeComplete(pendingBytes: [])
            pendingBytes.append(data)
            upgradeState = .upgradeComplete(pendingBytes: pendingBytes)

        case .upgradeFailed:
            break
        }
    }
}

extension HttpConnectHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        var didRead = false

        // We are being removed, and need to deliver any pending bytes we may have if we're upgrading.
        while case var .upgradeComplete(pendingBytes) = upgradeState, pendingBytes.count > 0 {
            // Avoid a CoW while we pull some data out.
            upgradeState = .upgradeComplete(pendingBytes: [])
            let nextRead = pendingBytes.removeFirst()
            upgradeState = .upgradeComplete(pendingBytes: pendingBytes)

            context.fireChannelRead(nextRead)
            didRead = true
        }

        if didRead {
            context.fireChannelReadComplete()
        }

        context.leavePipeline(removalToken: removalToken)
    }
}

extension HttpConnectHandler {
    private func handleInitialMessage(context: ChannelHandlerContext, data: InboundIn) {
        guard case let .head(head) = data else {
            httpErrorAndClose(context: context)
            return
        }

        guard head.method == .CONNECT else {
            httpErrorAndClose(context: context)
            return
        }

        let components = head.uri.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = components.first! // There will always be a first.
        let port = components.last.flatMap { Int($0, radix: 10) } ?? 80 // Port 80 if not specified

        upgradeState = .beganConnecting
        connectTo(host: String(host), port: port, context: context)
    }

    private func connectTo(host: String, port: Int, context: ChannelHandlerContext) {
        let channelFuture = connector
            .connect(on: context.eventLoop, host: String(host), port: port)

        channelFuture.whenSuccess { channel in
            self.connectSucceeded(channel: channel, context: context)
        }
        channelFuture.whenFailure { error in
            self.connectFailed(error: error, context: context)
        }
    }

    private func connectSucceeded(channel: Channel, context: ChannelHandlerContext) {
        switch upgradeState {
        case .beganConnecting:
            // Ok, we have a channel, let's wait for end.
            upgradeState = .awaitingEnd(connectResult: channel)

        case let .awaitingConnection(pendingBytes: pendingBytes):
            // Upgrade complete! Begin gluing the connection together.
            upgradeState = .upgradeComplete(pendingBytes: pendingBytes)
            glue(channel, context: context)

        case .idle, .awaitingEnd, .upgradeFailed, .upgradeComplete:
            // These cases are logic errors, but let's be careful and just shut the connection.
            context.close(promise: nil)
        }
    }

    private func connectFailed(error: Error, context: ChannelHandlerContext) {
        switch upgradeState {
        case .beganConnecting, .awaitingConnection:
            // We still have a somewhat active connection here in HTTP mode, and can report failure.
            httpErrorAndClose(context: context)

        case .idle, .awaitingEnd, .upgradeFailed, .upgradeComplete:
            // Most of these cases are logic errors, but let's be careful and just shut the connection.
            context.close(promise: nil)
        }

        context.fireErrorCaught(error)
    }

    private func glue(_ peerChannel: Channel, context: ChannelHandlerContext) {
        // Ok, upgrade has completed! We now need to begin the upgrade process.
        // First, send the 200 message.
        // This content-length header is MUST NOT, but we need to workaround NIO's insistence that we set one.
        let headers = HTTPHeaders([("Content-Length", "0")])
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        // Now remove the HTTP encoder.
        removeEncoder(context: context)

        // Now we need to glue our channel and the peer channel together.
        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        context.channel.pipeline.addHandler(localGlue).and(peerChannel.pipeline.addHandler(peerGlue)).whenComplete { _ in
            context.pipeline.removeHandler(self, promise: nil)
        }
    }

    private func httpErrorAndClose(context: ChannelHandlerContext) {
        upgradeState = .upgradeFailed

        let headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .badRequest, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
    }

    private func removeDecoder(context: ChannelHandlerContext) {
        // We drop the future on the floor here as these handlers must all be in our own pipeline, and this should
        // therefore succeed fast.
        context.pipeline.removeHandler(name: decoderHandlerName, promise: nil)
    }

    private func removeEncoder(context: ChannelHandlerContext) {
        context.pipeline.removeHandler(name: encoderHandlerName, promise: nil)
    }
}
