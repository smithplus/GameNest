import Foundation
import Testing
@testable import GameNest

@Test func epicLauncherInstalledDataCreatesUrlLauncher() throws {
    let data = """
    {
      "InstallationList": [
        {
          "AppName": "TestGameApp",
          "DisplayName": "Test Game",
          "InstallLocation": "\(NSTemporaryDirectory())"
        }
      ]
    }
    """.data(using: .utf8)!

    let games = EpicInstalledGames.detect(fromLauncherInstalledData: data)

    #expect(games.count == 1)
    #expect(games.first?.name == "Test Game")
    if case .urlScheme(let url) = games.first?.launch {
        #expect(url.absoluteString == "com.epicgames.launcher://apps/TestGameApp?action=launch&silent=true")
    } else {
        Issue.record("Expected Epic game to launch through the Epic URL scheme")
    }
}

@Test func heroicInstalledJsonCreatesHeroicLauncherOnlyWhenInstallPathExists() throws {
    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let installPath = tempRoot.appendingPathComponent("Installed Game", isDirectory: true)
    try FileManager.default.createDirectory(at: installPath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let data = """
    {
      "InstalledApp": {
        "title": "Installed Game",
        "app_name": "InstalledApp",
        "install_path": "\(installPath.path)"
      },
      "MissingApp": {
        "title": "Missing Game",
        "app_name": "MissingApp",
        "install_path": "\(tempRoot.appendingPathComponent("Missing").path)"
      }
    }
    """.data(using: .utf8)!

    let games = HeroicInstalledGames.detect(fromInstalledData: data)

    #expect(games.count == 1)
    #expect(games.first?.name == "Installed Game")
    if case .urlScheme(let url) = games.first?.launch {
        #expect(url.absoluteString == "heroic://launch/legendary/InstalledApp")
    } else {
        Issue.record("Expected Heroic game to launch through the Heroic URL scheme")
    }
}
