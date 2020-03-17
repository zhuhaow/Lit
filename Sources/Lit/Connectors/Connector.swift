import Foundation
import NIO

protocol Connector {
    func connect(on eventLoop: EventLoop, host: String, port: Int) -> EventLoopFuture<Channel>
    func connect(on eventLoop: EventLoop, to address: SocketAddress) -> EventLoopFuture<Channel>
}
