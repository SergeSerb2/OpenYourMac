import Foundation

/// One `[windows.<name>]` table: how matching windows behave.
struct WindowRule: Identifiable, Equatable {
    /// Table key under `[windows]` (for example `pip`). Stable identity.
    var id: String
    /// Optional app filter (bundle identifier). nil = any app.
    var bundleID: String?
    /// Display name of the chosen app, if known (not stored in the file).
    var appName: String?
    /// How the title is matched.
    var titleMatch: TitleMatch
    /// Choose normal heuristics, force tiling, or force floating.
    var floating: Floating
    /// Complex TOML is displayed in the list, but edited only in the file.
    var isHandEdited = false

    enum Floating: String, CaseIterable {
        case automatic = "Automatic", tile = "Tile", float = "Float"

        var value: Bool? {
            switch self {
            case .automatic: return nil
            case .tile: return false
            case .float: return true
            }
        }
    }
    /// Where new matching windows join the strip.
    var placement: Placement

    enum TitleMatch: Equatable {
        /// Matches every title (`title = '.*'`).
        case any
        /// Plain text, matched anywhere in the title (stored escaped as a regex).
        case contains(String)
        /// A raw regular expression.
        case pattern(String)

        /// The regex written to `title`.
        var regex: String {
            switch self {
            case .any: return ".*"
            case .contains(let text): return NSRegularExpression.escapedPattern(for: text)
            case .pattern(let p): return p
            }
        }

        /// Reads a stored regex back: plain text if it only escapes literals.
        init(regex: String) {
            if regex.isEmpty || regex == ".*" {
                self = .any
            } else if let literal = TitleMatch.unescapedLiteral(regex) {
                self = .contains(literal)
            } else {
                self = .pattern(regex)
            }
        }

        private static func unescapedLiteral(_ regex: String) -> String? {
            let special = Set("\\^$.|?*+()[]{}")
            var out = ""
            var escaping = false
            for ch in regex {
                if escaping {
                    guard special.contains(ch) || ch == "-" || ch == "/" else { return nil }
                    out.append(ch)
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else if special.contains(ch) && ch != "]" && ch != "}" {
                    return nil
                } else {
                    out.append(ch)
                }
            }
            guard !escaping, NSRegularExpression.escapedPattern(for: out) == regex else { return nil }
            return out
        }
    }

    enum Placement: Equatable, Hashable {
        /// Next to the window you are using.
        case automatic
        case start
        case end
        /// Always open at this 1-based column.
        case column(Int)
    }

    /// Human title for the rules list.
    var displayName: String {
        if id == "pip" { return "Picture in Picture" }
        if let appName, !appName.isEmpty { return appName }
        return id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Fast feedback for known Rust-regex incompatibilities. The engine is the
    /// final authority when saving; ICU is the fallback when it is unavailable.
    static func validatePattern(_ pattern: String, checkSyntax: Bool = true) -> String? {
        let unsupported = "OpenYourMac can't use this pattern (look-arounds and back-references aren't supported)."
        let characters = Array(pattern)
        var index = 0
        var inClass = false
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                let escape = characters[index + 1]
                if "ZhH".contains(escape) || (!inClass && ("123456789".contains(escape) || escape == "k" || escape == "g")) { return unsupported }
                index += 2
                continue
            }
            if character == "[" { inClass = true }
            if character == "]" { inClass = false }
            if !inClass {
                if character == "(" {
                    let prefix = String(characters[index...].prefix(4))
                    if ["(?=", "(?!", "(?<=", "(?<!", "(?>", "(?#", "(?P="].contains(where: prefix.hasPrefix) { return unsupported }
                }
                if "+*?".contains(character), index + 1 < characters.count, characters[index + 1] == "+" { return unsupported }
                if character == "{", let end = characters[index...].firstIndex(of: "}"), end + 1 < characters.count,
                   characters[end + 1] == "+", characters[(index + 1)..<end].allSatisfy({ $0.isNumber || $0 == "," }) { return unsupported }
            }
            index += 1
        }
        guard checkSyntax else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            return "This isn't a valid pattern."
        }
        return nil
    }
}
