import XCTest
@testable import iiire

/// `speech models --json` の結果から、既定の type のファイルの状態を取り出す
final class ModelCatalogTests: XCTestCase {
    func testPicksDefaultTypeFile() throws {
        let json = """
        {"models": [
          {"name": "haas-ja-v1.0", "type": "q8_0", "files": [
            {"type": "f16", "size": 1200, "fetched": true, "partial": 0},
            {"type": "q8_0", "size": 600, "fetched": false, "partial": 150}
          ]},
          {"name": "no-files"}
        ]}
        """
        let files = try ModelCatalog.parse(Data(json.utf8))
        XCTAssertEqual(files["haas-ja-v1.0"], ModelFile(fetched: false, partial: 150, size: 600))
        XCTAssertEqual(files["haas-ja-v1.0"]?.fraction, 0.25)
        XCTAssertNil(files["no-files"])
    }
}
