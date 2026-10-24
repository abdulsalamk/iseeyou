import Foundation
import CryptoKit

func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
let args = CommandLine.arguments
if args.count == 4 && args[1] == "init" {
    let privateURL = URL(fileURLWithPath: args[2]), publicURL = URL(fileURLWithPath: args[3])
    guard !FileManager.default.fileExists(atPath: privateURL.path), !FileManager.default.fileExists(atPath: publicURL.path) else { fail("Refusing to overwrite signing keys") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: privateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try key.rawRepresentation.write(to: privateURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
    try key.publicKey.rawRepresentation.base64EncodedString().write(to: publicURL, atomically: true, encoding: .utf8)
    print("Created private signing key and public pin; no key material printed")
} else if args.count == 5 && args[1] == "sign" {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let payload = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    let envelope = ["payload": payload.base64EncodedString(), "signature": try key.signature(for: payload).base64EncodedString()]
    try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
    print("Signed release payload")
} else if args.count == 5 && args[1] == "verify" {
    let publicText = try String(contentsOf: URL(fileURLWithPath: args[2]), encoding: .utf8)
    guard let rawKey = Data(base64Encoded: publicText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("Invalid public key") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let envelopeData = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    let envelope = try JSONSerialization.jsonObject(with: envelopeData) as! [String: String]
    guard let payload = Data(base64Encoded: envelope["payload"] ?? ""),
          let signature = Data(base64Encoded: envelope["signature"] ?? ""),
          key.isValidSignature(signature, for: payload),
          payload == (try Data(contentsOf: URL(fileURLWithPath: args[4]))) else { fail("Release signature or payload mismatch") }
    print("Release signature verified")
} else { fail("Usage: swift sign.swift init PRIVATE_KEY PUBLIC_PIN | sign PRIVATE_KEY PAYLOAD_JSON RELEASE_JSON | verify PUBLIC_PIN RELEASE_JSON PAYLOAD_JSON") }
