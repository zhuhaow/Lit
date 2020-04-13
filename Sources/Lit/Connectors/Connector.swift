import NIO

public enum Endpoint {
    case domain(String, Int)
    case address(SocketAddress)
}

public protocol Connector {
    func connect(on eventLoop: EventLoop, endpoint: Endpoint) -> EventLoopFuture<Channel>
}
