import XCTest
import Foundation
import LegacyCrypto
@testable import RoamPrintCore

final class LegacyCryptoTests: XCTestCase {
    func testPublishedTwofish128Vectors() throws {
        // Twofish AES submission known-answer vectors (zero key/plaintext).
        let zero = [UInt8](repeating: 0, count: 16)
        var encrypted = zero
        XCTAssertEqual(rp_twofish128_ecb(zero, zero, &encrypted, 16, 0), 1)
        XCTAssertEqual(hex(encrypted), "9f589f5cf6122c32b6bfec2f2ae8c35a")
        var decrypted = zero
        XCTAssertEqual(rp_twofish128_ecb(zero, encrypted, &decrypted, 16, 1), 1)
        XCTAssertEqual(decrypted, zero)

        // Schneier et al. Twofish book, Appendix A.1, cycle 49.
        let key = bytes("9f589f5cf6122c32b6bfec2f2ae8c35a")
        let plain = bytes("d491db16e7b1c39e86cb086b789f5419")
        XCTAssertEqual(rp_twofish128_ecb(key, plain, &encrypted, 16, 0), 1)
        XCTAssertEqual(hex(encrypted), "019f9809de1711858faac3a3ba20fbc3")
    }

    func testRFC1321DigestVectors() {
        let vectors = [
            "": "d41d8cd98f00b204e9800998ecf8427e",
            "a": "0cc175b9c0f1b6a831c399e269772661",
            "abc": "900150983cd24fb0d6963f7d28e17f72",
            "message digest": "f96b697d7cb7938d525a2f31aaf161d0",
            "abcdefghijklmnopqrstuvwxyz": "c3fcd3d76192e4007dfb496cca67e13b",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789": "d174ab98d277d9f5a5611c2c9f419d9f"
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(LegacyDigest.md5(Data(input.utf8)), expected)
        }
        // Multi-block length and binary high-bit bytes, generated with hashlib.
        XCTAssertEqual(LegacyDigest.md5(Data((0..<256).map(UInt8.init))),
                       "e2c865db4162bed963bfaa9ef6ac18f0")
        XCTAssertEqual(LegacyDigest.md5(Data(repeating: 97, count: 1_000_000)),
                       "7707d6ae4e027c70eea2a935c2296f21")
    }

    func testIndependentLegacyFixture() throws {
        // Created independently with libgcrypt 1.11.0 Twofish ECB and the REA
        // trailer layout: positions 0,2,5,9,15; injected letters ABC...P.
        // Plain blocks: 0562ff0000ff000000ff0000000000ff
        //               000205090f0000000000000000006361
        // Ciphertext: a92bb517f2f253af4be9ac2a0f9bd75e
        //             21c7360b4ca71e83019ab012a112d133
        let expected = "JKABLCFLHBCPCDCPDFPKLEJOEFMKKCPALJHNGHOFBCHMGDLAIJMEHKOBDIBAKLKJMNALCBBKCBOPBNDD"
        let encrypted = try LegacyPassword.encrypt("abc", positions: [0, 2, 5, 9, 15],
                                                   mixLetters: Array("ABCDEFGHIJKLMNOP".utf8))
        XCTAssertEqual(encrypted, expected)
        XCTAssertEqual(try LegacyPassword.decrypt(expected), "abc")
    }

    func testRoundTripsPaddingUTF8AndMaximumLength() throws {
        for password in ["", "hello", "密码测试🔒", String(repeating: "a", count: 15),
                         String(repeating: "b", count: 16), String(repeating: "c", count: 17),
                         String(repeating: "x", count: 255)] {
            for _ in 0..<4 {
                let encrypted = try LegacyPassword.encrypt(password)
                XCTAssertEqual(try LegacyPassword.decrypt(encrypted), password)
                let padded = max(16, (password.utf8.count + 15) / 16 * 16)
                XCTAssertEqual(encrypted.utf8.count, (padded + 16) * 2 + 16)
                XCTAssertTrue(encrypted.utf8.allSatisfy { (65...90).contains($0) })
            }
        }
    }

    func testRejectsUnsupportedPasswordsAndMalformedCiphertext() throws {
        XCTAssertThrowsError(try LegacyPassword.encrypt("a\u{0}b"))
        XCTAssertThrowsError(try LegacyPassword.encrypt(String(repeating: "x", count: 256)))
        XCTAssertThrowsError(try LegacyPassword.encrypt(String(repeating: "密", count: 86)))
        XCTAssertThrowsError(try LegacyPassword.encrypt("abc", positions: [1, 1, 2, 3, 4],
                                                        mixLetters: Array("ABCDEFGHIJKLMNOP".utf8)))
        for invalid in ["", "plain-password", String(repeating: "A", count: 80),
                        String(repeating: "Z", count: 80), String(repeating: "A", count: 81)] {
            XCTAssertThrowsError(try LegacyPassword.decrypt(invalid))
        }
        var corrupted = Array(try LegacyPassword.encrypt("password").utf8)
        corrupted[0] = 90 // Z cannot represent a nibble.
        XCTAssertThrowsError(try LegacyPassword.decrypt(String(decoding: corrupted, as: UTF8.self)))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex)
        return stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...$0 + 1]), radix: 16)!
        }
    }
}
