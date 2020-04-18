import NIO

public enum Endpoint {
    case domain(String, Int)
    case address(SocketAddress)
}

extension Endpoint {
    public var host: String {
        switch self {
        case .domain(let d, _):
            return d
        case .address(let addr):
            return addr.ipAddress!
        }
    }
    
    public var port: Int {
        switch self {
        case .domain(_, let p):
            return p
        case .address(let addr):
            return addr.port!
        }
    }
}

public protocol Connector {
    func connect(on eventLoop: EventLoop, endpoint: Endpoint) -> EventLoopFuture<Channel>
}
