import Foundation

enum ProviderError: LocalizedError {
    case notImplemented
    case notLoggedIn(String)
    case tokenMissing
    case badResponse(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:      return "not implemented yet"
        case .notLoggedIn(let m):  return m
        case .tokenMissing:        return "no auth token found"
        case .badResponse(let m):  return "bad response: \(m)"
        case .decoding(let m):     return "decode error: \(m)"
        }
    }
}
