import Carbon.HIToolbox

/// Whether macOS is keeping key presses to itself right now.
///
/// While a password field has the keyboard (or Terminal's "Secure Keyboard
/// Entry" is on), macOS hides every key press from other apps. The global
/// shortcuts cannot be heard until it ends; clicking the pill still works.
public enum SecureInput {
  /// Asks the system. Cheap, and safe to call from any thread.
  public static var isOn: Bool { IsSecureEventInputEnabled() }
}
