import Foundation
import Testing
@testable import GameNest

@Test func latestReleaseParserPrefersDmgAssetForAvailableUpdate() throws {
    let data = """
    {
      "tag_name": "v0.5.0",
      "html_url": "https://github.com/smithplus/GameNest/releases/tag/v0.5.0",
      "assets": [
        {
          "name": "GameNest-0.5.0.zip",
          "browser_download_url": "https://example.com/GameNest-0.5.0.zip"
        },
        {
          "name": "GameNest-0.5.0.dmg",
          "browser_download_url": "https://example.com/GameNest-0.5.0.dmg"
        }
      ]
    }
    """.data(using: .utf8)!

    let state = UpdateChecker.state(fromLatestReleaseData: data, currentVersion: "0.4.0")

    #expect(state == .available(
        version: "0.5.0",
        url: URL(string: "https://example.com/GameNest-0.5.0.dmg")!
    ))
}

@Test func latestReleaseParserFallsBackToReleasePageWithoutDmgAsset() throws {
    let data = """
    {
      "tag_name": "v0.5.0",
      "html_url": "https://github.com/smithplus/GameNest/releases/tag/v0.5.0",
      "assets": []
    }
    """.data(using: .utf8)!

    let state = UpdateChecker.state(fromLatestReleaseData: data, currentVersion: "0.4.0")

    #expect(state == .available(
        version: "0.5.0",
        url: URL(string: "https://github.com/smithplus/GameNest/releases/tag/v0.5.0")!
    ))
}
