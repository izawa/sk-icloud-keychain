import Foundation
import LocalAuthentication

/// Touch ID gate. The keychain items carry no biometric ACL (such items cannot
/// sync), so this check in the helper is what enforces user verification.
enum UserVerification {
    /// `reason` completes the system prompt "<app> is trying to ...".
    static func require(reason: String) throws {
        let context = LAContext()
        context.localizedFallbackTitle = ""  // biometrics only, no password fallback
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw VerificationError.unavailable(error?.localizedDescription ?? "biometrics unavailable")
        }
        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .success(())
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, err in
            if !ok { result = .failure(VerificationError.failed(err?.localizedDescription ?? "authentication failed")) }
            done.signal()
        }
        done.wait()
        try result.get()
    }
}

enum VerificationError: Error, CustomStringConvertible {
    case unavailable(String)
    case failed(String)

    var description: String {
        switch self {
        case .unavailable(let m): return "Touch ID unavailable: \(m)"
        case .failed(let m): return "Touch ID failed: \(m)"
        }
    }
}
