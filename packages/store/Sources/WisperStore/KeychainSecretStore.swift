import Foundation
import Security
import WisperDomain

/// `SecretStore` backed by the Keychain.
///
/// The key is one generic password item. It stays on this device: it is never synced to
/// iCloud, and it can be read after the first unlock following a restart, so dictation
/// works while the screen is locked.
///
/// The host the key was saved for is kept on the same item, as its comment. An item with no
/// comment was saved before hosts were recorded and counts as a key for OpenAI itself.
///
/// On macOS the item lives in the user's login keychain, because the newer kind of keychain
/// is closed to apps that are not signed with a developer identity.
public struct KeychainSecretStore: SecretStore {
  private let service: String
  private let accessGroup: String?

  /// - Parameters:
  ///   - service: the name the item is filed under.
  ///   - accessGroup: on iOS, a keychain group shared with the keyboard extension. Not used on macOS.
  public init(service: String = "dev.openwisper", accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  public func apiKey(for host: String) async throws -> String? {
    try await KeychainSecretStore.offThePool { [self] in
      var query = itemQuery
      query[kSecReturnData] = true
      query[kSecReturnAttributes] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
      var found: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &found)
      if status == errSecItemNotFound { return nil }
      try KeychainSecretStore.check(status, "read")
      guard let item = found as? [String: Any], let data = item[kSecValueData as String] as? Data,
        let key = String(data: data, encoding: .utf8), !key.isEmpty
      else { return nil }
      let comment =
        (item[kSecAttrComment as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let savedFor = comment.isEmpty ? APIServer.openAIHost : comment
      // A key is only ever handed out for the server it was saved for.
      return APIServer.sameHost(savedFor, host) ? key : nil
    }
  }

  public func setAPIKey(_ key: String?, host: String) async throws {
    try await KeychainSecretStore.offThePool { [self] in
      let query = itemQuery
      guard let key, !key.isEmpty else {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try KeychainSecretStore.check(status, "removed") }
        return
      }
      // The key and its host are written in one step, so the item never pairs a key with
      // the host of the key before it.
      let value =
        [
          kSecValueData: Data(key.utf8),
          kSecAttrComment: host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ] as [CFString: Any]
      var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
      if status == errSecItemNotFound {
        var item = query.merging(value) { $1 }
        item[kSecAttrLabel] = "Open Wisper: API key"
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        status = SecItemAdd(item as CFDictionary, nil)
        // Somebody else added it in between. Theirs is replaced.
        if status == errSecDuplicateItem {
          status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        }
      }
      try KeychainSecretStore.check(status, "saved")
    }
  }

  private static let account = "openai-api-key"

  /// What picks out the one item.
  private var itemQuery: [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: KeychainSecretStore.account,
      kSecAttrSynchronizable: false,
    ]
    #if !os(macOS)
      if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
    #endif
    return query
  }

  /// The Keychain can wait for the user (to unlock it, or to allow access), so its calls
  /// stay off the threads the rest of the app's async code shares.
  private static func offThePool<Result: Sendable>(
    _ work: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Swift.Result { try work() })
      }
    }
  }

  /// Turns a Keychain failure into an error a person can read. Never mentions the key itself.
  private static func check(_ status: OSStatus, _ verb: String) throws {
    guard status != errSecSuccess else { return }
    let reason: String
    switch status {
    case errSecUserCanceled, errSecAuthFailed:
      reason = "Access to the Keychain was not allowed."
    case errSecInteractionNotAllowed:
      reason = "The Keychain is locked. Unlock this device and try again."
    case errSecMissingEntitlement:
      reason = "This copy of the app is not allowed to use the Keychain."
    default:
      let system = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
      reason = "\(system) (Keychain error \(status))."
    }
    throw WisperError.storage("Your API key could not be \(verb). \(reason)")
  }
}
