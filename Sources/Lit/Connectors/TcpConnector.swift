import NIO

public class TcpConnector: Connector {
    public init() {}

    public func connect(on eventLoop: EventLoop, endpoint: Endpoint) -> EventLoopFuture<Channel> {
        switch endpoint {
        case let .address(addr):
            return ClientBootstrap(group: eventLoop).connect(to: addr)
        case let .domain(host, port):
            return ClientBootstrap(group: eventLoop).connect(host: host, port: port)
        }
    }
}
