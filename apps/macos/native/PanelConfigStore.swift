import Foundation

/// Owns the committed panel configuration and its single file. Loading is strict (the full Node `parseConfig`
/// contract); saving validates the whole candidate, atomically replaces the file with private permissions and only
/// then updates `config`. A failed validation or write leaves both the file and `config` untouched.
final class PanelConfigStore {
    let configPath: String
    private(set) var config: PanelConfig

    init(configPath: String) throws {
        self.configPath = configPath
        self.config = try PanelConfigStore.load(path: configPath)
    }

    func save(_ candidate: PanelConfig) throws {
        try candidate.validate()
        if candidate == config { return }
        let data = try PanelConfigStore.serialize(candidate)
        try PanelConfigStore.writeAtomically(data, to: configPath)
        config = candidate
    }

    static func load(path: String) throws -> PanelConfig {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw PanelConfigError.unreadable((error as NSError).localizedDescription) }
        return try decode(data)
    }

    private static func writeAtomically(_ data: Data, to path: String) throws {
        func failure(_ message: String) -> PanelConfigError { .writeFailed(message) }
        func lastError() -> String { String(cString: strerror(errno)) }

        // Replace the real file (following a symlinked config) in its own directory so rename(2) stays atomic.
        // If the path cannot be resolved (missing file, dangling link) nothing is written: guessing a destination
        // could replace a symlink or create a config the running panel never loaded.
        guard let resolved = realpath(path, nil) else {
            throw failure("the configuration file could not be resolved (\(lastError()))")
        }
        let target = String(cString: resolved)
        free(resolved)
        let directory = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        var template = Array((directory + "/." + name + ".XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw failure(lastError()) }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var committed = false
        var closed = false
        defer {
            if !closed { close(descriptor) }
            if !committed { unlink(temporary) }
        }

        guard fchmod(descriptor, 0o600) == 0 else { throw failure(lastError()) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) throws -> Void in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure(lastError())
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw failure(lastError()) }
        closed = true
        guard close(descriptor) == 0 else { throw failure(lastError()) }
        guard rename(temporary, target) == 0 else { throw failure(lastError()) }
        committed = true
    }
}

/// Strict raw-JSON reader and deterministic writer for `PanelConfig`. It parses the bytes itself instead of using
/// `JSONDecoder`/`JSONSerialization`, because those build Swift dictionaries that merge keys Swift considers
/// canonically equivalent while Node keeps them distinct. Every key, ID, path and label is preserved scalar for
/// scalar. Errors name the field and rule only, never raw values.
extension PanelConfigStore {
    // MARK: Reading

    static func decode(_ data: Data) throws -> PanelConfig {
        var parser = Parser(bytes: Array(data))
        let root = try parser.parseDocument()
        guard case .object(let members) = root else { throw invalid("configuration", "must be a JSON object") }

        let names = ["version", "nodePath", "ompPath", "profile", "refreshSeconds", "cacheMinutes", "timeoutSeconds",
                     "providers", "labels", "metrics", "warnPercent", "criticalPercent", "showPace"]
        if members.contains(where: { member in !names.contains { $0.isExactlyEqual(to: member.key) } }) {
            throw invalid("configuration", "must not contain unsupported keys")
        }
        func member(_ name: String) throws -> Value {
            guard let found = members.first(where: { $0.key.isExactlyEqual(to: name) }) else { throw invalid(name, "is required") }
            return found.value
        }
        func string(_ name: String) throws -> String {
            guard case .string(let value) = try member(name) else { throw invalid(name, "must be a string") }
            return value
        }
        func number(_ name: String) throws -> Double {
            guard case .number(let value) = try member(name) else { throw invalid(name, "must be a number") }
            return value
        }
        func map(_ name: String) throws -> ExactConfigMap {
            guard case .object(let entries) = try member(name) else { throw invalid(name, "must be an object of strings") }
            var result = ExactConfigMap()
            for entry in entries {
                guard case .string(let value) = entry.value else { throw invalid(name, "must be an object of strings") }
                result[entry.key] = value
            }
            return result
        }

        guard try number("version") == 1 else { throw invalid("version", "must be the number 1") }
        let providers: [String]?
        switch try member("providers") {
        case .null: providers = nil
        case .array(let items):
            providers = try items.map { (item: Value) throws -> String in
                guard case .string(let value) = item else { throw invalid("providers", "must be null or an array of strings") }
                return value
            }
        default: throw invalid("providers", "must be null or an array of strings")
        }
        guard case .bool(let showPace) = try member("showPace") else { throw invalid("showPace", "must be a boolean") }
        let config = PanelConfig(
            version: 1, nodePath: try string("nodePath"), ompPath: try string("ompPath"), profile: try string("profile"),
            refreshSeconds: try number("refreshSeconds"), cacheMinutes: try number("cacheMinutes"),
            timeoutSeconds: try number("timeoutSeconds"), providers: providers, labels: try map("labels"),
            metrics: try map("metrics"), warnPercent: try number("warnPercent"), criticalPercent: try number("criticalPercent"),
            showPace: showPace)
        try config.validate()
        return config
    }

    private static func invalid(_ field: String, _ rule: String) -> PanelConfigError { .invalid(field: field, rule: rule) }

    private enum Value {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([Value])
        case object([(key: String, value: Value)])
    }

