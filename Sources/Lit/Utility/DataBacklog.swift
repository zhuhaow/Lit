import NIO

class DataBacklog {
    var pendingData: [NIOAny] = []

    func add(_ data: NIOAny) {
        pendingData.append(data)
    }

    func flush(to context: ChannelHandlerContext) {
        let hasPending = !pendingData.isEmpty

        // Avoid using `forEach` which might require the data to be copied
        while !pendingData.isEmpty {
            let data = pendingData.removeFirst()
            context.fireChannelRead(data)
        }

        if hasPending {
            context.fireChannelReadComplete()
        }
    }
}
