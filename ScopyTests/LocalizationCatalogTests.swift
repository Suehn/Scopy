import Foundation
import XCTest

@testable import Scopy

/// The string catalog compiles into this bundle as one `.strings` table per translated language and
/// an English `.stringsdict` for the plural forms. The other tests see only the untranslated keys
/// because their host has no catalog, so this is where the compiled resources are checked. The
/// lookup is done on the files rather than through `Bundle.localizedString`, which follows the
/// machine's language and would make the expectations depend on it.
final class LocalizationCatalogTests: XCTestCase {
    private let bundle = Bundle(for: LocalizationCatalogTests.self)

    private func table(_ language: String, _ file: String) throws -> NSDictionary {
        let url = try XCTUnwrap(bundle.url(forResource: file, withExtension: nil, subdirectory: "\(language).lproj"))
        return try XCTUnwrap(NSDictionary(contentsOf: url))
    }

    func testSimplifiedChineseTableCarriesTheTranslations() throws {
        let zhHans = try table("zh-Hans", "Localizable.strings")
        XCTAssertEqual(zhHans["Position match"] as? String, "位置命中")
        XCTAssertEqual(zhHans["Launch at Login"] as? String, "登录时启动")
        XCTAssertEqual(zhHans["%lld matches found"] as? String, "%lld 处命中")
        XCTAssertNil(zhHans["Exact"], "Search modes stay product terms")
    }

    func testEnglishPluralsCompileIntoTheStringsDictionary() throws {
        let en = try table("en", "Localizable.stringsdict")
        let entry = try XCTUnwrap(en["%lld matches found"] as? NSDictionary)
        let variable = try XCTUnwrap(entry["value"] as? NSDictionary)
        XCTAssertEqual(variable["NSStringFormatSpecTypeKey"] as? String, "NSStringPluralRuleType")
        XCTAssertEqual(variable["one"] as? String, "%lld match found")
        XCTAssertEqual(variable["other"] as? String, "%lld matches found")
        let results = try XCTUnwrap((en["%lld results"] as? NSDictionary)?["value"] as? NSDictionary)
        XCTAssertEqual(results["one"] as? String, "%lld result")
    }
}
