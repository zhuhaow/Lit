import NIO

public enum Socks5Request: Equatable {
    case method
    case connectToAddress(SocketAddress)
    // Avoid heap allocation
    // https://github.com/apple/swift-nio/blob/master/docs/optimization-tips.md#wrapping-types-in-nioany
    indirect case connectTo(host: String, port: Int)
}
