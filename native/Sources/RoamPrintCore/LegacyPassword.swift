import Foundation
import LegacyCrypto

public enum LegacyCryptoError: Error, LocalizedError {
    case invalidPassword
    case encryptionFailed
    case invalidRandomParameters
    case invalidCiphertext

    public var errorDescription: String? {
        switch self {
        case .invalidPassword: return "密码包含空字符或超过旧平台支持的 255 个 UTF-8 字节。"
        case .encryptionFailed: return "旧平台密码编码失败。"
        case .invalidRandomParameters: return "密码编码随机参数无效。"
        case .invalidCiphertext: return "旧平台返回的密码编码无效。"
        }
    }
}

/// The V5 client protocol requires MD5; this is not a password-storage digest.
public enum LegacyDigest {
    public static func md5(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBytes { bytes in
            rp_md5(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Wire-compatible CPWDCry::encryptPwd encoding recovered from the V5 client.
/// REA ev_46be9d56c39b44d68d7221bd38c02b3b926e6a746140d9c17190baf51b64559a
/// and ev_b43e56fb248772815604664e0c18fd5fd5fd5fbfba7d6c6f32bd5343c7b86234.
public enum LegacyPassword {
    static let key: [UInt8] = [0xb5, 0, 0, 0, 0xc7, 0, 0, 0, 0xc2, 0, 0, 0, 0xbc, 0, 0, 0]
    static let mixIndices: Set<Int> = [1, 5, 10, 15, 20, 25, 26, 30]

    public static func encrypt(_ password: String) throws -> String {
        let bytes = try passwordBytes(password)
        let paddedCount = max(16, (bytes.count + 15) / 16 * 16)
        var generator = SystemRandomNumberGenerator()
        var positions: [UInt8] = []
        while positions.count < 5 {
            let value = UInt8(Int.random(in: 0..<paddedCount, using: &generator))
            if !positions.contains(value) { positions.append(value) }
        }
        let letters = (0..<16).map { _ in UInt8.random(in: 65...90, using: &generator) }
        return try encrypt(password, positions: positions, mixLetters: letters)
    }

    /// Decodes the encrypted storage credential returned by V5 filestorage.
    public static func decrypt(_ ciphertext: String) throws -> String {
        let encoded = Array(ciphertext.utf8)
        guard encoded.count >= 80, (encoded.count - 16) % 32 == 0 else {
            throw LegacyCryptoError.invalidCiphertext
        }
        let byteCount = (encoded.count - 16) / 2
        // Position fields are bytes, just as in the original encoder.
        guard byteCount <= 272 else { throw LegacyCryptoError.invalidCiphertext }
        var encrypted = [UInt8]()
        encrypted.reserveCapacity(byteCount)
        var offset = 0
        for index in 0..<byteCount {
            if mixIndices.contains(index) {
                guard (65...90).contains(encoded[offset]),
                      (65...90).contains(encoded[offset + 1]) else {
                    throw LegacyCryptoError.invalidCiphertext
                }
                offset += 2
            }
            let low = encoded[offset], high = encoded[offset + 1]
            guard (65...80).contains(low), (65...80).contains(high) else {
                throw LegacyCryptoError.invalidCiphertext
            }
            encrypted.append((low - 65) | ((high - 65) << 4))
            offset += 2
        }
        guard offset == encoded.count else { throw LegacyCryptoError.invalidCiphertext }
        var plain = [UInt8](repeating: 0, count: byteCount)
        let success = key.withUnsafeBufferPointer { keyBuffer in
            encrypted.withUnsafeBufferPointer { input in
                plain.withUnsafeMutableBufferPointer { output in
                    rp_twofish128_ecb(keyBuffer.baseAddress, input.baseAddress,
                                     output.baseAddress, byteCount, 1)
                }
            }
        }
        defer { plain.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) } }
        guard success == 1 else { throw LegacyCryptoError.encryptionFailed }
        let payloadCount = byteCount - 16
        let positions = Array(plain[payloadCount..<payloadCount + 5])
        guard Set(positions).count == 5,
              positions.allSatisfy({ Int($0) < payloadCount }),
              plain[payloadCount + 5..<payloadCount + 11].allSatisfy({ $0 == 0 }) else {
            throw LegacyCryptoError.invalidCiphertext
        }
        let expectedMetadata: [UInt8] = [5, 255, 255, 255, 255]
        for index in 0..<5 {
            let position = Int(positions[index])
            guard plain[position] == expectedMetadata[index] else {
                throw LegacyCryptoError.invalidCiphertext
            }
            plain[position] = plain[byteCount - 1 - index]
        }
        let payload = plain.prefix(payloadCount)
        let textCount = payload.firstIndex(of: 0) ?? payloadCount
        guard payload.dropFirst(textCount).allSatisfy({ $0 == 0 }),
              let result = String(bytes: payload.prefix(textCount), encoding: .utf8) else {
            throw LegacyCryptoError.invalidCiphertext
        }
        return result
    }

    // Deterministic seam for fixtures; production uses OS-seeded randomness.
    static func encrypt(_ password: String, positions: [UInt8], mixLetters: [UInt8]) throws -> String {
        let bytes = try passwordBytes(password)
        let paddedCount = max(16, (bytes.count + 15) / 16 * 16)
        guard positions.count == 5, Set(positions).count == 5,
              positions.allSatisfy({ Int($0) < paddedCount }),
              mixLetters.count == 16, mixLetters.allSatisfy({ (65...90).contains($0) }) else {
            throw LegacyCryptoError.invalidRandomParameters
        }
        var plain = [UInt8](repeating: 0, count: paddedCount + 16)
        plain.replaceSubrange(0..<bytes.count, with: bytes)
        plain.replaceSubrange(paddedCount..<paddedCount + 5, with: positions)
        let metadata: [UInt8] = [5, 255, 255, 255, 255]
        for index in 0..<5 {
            let position = Int(positions[index])
            plain[plain.count - 1 - index] = plain[position]
            plain[position] = metadata[index]
        }
        var encrypted = [UInt8](repeating: 0, count: plain.count)
        let success = key.withUnsafeBufferPointer { keyBuffer in
            plain.withUnsafeBufferPointer { input in
                encrypted.withUnsafeMutableBufferPointer { output in
                    rp_twofish128_ecb(keyBuffer.baseAddress, input.baseAddress,
                                     output.baseAddress, plain.count, 0)
                }
            }
        }
        plain.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        guard success == 1 else { throw LegacyCryptoError.encryptionFailed }
        var encoded = [UInt8]()
        encoded.reserveCapacity(encrypted.count * 2 + 16)
        var mixOffset = 0
        for (index, byte) in encrypted.enumerated() {
            if mixIndices.contains(index) {
                encoded.append(contentsOf: mixLetters[mixOffset..<mixOffset + 2])
                mixOffset += 2
            }
            encoded.append((byte & 15) + 65)
            encoded.append((byte >> 4) + 65)
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func passwordBytes(_ password: String) throws -> [UInt8] {
        let bytes = Array(password.utf8)
        // Original uses strlen and one-byte position fields. Reject unsupported
        // input instead of truncating a user's password or generating bad wire data.
        guard bytes.count <= 255, !bytes.contains(0) else { throw LegacyCryptoError.invalidPassword }
        return bytes
    }
}
