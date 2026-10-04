import Foundation
import Testing

struct LocalizableStringsTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ language: String) throws -> [String: String] {
        let url = Self.root.appendingPathComponent("Sources/MacDuo/Resources/\(language).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    @Test
    func testEveryLanguageHasTheSameKeys() throws {
        let english = try table("en")
        let chinese = try table("zh-Hans")
        #expect(Set(english.keys) == Set(chinese.keys))
        for (key, value) in english {
            #expect(key == value, "the English table maps \(key) to something else")
        }
    }

    @Test
    func testEveryPanelStringIsTranslated() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("Sources/MacDuo/SettingsView.swift"),
            encoding: .utf8
        )
        let pattern = try NSRegularExpression(pattern: #"localized\("((?:[^"\\]|\\.)*)"\)"#)
        let keys = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
        #expect(!keys.isEmpty)
        let chinese = try table("zh-Hans")
        for key in keys {
            #expect(chinese[key] != nil, "\(key) has no Chinese translation")
        }
    }
}
