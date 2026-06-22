import Foundation

enum APIError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, data: Data?)
    case decodingError(Error)
    case networkError(Error)
    /// 401; `message` carries the server-provided reason when present so the user sees a real explanation.
    case unauthorized(message: String?)
    case serverUnreachable
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "error.invalidURL", defaultValue: "Invalid URL")
        case .invalidResponse:
            String(localized: "error.invalidResponse", defaultValue: "Invalid server response")
        case .httpError(let statusCode, let data):
            if let message = Self.extractErrorMessage(from: data) {
                String(
                    localized: "error.httpError.withMessage",
                    defaultValue: "HTTP \(statusCode) · \(message)"
                )
            } else {
                String(localized: "error.httpError", defaultValue: "Server error (\(statusCode))")
            }
        case .decodingError:
            String(localized: "error.decodingError", defaultValue: "Failed to process server response")
        case .networkError:
            String(localized: "error.networkError", defaultValue: "Network connection failed")
        case .unauthorized(let message):
            message ?? String(localized: "error.unauthorized", defaultValue: "Authentication required")
        case .serverUnreachable:
            String(localized: "error.serverUnreachable", defaultValue: "Server unreachable")
        case .timeout:
            String(localized: "error.timeout", defaultValue: "Request timed out")
        }
    }

    /// True for `.unauthorized` (401) and `.httpError(403, _)`: Seerr admin gates surface as 403, cookie expiry as 401, both → permission-denied toast.
    var isUnauthorized: Bool {
        switch self {
        case .unauthorized:                                return true
        case .httpError(let code, _) where code == 403:   return true
        default:                                           return false
        }
    }

    /// True for `.httpError(404, _)`: admin mutation paths silently reload when another admin already changed the request.
    var isNotFound: Bool {
        if case .httpError(404, _) = self { return true }
        return false
    }

    static func extractErrorMessage(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (json["message"] as? String) ?? (json["error"] as? String),
           !message.isEmpty {
            return message
        }
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(200))
    }
}
