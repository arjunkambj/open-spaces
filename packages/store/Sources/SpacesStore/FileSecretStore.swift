import Foundation
import SpacesDomain

/// `SecretStore` backed by one small file that only this user can read (mode 0600).
///
/// Reading it never asks the user for anything, so dictation starts at once. The file holds
/// each key under the host it was saved for. It is left out of backups (iCloud Backup, Time
/// Machine), so the keys stay on this device.
///
/// The file is JSON like the rest of the data folder:
/// `{"keys": {"api.openai.com": "sk-...", "api.anthropic.com": "sk-ant-..."}}`.
/// Any program that runs as this user can read it, the same as any other file in the home folder.
public struct FileSecretStore: SecretStore {
  /// The name the file has, wherever the app keeps it.
  public static let fileName = "api-key.json"

  private let file: URL

  /// - Parameter file: where the keys are kept. The folder is created when a key is saved.
  public init(file: URL) {
    self.file = file
  }

  public func apiKey(for host: String) async throws -> String? {
    let key = try read().keys[FileSecretStore.tidy(host)] ?? ""
    return key.isEmpty ? nil : key
  }

  public func setAPIKey(_ key: String?, host: String) async throws {
    var saved = try read()
    saved.keys[FileSecretStore.tidy(host)] = (key?.isEmpty ?? true) ? nil : key
    guard !saved.keys.isEmpty else {
      try FileAccess.remove(file)
      return
    }
    // All keys are written in one step, so the file never pairs a key with the wrong host.
    let data = try LibraryJSON.encode(saved)
    try FileAccess.createFolder(file.deletingLastPathComponent())
    try FileAccess.writeAtomically(data, to: file)
    // Set on the file itself, after the rename, so the new file carries it.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var written = file
    try? written.setResourceValues(values)
  }

  private func read() throws -> Saved {
    guard let (data, _) = try FileAccess.read(file) else { return Saved(keys: [:]) }
    guard let saved = try? LibraryJSON.decode(Saved.self, from: data) else {
      throw SpacesError.storage("Your API keys could not be read. Add them again in Settings.")
    }
    return saved
  }

  private static func tidy(_ host: String) -> String {
    host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private struct Saved: Codable {
    /// Key by host name, in lower case.
    var keys: [String: String]
  }
}
