// Signs and checks update archives with the release key (Ed25519), the way Updater.swift
// checks them. Run with `swift scripts/update-signature.swift <command>`:
//
//   generate <file>                    a new key: the private half goes to <file>, the public half is printed
//   sign <archive>                     prints the signature; the private key is read from LITHIUM_UPDATE_PRIVATE_KEY
//   verify <archive> <signature> <key> exits 0 when <signature> is the release key's for <archive>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("generate", 2):
    let key = Curve25519.Signing.PrivateKey()
    let secret = Data(key.rawRepresentation.base64EncodedString().utf8)
    guard FileManager.default.createFile(atPath: arguments[1], contents: secret, attributes: [.posixPermissions: 0o600]) else { fail("can't write \(arguments[1])") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("sign", 2):
    guard let secret = ProcessInfo.processInfo.environment["LITHIUM_UPDATE_PRIVATE_KEY"].flatMap({ Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else { fail("LITHIUM_UPDATE_PRIVATE_KEY holds no release key") }
    guard let archive = FileManager.default.contents(atPath: arguments[1]), let signature = try? key.signature(for: archive) else { fail("can't sign \(arguments[1])") }
    print(signature.base64EncodedString())
case ("verify", 4):
    guard let archive = FileManager.default.contents(atPath: arguments[1]), let signature = Data(base64Encoded: arguments[2]),
          let key = Data(base64Encoded: arguments[3]).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
          key.isValidSignature(signature, for: archive) else { fail("the signature is not the release key's for \(arguments[1])") }
default:
    fail("usage: update-signature.swift generate <file> | sign <archive> | verify <archive> <signature> <public key>")
}
