import Foundation
import CryptoSwift
import BigInt

nonisolated enum EIP712Hasher {

    enum Error: Swift.Error {
        case invalidJSON
        case missingField(String)
        case encodingFailed(String)
    }

    static func hashTypedData(json: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Error.invalidJSON
        }
        guard let types = root["types"] as? [String: [[String: String]]] else {
            throw Error.missingField("types")
        }
        guard let primaryType = root["primaryType"] as? String else {
            throw Error.missingField("primaryType")
        }
        guard let domain = root["domain"] as? [String: Any] else {
            throw Error.missingField("domain")
        }
        guard let message = root["message"] as? [String: Any] else {
            throw Error.missingField("message")
        }

        let domainSeparator = try hashStruct("EIP712Domain", data: domain, types: types)
        let messageHash = try hashStruct(primaryType, data: message, types: types)

        var payload = Data([0x19, 0x01])
        payload.append(domainSeparator)
        payload.append(messageHash)
        return Data(payload.keccak256())
    }

    private static func hashStruct(_ typeName: String, data: [String: Any],
                                    types: [String: [[String: String]]]) throws -> Data {
        var encoded = try typeHash(typeName, types: types)
        encoded.append(try encodeData(typeName, data: data, types: types))
        return Data(encoded.keccak256())
    }

    private static func typeHash(_ typeName: String,
                                  types: [String: [[String: String]]]) throws -> Data {
        let str = encodeType(typeName, types: types)
        return Data(Array(str.utf8).sha3(.keccak256))
    }

    private static func encodeType(_ typeName: String,
                                    types: [String: [[String: String]]]) -> String {
        guard let fields = types[typeName] else { return "" }

        let primary = typeName + "(" + fields.map { ($0["name"] ?? "") + " " + ($0["type"] ?? "") }
            .joined(separator: ",") + ")"

        var referenced = Set<String>()
        collectReferencedTypes(typeName, types: types, visited: &referenced)
        referenced.remove(typeName)

        let sorted = referenced.sorted().map { encodeType($0, types: types) }
        return primary + sorted.joined()
    }

    private static func collectReferencedTypes(_ typeName: String,
                                                types: [String: [[String: String]]],
                                                visited: inout Set<String>) {
        guard !visited.contains(typeName), let fields = types[typeName] else { return }
        visited.insert(typeName)
        for field in fields {
            let fieldType = baseType(field["type"] ?? "")
            if types[fieldType] != nil {
                collectReferencedTypes(fieldType, types: types, visited: &visited)
            }
        }
    }

    private static func baseType(_ type: String) -> String {
        if type.hasSuffix("[]") { return String(type.dropLast(2)) }
        return type
    }

    private static func encodeData(_ typeName: String, data: [String: Any],
                                    types: [String: [[String: String]]]) throws -> Data {
        guard let fields = types[typeName] else {
            throw Error.missingField("type definition for \(typeName)")
        }

        var encoded = Data()
        for field in fields {
            let name = field["name"] ?? ""
            let type = field["type"] ?? ""
            let value = data[name] as Any
            encoded.append(try encodeValue(type, value: value, types: types))
        }
        return encoded
    }

    private static func encodeValue(_ type: String, value: Any,
                                     types: [String: [[String: String]]]) throws -> Data {
        if type.hasSuffix("[]") {
            let elementType = String(type.dropLast(2))
            let array = value as? [Any] ?? []
            var concat = Data()
            for item in array {
                concat.append(try encodeValue(elementType, value: item, types: types))
            }
            return Data(concat.keccak256())
        }

        if types[type] != nil {
            guard let structData = value as? [String: Any] else {
                throw Error.encodingFailed("Expected object for struct type \(type)")
            }
            return try hashStruct(type, data: structData, types: types)
        }

        if type == "string" {
            let str = stringValue(value)
            return Data(Array(str.utf8).sha3(.keccak256))
        }

        if type == "bytes" {
            let hex = stringValue(value)
            let bytes = hex.stripHexPrefix().hexToData() ?? Data()
            return Data(bytes.keccak256())
        }

        if type == "address" {
            return encodeAddress(stringValue(value))
        }

        if type == "bool" {
            let b: Bool
            if let boolVal = value as? Bool { b = boolVal }
            else if let num = value as? NSNumber { b = num.boolValue }
            else { b = stringValue(value) == "true" }
            return padLeft(Data([b ? 1 : 0]), to: 32)
        }

        if type.hasPrefix("uint") || type.hasPrefix("int") {
            return encodeInteger(stringValue(value))
        }

        if type.hasPrefix("bytes"), let size = Int(type.dropFirst(5)), size >= 1, size <= 32 {
            let hex = stringValue(value)
            let bytes = hex.stripHexPrefix().hexToData() ?? Data()
            return padRight(bytes, to: 32)
        }

        throw Error.encodingFailed("Unsupported type: \(type)")
    }

    private static func stringValue(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return "\(value)"
    }

    private static func encodeAddress(_ hex: String) -> Data {
        let bytes = hex.stripHexPrefix().hexToData() ?? Data()
        return padLeft(bytes, to: 32)
    }

    private static func encodeInteger(_ str: String) -> Data {
        let stripped = str.stripHexPrefix()
        let big: BigUInt
        if str.hasPrefix("0x") || str.hasPrefix("0X") {
            big = BigUInt(stripped, radix: 16) ?? 0
        } else {
            big = BigUInt(stripped, radix: 10) ?? 0
        }
        let serialized = big.serialize()
        return padLeft(serialized, to: 32)
    }

    private static func padLeft(_ data: Data, to length: Int) -> Data {
        if data.count >= length { return data.suffix(length) }
        return Data(repeating: 0, count: length - data.count) + data
    }

    private static func padRight(_ data: Data, to length: Int) -> Data {
        if data.count >= length { return data.prefix(length) }
        return data + Data(repeating: 0, count: length - data.count)
    }
}

private extension Data {
    func keccak256() -> [UInt8] {
        Array(self).sha3(.keccak256)
    }
}
