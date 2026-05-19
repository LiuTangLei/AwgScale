import Foundation

struct InAppBrowserRequest: Encodable {
    let url: String
    let timeoutMillis: Int
}

struct InAppBrowserPage: Decodable {
    let url: String
    let statusCode: Int
    let headers: [String: String]
    let contentType: String
    let body: String?
    let bodyBase64: String?
    let truncated: Bool
}

struct InAppBrowserProxy: Decodable {
    let type: String
    let host: String
    let port: Int
    let address: String
}

struct InAppTerminalRequest: Encodable {
    let host: String
    let port: Int
    let payload: String
    let appendNewline: Bool
    let timeoutMillis: Int
}

struct InAppTerminalResponse: Decodable {
    let body: String?
    let bodyBase64: String?
    let truncated: Bool
}

struct InAppSSHOpenRequest: Encodable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let privateKey: String
    let passphrase: String
    let terminal: String
    let columns: Int
    let rows: Int
    let timeoutMillis: Int
}

struct InAppSSHSessionRequest: Encodable {
    let sessionID: String
}

struct InAppSSHSendRequest: Encodable {
    let sessionID: String
    let input: String
}

struct InAppSSHResponse: Decodable {
    let sessionID: String
    let body: String?
    let bodyBase64: String?
    let active: Bool
    let truncated: Bool
}