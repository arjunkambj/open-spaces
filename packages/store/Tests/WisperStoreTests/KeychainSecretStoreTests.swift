import Foundation
import Security
import Testing
import WisperDomain

@testable import WisperStore

/// Whether this machine lets a test use the Keychain at all (some build servers do not).
/// Asked with the plain system calls, not with the code under test.
enum KeychainProbe {
  static let works: Bool = {
    let item: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "dev.openwisper.tests.probe.\(UUID().uuidString)",
      kSecAttrAccount: "probe",
      kSecAttrSynchronizable: false,
    ]
    var adding = item
    adding[kSecValueData] = Data("probe".utf8)
    guard SecItemAdd(adding as CFDictionary, nil) == errSecSuccess else { return false }
    return SecItemDelete(item as CFDictionary) == errSecSuccess
  }()
}

@Suite("KeychainSecretStore", .enabled(if: KeychainProbe.works, "The Keychain cannot be used here."))
struct KeychainSecretStoreTests {
  /// A name nobody else uses, so the user's real key is never touched.
  let service = "dev.openwisper.tests.\(UUID().uuidString)"

  /// Looks in the Keychain directly, to see what is really there.
  private func storedItems() -> Int {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecMatchLimit: kSecMatchLimitAll,
      kSecReturnAttributes: true,
    ]
    var found: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return 0 }
    return (found as? [Any])?.count ?? 0
  }

  @Test func storesReplacesAndRemovesTheKey() async throws {
    let store = KeychainSecretStore(service: service)
    #expect(try await store.apiKey() == nil)

    // Made up. Not a real key.
    try await store.setAPIKey("test-key-one-\u{00E9}")
    #expect(try await store.apiKey() == "test-key-one-\u{00E9}")
    #expect(storedItems() == 1)
    // Another store with the same name reads the same item, as another process would.
    #expect(try await KeychainSecretStore(service: service).apiKey() == "test-key-one-\u{00E9}")

    try await store.setAPIKey("test-key-two")
    #expect(try await store.apiKey() == "test-key-two")
    #expect(storedItems() == 1)

    try await store.setAPIKey(nil)
    #expect(try await store.apiKey() == nil)
    #expect(storedItems() == 0)
    // Removing what is not there is fine.
    try await store.setAPIKey(nil)

    try await store.setAPIKey("test-key-three")
    try await store.setAPIKey("")
    #expect(try await store.apiKey() == nil)
    #expect(storedItems() == 0)
  }

  @Test func storesWithDifferentNamesDoNotShare() async throws {
    let first = KeychainSecretStore(service: service)
    let second = KeychainSecretStore(service: service + ".other")
    try await first.setAPIKey("test-key-first")
    #expect(try await second.apiKey() == nil)
    try await second.setAPIKey("test-key-second")
    #expect(try await first.apiKey() == "test-key-first")
    try await second.setAPIKey(nil)
    #expect(try await first.apiKey() == "test-key-first")
    try await first.setAPIKey(nil)
    #expect(storedItems() == 0)
  }

  @Test func agreesWithTheInMemoryStore() async throws {
    let stores: [any SecretStore] = [InMemorySecretStore(), KeychainSecretStore(service: service)]
    for store in stores {
      #expect(try await store.apiKey() == nil)
      try await store.setAPIKey("test-key")
      #expect(try await store.apiKey() == "test-key")
      try await store.setAPIKey("")
      #expect(try await store.apiKey() == nil)
      try await store.setAPIKey("test-key-again")
      try await store.setAPIKey(nil)
      #expect(try await store.apiKey() == nil)
    }
  }
}
