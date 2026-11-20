import Foundation
import Security
@testable import Strimr
import Testing

struct KeychainErrorTests {
    @Test func `Keychain errors retain the actual Security status without exposing credentials`() {
        let error = KeychainError.unexpectedStatus(errSecMissingEntitlement)
        #expect(error.localizedDescription.contains(String(errSecMissingEntitlement)))
        #expect(error.localizedDescription.contains("entitlements"))
        #expect(error.localizedDescription.contains("unsigned simulator"))
        #expect(!error.localizedDescription.contains("error 0"))
    }

    @Test func `locked device and invalid credential diagnostics are actionable`() {
        #expect(KeychainError.unexpectedStatus(errSecInteractionNotAllowed).localizedDescription.contains("Unlock"))
        #expect(KeychainError.invalidItem.localizedDescription.contains("Settings"))
    }
}
