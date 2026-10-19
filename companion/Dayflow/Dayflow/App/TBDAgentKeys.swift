import CryptoKit
import Foundation
import Security
import TBDModels

/// TBD's AGENT key (K4, CREDENTIALS §9, §12 b): an Ed25519 key pair whose private
/// half never leaves this process. It lives in the Keychain (this device only,
/// when unlocked) as item `com.tealbrick.desktop.agent.<label>` (account `k4`); after Portal
/// approves the connection the label becomes the connection id, so the item is
/// `com.tealbrick.desktop.agent.<con>` (the spec's `tealbrick.agent.<con>` under TBD v2's own prefix, C284). The Chat helper can ask for the public JWK and for
/// signatures over agent assertions; it never receives the private key.
enum TBDAgentKeys {
  static let servicePrefix = TBDIdentity.keychainService("agent") + "."
  static let account = "k4"

  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// Creates a new key under `label` (fails if one exists) and returns its public JWK.
  static func create(label: String) throws -> [String: String] {
    try validate(label)
    if try load(label) != nil { throw Failure(message: "Agent key already exists") }
    let key = Curve25519.Signing.PrivateKey()
    var add = base(label)
    add[kSecValueData as String] = key.rawRepresentation
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw Failure(message: "Unable to store agent key (\(status))") }
    return jwk(key.publicKey)
  }

  static func publicJwk(label: String) throws -> [String: String] {
    guard let key = try load(label) else { throw Failure(message: "No agent key") }
    return jwk(key.publicKey)
  }

  /// Signs the JWS signing input (`base64url(header).base64url(payload)`, ASCII) and returns base64url(signature).
  static func sign(label: String, signingInput: String) throws -> String {
    guard let key = try load(label) else { throw Failure(message: "No agent key") }
    let parts = signingInput.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, signingInput.utf8.count <= 16_384,
          signingInput.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") })
    else { throw Failure(message: "Invalid signing input") }
    return base64url(try key.signature(for: Data(signingInput.utf8)))
  }

  /// Moves a key to a new label (e.g. pending → connection id).
  static func rename(from: String, to: String) throws {
    try validate(from); try validate(to)
    let status = SecItemUpdate(base(from) as CFDictionary, [kSecAttrService as String: servicePrefix + to] as CFDictionary)
    guard status == errSecSuccess else { throw Failure(message: "Unable to rename agent key (\(status))") }
  }

  static func delete(label: String) throws {
    try validate(label)
    let status = SecItemDelete(base(label) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(message: "Unable to delete agent key (\(status))") }
  }

  // MARK: - internals

  private static func validate(_ label: String) throws {
    guard !label.isEmpty, label.count <= 64,
          label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    else { throw Failure(message: "Invalid agent key label") }
  }

  private static func base(_ label: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: servicePrefix + label,
     kSecAttrAccount as String: account]
  }

  private static func load(_ label: String) throws -> Curve25519.Signing.PrivateKey? {
    try validate(label)
    var query = base(label)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &out)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = out as? Data else { throw Failure(message: "Unable to read agent key (\(status))") }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
  }

  private static func jwk(_ key: Curve25519.Signing.PublicKey) -> [String: String] {
    ["kty": "OKP", "crv": "Ed25519", "x": base64url(key.rawRepresentation)]
  }

  private static func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
