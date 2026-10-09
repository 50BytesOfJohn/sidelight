import CryptoKit
import Foundation

enum VerificationError: Error {
    case invalidArguments
    case invalidSignature
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 4,
        let publicKey = Data(base64Encoded: arguments[1]),
        let signature = Data(base64Encoded: arguments[2])
    else { throw VerificationError.invalidArguments }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else { throw VerificationError.invalidSignature }
    print("Verified DMG update signature using the app's public key.")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
