import Testing
import Foundation
@testable import Sodalite

/// The two rules that keep a Swift type name off a viewer's screen, pinned against the sources rather
/// than against a habit.
///
/// `error.localizedDescription` on a type that does not conform to `LocalizedError` renders the bridged
/// NSError fallback, which names the type: "The operation couldn't be completed.
/// (Sodalite.DependencyContainer.ServerSwitchError error 0.)". No locale changes that, because the
/// untranslated half is an identifier. Both rules are checkable by reading the sources, and a rule that
/// is only remembered is a rule that lapses on the next new error type.
@MainActor
struct ErrorTextCoverageTests {

    /// Diagnostics keep the raw description on purpose: a log line is read by us, and translating it
    /// hides the sentence the failure actually carried.
    private static let logMarkers = ["LogTap", "logLine", ".note(", "print(", "os_log", ".notice(", ".error(", ".debug(", "Logger("]

    /// Owns the one legitimate read, and its doc comment names the trap.
    private static let readerOfLastResort = "Sodalite/Services/Networking/ErrorText.swift"

    @Test func everyErrorTypeCanDescribeItselfInTheViewersLanguage() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let name = Self.errorTypeDeclaration(in: String(line)) else { continue }
                if !line.contains("LocalizedError") {
                    offenders.append("\(file.lastPathComponent): \(name)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            These types conform to Error without LocalizedError, so localizedDescription renders their \
            Swift type name at the viewer: \(offenders.joined(separator: ", "))
            """
        )
    }

    @Test func noViewerFacingTextIsReadStraightOffLocalizedDescription() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources() {
            let relative = Self.relativePath(of: file)
            guard relative != Self.readerOfLastResort else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("localizedDescription") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if Self.logMarkers.contains(where: { line.contains($0) }) { continue }
                offenders.append("\(relative):\(index + 1)")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            These read localizedDescription outside a log line; ask ErrorText.user(for:) instead so a \
            foreign error type cannot reach a viewer untranslated: \(offenders.joined(separator: ", "))
            """
        )
    }

    // MARK: - Source scanning

    /// `enum X: Error`, `struct X: Error, Sendable`, and so on. Protocol declarations are excluded: a
    /// protocol refining Error is a shape, not a thrown value.
    private static let declarationPattern = try! Regex(
        #"^\s*(?:public |internal |private |fileprivate |final )*(?:enum|struct|class)\s+(\w+)\s*:\s*([^{]+)\{"#
    )

    private static func errorTypeDeclaration(in line: String) -> String? {
        guard let match = line.firstMatch(of: Self.declarationPattern),
              let name = match[1].substring,
              let conformances = match[2].substring
        else { return nil }
        let list = conformances.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard list.contains(where: { $0 == "Error" || $0 == "LocalizedError" }) else { return nil }
        return String(name)
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func relativePath(of file: URL) -> String {
        file.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
    }

    private static func swiftSources() throws -> [URL] {
        let root = repositoryRoot().appendingPathComponent("Sodalite")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The scan is worthless if it walks an empty tree, which is exactly how a path typo would present.
    @Test func theScanActuallyReadsTheSources() throws {
        let files = try Self.swiftSources()
        #expect(files.count > 100)
        #expect(files.contains { Self.relativePath(of: $0) == Self.readerOfLastResort })
    }
}
