import Testing

@testable import ClipboardCore

@Suite struct ClassifierTests {
    // Assembled here so the source doesn't hold anything GitHub's secret scanning would stop a push over.
    @Test func googleClientSecretsAreDetected() throws {
        let secret = "GOCSPX" + "-" + String(repeating: "aB3_", count: 7)
        #expect(SecretDetector.containsSecret(secret))
        #expect(SecretDetector.containsSecret("CLIENT_SECRET=\(secret)"))
        #expect(!SecretDetector.containsSecret("GOCSPX is a prefix Google uses"))
        guard case .skippedSecret = ClipBuilder.build(items: [[utf8Rep(secret)]], source: ClipSource(bundleID: nil, name: nil), secrets: .skip) else {
            Issue.record("expected the secret to be skipped")
            return
        }
        #expect(try #require(draft(from: [[utf8Rep(secret)]], secrets: .show)).isSecret)
    }

    @Test(arguments: [
        "https://example.com", "http://example.com/a?b=c", "www.example.org", "mailto:ali@example.com",
        "  https://example.com/trailing-space \n",
    ])
    func linksAreLinks(text: String) {
        #expect(ClipClassifier.classify(text: text) == .link)
    }

    @Test(arguments: ["see https://example.com for more", "example", "https://", "file:///etc/hosts", "ali@example.com"])
    func nonLinksAreNotLinks(text: String) {
        #expect(ClipClassifier.classify(text: text) != .link)
    }

    @Test(arguments: [
        "#fff", "#FF8800", "#ff880080", "0xFF8800", "rgb(255, 136, 0)", "rgba(255,136,0,0.5)", "rgb(255 136 0 / 50%)",
        "hsl(32, 100%, 50%)",
    ])
    func colorsAreColors(text: String) {
        #expect(ClipClassifier.classify(text: text) == .color)
    }

    @Test func colorValuesParseCorrectly() throws {
        #expect(ClipColor.parse("#FF8800")?.hex == "#FF8800")
        #expect(ClipColor.parse("#f80")?.hex == "#FF8800")
        #expect(ClipColor.parse("rgb(255, 136, 0)")?.hex == "#FF8800")
        #expect(ClipColor.parse("hsl(0, 100%, 50%)")?.hex == "#FF0000")
        let translucent = try #require(ClipColor.parse("rgba(255,136,0,0.5)"))
        #expect(translucent.alpha == 0.5)
        #expect(ClipColor.parse("rgb(999, 0, 0)") == nil)
        #expect(ClipColor.parse("#12345") == nil)
    }

    @Test(arguments: [
        "func greet(name: String) -> String {\n    return \"Hello \\(name)\"\n}",
        "const total = items.reduce((a, b) => a + b, 0);",
        "#!/bin/bash\nset -euo pipefail\necho hi",
        "SELECT id, name FROM users WHERE age > 21;",
        "{\"name\": \"paste\", \"version\": 1}",
        "def main():\n    print('hi')\n\nmain()",
        "<div class=\"row\">\n  <span>hello</span>\n</div>",
    ])
    func codeIsCode(text: String) {
        #expect(ClipClassifier.classify(text: text) == .code)
    }

    @Test(arguments: [
        "Hello there, this is a normal sentence.",
        "The class action was filed last week; nobody noticed.",
        "Milk\nEggs\nBread",
        "import duties were raised in March",
        "Let me know if that works for you!",
    ])
    func proseIsText(text: String) {
        #expect(ClipClassifier.classify(text: text) == .text)
    }

    @Test func editorSourceTipsAmbiguousCode() {
        let line = "let total = price"
        #expect(ClipClassifier.classify(text: line) == .text)
        #expect(ClipClassifier.classify(text: line, sourceBundleID: "com.microsoft.VSCode") == .code)
    }

    @Test(arguments: [
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345",
        "export TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "AKIAIOSFODNN7EXAMPLE",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----",
        "xoxb-123456789012-abcdefghijkl",
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "4242 4242 4242 4242",
    ])
    func secretsAreDetected(text: String) {
        #expect(SecretDetector.containsSecret(text))
    }

    @Test(arguments: [
        "Hello world", "https://example.com/sk-short", "1234 5678 9012 3456", "The risk-free rate moved today",
        "2026-10-31",
    ])
    func ordinaryTextIsNotSecret(text: String) {
        #expect(!SecretDetector.containsSecret(text))
    }
}
