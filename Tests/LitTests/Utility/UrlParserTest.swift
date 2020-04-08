@testable import Lit
import XCTest

class UrlParserTests: XCTestCase {
    func testParseFullHttpUrl() {
        XCTAssertEqual(UrlParser.parse(url: "http://www.example.com/example"),
                       UrlParser.ParseResult(scheme: "http", host: "www.example.com", port: nil, path: "/example"))
        XCTAssertEqual(UrlParser.parse(url: "http://www.example.com/example/"),
                       UrlParser.ParseResult(scheme: "http", host: "www.example.com", port: nil, path: "/example/"))
        XCTAssertEqual(UrlParser.parse(url: "https://www.example.com/example/"),
                       UrlParser.ParseResult(scheme: "https", host: "www.example.com", port: nil, path: "/example/"))
        XCTAssertEqual(UrlParser.parse(url: "https://www.example.com/example/"),
                       UrlParser.ParseResult(scheme: "https", host: "www.example.com", port: nil, path: "/example/"))
        XCTAssertEqual(UrlParser.parse(url: "https://www.example.com:80/example/"),
                       UrlParser.ParseResult(scheme: "https", host: "www.example.com", port: 80, path: "/example/"))
        XCTAssertEqual(UrlParser.parse(url: "https://www.example.com:80"),
                       UrlParser.ParseResult(scheme: "https", host: "www.example.com", port: 80, path: nil))
        XCTAssertEqual(UrlParser.parse(url: "https://www.example.com:80/"),
                       UrlParser.ParseResult(scheme: "https", host: "www.example.com", port: 80, path: "/"))
    }

    func testParsePartialHttpUrl() {
        XCTAssertEqual(UrlParser.parse(url: "/example"),
                       UrlParser.ParseResult(scheme: nil, host: nil, port: nil, path: "/example"))
        XCTAssertEqual(UrlParser.parse(url: "/"),
                       UrlParser.ParseResult(scheme: nil, host: nil, port: nil, path: "/"))
    }
}
