import XCTest
import SwiftTreeSitter
import TreeSitterZortex

final class TreeSitterZortexTests: XCTestCase {
    func testCanLoadGrammar() throws {
        let parser = Parser()
        let language = Language(language: tree_sitter_zortex())
        XCTAssertNoThrow(try parser.setLanguage(language),
                         "Error loading Zortex grammar")
    }
}
