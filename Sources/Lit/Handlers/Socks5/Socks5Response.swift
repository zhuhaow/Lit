public enum Socks5ResponseType: UInt8 {
    case succeeded
    case generalFailue
    case connectionNotAllowed
    case networkUnreachable
    case connectionRefused
    case ttlExpired
    case commandNotSupported
    case addressTypeNotSupported
}

public enum Socks5Response: Equatable {
    case method
    case connected(Socks5ResponseType)
}
