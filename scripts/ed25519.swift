// ed25519.swift: the two things the release scripts need to know about an update signing key.
//
//   swift scripts/ed25519.swift public-key <private-key-file>
//       Prints the public half of a private key. This is the value of SUPublicEDKey in
//       apps/macos/Resources/Info.plist.
//
//   swift scripts/ed25519.swift verify <public-key> <signature> <file>
//       Exits 0 when the signature of the file was made with the private half of that key.
//
// A private key file holds one line: 32 random bytes in base64. That is the form Sparkle's
// own tools read (`sign_update --ed-key-file`, `generate_appcast --ed-key-file`) and write
// (`generate_keys -x`). The private key is only ever read from a file, never from an
// argument, so it does not show up in the list of running programs.
//
// This uses Apple's CryptoKit, not Sparkle's code, so it is an independent check that a
// signature made by Sparkle's tools matches the key the app will trust.
import CryptoKit
import Foundation

func stop(_ message: String) -> Never {
  FileHandle.standardError.write(Data("ed25519: \(message)\n".utf8))
  exit(1)
}

func bytes(base64 text: String, count: Int, called name: String) -> Data {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let data = Data(base64Encoded: trimmed), data.count == count else {
    stop("the \(name) is not \(count) bytes of base64.")
  }
  return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "public-key" where arguments.count == 2:
  guard let text = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
    stop("cannot read \(arguments[1]).")
  }
  let seed = bytes(base64: text, count: 32, called: "private key")
  guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    stop("the private key is not usable.")
  }
  print(key.publicKey.rawRepresentation.base64EncodedString())

case "verify" where arguments.count == 4:
  let publicKey = bytes(base64: arguments[1], count: 32, called: "public key")
  let signature = bytes(base64: arguments[2], count: 64, called: "signature")
  guard let content = FileManager.default.contents(atPath: arguments[3]) else {
    stop("cannot read \(arguments[3]).")
  }
  guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
    stop("the public key is not usable.")
  }
  guard key.isValidSignature(signature, for: content) else {
    stop("the signature does not match \(arguments[3]).")
  }

default:
  stop("usage: ed25519.swift public-key <private-key-file> | verify <public-key> <signature> <file>")
}
