import Foundation

enum LocalAPIError: Error, LocalizedError {
    case backend(String)
    case unsuccessfulStatus(statusCode: Int, endpoint: String, bodyPreview: String?)
    case missingBody(endpoint: String)
    case invalidBodyEncoding(endpoint: String)
    case decoding(endpoint: String, underlying: Error, bodyPreview: String?)

    var errorDescription: String? {
        switch self {
        case .backend(let message):
            return message
        case .unsuccessfulStatus(let statusCode, let endpoint, let bodyPreview):
            if let bodyPreview, !bodyPreview.isEmpty {
                return "LocalAPI \(endpoint) returned HTTP \(statusCode): \(bodyPreview)"
            }
            return "LocalAPI \(endpoint) returned HTTP \(statusCode)"
        case .missingBody(let endpoint):
            return "LocalAPI \(endpoint) returned no response body"
        case .invalidBodyEncoding(let endpoint):
            return "LocalAPI \(endpoint) returned an invalid response body"
        case .decoding(let endpoint, let underlying, let bodyPreview):
            if let bodyPreview, !bodyPreview.isEmpty {
                return "LocalAPI \(endpoint) decode failed: \(underlying.localizedDescription); body=\(bodyPreview)"
            }
            return "LocalAPI \(endpoint) decode failed: \(underlying.localizedDescription)"
        }
    }
}

extension IPCResponse {
    func requireSuccess(endpoint: String) throws {
        if let error {
            throw LocalAPIError.backend(error)
        }
        guard (200..<300).contains(statusCode) else {
            throw LocalAPIError.unsuccessfulStatus(
                statusCode: statusCode,
                endpoint: endpoint,
                bodyPreview: bodyPreview()
            )
        }
    }

    func bodyData(endpoint: String) throws -> Data {
        try requireSuccess(endpoint: endpoint)
        guard let bodyBase64 else {
            throw LocalAPIError.missingBody(endpoint: endpoint)
        }
        guard let data = Data(base64Encoded: bodyBase64) else {
            throw LocalAPIError.invalidBodyEncoding(endpoint: endpoint)
        }
        return data
    }

    func decodedBody<T: Decodable>(_ type: T.Type, endpoint: String, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try bodyData(endpoint: endpoint)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LocalAPIError.decoding(endpoint: endpoint, underlying: error, bodyPreview: bodyPreview())
        }
    }

    func bodyPreview(limit: Int = 512) -> String? {
        guard let bodyBase64,
              let data = Data(base64Encoded: bodyBase64),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }
}