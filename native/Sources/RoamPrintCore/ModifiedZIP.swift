import Foundation

/// Original FileEncType=1 is a ZIP with its first four bytes zeroed, not a cryptographic cipher.
public enum ModifiedZIP {
    public static func write(source: URL, destination: URL, name: String? = nil) throws {
        let input = try Data(contentsOf: source)
        let output = try encode(input, name: name ?? source.lastPathComponent)
        try output.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    public static func encode(_ data: Data, name: String) throws -> Data {
        let filename = Data(name.utf8)
        guard !filename.isEmpty, filename.count <= 65535, !name.contains("/"), !name.contains("\\"),
              name != ".", name != "..", !name.contains("\0"), data.count <= 128 * 1024 * 1024 else {
            throw PrintError.invalidDocument("文件不能转换为平台上传格式。")
        }
        let size = UInt32(data.count), crc = crc32(data)
        var result = Data()
        func u16(_ n: UInt16) { result.append(UInt8(truncatingIfNeeded: n)); result.append(UInt8(truncatingIfNeeded: n >> 8)) }
        func u32(_ n: UInt32) { u16(UInt16(truncatingIfNeeded: n)); u16(UInt16(truncatingIfNeeded: n >> 16)) }
        // ZIP stored method is supported by standard ZIP readers; no Intel compressor dependency.
        u32(0); u16(20); u16(0x800); u16(0); u16(0); u16(33); u32(crc)
        u32(size); u32(size); u16(UInt16(filename.count)); u16(0)
        result.append(filename); result.append(data)
        let directoryOffset = UInt32(result.count)
        u32(0x02014b50); u16(20); u16(20); u16(0x800); u16(0); u16(0); u16(33)
        u32(crc); u32(size); u32(size); u16(UInt16(filename.count)); u16(0); u16(0)
        u16(0); u16(0); u32(0); u32(0); result.append(filename)
        let directorySize = UInt32(result.count) - directoryOffset
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(directorySize); u32(directoryOffset); u16(0)
        return result
    }
    public static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        }
        return value ^ 0xffffffff
    }
}
