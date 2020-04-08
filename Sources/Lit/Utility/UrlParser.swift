import Foundation

private let urlRegex = try! NSRegularExpression(pattern: #"^(?:(?:(https?):\/\/)?([\w\.-]+)(?::(\d+))?)?(\/.*)?$"#, options: NSRegularExpression.Options.caseInsensitive)

class UrlParser {
    struct ParseResult: Equatable {
        let scheme: String?
        let host: String?
        let port: Int?
        let path: String?

        static let nullResult: ParseResult = .init(scheme: nil, host: nil, port: nil, path: nil)
    }

    static func parse(url: String) -> ParseResult {
        guard let result = urlRegex.firstMatch(in: url, range: .init(url.startIndex ..< url.endIndex, in: url)) else {
            return .nullResult
        }

        guard result.numberOfRanges == 5, result.range(at: 0).location != NSNotFound else {
            return .nullResult
        }

        func checkRange(_ ind: Int) -> String? {
            let range = result.range(at: ind)
            if range.location != NSNotFound {
                return String(url[Range(range, in: url)!])
            } else {
                return nil
            }
        }

        return .init(scheme: checkRange(1), host: checkRange(2), port: checkRange(3).flatMap { Int($0) }, path: checkRange(4))
    }
}
