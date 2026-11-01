import Foundation

public enum ClipClassifier {
    public static func classify(text: String, sourceBundleID: String? = nil) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if linkURL(from: trimmed) != nil { return .link }
        if ClipColor.parse(trimmed) != nil { return .color }
        if looksLikeCode(trimmed, sourceBundleID: sourceBundleID) { return .code }
        return .text
    }

    public static func linkURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8192,
            trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        if trimmed.lowercased().hasPrefix("www."), trimmed.dropFirst(4).contains(".") {
            return URL(string: "https://" + trimmed)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "ftp": return url.host?.isEmpty == false ? url : nil
        case "mailto": return trimmed.contains("@") ? url : nil
        default: return nil
        }
    }

    private static let editorBundlePrefixes = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.sublimetext.", "com.jetbrains.", "com.googlecode.iterm2", "com.apple.Terminal", "com.github.GitHubClient",
        "com.panic.Nova",
    ]

    private static let declarationPatterns: [NSRegularExpression] = [
        #"^\s*(func|def|fn|class|struct|interface|enum|impl|trait|protocol|extension)\s+\w+.*[:{(<]"#,
        #"^\s*(export\s+)?(const|let|var|val)\s+[\w{\[][^=]*(=|:)"#,
        #"^\s*import\s+[\w.{"'*]+"#,
        #"^\s*from\s+\S+\s+import\s"#,
        #"^\s*#include\s*[<"]"#,
        #"^\s*(public|private|protected|internal|static)\s+\w+\s+\w+"#,
        #"^\s*(SELECT\s.+\sFROM\s|INSERT\s+INTO\s|UPDATE\s+\w+\s+SET\s|DELETE\s+FROM\s|CREATE\s+TABLE\s)"#,
        #"^\s*<(!doctype|html|head|body|div|script|style|svg)\b"#,
        #"^\s*(if|for|while|switch)\s*\(.*\)\s*\{?\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive, .anchorsMatchLines]) }

    static func looksLikeCode(_ text: String, sourceBundleID: String?) -> Bool {
        guard text.count >= 6 else { return false }
        if text.hasPrefix("#!/") { return true }
        if (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")),
            let data = text.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil {
            return true
        }
        let sample = String(text.prefix(4000))
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }

        var score = 0
        let range = NSRange(sample.startIndex..., in: sample)
        if declarationPatterns.contains(where: { $0.firstMatch(in: sample, range: range) != nil }) { score += 2 }

        let terminated = lines.filter { line in
            guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
            return last == ";" || last == "{" || last == "}"
        }
        if Double(terminated.count) / Double(lines.count) >= 0.3 { score += 2 }

        if lines.count >= 2 {
            let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
            if Double(indented.count) / Double(lines.count) >= 0.3 { score += 1 }
        }
        if ["=>", "->", "::", "==", "!=", "&&", "||", "</", "/>"].contains(where: sample.contains) { score += 1 }
        if let sourceBundleID, editorBundlePrefixes.contains(where: sourceBundleID.hasPrefix) { score += 1 }
        return score >= 3
    }
}

public enum SecretDetector {
    private static let patterns: [NSRegularExpression] = [
        #"sk-ant-[A-Za-z0-9_-]{20,}"#,
        #"\bsk-[A-Za-z0-9_-]{32,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_\w{20,}"#,
        #"\bglpat-[A-Za-z0-9_-]{16,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[abeprs]-[A-Za-z0-9-]{10,}"#,
        #"\bAIza[0-9A-Za-z_-]{35}\b"#,
        #"\b[sr]k_live_[0-9A-Za-z]{16,}"#,
        #"\bnpm_[A-Za-z0-9]{30,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"\beyJ[\w-]{10,}\.eyJ[\w-]{10,}\.[\w-]{10,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func containsSecret(_ text: String) -> Bool {
        let sample = String(text.prefix(200_000))
        let range = NSRange(sample.startIndex..., in: sample)
        if patterns.contains(where: { $0.firstMatch(in: sample, range: range) != nil }) { return true }
        return isCardNumber(sample)
    }

    private static func isCardNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 23, trimmed.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return false }
        let digits = trimmed.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
