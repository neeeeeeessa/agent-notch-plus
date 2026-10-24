import CryptoKit
import Foundation

/// In-app Claude OAuth is retired in every build.
/// `signIn` and `refresh` fail before any browser, callback server, or network call.
/// PKCE helpers remain for compatibility tests and are not an entry point.
enum ClaudeCredentialAccessError: Error, Equatable, LocalizedError {
    case signInDisabled
    case refreshDisabled
    case sessionSaveDisabled

    var errorDescription: String? {
        switch self {
        case .signInDisabled:
            "Claude sign-in is disabled. Refresh the sign-in in Claude Code."
        case .refreshDisabled:
            "Claude token refresh is disabled. Refresh the sign-in in Claude Code."
        case .sessionSaveDisabled:
            "Saving a Claude session is disabled."
        }
    }
}

nonisolated enum ClaudeOAuthLogin {
    @MainActor
    static func signIn() async throws {
        throw ClaudeCredentialAccessError.signInDisabled
    }

    static func refresh(_ session: ClaudeOAuthSession) async throws -> ClaudeOAuthSession {
        throw ClaudeCredentialAccessError.refreshDisabled
    }
}

nonisolated enum PKCE {
    struct Pair: Equatable, Sendable {
        var verifier: String
        var challenge: String
    }

    static func generate() -> Pair {
        let verifier = random(bytes: 32)
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Pair(verifier: verifier, challenge: Data(hash).base64URL)
    }

    static func random(bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return Data(raw).base64URL
    }
}

extension Data {
    fileprivate nonisolated var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
