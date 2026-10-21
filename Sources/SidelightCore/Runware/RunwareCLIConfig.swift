import Foundation

/// The Runware CLI's saved sign-in: the API key `runware auth login` writes to `~/.runware/config.yaml`. Sidelight
/// only reads it, and never writes it. A key set only in `RUNWARE_API_KEY` is ignored on purpose: a shell's
/// environment never reaches an app opened from the Finder.
///
/// The CLI writes the file with Go's `yaml.Marshal` of a flat struct, so the reader is deliberately narrow, with no
/// YAML library: it reads a top-level `api_key` written plainly or quoted, and refuses anything it can't read with
/// certainty (block scalars, anchors, tags, flow collections, several documents, the key twice), rather than guess.
public enum RunwareCLIConfig {
    /// `~/.runware/config.yaml`
    public static var configFile: URL {
        URL.homeDirectory.appending(path: ".runware/config.yaml", directoryHint: .notDirectory)
    }

    /// Where the CLI may be installed: Homebrew's folders and `~/.local/bin`.
    public static var executableDirectories: [URL] { ExecutableLocator.standardDirectories }

    /// What the file says. Never describes the key itself.
    public enum Reading: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        case signedIn(String)
        /// No key saved: the file is missing, or has no `api_key`, or an empty one.
        case signedOut
        /// The file is there, but not in a shape Sidelight reads safely.
        case unreadable

        public var description: String {
            switch self {
            case .signedIn: "signed in"
            case .signedOut: "signed out"
            case .unreadable: "unreadable"
            }
        }

        public var debugDescription: String { description }

        /// The key, when there is one.
        public var key: String? {
            if case .signedIn(let key) = self { key } else { nil }
        }
    }

    /// What the file at ``configFile`` says; signed out when there's none.
    public static func read(file: URL = configFile) -> Reading {
        guard let data = try? Data(contentsOf: file) else {
            return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? .unreadable : .signedOut
        }
        return read(yaml: data)
    }

    /// The `api_key` in `yaml`.
    public static func read(yaml: Data) -> Reading {
        guard var text = String(data: yaml, encoding: .utf8) else { return .unreadable }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var value: String??  // nil: no api_key line yet; .some(nil): one with no value
        var hasContent = false
        var awaitsValue = false
        // `\r\n` is one character to Swift, and a newline like `\n`.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "---" {
                if hasContent { return .unreadable }
                continue
            }
            if trimmed == "..." || trimmed.hasPrefix("%") { return .unreadable }
            if line.first == " " || line.first == "\t" {
                // Nested under a key. Under `api_key`, its value would be a mapping or a list, not a key.
                if awaitsValue { return .unreadable }
                continue
            }
            awaitsValue = false
            hasContent = true
            guard let first = line.first, !"{[-&*!|>@`?".contains(first) else { return .unreadable }
            guard line.hasPrefix("api_key:") else { continue }
            guard value == nil else { return .unreadable }
            let rest = line.dropFirst("api_key:".count)
            if let next = rest.first, next != " ", next != "\t" { return .unreadable }
            switch scalar(rest.trimmingCharacters(in: .whitespaces)) {
            case .none: return .unreadable
            case .some(let scalar):
                value = .some(scalar)
                awaitsValue = scalar == nil
            }
        }
        guard case .some(.some(let key)) = value else { return .signedOut }
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        return trimmedKey.isEmpty ? .signedOut : .signedIn(trimmedKey)
    }

    /// The scalar `text` spells: `.some(nil)` for none (empty or null), `nil` for anything not read safely.
    private static func scalar(_ text: String) -> String?? {
        guard let first = text.first else { return .some(nil) }
        switch first {
        case "'":
            guard let value = singleQuoted(text) else { return nil }
            return .some(value)
        case "\"":
            guard let value = doubleQuoted(text) else { return nil }
            return .some(value)
        case "#": return .some(nil)
        case "|", ">", "&", "*", "!", "{", "[", "@", "`", "%": return nil
        default:
            var plain = text
            if let comment = plain.range(of: " #") ?? plain.range(of: "\t#") {
                plain = String(plain[..<comment.lowerBound])
            }
            plain = plain.trimmingCharacters(in: .whitespaces)
            if plain.contains(" ") || plain.contains("\t") || plain.contains(":") { return nil }
            if ["null", "Null", "NULL", "~"].contains(plain) { return .some(nil) }
            return .some(plain)
        }
    }

    /// `'value'`, with `''` for a quote, and nothing after it but a comment.
    private static func singleQuoted(_ text: String) -> String? {
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "'" {
                if next < text.endIndex, text[next] == "'" {
                    result.append("'")
                    index = text.index(after: next)
                    continue
                }
                return isOnlyComment(text[next...]) ? result : nil
            }
            result.append(character)
            index = next
        }
        return nil
    }

    /// `"value"`, with only `\"` and `\\` escapes, and nothing after it but a comment.
    private static func doubleQuoted(_ text: String) -> String? {
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            switch character {
            case "\\":
                guard next < text.endIndex, text[next] == "\"" || text[next] == "\\" else { return nil }
                result.append(text[next])
                index = text.index(after: next)
            case "\"":
                return isOnlyComment(text[next...]) ? result : nil
            default:
                result.append(character)
                index = next
            }
        }
        return nil
    }

    private static func isOnlyComment(_ rest: Substring) -> Bool {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || (trimmed.hasPrefix("#") && rest.first.map { $0 == " " || $0 == "\t" } == true)
    }
}
