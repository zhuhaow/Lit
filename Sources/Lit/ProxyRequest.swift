import NIO

public enum Endpoint {
    case address(SocketAddress)
    case domain(String, Int)
}

public enum ProxyRequest<T> {
    case endpoint(Endpoint), data(T)
}