    /// RFC 8259 JSON as accepted by `JSON.parse`: duplicate object keys keep the first position with the last value
    /// (exact key identity); unpaired `\u` surrogate escapes cannot be represented by a Swift String and are rejected.
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parseDocument() throws -> Value {
            skipSpace()
            let value = try parseValue()
            skipSpace()
            guard index == bytes.count else { throw PanelConfigError.malformed }
            return value
        }

        private mutating func skipSpace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D { index += 1 }
        }

        private mutating func parseValue() throws -> Value {
            guard index < bytes.count else { throw PanelConfigError.malformed }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw PanelConfigError.malformed
            }
        }

        private mutating func literal(_ text: String) throws {
            let expected = text.utf8
            let end = index + expected.count
            guard end <= bytes.count, bytes[index..<end].elementsEqual(expected) else { throw PanelConfigError.malformed }
            index += expected.count
        }

        private mutating func enter() throws {
            depth += 1
            guard depth <= 32 else { throw PanelConfigError.malformed }
        }

        private mutating func parseObject() throws -> Value {
            try enter()
            defer { depth -= 1 }
            index += 1
            var members: [(key: String, value: Value)] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw PanelConfigError.malformed }
                let key = try parseString()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw PanelConfigError.malformed }
                index += 1
                skipSpace()
                let value = try parseValue()
                if let existing = members.firstIndex(where: { $0.key.isExactlyEqual(to: key) }) { members[existing].value = value }
                else { members.append((key: key, value: value)) }
                skipSpace()
                guard index < bytes.count else { throw PanelConfigError.malformed }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw PanelConfigError.malformed
            }
        }

        private mutating func parseArray() throws -> Value {
            try enter()
            defer { depth -= 1 }
            index += 1
            var items: [Value] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try parseValue())
                skipSpace()
                guard index < bytes.count else { throw PanelConfigError.malformed }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw PanelConfigError.malformed
            }
        }

        private mutating func hexUnit() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw PanelConfigError.malformed }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
                default: throw PanelConfigError.malformed
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        private mutating func parseString() throws -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw PanelConfigError.malformed }
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(bytes: out, encoding: .utf8) else { throw PanelConfigError.malformed }
                    return text
                case 0x00..<0x20:
                    throw PanelConfigError.malformed
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw PanelConfigError.malformed }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var unit = try hexUnit()
                        if (0xDC00...0xDFFF).contains(unit) { throw unpaired() }
                        if (0xD800...0xDBFF).contains(unit) {
                            guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw unpaired() }
                            index += 2
                            let low = try hexUnit()
                            guard (0xDC00...0xDFFF).contains(low) else { throw unpaired() }
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(unit) else { throw unpaired() }
                        out.append(contentsOf: String(Character(scalar)).utf8)
                    default: throw PanelConfigError.malformed
                    }
                default:
                    out.append(byte)
                }
            }
        }

        private func unpaired() -> PanelConfigError {
            .invalid(field: "configuration", rule: "contains an unpaired surrogate escape, which cannot be represented")
        }

        private mutating func parseNumber() throws -> Double {
            let start = index
            func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw PanelConfigError.malformed }
            if bytes[index] == UInt8(ascii: "0") { index += 1 }
            else { while index < bytes.count, isDigit(bytes[index]) { index += 1 } }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard index < bytes.count, isDigit(bytes[index]) else { throw PanelConfigError.malformed }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, isDigit(bytes[index]) else { throw PanelConfigError.malformed }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            // Overflow reads as infinity (like JS) and is rejected by validation.
            return Double(String(decoding: bytes[start..<index], as: UTF8.self)) ?? .infinity
        }
    }

    // MARK: Writing

    /// Deterministic pretty JSON in the installer's key order, newline terminated. Maps are written in UTF-8
    /// byte order of their exact keys, `providers` keeps its order, and a nil `providers` is an explicit `null`.
    static func serialize(_ config: PanelConfig) throws -> Data {
        func text<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        func array(_ values: [String]) throws -> String {
            if values.isEmpty { return "[]" }
            return "[\n" + (try values.map { "    " + (try text($0)) }).joined(separator: ",\n") + "\n  ]"
        }
        func map(_ values: ExactConfigMap) throws -> String {
            if values.isEmpty { return "{}" }
            let lines = try values.sortedEntries.map { "    " + (try text($0.key)) + ": " + (try text($0.value)) }
            return "{\n" + lines.joined(separator: ",\n") + "\n  }"
        }
        let entries: [(String, String)] = [
            ("version", try text(config.version)),
            ("nodePath", try text(config.nodePath)),
            ("ompPath", try text(config.ompPath)),
            ("profile", try text(config.profile)),
            ("refreshSeconds", try text(config.refreshSeconds)),
            ("cacheMinutes", try text(config.cacheMinutes)),
            ("timeoutSeconds", try text(config.timeoutSeconds)),
            ("providers", try config.providers.map(array) ?? "null"),
            ("labels", try map(config.labels)),
            ("metrics", try map(config.metrics)),
            ("warnPercent", try text(config.warnPercent)),
            ("criticalPercent", try text(config.criticalPercent)),
            ("showPace", config.showPace ? "true" : "false"),
        ]
        let body = try entries.map { "  " + (try text($0.0)) + ": " + $0.1 }.joined(separator: ",\n")
        let data = Data(("{\n" + body + "\n}\n").utf8)
        // The writer must be exactly invertible; never persist bytes the strict reader would not restore.
        guard let restored = try? decode(data), restored == config else {
            throw PanelConfigError.writeFailed("the configuration could not be serialized faithfully")
        }
        return data
    }
}
