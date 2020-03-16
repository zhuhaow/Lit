import Foundation
import NIO

protocol Connector {
    func connect(host: String, port: Int) -> EventLoopFuture<Channel>
    func connect(to address: SocketAddress) -> EventLoopFuture<Channel>
}
