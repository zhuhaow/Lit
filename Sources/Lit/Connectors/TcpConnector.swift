import NIO

public class TcpConnector: Connector {
    public func connect(on eventLoop: EventLoop, to address: SocketAddress) -> EventLoopFuture<Channel> {
        buildBootstrap(on: eventLoop).connect(to: address)
    }

    public func connect(on eventLoop: EventLoop, host: String, port: Int) -> EventLoopFuture<Channel> {
        buildBootstrap(on: eventLoop).connect(host: host, port: port)
    }

    private func buildBootstrap(on eventLoop: EventLoop) -> ClientBootstrap {
        ClientBootstrap(group: eventLoop)
    }
}
