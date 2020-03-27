public enum Socks5HandlerError: Error {
    case unsupportedVersion
    case noAuthMethodSpecified
    case tooManyMethods
    case noSupportedMethod
    case unSupportedCommand
    case protocolError
    case invalidDomainLength
    case invalidAddressType
}
