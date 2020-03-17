/// ===----------------------------------------------------------------------===//
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

final class GlueHandler {
    private var partner: GlueHandler?

    private var context: ChannelHandlerContext?

    private var pendingRead: Bool = false

    private init() {}
}

extension GlueHandler {
    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()

        first.partner = second
        second.partner = first

        return (first, second)
    }
}

extension GlueHandler {
    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        return context?.channel.isWritable ?? false
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context _: ChannelHandlerContext) {
        context = nil
        partner = nil
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context _: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context _: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context _: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // We have read EOF.
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context _: ChannelHandlerContext, error _: Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner = self.partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
