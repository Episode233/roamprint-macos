import Foundation

public struct IPPAttribute: Equatable, Sendable {
    public let group: UInt8
    public let tag: UInt8
    public let name: String
    public let value: Data
    public init(group: UInt8, tag: UInt8, name: String, value: Data) {
        self.group = group; self.tag = tag; self.name = name; self.value = Data(value)
    }
    public static func text(_ name: String, _ value: String, tag: UInt8 = 0x44, group: UInt8 = 4) -> Self {
        Self(group: group, tag: tag, name: name, value: Data(value.utf8))
    }
    public static func integer(_ name: String, _ value: Int, tag: UInt8 = 0x21, group: UInt8 = 4) -> Self {
        var bytes = Data(); bytes.appendUInt32(UInt32(truncatingIfNeeded: value))
        return Self(group: group, tag: tag, name: name, value: bytes)
    }
    public static func boolean(_ name: String, _ value: Bool, group: UInt8 = 4) -> Self {
        Self(group: group, tag: 0x22, name: name, value: Data([value ? 1 : 0]))
    }
    /// RFC 8010 collections use memberAttrName values and zero-length wire names.
    /// A member can itself be a collection; flattening retains the nested delimiters.
    public static func collection(_ name: String, members: [[Self]], group: UInt8 = 4) -> [Self] {
        var result = [Self(group: group, tag: 0x34, name: name, value: Data())]
        for member in members where !member.isEmpty {
            result.append(.text(name, member[0].name, tag: 0x4a, group: group))
            result += member.map { Self(group: group, tag: $0.tag, name: name, value: $0.value) }
        }
        result.append(Self(group: group, tag: 0x37, name: name, value: Data()))
        return result
    }
    public static func resolution(_ name: String, dpi: Int, group: UInt8 = 4) -> Self {
        var bytes = Data(); bytes.appendUInt32(UInt32(dpi)); bytes.appendUInt32(UInt32(dpi)); bytes.append(3)
        return Self(group: group, tag: 0x32, name: name, value: bytes)
    }
    public var string: String? { String(data: value, encoding: .utf8) }
    public var integer: Int? {
        guard value.count == 4 else { return nil }
        return Int(Int32(bitPattern: value.uint32(at: 0)))
    }
}

public struct IPPMessage: Sendable {
    public var major: UInt8 = 2
    public var minor: UInt8 = 0
    public let code: UInt16
    public let requestID: UInt32
    public var attributes: [IPPAttribute]
    public var document: Data
    public init(code: UInt16, requestID: UInt32, attributes: [IPPAttribute] = [], document: Data = Data()) {
        self.code = code; self.requestID = requestID; self.attributes = attributes; self.document = document
    }
    public init(data: Data) throws {
        let data = Data(data)
        guard data.count >= 9 else { throw PrintError.invalidDocument("IPP 消息不完整。") }
        major = data[0]; minor = data[1]
        code = data.uint16(at: 2); requestID = data.uint32(at: 4)
        attributes = []; document = Data()
        var pos = 8, group: UInt8 = 0, previous = ""
        while pos < data.count {
            let tag = data[pos]; pos += 1
            if tag == 3 { document = Data(data[pos...]); return }
            if tag <= 15 {
                guard [1, 2, 4, 5, 6, 7, 9].contains(tag) else {
                    throw PrintError.invalidDocument("IPP 属性分组无效。")
                }
                group = tag; previous = ""; continue
            }
            guard group != 0, pos + 2 <= data.count else { throw PrintError.invalidDocument("IPP 属性分组错误。") }
            let length = Int(data.uint16(at: pos)); pos += 2
            guard pos + length + 2 <= data.count else { throw PrintError.invalidDocument("IPP 属性长度错误。") }
            let name: String
            if length == 0 {
                guard !previous.isEmpty else { throw PrintError.invalidDocument("IPP 多值属性缺少名称。") }
                name = previous
            } else {
                guard let decoded = String(data: data[pos..<pos + length], encoding: .utf8) else { throw PrintError.invalidDocument("IPP 属性名编码错误。") }
                name = decoded; previous = name
            }
            pos += length
            let size = Int(data.uint16(at: pos)); pos += 2
            guard pos + size <= data.count, attributes.count < 4096 else { throw PrintError.invalidDocument("IPP 属性超过限制。") }
            attributes.append(IPPAttribute(group: group, tag: tag, name: name, value: Data(data[pos..<pos + size])))
            pos += size
        }
        throw PrintError.invalidDocument("IPP 消息缺少结束标记。")
    }
    public func value(_ name: String) -> IPPAttribute? { attributes.first { $0.name == name } }
    public func encoded() throws -> Data {
        var result = Data([major, minor]); result.appendUInt16(code); result.appendUInt32(requestID)
        var group: UInt8 = 0, previous = ""
        for attr in attributes {
            guard [1, 2, 4, 5, 6, 7, 9].contains(attr.group), attr.tag > 15,
                  !attr.name.isEmpty, attr.name.utf8.count <= 65535, attr.value.count <= 65535 else {
                throw PrintError.invalidDocument("IPP 属性编码超过限制或格式无效。")
            }
            if group != attr.group { result.append(attr.group); group = attr.group; previous = "" }
            let name = attr.name == previous ? Data() : Data(attr.name.utf8)
            result.append(attr.tag); result.appendUInt16(UInt16(name.count)); result.append(name)
            result.appendUInt16(UInt16(attr.value.count)); result.append(attr.value)
            previous = attr.name
        }
        result.append(3); result.append(document)
        return result
    }
    public static func response(to request: IPPMessage, status: UInt16 = 0, attributes: [IPPAttribute] = []) -> Self {
        var result = Self(code: status, requestID: request.requestID, attributes: [
            .text("attributes-charset", "utf-8", tag: 0x47, group: 1),
            .text("attributes-natural-language", "en", tag: 0x48, group: 1)
        ] + attributes)
        result.major = request.major; result.minor = request.minor
        return result
    }
}

extension Data {
    func uint16(at i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func uint32(at i: Int) -> UInt32 { UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3]) }
    mutating func appendUInt16(_ value: UInt16) { append(UInt8(value >> 8)); append(UInt8(value & 255)) }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24)); append(UInt8((value >> 16) & 255)); append(UInt8((value >> 8) & 255)); append(UInt8(value & 255))
    }
}
