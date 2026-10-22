import Foundation

/// A deliberately small TOML editor. Original lines are the source of truth;
/// unsupported values remain opaque and cannot be edited through the app.
struct ConfigDocument {
    indirect enum Value: Equatable {
        case string(String)
        case integer(Int)
        case float(Double)
        case bool(Bool)
        case array([Value])

        /// The value as it is written to the file.
        var token: String {
            switch self {
            case .string(let string): return Self.basicString(string)
            case .integer(let integer): return String(integer)
            case .float(let double): return String(double)
            case .bool(let bool): return bool ? "true" : "false"
            case .array(let elements): return "[" + elements.map(\.token).joined(separator: ", ") + "]"
            }
        }

        var number: Double? {
            switch self {
            case .integer(let integer): return Double(integer)
            case .float(let double): return double
            default: return nil
            }
        }

        var string: String? {
            if case .string(let string) = self { return string }
            return nil
        }

        /// Equality that treats `8` and `8.0` as the same value.
        func equivalent(to other: Value) -> Bool {
            if let lhs = number, let rhs = other.number { return lhs == rhs }
            if case .array(let lhs) = self, case .array(let rhs) = other {
                return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.equivalent(to: $1) }
            }
            return self == other
        }

        /// A double-quoted TOML string with quotes, backslashes, and control characters escaped.
        private static func basicString(_ string: String) -> String {
            var escaped = "\""
            for scalar in string.unicodeScalars {
                switch scalar.value {
                case 0x22: escaped += "\\\""
                case 0x5C: escaped += "\\\\"
                case 0x08: escaped += "\\b"
                case 0x09: escaped += "\\t"
                case 0x0A: escaped += "\\n"
                case 0x0C: escaped += "\\f"
                case 0x0D: escaped += "\\r"
                case 0..<0x20, 0x7F: escaped += String(format: "\\u%04X", scalar.value)
                default: escaped.unicodeScalars.append(scalar)
                }
            }
            return escaped + "\""
        }
    }

    struct Entry {
        var table: [String]
        var key: String
        var line: Int
        var endLine: Int
        var valueRange: Range<String.Index>
        var value: Value?
        var editable: Bool
        var isDotted: Bool
    }

    private struct Line {
        var text: String
        var ending: String
    }

    private struct Header {
        var line: Int
        var path: [String]
    }

    private var lines: [Line] = []
    private var bom = ""
    private(set) var entries: [Entry] = []
    private var headers: [Header] = []
    private var newline = "\n"

    init(_ source: String) {
        var text = source
        if text.hasPrefix("\u{FEFF}") {
            bom = "\u{FEFF}"
            text.removeFirst()
        }
        lines = Self.splitLines(text)
        newline = lines.first { !$0.ending.isEmpty }?.ending ?? "\n"
        scan()
    }

    // MARK: Reading

    var text: String { bom + lines.map { $0.text + $0.ending }.joined() }

    var tables: [[String]] { headers.map(\.path) }

    /// The last assignment of `key`, which is the one TOML readers use.
    func entry(_ key: String, in table: [String]) -> Entry? {
        entries.last { $0.table == table && $0.key == key }
    }

    func value(_ key: String, in table: [String]) -> Value? {
        entry(key, in: table)?.value
    }

    /// An opaque assignment can contain a whole table, such as `options = { … }`.
    func opaqueEntry(containing path: [String]) -> Entry? {
        entries.first { $0.value == nil && path.starts(with: $0.table + [$0.key]) }
    }

    /// Paths that exist even without an explicit table header.
    var definedPaths: [[String]] { tables + entries.map { $0.table + [$0.key] } }

    // MARK: Editing

    /// Sets a simple key, or removes every assignment of it when `value` is nil.
    mutating func set(_ key: String, in table: [String], to value: Value?) throws {
        guard Self.isBareKey(key), table.allSatisfy({ !$0.isEmpty }) else {
            throw ConfigError(message: "This config key cannot be edited safely.", line: nil)
        }
        let matches = entries.filter { $0.table == table && $0.key == key }
        if let existing = matches.last {
            try replace(existing, duplicates: matches, with: value)
        } else if let value {
            try insert(key, in: table, value: value)
        }
    }

    mutating func removeTable(_ path: [String]) {
        for header in headers.filter({ $0.path == path }).reversed() {
            lines.removeSubrange(header.line..<line(after: header))
        }
        scan()
    }

    /// Edits the last duplicate of a key, or removes all duplicates when `value` is nil.
    private mutating func replace(_ entry: Entry, duplicates: [Entry], with value: Value?) throws {
        guard entry.editable else {
            throw ConfigError(message: "The key ‘\(entry.key)’ uses complex TOML. Edit it by hand; the app can edit only simple keys and single-line values.", line: entry.line + 1)
        }
        if let value {
            if let previous = entry.value, previous.equivalent(to: value) { return }
            lines[entry.line].text.replaceSubrange(entry.valueRange, with: value.token)
        } else {
            guard duplicates.allSatisfy(\.editable) else {
                throw ConfigError(message: "The key ‘\(entry.key)’ has a complex duplicate. Edit it by hand.", line: entry.line + 1)
            }
            for duplicate in duplicates.reversed() {
                lines.removeSubrange(duplicate.line...duplicate.endLine)
            }
        }
        scan()
    }

    /// Adds a new assignment at the end of its table, creating the table when needed.
    private mutating func insert(_ key: String, in table: [String], value: Value) throws {
        // A dotted assignment can define a parent table without a header.
        let tableHasHeader = headers.contains { $0.path == table }
        let conflict = entries.first { entry in
            let isInsideComplexValue = !entry.editable && (table + [key]).starts(with: entry.table + [entry.key])
            let isDefinedByDottedKey = !tableHasHeader && entry.isDotted && entry.table.starts(with: table)
            return isInsideComplexValue || isDefinedByDottedKey
        }
        if let conflict {
            throw ConfigError(message: "This table uses dotted keys or complex TOML. Edit it by hand.", line: conflict.line + 1)
        }

        let assignment = "\(key) = \(value.token)"
        if let header = headers.last(where: { $0.path == table }) {
            // Trailing comments introduce the next table, not this key.
            let end = line(after: header)
            let index = entries.last { $0.line > header.line && $0.line < end }.map { $0.endLine + 1 } ?? (header.line + 1)
            insertLines([assignment], at: index)
        } else {
            var index = lines.count
            // Keep a new window rule next to the existing ones.
            if table.first == "windows", let lastRule = headers.last(where: { $0.path.first == "windows" && $0.path.count > 1 }) {
                index = line(after: lastRule)
            }
            let header = table.map { Self.isBareKey($0) ? $0 : Value.string($0).token }.joined(separator: ".")
            let spacer: [String] = index > 0 && !lines[index - 1].text.isEmpty ? [""] : []
            insertLines(spacer + ["[\(header)]", assignment], at: index)
        }
        scan()
    }

    /// The index of the first line after `header`'s table.
    private func line(after header: Header) -> Int {
        var end = headers.first { $0.line > header.line }?.line ?? lines.count
        // A multiline value can itself end with a line that starts with #.
        let contentEnd = entries.last { $0.line > header.line && $0.line < end }.map { $0.endLine + 1 } ?? (header.line + 1)
        while end > contentEnd {
            let text = lines[end - 1].text.trimmingCharacters(in: .whitespaces)
            guard text.isEmpty || text.hasPrefix("#") else { break }
            end -= 1
        }
        return end
    }

    /// Inserts lines using the file's newline style, keeping a missing final newline missing.
    private mutating func insertLines(_ content: [String], at index: Int) {
        let hadFinalNewline = lines.last.map { !$0.ending.isEmpty } ?? true
        if index > 0 && lines[index - 1].ending.isEmpty {
            lines[index - 1].ending = newline
        }
        var added = content.map { Line(text: $0, ending: newline) }
        if index == lines.count && !hadFinalNewline {
            added[added.count - 1].ending = ""
        }
        lines.insert(contentsOf: added, at: index)
    }

    // MARK: Scanning

    /// Splits on LF scalars, not Characters: CRLF is a single Swift Character.
    private static func splitLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        var rest = text[...]
        while let lineFeed = rest.unicodeScalars.firstIndex(of: "\n") {
            var content = String(rest[..<lineFeed])
            let ending = content.hasSuffix("\r") ? "\r\n" : "\n"
            if ending == "\r\n" {
                content.removeLast()
            }
            lines.append(Line(text: content, ending: ending))
            rest = rest[rest.index(after: lineFeed)...]
        }
        if !rest.isEmpty {
            lines.append(Line(text: String(rest), ending: ""))
        }
        return lines
    }

    /// Rebuilds `headers` and `entries` from `lines`.
    private mutating func scan() {
        entries = []
        headers = []
        var table: [String] = []
        var index = 0
        while index < lines.count {
            let text = lines[index].text
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                // Do not associate entries in array/unknown tables with a known table.
                table = Self.tablePath(ofHeader: trimmed) ?? ["\u{0}opaque-\(index)"]
                headers.append(Header(line: index, path: table))
                index += 1
                continue
            }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equals = Self.unquotedEquals(in: text),
                  let keyPath = Self.keyPath(String(text[..<equals]))
            else {
                index += 1
                continue
            }
            let entry = scanEntry(at: index, in: table, keyPath: keyPath, equals: equals)
            entries.append(entry)
            index = entry.endLine + 1
        }
    }

    /// Reads the assignment on `line`, following a multiline value to its last line.
    private func scanEntry(at line: Int, in table: [String], keyPath: [String], equals: String.Index) -> Entry {
        let text = lines[line].text
        let valueStart = text[text.index(after: equals)...].firstIndex { !$0.isWhitespace } ?? text.endIndex
        let code = Self.codeToken(String(text[valueStart...]))
        let valueEnd = text.index(valueStart, offsetBy: code.count)
        var combined = String(text[valueStart...])
        var endLine = line
        while !Self.isComplete(combined), endLine + 1 < lines.count {
            endLine += 1
            combined += "\n" + lines[endLine].text
        }
        // Multiline values stay opaque.
        let value = endLine == line ? Self.parse(code) : nil
        return Entry(
            table: table + keyPath.dropLast(),
            key: keyPath.last ?? "",
            line: line,
            endLine: endLine,
            valueRange: valueStart..<valueEnd,
            value: value,
            editable: keyPath.count == 1 && value != nil,
            isDotted: keyPath.count > 1
        )
    }

    // MARK: Lexing

    /// Tracks whether a left-to-right scan of one line is inside a quoted string.
    private struct QuoteScanner {
        private var quote: Character?
        private var isEscaped = false

        var isInsideString: Bool { quote != nil }

        /// Feeds the next character. Returns true when it belongs to a string,
        /// including the opening and closing quotes.
        mutating func consume(_ character: Character) -> Bool {
            if let open = quote {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" && open == "\"" {
                    isEscaped = true
                } else if character == open {
                    quote = nil
                }
                return true
            }
            if character == "\"" || character == "'" {
                quote = character
                return true
            }
            return false
        }
    }

    private static let bareKeyCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// True for a non-empty key of ASCII letters, digits, `_`, and `-`.
    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { bareKeyCharacters.contains($0) }
    }

    /// The path of a `[table]` header, or nil for `[[array]]` tables and unreadable headers.
    private static func tablePath(ofHeader header: String) -> [String]? {
        let code = codeToken(header)
        guard code.hasSuffix("]"), !code.hasPrefix("[[") else { return nil }
        return keyPath(String(code.dropFirst().dropLast()))
    }

    /// Splits and decodes a dotted key such as `windows."my app"`. Returns nil
    /// when a part is neither a bare key nor a single-line quoted string.
    private static func keyPath(_ source: String) -> [String]? {
        var parts: [String] = []
        var part = ""
        var scanner = QuoteScanner()
        for character in source {
            if !scanner.consume(character) && character == "." {
                parts.append(part.trimmingCharacters(in: .whitespaces))
                part = ""
            } else {
                part.append(character)
            }
        }
        guard !scanner.isInsideString else { return nil }
        parts.append(part.trimmingCharacters(in: .whitespaces))

        var decoded: [String] = []
        for part in parts {
            if isBareKey(part) {
                decoded.append(part)
            } else if let name = parse(part)?.string {
                decoded.append(name)
            } else {
                return nil
            }
        }
        return decoded
    }

    /// The first `=` outside a string, or nil when a comment starts first.
    private static func unquotedEquals(in line: String) -> String.Index? {
        var scanner = QuoteScanner()
        for index in line.indices {
            let character = line[index]
            if scanner.consume(character) { continue }
            if character == "=" { return index }
            if character == "#" { return nil }
        }
        return nil
    }

    /// The text before any comment, without surrounding spaces.
    private static func codeToken(_ text: String) -> String {
        var scanner = QuoteScanner()
        for index in text.indices {
            if !scanner.consume(text[index]) && text[index] == "#" {
                return String(text[..<index]).trimmingCharacters(in: .whitespaces)
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Lexes enough multiline TOML to keep continuation lines from becoming keys.
    private static func isComplete(_ value: String) -> Bool {
        let characters = Array(value)
        var index = 0
        var depth = 0
        var quote: Character?
        var isTriple = false
        var isEscaped = false
        var isInComment = false
        while index < characters.count {
            let character = characters[index]
            if isInComment {
                if character == "\n" {
                    isInComment = false
                }
                index += 1
                continue
            }
            if let open = quote {
                if isEscaped {
                    isEscaped = false
                    index += 1
                    continue
                }
                if open == "\"" && character == "\\" {
                    isEscaped = true
                    index += 1
                    continue
                }
                if character == open {
                    if !isTriple {
                        quote = nil
                    } else if index + 2 < characters.count && characters[index + 1] == open && characters[index + 2] == open {
                        quote = nil
                        // Four or five closing quotes include one or two literal quotes.
                        var run = 3
                        while index + run < characters.count && characters[index + run] == open && run < 5 {
                            run += 1
                        }
                        index += run - 1
                    }
                }
            } else if character == "#" {
                isInComment = true
            } else if character == "\"" || character == "'" {
                quote = character
                isTriple = index + 2 < characters.count && characters[index + 1] == character && characters[index + 2] == character
                if isTriple {
                    index += 2
                }
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
            }
            index += 1
        }
        return quote == nil && depth <= 0
    }

    // MARK: Values

    /// Parses a single-line value. Returns nil for anything the editor does not support.
    static func parse(_ token: String) -> Value? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("\"\"\""), !trimmed.hasPrefix("'''") else { return nil }
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") { return parseString(trimmed) }
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if trimmed.hasPrefix("[") { return parseArray(trimmed) }
        return parseNumber(trimmed)
    }

    private static func parseString(_ token: String) -> Value? {
        guard let quote = token.first, token.count >= 2, token.last == quote else { return nil }
        let inner = String(token.dropFirst().dropLast())
        if quote == "'" {
            return inner.contains("'") || inner.contains("\n") ? nil : .string(inner)
        }
        return unescapeBasicString(inner).map(Value.string)
    }

    private static func unescapeBasicString(_ inner: String) -> String? {
        var result = ""
        var characters = inner.makeIterator()
        while let character = characters.next() {
            if character == "\"" || character == "\n" || character == "\r" { return nil }
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escape = characters.next() else { return nil }
            switch escape {
            case "b": result += "\u{8}"
            case "t": result += "\t"
            case "n": result += "\n"
            case "f": result += "\u{c}"
            case "r": result += "\r"
            case "\"": result += "\""
            case "\\": result += "\\"
            case "u", "U":
                guard let scalar = unicodeEscape(&characters, digits: escape == "u" ? 4 : 8) else { return nil }
                result.unicodeScalars.append(scalar)
            default: return nil
            }
        }
        return result
    }

    /// Reads the hex digits of a `\u` or `\U` escape.
    private static func unicodeEscape(_ characters: inout String.Iterator, digits: Int) -> Unicode.Scalar? {
        var hex = ""
        for _ in 0..<digits {
            guard let digit = characters.next(), digit.isHexDigit else { return nil }
            hex.append(digit)
        }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return Unicode.Scalar(value)
    }

    /// Parses a flat single-line array. Nested arrays are not supported.
    private static func parseArray(_ token: String) -> Value? {
        guard token.hasSuffix("]") else { return nil }
        var elements: [Value] = []
        var element = ""
        var scanner = QuoteScanner()
        for character in token.dropFirst().dropLast() {
            if scanner.consume(character) || character != "," {
                element.append(character)
                continue
            }
            guard let value = parseArrayElement(element) else { return nil }
            elements.append(value)
            element = ""
        }
        // A trailing comma leaves an empty final element.
        if !element.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = parseArrayElement(element) else { return nil }
            elements.append(value)
        }
        return scanner.isInsideString ? nil : .array(elements)
    }

    private static func parseArrayElement(_ element: String) -> Value? {
        let trimmed = element.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("[") else { return nil }
        return parse(element)
    }

    private static func parseNumber(_ token: String) -> Value? {
        let digits = token.replacingOccurrences(of: "_", with: "")
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
            return Int(digits.dropFirst(2), radix: radix).map(Value.integer)
        }
        if let integer = Int(digits) { return .integer(integer) }
        if let double = Double(digits) { return .float(double) }
        return nil
    }
}
