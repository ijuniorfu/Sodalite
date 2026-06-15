import Foundation
import CommonCrypto

/// PBKDF2-HMAC-SHA256 hashing for the Guardian-PIN. A 4-digit PIN has
/// only 10_000 combinations, so the keychain throttle (see
/// `DependencyContainer`) is the primary defense; PBKDF2 with a high
/// iteration count and a random per-PIN salt slows offline brute force
/// of a stolen keychain blob. Never stores or returns plaintext.
enum GuardianPINCrypto {
    /// Cost factor. High enough to be ~tens of ms on Apple TV hardware,
    /// low enough not to stall the unlock UI.
    static let iterations: Int = 120_000
    private static let keyByteCount = 32 // SHA-256 output
    private static let saltByteCount = 16

    struct Blob: Codable, Equatable {
        let salt: Data
        let hash: Data
        let iterations: Int
    }

    /// Derives a fresh blob (new random salt) for `pin`.
    static func makeBlob(pin: String) -> Blob {
        var salt = Data(count: saltByteCount)
        _ = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltByteCount, ptr.baseAddress!)
        }
        let hash = derive(pin: pin, salt: salt, iterations: iterations)
        return Blob(salt: salt, hash: hash, iterations: iterations)
    }

    /// Constant-time verify of `pin` against a stored blob.
    static func verify(pin: String, blob: Blob) -> Bool {
        let candidate = derive(pin: pin, salt: blob.salt, iterations: blob.iterations)
        return constantTimeEquals(candidate, blob.hash)
    }

    private static func derive(pin: String, salt: Data, iterations: Int) -> Data {
        let pinBytes = Array(pin.utf8)
        var derived = Data(count: keyByteCount)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pinBytes.map { Int8(bitPattern: $0) }, pinBytes.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    derivedPtr.bindMemory(to: UInt8.self).baseAddress, keyByteCount
                )
            }
        }
        // kCCSuccess == 0. A failure here means the OS rejected the
        // params; return empty so verify never matches (fail closed).
        return status == kCCSuccess ? derived : Data()
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
