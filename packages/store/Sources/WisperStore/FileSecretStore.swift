import Foundation
import WisperDomain

/// `SecretStore` backed by one small file that only this user can read (mode 0600).
///
/// Reading it never asks the user for anything, so dictation starts at once. The file holds
/// the key and the host it was saved for. It is left out of backups (iCloud Backup, Time
/// Machine), so the key stays on this device.
///
/// The file is JSON like the rest of the data folder: `{"host": "api.openai.com", "key": "sk-..."}`.
/// Any program that runs as this user can read it, the same as any other file in the home folder.
public struct FileSecretStore: SecretStore {
  /// The name the file has, wherever the app keeps it.
  public static let fileName = "api-key.json"

  private let file: URL

  /// - Parameter file: where the key is kept. The folder is created when the key is saved.
  public init(file: URL) {
    self.file = file
  }

  public func apiKey(for host: String) async throws -> String? {
    guard let (data, _) = try FileAccess.read(file) else { return nil }
    guard let saved = try? LibraryJSON.decode(Saved.self, from: data) else {
      throw WisperError.storage("Your API key could not be read. Add it again in Settings.")
    }
    guard !saved.key.isEmpty else { return nil }
    // A key is only ever handed out for the server it was saved for.
    return APIServer.sameHost(saved.host, host) ? saved.key : nil
  }

  public func setAPIKey(_ key: String?, host: String) async throws {
    guard let key, !key.isEmpty else {
      try FileAccess.remove(file)
      return
    }
    // The key and its host are written in one step, so the file never pairs a key with the
    // host of the key before it.
    let saved = Saved(host: host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), key: key)
    let data = try LibraryJSON.encode(saved)
    try FileAccess.createFolder(file.deletingLastPathComponent())
    try FileAccess.writeAtomically(data, to: file)
    // Set on the file itself, after the rename, so the new file carries it.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var written = file
    try? written.setResourceValues(values)
  }

  private struct Saved: Codable {
    var host: String
    var key: String
  }
}
