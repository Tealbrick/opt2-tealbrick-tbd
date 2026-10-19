import Foundation
import LocalAuthentication
import Security
import TBDModels

/// Keychain items with the names CREDENTIALS §12 fixes:
/// - `tealbrick.person` (account = Portal origin): the person's owner native session (K3).
///   Stored with user presence (Touch ID or the login password) when macOS supports it for
///   this app (data-protection keychain); otherwise this device only, when unlocked.
/// - `tealbrick.agent.<con>` (account `k4`): TBD's agent key (see TBDAgentKeys). No user
///   presence: the agent signs short assertions unattended in the background.
enum TBDKeychain {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static let personService = TBDIdentity.keychainService("person")

  // MARK: person session (K3)

  static func personLoad(origin: String) throws -> String? {
    let context = LAContext()
    context.localizedReason = "open your Teal Brick sign-in"
    for dataProtection in [true, false] {
      var q = base(personService, origin, dataProtection: dataProtection)
      q[kSecReturnData as String] = true
      q[kSecMatchLimit as String] = kSecMatchLimitOne
      if dataProtection { q[kSecUseAuthenticationContext as String] = context }
      var out: CFTypeRef?
      let status = SecItemCopyMatching(q as CFDictionary, &out)
      if status == errSecSuccess, let data = out as? Data { return String(data: data, encoding: .utf8) }
      if status == errSecItemNotFound || status == errSecMissingEntitlement || status == -34018 { continue }
      if status == errSecUserCanceled || status == errSecAuthFailed { throw Failure(message: "Sign-in access was not confirmed.") }
      throw Failure(message: "Unable to read the sign-in (\(status))")
    }
    return nil
  }

  static func personSave(origin: String, value: String) throws {
    try personClear(origin: origin)
    let data = Data(value.utf8)
    // Preferred: user presence, data-protection keychain.
    if let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) {
      var add = base(personService, origin, dataProtection: true)
      add[kSecValueData as String] = data
      add[kSecAttrAccessControl as String] = access
      let status = SecItemAdd(add as CFDictionary, nil)
      if status == errSecSuccess { return }
      guard status == errSecMissingEntitlement || status == -34018 || status == errSecParam else {
        throw Failure(message: "Unable to store the sign-in (\(status))")
      }
    }
    // Fallback where user presence is not available to this build: this device only, when unlocked.
    var add = base(personService, origin, dataProtection: false)
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw Failure(message: "Unable to store the sign-in (\(status))") }
  }

  static func personClear(origin: String) throws {
    for dataProtection in [true, false] {
      let status = SecItemDelete(base(personService, origin, dataProtection: dataProtection) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement || status == -34018 else {
        throw Failure(message: "Unable to remove the sign-in (\(status))")
      }
    }
  }

  // MARK: generic

  static func base(_ service: String, _ account: String, dataProtection: Bool = false) -> [String: Any] {
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: account]
    if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
    return q
  }
}
