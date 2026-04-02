import Foundation

extension URL {
    /// Creates a URL from a static string literal, trapping if the string is not a valid URL.
    /// Use only for hardcoded URL constants that are known to be valid at compile time.
    init(staticString: StaticString) {
        guard let url = URL(string: String(describing: staticString)) else {
            preconditionFailure("Invalid URL string: \(staticString)")
        }
        self = url
    }
}
