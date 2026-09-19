import Foundation

public struct LeakViolation: Equatable, Sendable, CustomStringConvertible {
    public enum Rule: String, Sendable {
        case knownSecretMatch = "Known Secret Detected"
        case providerPatternMatch = "Cloud Provider Key Pattern Match"
        case suspiciousKeyInAST = "Suspicious Key Name in JSON AST"
        case absoluteUserPath = "User Absolute Path Detected"
    }

    public let rule: Rule
    public let fileRelativePath: String
    public let contextSnippet: String
    public let astPath: String?

    public init(rule: Rule, fileRelativePath: String, contextSnippet: String, astPath: String? = nil) {
        self.rule = rule
        self.fileRelativePath = fileRelativePath
        self.contextSnippet = contextSnippet
        self.astPath = astPath
    }

    public var description: String {
        let pathStr = astPath != nil ? " at '\(astPath!)'" : ""
        return "[\(rule.rawValue)] in \(fileRelativePath)\(pathStr): \(contextSnippet)"
    }
}

public protocol CredentialLeakScanning: Sendable {
    func scan(bundleURL: URL, knownSecrets: [String]) throws -> [LeakViolation]
    func scan(projectJSONData: Data, knownSecrets: [String]) throws -> [LeakViolation]
}

public final class CredentialLeakScanner: CredentialLeakScanning, @unchecked Sendable {
    public static let shared = CredentialLeakScanner()

    // Compiled regex patterns
    private let providerPatterns: [NSRegularExpression] = [
        // ElevenLabs sk_... or 32-hex
        try! NSRegularExpression(pattern: "(?i)\\b(?:sk_)?[a-f0-9]{32}\\b"),
        try! NSRegularExpression(pattern: "(?i)\\bsk_[a-zA-Z0-9_\\-]{20,}\\b"),
        try! NSRegularExpression(pattern: "(?i)\\beleven_[a-zA-Z0-9_\\-]{20,}\\b"),
        // Google / Gemini AIza...
        try! NSRegularExpression(pattern: "\\bAIza[0-9A-Za-z_\\-]{35}\\b"),
        // Resemble AI resemble_...
        try! NSRegularExpression(pattern: "(?i)\\bresemble_[a-zA-Z0-9_\\-]{20,}\\b"),
        // Bearer tokens
        try! NSRegularExpression(pattern: "(?i)\\bbearer\\s+[a-zA-Z0-9_\\-\\.\\=]{20,}\\b")
    ]

    private let suspiciousKeyPattern = try! NSRegularExpression(pattern: "(?i)^(api[_-]?key|secret|token|password|auth_header|bearer|credentials)$")
    private let userAbsolutePathPattern = try! NSRegularExpression(pattern: "/(?:Users|home)/[A-Za-z0-9._\\-]+/")

    public init() {}

    public func scan(projectJSONData: Data, knownSecrets: [String] = []) throws -> [LeakViolation] {
        var violations: [LeakViolation] = []

        // 1. Raw text pattern and known secret check
        guard let jsonString = String(data: projectJSONData, encoding: .utf8) else {
            throw NSError(
                domain: "CredentialLeakScanner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 project.json data"]
            )
        }
        scanText(jsonString, relativePath: "project.json", knownSecrets: knownSecrets, violations: &violations)

        // 2. JSON AST Traversal
        if let jsonObject = try? JSONSerialization.jsonObject(with: projectJSONData, options: []) {
            walkJSONAST(node: jsonObject, currentPath: "$", relativePath: "project.json", knownSecrets: knownSecrets, violations: &violations)
        }

        return violations
    }

    public func scan(bundleURL: URL, knownSecrets: [String] = []) throws -> [LeakViolation] {
        var violations: [LeakViolation] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return violations
        }

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: bundleURL.path + "/", with: "")
            let fileName = fileURL.lastPathComponent
            let ext = fileURL.pathExtension.lowercased()

            // Skip binary media and cache files
            if ["mov", "mp4", "wav", "m4a", "png", "jpg", "jpeg", "bin", "waveform"].contains(ext) {
                continue
            }
            if fileName.hasPrefix(".DS_Store") || fileName == ".git" {
                continue
            }

            if relativePath == "project.json" {
                let data = try Data(contentsOf: fileURL)
                let subViolations = try scan(projectJSONData: data, knownSecrets: knownSecrets)
                violations.append(contentsOf: subViolations)
            } else if ["json", "txt", "plist", "xml", "log", "yaml", "yml", "env", "conf", "cfg", "ini"].contains(ext) || fileName.hasPrefix(".env") {
                if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                    scanText(text, relativePath: relativePath, knownSecrets: knownSecrets, violations: &violations)
                }
            }
        }

        return violations
    }

    private func scanText(_ text: String, relativePath: String, knownSecrets: [String], violations: inout [LeakViolation]) {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // Known secrets match
        for secret in knownSecrets where secret.count >= 8 {
            if text.contains(secret) {
                let snippet = String(secret.prefix(4)) + "..." + String(secret.suffix(4))
                violations.append(LeakViolation(rule: .knownSecretMatch, fileRelativePath: relativePath, contextSnippet: snippet, astPath: nil))
            }
        }

        // Provider regex patterns
        for regex in providerPatterns {
            let matches = regex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                let matchedString = nsString.substring(with: match.range)
                let snippet = String(matchedString.prefix(6)) + "..." + String(matchedString.suffix(4))
                violations.append(LeakViolation(rule: .providerPatternMatch, fileRelativePath: relativePath, contextSnippet: snippet, astPath: nil))
            }
        }

        // User absolute path check
        let userPathMatches = userAbsolutePathPattern.matches(in: text, options: [], range: fullRange)
        for match in userPathMatches {
            let matchedString = nsString.substring(with: match.range)
            violations.append(LeakViolation(rule: .absoluteUserPath, fileRelativePath: relativePath, contextSnippet: matchedString, astPath: nil))
        }
    }

    private func walkJSONAST(node: Any, currentPath: String, relativePath: String, knownSecrets: [String], violations: inout [LeakViolation]) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                let nextPath = "\(currentPath).\(key)"
                let keyRange = NSRange(location: 0, length: key.utf16.count)

                // Check suspicious key
                if suspiciousKeyPattern.firstMatch(in: key, options: [], range: keyRange) != nil {
                    // Check if value is non-empty / non-trivial
                    if let strVal = value as? String, !strVal.isEmpty {
                        violations.append(LeakViolation(rule: .suspiciousKeyInAST, fileRelativePath: relativePath, contextSnippet: "Key '\(key)' with non-empty string", astPath: nextPath))
                    } else if !(value is NSNull) {
                        violations.append(LeakViolation(rule: .suspiciousKeyInAST, fileRelativePath: relativePath, contextSnippet: "Key '\(key)' present", astPath: nextPath))
                    }
                }

                walkJSONAST(node: value, currentPath: nextPath, relativePath: relativePath, knownSecrets: knownSecrets, violations: &violations)
            }
        } else if let array = node as? [Any] {
            for (idx, item) in array.enumerated() {
                walkJSONAST(node: item, currentPath: "\(currentPath)[\(idx)]", relativePath: relativePath, knownSecrets: knownSecrets, violations: &violations)
            }
        } else if let str = node as? String {
            // Check absolute user path
            let strRange = NSRange(location: 0, length: str.utf16.count)
            if userAbsolutePathPattern.firstMatch(in: str, options: [], range: strRange) != nil {
                violations.append(LeakViolation(rule: .absoluteUserPath, fileRelativePath: relativePath, contextSnippet: str, astPath: currentPath))
            }
        }
    }
}
