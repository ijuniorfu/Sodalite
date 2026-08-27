import Foundation

/// One-line renderings of a failed HTTP round trip, for `LogTap`.
///
/// Emitted from the `HTTPClient` funnel rather than per service (Sodalite#88). A caller that writes
/// `try?` around a request removes the error from the code, and until this existed it removed the
/// failure from the diagnostic log with it: an empty grid and a 400 read identically in
/// Settings > Diagnostic Log, so "No albums found" could not be told apart from "the request threw".
/// One place, so a service written tomorrow reports its failures without anyone remembering to.
///
/// The whole URL including the query is logged on purpose: `Fields=` / `IncludeItemTypes=` is
/// usually the answer to the question the failure raises, and credentials are stripped on the way
/// into `LogTap` by `LogRedaction`.
enum HTTPDiagnostics {

    /// Server answered, with a status the client rejects.
    static func status(method: String, url: URL, statusCode: Int, body: Data?) -> String {
        let message = APIError.extractErrorMessage(from: body).map { ": \($0)" } ?? ""
        return "[http] \(method) \(url.absoluteString) -> \(statusCode)\(message)"
    }

    /// Never got an answer (timeout, unreachable host, TLS). Cancellation is not a failure and is
    /// not logged: the home fan-out cancels routinely and would bury everything else.
    static func transport(method: String, url: URL, error: Error) -> String {
        "[http] \(method) \(url.absoluteString) -> transport: \(describe(error))"
    }

    /// Answered 2xx, and the body did not fit the type the caller asked for.
    static func decode(method: String, url: URL, type: Any.Type, error: Error) -> String {
        "[http] \(method) \(url.absoluteString) -> decode \(type): \(describe(error))"
    }

    /// Stable text for the error.
    ///
    /// Deliberately not the localized sentence: this line is read by someone else, usually from a
    /// screenshot taken on a device set to a language neither of us reads, and a translated
    /// "Zeitueberschreitung" answers less than `-1001 timedOut` does. The numeric code and the
    /// decoding key path carry the meaning, and both survive any locale.
    static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            return describe(decoding)
        }
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue)\(Self.name(of: urlError.code).map { " " + $0 } ?? "")"
        }
        return "\(error)"
    }

    /// English name for the transport failures worth recognising on sight. Anything else is left as
    /// its number, which is still unambiguous.
    private static func name(of code: URLError.Code) -> String? {
        switch code {
        case .timedOut:                   "timedOut"
        case .cannotConnectToHost:        "cannotConnectToHost"
        case .cannotFindHost:             "cannotFindHost"
        case .dnsLookupFailed:            "dnsLookupFailed"
        case .notConnectedToInternet:     "notConnectedToInternet"
        case .networkConnectionLost:      "networkConnectionLost"
        case .secureConnectionFailed:     "secureConnectionFailed"
        case .serverCertificateUntrusted: "serverCertificateUntrusted"
        case .badServerResponse:          "badServerResponse"
        case .appTransportSecurityRequiresSecureConnection: "appTransportSecurityRequiresSecureConnection"
        default:                          nil
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key \(key.stringValue) at \(path(context))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "null \(type) at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupted at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    /// `Items[3].RunTimeTicks`. Array indices arrive as unnamed keys whose `stringValue` is
    /// "Index 3", so they are rewritten to the subscript that names them at a glance.
    private static func path(_ context: DecodingError.Context) -> String {
        guard !context.codingPath.isEmpty else { return "<root>" }
        var rendered = ""
        for key in context.codingPath {
            if let index = key.intValue {
                rendered += "[\(index)]"
            } else {
                rendered += rendered.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return rendered
    }
}
