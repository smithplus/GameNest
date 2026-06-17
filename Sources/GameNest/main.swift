import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by the AppDelegate whenever the launcher panel is shown, so the UI can refocus search.
    static let gameNestPanelDidOpen = Notification.Name("gameNestPanelDidOpen")
    /// Posted from the global hotkey handler to toggle the launcher panel.
    static let gameNestToggleHotKey = Notification.Name("gameNestToggleHotKey")
}

/// Keys used to persist the optional user-defined global shortcut.
enum HotKeyDefaults {
    static let code = "globalHotKeyCode"
    static let modifiers = "globalHotKeyModifiers"
    static let display = "globalHotKeyDisplay"
}

/// Helpers to translate between AppKit modifier flags and Carbon hotkey flags.
enum HotKeyUtil {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func symbols(from flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    static func keyLabel(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        default:
            let raw = (event.charactersIgnoringModifiers ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return raw.isEmpty ? "Key \(event.keyCode)" : raw
        }
    }
}

/// Registers a single optional system-wide hotkey via Carbon and posts a
/// notification when it fires. No default is set; the user opts in from Settings.
final class GlobalHotKeyManager: @unchecked Sendable {
    static let shared = GlobalHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    private init() {}

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .gameNestToggleHotKey, object: nil)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    /// Registers (or clears, when modifiers are 0) the global hotkey.
    func update(keyCode: UInt32, carbonModifiers: UInt32) {
        unregister()
        guard carbonModifiers != 0 else { return }
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x474E5354), id: 1) // 'GNST'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

enum ItemKind {
    case game
    case launcher
}

struct GameItem: Identifiable {
    var id: String { url.path }
    /// Base name derived from the file (used for covers, recents, classification).
    let name: String
    /// Name shown in the UI; equals `name` unless the user set a custom override.
    var displayName: String = ""
    var hasCustomName: Bool = false
    let url: URL
    /// The target actually opened on launch: the item itself for apps/aliases, or the parsed URL for `.webloc` launchers.
    let launchURL: URL
    let appIcon: NSImage
    var coverImage: NSImage?
    var isFetchingCover: Bool = false
    var timePlayedMinutes: Int?
    var progress: Double?
    var lastPlayedAt: Date?
    var kind: ItemKind = .game
    /// When set, launching opens this app (e.g. an emulator) with `launchArguments`
    /// instead of opening `launchURL` directly. Used for detected emulator ROMs.
    var emulatorURL: URL?
    var launchArguments: [String] = []
    /// Detected ROMs are not files inside the Games folder, so they must not be trashed.
    var canRemove: Bool = true

    var formattedTimePlayed: String? {
        guard let timePlayedMinutes, timePlayedMinutes > 0 else {
            return nil
        }

        let hours = timePlayedMinutes / 60
        if hours > 0 {
            return "\(hours)h"
        }

        return "\(timePlayedMinutes)m"
    }
}

/// Lightweight, name-based classifier that separates real games from storefronts,
/// launchers, emulators, and streaming/controller utilities so they can be grouped apart.
enum GameClassifier {
    private static let launcherKeywords: [String] = [
        // Storefronts / launchers
        "steam", "epicgames", "gog", "goggalaxy", "heroic", "gamehub",
        "battlenet", "blizzard", "eaapp", "origin", "ubisoftconnect", "uplay",
        "riotclient", "rockstargames", "amazongames", "lutris", "playnite", "itch",
        // Emulators
        "ryujinx", "yuzu", "dolphin", "retroarch", "openemu", "pcsx2", "rpcs3",
        "citra", "cemu", "ppsspp", "duckstation", "mgba", "snes9x", "mupen",
        "melonds", "bluestacks", "mame", "vita3k", "xemu", "flycast", "redream", "azahar",
        // Streaming / controller utilities
        "moonlight", "parsec", "steamlink", "chiaki", "geforcenow", "controller"
    ]

    static func kind(forName name: String) -> ItemKind {
        let normalized = GameNaming.normalized(name)
        for keyword in launcherKeywords where normalized.contains(keyword) {
            return .launcher
        }
        return .game
    }
}

struct GameMetadata {
    var timePlayedMinutes: Int?
    var progress: Double?
}

protocol GameMetadataProvider {
    var name: String { get }
    func metadataByNormalizedGameName() -> [String: GameMetadata]
}

final class GameMetadataRegistry {
    private let providers: [GameMetadataProvider]

    init(providers: [GameMetadataProvider] = [SteamMetadataProvider()]) {
        self.providers = providers
    }

    func metadataByNormalizedGameName() -> [String: GameMetadata] {
        var result: [String: GameMetadata] = [:]

        for provider in providers {
            let providerMetadata = provider.metadataByNormalizedGameName()
            for (name, metadata) in providerMetadata {
                result[name] = (result[name] ?? GameMetadata()).merging(metadata)
            }
        }

        return result
    }
}

private extension GameMetadata {
    func merging(_ other: GameMetadata) -> GameMetadata {
        GameMetadata(
            timePlayedMinutes: other.timePlayedMinutes ?? timePlayedMinutes,
            progress: other.progress ?? progress
        )
    }
}

enum ArtworkMode: String, CaseIterable, Identifiable {
    case covers
    case appIcons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .covers:
            return "Covers"
        case .appIcons:
            return "App Icons"
        }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case name
    case recent
    case timePlayed
    case progress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return "Name"
        case .recent:
            return "Recent"
        case .timePlayed:
            return "Time Played"
        case .progress:
            return "Progress"
        }
    }
}

enum GameNestPaths {
    static let gamesDirectory = URL(fileURLWithPath: "/Applications/Games", isDirectory: true)

    static var manualCoversDirectory: URL {
        gamesDirectory.appendingPathComponent("Covers", isDirectory: true)
    }

    static var metadataDirectory: URL {
        gamesDirectory.appendingPathComponent(".metadata", isDirectory: true)
    }

    static var autoCoversDirectory: URL {
        metadataDirectory.appendingPathComponent("covers", isDirectory: true)
    }

    static var noCoverDirectory: URL {
        metadataDirectory.appendingPathComponent("nocover", isDirectory: true)
    }

    static var recentsFile: URL {
        metadataDirectory.appendingPathComponent("recents.json")
    }

    static var namesFile: URL {
        metadataDirectory.appendingPathComponent("names.json")
    }

    static var legacyCacheDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameNest/Covers/v3", isDirectory: true)
    }
}

/// Persists "last launched" timestamps keyed by normalized game name.
enum RecentsStore {
    static func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: GameNestPaths.recentsFile),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func record(name: String, at date: Date = Date()) {
        var entries = load()
        entries[GameNaming.normalized(name)] = date
        save(entries)
    }

    private static func save(_ entries: [String: Date]) {
        let raw = entries.mapValues { $0.timeIntervalSince1970 }
        guard let data = try? JSONEncoder().encode(raw) else {
            return
        }
        try? FileManager.default.createDirectory(at: GameNestPaths.metadataDirectory, withIntermediateDirectories: true)
        try? data.write(to: GameNestPaths.recentsFile, options: [.atomic])
    }
}

/// Persists custom display-name overrides keyed by normalized base name, so renaming a tile
/// never touches the underlying alias/file and won't trigger duplicate auto-detection.
enum DisplayNameStore {
    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: GameNestPaths.namesFile),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return raw
    }

    static func name(forNormalized normalized: String) -> String? {
        let value = load()[normalized]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func set(_ name: String, forNormalized normalized: String) {
        var entries = load()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            entries.removeValue(forKey: normalized)
        } else {
            entries[normalized] = trimmed
        }
        save(entries)
    }

    static func clear(forNormalized normalized: String) {
        var entries = load()
        entries.removeValue(forKey: normalized)
        save(entries)
    }

    private static func save(_ entries: [String: String]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        try? FileManager.default.createDirectory(at: GameNestPaths.metadataDirectory, withIntermediateDirectories: true)
        try? data.write(to: GameNestPaths.namesFile, options: [.atomic])
    }
}

/// Watches the games folder and fires a callback (coalesced) when its contents change.
final class FolderWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.gamenest.folderwatcher")
    private var debounceWorkItem: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit {
        source?.cancel()
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    private func start() {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleCallback()
        }

        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else {
                return
            }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }

        self.source = source
        source.resume()
    }

    private func scheduleCallback() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}

enum GameNaming {
    static func cleanName(for url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [" alias", ".app", ".webloc"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }

    static func normalized(_ name: String) -> String {
        name
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }
            .joined()
    }
}

/// How a detected game should be launched once it lives in the Games folder.
enum LaunchTarget {
    /// A real `.app` bundle that should be exposed as a Finder alias (GOG, itch.io, emulators, standalone apps).
    case application(URL)
    /// A URL scheme that should be exposed as a `.webloc` launcher (Steam `steam://`, etc.).
    case urlScheme(URL)
}

struct DetectedGame {
    let name: String
    let launch: LaunchTarget
}

/// Creates the on-disk game library structure and migrates the old Library cache once.
enum GameLibraryBootstrap {
    static func run() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: GameNestPaths.gamesDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: GameNestPaths.manualCoversDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: GameNestPaths.autoCoversDirectory, withIntermediateDirectories: true)
        GameLibraryEntry.hideSupportFolders()
        migrateLegacyCovers()
    }

    private static func migrateLegacyCovers() {
        let fileManager = FileManager.default
        let legacy = GameNestPaths.legacyCacheDirectory

        guard fileManager.fileExists(atPath: legacy.path),
              let items = try? fileManager.contentsOfDirectory(
                  at: legacy,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for item in items {
            let destination = GameNestPaths.autoCoversDirectory.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                continue
            }
            try? fileManager.copyItem(at: item, to: destination)
        }
    }
}

/// Detects installed games from multiple sources and writes launchers into `/Applications/Games`.
enum GameInstaller {
    static func run() {
        GameLibraryBootstrap.run()
        GameLibraryEntry.pruneStaleEntries(in: GameNestPaths.gamesDirectory)

        var claimedNames = existingNormalizedNames()
        let detected = SteamInstalledGames.detect()
            + EpicInstalledGames.detect()
            + HeroicInstalledGames.detect()
            + InstalledApplications.detectGames()

        for game in detected {
            let normalized = GameNaming.normalized(game.name)
            guard !normalized.isEmpty, !claimedNames.contains(normalized) else {
                continue
            }

            if install(game) {
                claimedNames.insert(normalized)
            }
        }
    }

    private static func existingNormalizedNames() -> Set<String> {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: GameNestPaths.gamesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return Set(
            urls
                .filter { !GameLibraryEntry.isInternal($0) }
                .filter { GameLibraryEntry.isUsable($0) }
                .map { GameNaming.normalized(GameNaming.cleanName(for: $0)) }
        )
    }

    private static func install(_ game: DetectedGame) -> Bool {
        switch game.launch {
        case .application(let appURL):
            return createAlias(to: appURL, named: game.name)
        case .urlScheme(let url):
            return createWebloc(for: url, named: game.name)
        }
    }

    private static func createAlias(to appURL: URL, named name: String) -> Bool {
        let destination = GameNestPaths.gamesDirectory
            .appendingPathComponent(sanitizedFileName(name))
            .appendingPathExtension("app")

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return false
        }

        do {
            let bookmark = try appURL.bookmarkData(
                options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try URL.writeBookmarkData(bookmark, to: destination)
            return true
        } catch {
            return false
        }
    }

    private static func createWebloc(for url: URL, named name: String) -> Bool {
        let destination = GameNestPaths.gamesDirectory
            .appendingPathComponent(sanitizedFileName(name))
            .appendingPathExtension("webloc")

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return false
        }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["URL": url.absoluteString],
                format: .xml,
                options: 0
            )
            try data.write(to: destination, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let invalid: Set<Character> = ["/", ":"]
        let cleaned = String(name.map { invalid.contains($0) ? " " : $0 })
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func weblocTarget(at fileURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let urlString = plist["URL"] as? String else {
            return nil
        }
        return URL(string: urlString)
    }
}

/// A ROM discovered in an emulator's configured game directories.
struct EmulatorROM {
    let name: String
    let url: URL
    let emulator: URL
}

/// Detects ROMs from installed emulators by reading their own configured game
/// directories, so GameNest never has to guess where the user keeps ROMs.
/// Currently supports Ryujinx (Nintendo Switch).
enum EmulatorROMs {
    static func detect() -> [EmulatorROM] {
        detectRyujinx()
    }

    /// Strips common ROM-dump noise like `[TITLEID]`, `(USA)`, version tags.
    static func cleanName(_ raw: String) -> String {
        var value = raw
        value = value.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\([^\\)]*\\)", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "_", with: " ")
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func detectRyujinx() -> [EmulatorROM] {
        guard let ryujinx = ryujinxAppURL() else { return [] }

        let romExtensions: Set<String> = ["nsp", "xci", "nca", "nro", "nsz", "xcz"]
        let fileManager = FileManager.default
        var roms: [EmulatorROM] = []
        var seenPaths = Set<String>()

        for directory in ryujinxGameDirectories() {
            // Scan the directory itself plus one level of subfolders (common "folder per game" layouts).
            var scanRoots = [directory]
            if let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                scanRoots += entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            }

            for root in scanRoots {
                guard let files = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for file in files where romExtensions.contains(file.pathExtension.lowercased()) {
                    guard seenPaths.insert(file.path).inserted else { continue }
                    let name = cleanName(file.deletingPathExtension().lastPathComponent)
                    roms.append(EmulatorROM(name: name.isEmpty ? file.lastPathComponent : name, url: file, emulator: ryujinx))
                }
            }
        }

        return roms
    }

    private static func ryujinxAppURL() -> URL? {
        let candidate = URL(fileURLWithPath: "/Applications/Ryujinx.app")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func ryujinxGameDirectories() -> [URL] {
        let configURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ryujinx/Config.json")

        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let gameDirs = (json["game_dirs"] as? [String]) ?? []
        let autoloadDirs = (json["autoload_dirs"] as? [String]) ?? []
        let unique = Array(Set(gameDirs + autoloadDirs))
        return unique.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

/// Reads installed Epic Games Launcher entries and exposes them as `com.epicgames.launcher://` launchers.
enum EpicInstalledGames {
    static func detect() -> [DetectedGame] {
        let launcherInstalledURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Epic/UnrealEngineLauncher/LauncherInstalled.dat")

        guard let data = try? Data(contentsOf: launcherInstalledURL) else {
            return []
        }

        return detect(fromLauncherInstalledData: data)
    }

    static func detect(fromLauncherInstalledData data: Data) -> [DetectedGame] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let installations = root["InstallationList"] as? [[String: Any]] else {
            return []
        }

        var games: [DetectedGame] = []
        var seenAppNames: Set<String> = []

        for installation in installations {
            guard let appName = stringValue(in: installation, keys: ["AppName", "AppId"]),
                  seenAppNames.insert(appName).inserted,
                  hasExistingInstallLocation(in: installation),
                  let launchURL = epicLaunchURL(appName: appName) else {
                continue
            }

            let name = stringValue(in: installation, keys: ["DisplayName", "AppName"]) ?? appName
            games.append(DetectedGame(name: name, launch: .urlScheme(launchURL)))
        }

        return games
    }

    private static func hasExistingInstallLocation(in installation: [String: Any]) -> Bool {
        guard let path = stringValue(in: installation, keys: ["InstallLocation", "InstallDir", "InstallPath"]),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return FileManager.default.fileExists(atPath: path)
    }

    private static func epicLaunchURL(appName: String) -> URL? {
        guard let encodedAppName = appName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        return URL(string: "com.epicgames.launcher://apps/\(encodedAppName)?action=launch&silent=true")
    }

    private static func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

/// Reads Heroic Games Launcher metadata and exposes installed entries through `heroic://` launchers.
enum HeroicInstalledGames {
    static func detect() -> [DetectedGame] {
        let heroicDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heroic", isDirectory: true)

        let manifests: [(URL, String)] = [
            (
                heroicDirectory.appendingPathComponent("legendaryConfig/legendary/installed.json"),
                "legendary"
            ),
            (
                heroicDirectory.appendingPathComponent("sideload_apps/library.json"),
                "sideload"
            ),
            (
                heroicDirectory.appendingPathComponent("store_cache/gog_library.json"),
                "gog"
            )
        ]

        var games: [DetectedGame] = []
        var seenNames: Set<String> = []

        for (url, defaultRunner) in manifests {
            guard let data = try? Data(contentsOf: url) else {
                continue
            }

            for game in detect(fromInstalledData: data, defaultRunner: defaultRunner) {
                let normalized = GameNaming.normalized(game.name)
                guard !normalized.isEmpty, seenNames.insert(normalized).inserted else {
                    continue
                }
                games.append(game)
            }
        }

        return games
    }

    static func detect(fromInstalledData data: Data, defaultRunner: String = "legendary") -> [DetectedGame] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let entries: [(String?, [String: Any])] = {
            if let root = json as? [String: Any],
               let games = root["games"] as? [[String: Any]] {
                return games.map { (nil, $0) }
            }

            if let root = json as? [String: Any] {
                return root.compactMap { key, value in
                    guard !key.hasPrefix("__"),
                          let entry = value as? [String: Any] else {
                        return nil
                    }
                    return (key, entry)
                }
            }

            if let array = json as? [[String: Any]] {
                return array.map { (nil, $0) }
            }

            return []
        }()

        var games: [DetectedGame] = []
        var seenAppNames: Set<String> = []

        for (key, entry) in entries {
            guard isInstalled(entry),
                  installPathExists(in: entry),
                  let appName = stringValue(in: entry, keys: ["app_name", "appName", "appId"]) ?? key,
                  seenAppNames.insert(appName).inserted else {
                continue
            }

            let runner = stringValue(in: entry, keys: ["runner"]) ?? defaultRunner
            guard let launchURL = heroicLaunchURL(runner: runner, appName: appName) else {
                continue
            }

            let name = stringValue(in: entry, keys: ["title", "displayName", "name"]) ?? appName
            games.append(DetectedGame(name: name, launch: .urlScheme(launchURL)))
        }

        return games
    }

    private static func isInstalled(_ entry: [String: Any]) -> Bool {
        if let installed = entry["is_installed"] as? Bool {
            return installed
        }

        if let installed = entry["isInstalled"] as? Bool {
            return installed
        }

        return true
    }

    private static func installPathExists(in entry: [String: Any]) -> Bool {
        let directPath = stringValue(
            in: entry,
            keys: ["install_path", "installPath", "installLocation", "folder_name"]
        )

        let nestedInstall = entry["install"] as? [String: Any]
        let nestedPath = nestedInstall.flatMap {
            stringValue(in: $0, keys: ["install_path", "installPath", "executable"])
        }

        guard let path = directPath ?? nestedPath,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return FileManager.default.fileExists(atPath: path)
    }

    private static func heroicLaunchURL(runner: String, appName: String) -> URL? {
        guard let encodedRunner = runner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedAppName = appName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        return URL(string: "heroic://launch/\(encodedRunner)/\(encodedAppName)")
    }

    private static func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

/// Reads installed Steam games from local appmanifest files and exposes them as `steam://` launchers.
enum SteamInstalledGames {
    private static let skippedNameFragments = [
        "steam linux runtime",
        "steamworks common redistributables",
        "proton",
        "steamvr"
    ]

    static func detect() -> [DetectedGame] {
        var games: [DetectedGame] = []
        var seenAppIDs: Set<String> = []

        for libraryFolder in libraryFolders() {
            let steamApps = libraryFolder.appendingPathComponent("steamapps", isDirectory: true)
            guard let manifestURLs = try? FileManager.default.contentsOfDirectory(
                at: steamApps,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for manifestURL in manifestURLs where manifestURL.lastPathComponent.hasPrefix("appmanifest_") {
                guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8),
                      let appID = vdfValue(named: "appid", in: contents),
                      let name = vdfValue(named: "name", in: contents),
                      !seenAppIDs.contains(appID),
                      !isSkipped(name),
                      let url = URL(string: "steam://rungameid/\(appID)") else {
                    continue
                }

                seenAppIDs.insert(appID)
                games.append(DetectedGame(name: name, launch: .urlScheme(url)))
            }
        }

        return games
    }

    private static func isSkipped(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return skippedNameFragments.contains { lowercased.contains($0) }
    }

    private static var steamDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Steam", isDirectory: true)
    }

    private static func libraryFolders() -> [URL] {
        let candidates = [
            steamDirectory.appendingPathComponent("config/libraryfolders.vdf"),
            steamDirectory.appendingPathComponent("steamapps/libraryfolders.vdf")
        ]

        for candidate in candidates {
            guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else {
                continue
            }

            let paths = vdfValues(named: "path", in: contents)
            if !paths.isEmpty {
                return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            }
        }

        return [steamDirectory]
    }

    private static func vdfValue(named key: String, in contents: String) -> String? {
        vdfValues(named: key, in: contents).first
    }

    private static func vdfValues(named key: String, in contents: String) -> [String] {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "\"\(escapedKey)\"\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.matches(in: contents, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: contents) else {
                return nil
            }
            return String(contents[valueRange])
        }
    }
}

/// Detects installed `.app` games (GOG, itch.io, emulators, standalone) by their app category.
enum InstalledApplications {
    static func detectGames() -> [DetectedGame] {
        let fileManager = FileManager.default
        var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true)]

        if let userApps = try? fileManager.url(
            for: .applicationDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            roots.append(userApps)
        }

        roots.append(
            fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("itch/apps", isDirectory: true)
        )

        var result: [DetectedGame] = []
        var seenPaths: Set<String> = []

        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries {
                for appURL in appBundles(under: entry, fileManager: fileManager) where isGame(appURL) {
                    guard seenPaths.insert(appURL.path).inserted else {
                        continue
                    }
                    let name = appURL.deletingPathExtension().lastPathComponent
                    result.append(DetectedGame(name: name, launch: .application(appURL)))
                }
            }
        }

        return result
    }

    private static func appBundles(under url: URL, fileManager: FileManager) -> [URL] {
        if url.pathExtension == "app" {
            return [url]
        }

        // itch.io and some launchers nest the bundle one folder deep.
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children.filter { $0.pathExtension == "app" }
    }

    private static func isGame(_ appURL: URL) -> Bool {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let category = plist["LSApplicationCategoryType"] as? String else {
            return false
        }

        return category.lowercased().contains("games")
    }
}

enum GameLibraryEntry {
    static func isInternal(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == ".DS_Store" || name == "Covers" || name == ".metadata"
    }

    static func hideSupportFolders() {
        hide(GameNestPaths.manualCoversDirectory)
        hide(GameNestPaths.metadataDirectory)
    }

    static func pruneStaleEntries(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isAliasFileKey],
            options: []
        ) else {
            return
        }

        for url in urls where !isInternal(url) && !isUsable(url) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func isUsable(_ url: URL) -> Bool {
        if url.pathExtension == "webloc" {
            return GameInstaller.weblocTarget(at: url) != nil
        }

        let values = try? url.resourceValues(forKeys: [.isAliasFileKey])
        guard values?.isAliasFile == true else {
            return FileManager.default.fileExists(atPath: url.path)
        }

        guard let resolvedURL = try? URL(
            resolvingAliasFileAt: url,
            options: [.withoutUI]
        ) else {
            return false
        }

        if let steamInstallDirectory = steamInstallDirectory(containing: resolvedURL) {
            return isInstalledSteamDirectory(steamInstallDirectory)
        }

        return FileManager.default.fileExists(atPath: resolvedURL.path)
    }

    private static func hide(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isHidden = true
        try? mutableURL.setResourceValues(values)
    }

    private static func steamInstallDirectory(containing url: URL) -> URL? {
        let components = url.pathComponents
        guard let steamAppsIndex = components.lastIndex(of: "steamapps"),
              steamAppsIndex + 2 < components.count,
              components[steamAppsIndex + 1] == "common" else {
            return nil
        }

        let installComponents = Array(components.prefix(steamAppsIndex + 3))
        return NSURL.fileURL(withPathComponents: installComponents)
    }

    private static func isInstalledSteamDirectory(_ installDirectory: URL) -> Bool {
        let steamAppsDirectory = installDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let installDirectoryName = installDirectory.lastPathComponent

        guard let manifestURLs = try? FileManager.default.contentsOfDirectory(
            at: steamAppsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for manifestURL in manifestURLs where manifestURL.lastPathComponent.hasPrefix("appmanifest_") {
            guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8),
                  let installDir = vdfValue(named: "installdir", in: contents),
                  installDir == installDirectoryName else {
                continue
            }
            return true
        }

        return false
    }

    private static func vdfValue(named key: String, in contents: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "\"\(escapedKey)\"\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = regex.firstMatch(in: contents, range: range),
              let valueRange = Range(match.range(at: 1), in: contents) else {
            return nil
        }

        return String(contents[valueRange])
    }
}

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var games: [GameItem] = []

    private let gamesDirectory = GameNestPaths.gamesDirectory
    private let coverService = OnlineCoverService()
    private let metadataRegistry = GameMetadataRegistry()
    private var coversDirectory: URL { GameNestPaths.manualCoversDirectory }
    private var cacheDirectory: URL { GameNestPaths.autoCoversDirectory }
    private var folderWatcher: FolderWatcher?

    init() {
        GameLibraryBootstrap.run()
        reload()
        rescan()
        startWatchingFolder()
    }

    private func startWatchingFolder() {
        folderWatcher = FolderWatcher(url: gamesDirectory) { [weak self] in
            Task { @MainActor in
                self?.reload()
            }
        }
    }

    /// Re-runs detection off the main thread, then refreshes the list.
    func rescan() {
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                GameInstaller.run()
            }.value
            self?.reload()
        }
    }

    func reload() {
        let fileManager = FileManager.default
        GameLibraryEntry.hideSupportFolders()
        GameLibraryEntry.pruneStaleEntries(in: gamesDirectory)

        guard let urls = try? fileManager.contentsOfDirectory(
            at: gamesDirectory,
            includingPropertiesForKeys: [.isHiddenKey, .localizedNameKey],
            options: [.skipsHiddenFiles]
        ) else {
            games = []
            return
        }

        let metadataByName = metadataRegistry.metadataByNormalizedGameName()
        let recents = RecentsStore.load()
        let nameOverrides = DisplayNameStore.load()

        let folderItems = urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .filter { $0.lastPathComponent != "Covers" }
            .filter { $0.lastPathComponent != ".metadata" }
            .filter { GameLibraryEntry.isUsable($0) }
            .map { url -> GameItem in
                let name = GameNaming.cleanName(for: url)
                let normalizedName = GameNaming.normalized(name)
                let metadata = metadataByName[normalizedName]
                let kind = GameClassifier.kind(forName: name)
                let override = nameOverrides[normalizedName]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasCustomName = (override?.isEmpty == false)
                let displayName = hasCustomName ? override! : name
                // Launchers/tools fall back to their real app icon instead of unreliable online
                // game art; only an explicit manual cover in Covers/ overrides it.
                let manualCover = Self.coverImage(named: name, in: coversDirectory)
                let resolvedCover = kind == .launcher
                    ? manualCover
                    : (manualCover ?? Self.coverImage(named: name, in: cacheDirectory))
                return GameItem(
                    name: name,
                    displayName: displayName,
                    hasCustomName: hasCustomName,
                    url: url,
                    launchURL: Self.launchURL(for: url),
                    appIcon: NSWorkspace.shared.icon(forFile: url.path),
                    coverImage: resolvedCover,
                    timePlayedMinutes: metadata?.timePlayedMinutes,
                    progress: metadata?.progress,
                    lastPlayedAt: recents[normalizedName],
                    kind: kind
                )
            }

        // Detected emulator ROMs are added in-memory (they are not files in the Games folder),
        // skipping any whose name already matches a folder entry.
        let existingNames = Set(folderItems.map { GameNaming.normalized($0.name) })
        let romItems = EmulatorROMs.detect().compactMap { rom -> GameItem? in
            let name = rom.name
            let normalizedName = GameNaming.normalized(name)
            guard !normalizedName.isEmpty, !existingNames.contains(normalizedName) else { return nil }
            let override = nameOverrides[normalizedName]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasCustomName = (override?.isEmpty == false)
            let displayName = hasCustomName ? override! : name
            let manualCover = Self.coverImage(named: name, in: coversDirectory)
            let resolvedCover = manualCover ?? Self.coverImage(named: name, in: cacheDirectory)
            return GameItem(
                name: name,
                displayName: displayName,
                hasCustomName: hasCustomName,
                url: rom.url,
                launchURL: rom.url,
                appIcon: NSWorkspace.shared.icon(forFile: rom.emulator.path),
                coverImage: resolvedCover,
                lastPlayedAt: recents[normalizedName],
                kind: .game,
                emulatorURL: rom.emulator,
                launchArguments: [rom.url.path],
                canRemove: false
            )
        }

        games = (folderItems + romItems)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        Task {
            await fetchMissingCovers()
        }
    }

    private static func launchURL(for url: URL) -> URL {
        if url.pathExtension == "webloc", let target = GameInstaller.weblocTarget(at: url) {
            return target
        }
        return url
    }

    private static func coverImage(named name: String, in directory: URL) -> NSImage? {
        let supportedExtensions = ["png", "jpg", "jpeg", "heic", "tiff"]
        let fileManager = FileManager.default

        for fileExtension in supportedExtensions {
            let coverURL = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
            if fileManager.fileExists(atPath: coverURL.path), let image = NSImage(contentsOf: coverURL) {
                return image
            }
        }

        return nil
    }

    private func fetchMissingCovers() async {
        // Only attempt games with no cover and no recent "miss" marker, so we don't hit the network on every open.
        let missingGames = games.filter { $0.kind == .game && $0.coverImage == nil && !Self.hasRecentCoverMiss(for: $0.name) }
        guard !missingGames.isEmpty else {
            return
        }

        // Show a loading skeleton on every tile we're about to look up.
        let missingIDs = Set(missingGames.map(\.id))
        for index in games.indices where missingIDs.contains(games[index].id) {
            games[index].isFetchingCover = true
        }

        for game in missingGames {
            guard let coverData = await coverService.fetchCoverData(named: game.name),
                  Self.isSquareCoverData(coverData),
                  let coverImage = NSImage(data: coverData) else {
                Self.markCoverMiss(for: game.name)
                if let index = games.firstIndex(where: { $0.id == game.id }) {
                    games[index].isFetchingCover = false
                }
                continue
            }

            Self.writeCoverData(coverData, named: game.name, in: cacheDirectory)
            Self.clearCoverMiss(for: game.name)

            if let index = games.firstIndex(where: { $0.id == game.id }) {
                games[index].coverImage = coverImage
                games[index].isFetchingCover = false
            }
        }
    }

    /// Records the launch time so the "Recent" sort and timestamps stay current.
    func recordLaunch(_ game: GameItem) {
        let now = Date()
        RecentsStore.record(name: game.name, at: now)
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].lastPlayedAt = now
        }
    }

    /// Forces a fresh online cover lookup by clearing the cached cover and miss marker.
    func refreshCover(for game: GameItem) {
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(Self.cacheFileName(for: game.name)))
        Self.clearCoverMiss(for: game.name)

        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].coverImage = Self.coverImage(named: game.name, in: coversDirectory)
        }

        Task {
            await fetchMissingCovers()
        }
    }

    /// Copies a user-picked image into the manual covers folder and refreshes the tile.
    func installManualCover(from sourceURL: URL, for game: GameItem) {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let destination = coversDirectory
            .appendingPathComponent(game.name)
            .appendingPathExtension(fileExtension)

        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        // Replace any existing manual cover for this game first.
        for ext in ["png", "jpg", "jpeg", "heic", "tiff"] {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(game.name).appendingPathExtension(ext))
        }
        try? FileManager.default.copyItem(at: sourceURL, to: destination)
        Self.clearCoverMiss(for: game.name)

        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].coverImage = NSImage(contentsOf: destination)
        }
    }

    /// Moves a game's launcher entry to the Trash and refreshes the list.
    func remove(_ game: GameItem) {
        try? FileManager.default.trashItem(at: game.url, resultingItemURL: nil)
        games.removeAll { $0.id == game.id }
    }

    func revealInFinder(_ game: GameItem) {
        NSWorkspace.shared.activateFileViewerSelecting([game.url])
    }

    /// Sets (or clears, when blank) a custom display name without touching the underlying file.
    func setDisplayName(_ name: String, for game: GameItem) {
        DisplayNameStore.set(name, forNormalized: GameNaming.normalized(game.name))
        reload()
    }

    func clearDisplayName(for game: GameItem) {
        DisplayNameStore.clear(forNormalized: GameNaming.normalized(game.name))
        reload()
    }

    // MARK: - No-cover markers

    private static let coverMissTTL: TimeInterval = 7 * 24 * 60 * 60

    private static func coverMissURL(for name: String) -> URL {
        GameNestPaths.noCoverDirectory.appendingPathComponent(cacheFileName(for: name) + ".miss")
    }

    private static func hasRecentCoverMiss(for name: String) -> Bool {
        let url = coverMissURL(for: name)
        guard let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modified) < coverMissTTL
    }

    private static func markCoverMiss(for name: String) {
        try? FileManager.default.createDirectory(at: GameNestPaths.noCoverDirectory, withIntermediateDirectories: true)
        let url = coverMissURL(for: name)
        try? Data().write(to: url, options: [.atomic])
    }

    private static func clearCoverMiss(for name: String) {
        try? FileManager.default.removeItem(at: coverMissURL(for: name))
    }

    private static func isSquareCoverData(_ data: Data) -> Bool {
        guard let bitmap = NSBitmapImageRep(data: data) else {
            return false
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else {
            return false
        }

        let ratio = Double(width) / Double(height)
        return ratio >= 0.96 && ratio <= 1.04
    }

    private static func writeCoverData(_ data: Data, named name: String, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheURL = directory.appendingPathComponent(cacheFileName(for: name))
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private static func cacheFileName(for name: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let sanitizedName = name.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        return String(sanitizedName).trimmingCharacters(in: .whitespacesAndNewlines) + ".jpg"
    }
}

final class SteamMetadataProvider: GameMetadataProvider {
    let name = "Steam"

    private let steamDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Steam", isDirectory: true)

    func metadataByNormalizedGameName() -> [String: GameMetadata] {
        let playtimeByAppID = steamPlaytimeByAppID()
        guard !playtimeByAppID.isEmpty else {
            return [:]
        }

        let namesByAppID = steamNamesByAppID()
        var result: [String: GameMetadata] = [:]

        for (appID, minutes) in playtimeByAppID {
            guard let name = namesByAppID[appID] else {
                continue
            }

            result[Self.normalizedName(name)] = GameMetadata(timePlayedMinutes: minutes, progress: nil)
        }

        return result
    }

    private func steamPlaytimeByAppID() -> [String: Int] {
        let userdataDirectory = steamDirectory.appendingPathComponent("userdata", isDirectory: true)
        guard let userDirectories = try? FileManager.default.contentsOfDirectory(
            at: userdataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var result: [String: Int] = [:]

        for userDirectory in userDirectories {
            let localConfigURL = userDirectory
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("localconfig.vdf")

            guard let contents = try? String(contentsOf: localConfigURL, encoding: .utf8) else {
                continue
            }

            for (appID, minutes) in Self.parsePlaytimeEntries(from: contents) {
                result[appID] = max(result[appID] ?? 0, minutes)
            }
        }

        return result
    }

    private func steamNamesByAppID() -> [String: String] {
        let libraryFolders = steamLibraryFolders()
        var result: [String: String] = [:]

        for libraryFolder in libraryFolders {
            let steamAppsDirectory = libraryFolder.appendingPathComponent("steamapps", isDirectory: true)
            guard let manifestURLs = try? FileManager.default.contentsOfDirectory(
                at: steamAppsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for manifestURL in manifestURLs where manifestURL.lastPathComponent.hasPrefix("appmanifest_") {
                guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8),
                      let appID = Self.firstVDFValue(named: "appid", in: contents),
                      let name = Self.firstVDFValue(named: "name", in: contents) else {
                    continue
                }

                result[appID] = name
            }
        }

        return result
    }

    private func steamLibraryFolders() -> [URL] {
        let candidates = [
            steamDirectory.appendingPathComponent("config/libraryfolders.vdf"),
            steamDirectory.appendingPathComponent("steamapps/libraryfolders.vdf")
        ]

        for candidate in candidates {
            guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else {
                continue
            }

            let paths = Self.vdfValues(named: "path", in: contents)
            if !paths.isEmpty {
                return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            }
        }

        return [steamDirectory]
    }

    private static func parsePlaytimeEntries(from contents: String) -> [String: Int] {
        let pattern = #""(\d+)"\s*\{[^{}]*"Playtime"\s*"(\d+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }

        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        var result: [String: Int] = [:]

        for match in regex.matches(in: contents, range: range) {
            guard let appIDRange = Range(match.range(at: 1), in: contents),
                  let playtimeRange = Range(match.range(at: 2), in: contents),
                  let minutes = Int(contents[playtimeRange]) else {
                continue
            }

            result[String(contents[appIDRange])] = minutes
        }

        return result
    }

    private static func firstVDFValue(named key: String, in contents: String) -> String? {
        vdfValues(named: key, in: contents).first
    }

    private static func vdfValues(named key: String, in contents: String) -> [String] {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "\"\(escapedKey)\"\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.matches(in: contents, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: contents) else {
                return nil
            }
            return String(contents[valueRange])
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }
            .joined()
    }
}

actor OnlineCoverService {
    private let steamGridDBAPIBaseURL = URL(string: "https://www.steamgriddb.com/api/v2")!
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchCoverData(named name: String) async -> Data? {
        if let steamGridDBCoverData = await steamGridDBCoverData(for: name) {
            return steamGridDBCoverData
        }

        guard let imageURL = await steamCoverURL(for: name),
              let imageData = await downloadImageData(from: imageURL) else {
            return nil
        }

        return imageData
    }

    private func steamGridDBCoverData(for name: String) async -> Data? {
        guard let apiKey = steamGridDBAPIKey(),
              let gameID = await steamGridDBGameID(for: name, apiKey: apiKey) else {
            return nil
        }

        // 1) Prefer box-art grids (square or portrait). Portrait art is center-cropped to a square tile.
        if let gridURL = await steamGridDBImageURL(for: gameID, apiKey: apiKey),
           let raw = await downloadImageData(from: gridURL),
           let square = Self.squareCroppedPNGData(from: raw) {
            return square
        }

        // 2) Fallback for launchers/emulators/apps that have no box-art: use the (already square) icon.
        if let iconURL = await steamGridDBIconURL(for: gameID, apiKey: apiKey),
           let raw = await downloadImageData(from: iconURL),
           let square = Self.squareCroppedPNGData(from: raw) {
            return square
        }

        return nil
    }

    private func steamGridDBGameID(for name: String, apiKey: String) async -> Int? {
        let url = steamGridDBAPIBaseURL
            .appendingPathComponent("search")
            .appendingPathComponent("autocomplete")
            .appendingPathComponent(name)

        guard let data = await data(from: url, apiKey: apiKey),
              let response = try? decoder.decode(SteamGridDBSearchResponse.self, from: data) else {
            return nil
        }

        // Prefer an exact normalized match; otherwise fall back to the best-ranked search result
        // so titles like "Prince of Persia Lost Crown" still resolve "...: The Lost Crown".
        let normalizedName = Self.normalizedName(name)
        if let exact = response.data.first(where: { Self.normalizedName($0.name) == normalizedName }) {
            return exact.id
        }
        return response.data.first?.id
    }

    private func steamGridDBImageURL(for gameID: Int, apiKey: String) async -> URL? {
        let url = steamGridDBAPIBaseURL
            .appendingPathComponent("grids")
            .appendingPathComponent("game")
            .appendingPathComponent(String(gameID))

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // Include portrait box-art (the most common SteamGridDB format) plus square grids.
        components.queryItems = [
            URLQueryItem(name: "dimensions", value: "600x900,342x482,660x930,512x512,1024x1024"),
            URLQueryItem(name: "mimes", value: "image/png,image/jpeg"),
            URLQueryItem(name: "types", value: "static"),
            URLQueryItem(name: "nsfw", value: "false")
        ]

        guard let requestURL = components.url,
              let data = await data(from: requestURL, apiKey: apiKey),
              let response = try? decoder.decode(SteamGridDBGridResponse.self, from: data) else {
            return nil
        }

        return response.data
            .sorted { $0.score > $1.score }
            .compactMap { URL(string: $0.url) }
            .first
    }

    private func steamGridDBIconURL(for gameID: Int, apiKey: String) async -> URL? {
        let url = steamGridDBAPIBaseURL
            .appendingPathComponent("icons")
            .appendingPathComponent("game")
            .appendingPathComponent(String(gameID))

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "mimes", value: "image/png,image/jpeg"),
            URLQueryItem(name: "types", value: "static"),
            URLQueryItem(name: "nsfw", value: "false")
        ]

        guard let requestURL = components.url,
              let data = await data(from: requestURL, apiKey: apiKey),
              let response = try? decoder.decode(SteamGridDBGridResponse.self, from: data) else {
            return nil
        }

        return response.data
            .sorted { $0.score > $1.score }
            .compactMap { URL(string: $0.url) }
            .first
    }

    /// Center-crops image data to a square and re-encodes it as PNG so square-tile validation passes.
    private static func squareCroppedPNGData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else {
            return nil
        }

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else {
            return nil
        }

        // Already square (within tolerance): keep as-is, just normalize to PNG.
        let ratio = Double(width) / Double(height)
        if ratio >= 0.96 && ratio <= 1.04 {
            return rep.representation(using: .png, properties: [:]) ?? data
        }

        let side = min(width, height)
        let originX = (width - side) / 2
        let originY = (height - side) / 2
        guard let cgImage = rep.cgImage?.cropping(to: CGRect(x: originX, y: originY, width: side, height: side)) else {
            return nil
        }

        let cropped = NSBitmapImageRep(cgImage: cgImage)
        return cropped.representation(using: .png, properties: [:])
    }

    private func steamGridDBAPIKey() -> String? {
        if let environmentKey = ProcessInfo.processInfo.environment["STEAMGRIDDB_API_KEY"],
           !environmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let keyURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameNest/steamgriddb.key")

        guard let key = try? String(contentsOf: keyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }

        return key
    }

    private func steamCoverURL(for name: String) async -> URL? {
        guard let appID = await steamAppID(for: name) else {
            return nil
        }

        if let detailsImageURL = await steamAppDetailsImageURL(for: appID) {
            return detailsImageURL
        }

        return await steamSearchImageURL(for: name)
    }

    private func steamAppID(for name: String) async -> Int? {
        guard var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "l", value: "en"),
            URLQueryItem(name: "cc", value: Locale.current.region?.identifier ?? "US")
        ]

        guard let url = components.url,
              let data = await data(from: url),
              let response = try? decoder.decode(SteamSearchResponse.self, from: data) else {
            return nil
        }

        let normalizedName = Self.normalizedName(name)
        return response.items.first { item in
            item.type == "app" && Self.normalizedName(item.name) == normalizedName
        }?.id
    }

    private func steamSearchImageURL(for name: String) async -> URL? {
        guard var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "l", value: "en"),
            URLQueryItem(name: "cc", value: Locale.current.region?.identifier ?? "US")
        ]

        guard let url = components.url,
              let data = await data(from: url),
              let response = try? decoder.decode(SteamSearchResponse.self, from: data) else {
            return nil
        }

        let normalizedName = Self.normalizedName(name)
        let matchedItem = response.items.first { item in
            item.type == "app" && Self.normalizedName(item.name) == normalizedName
        }

        return matchedItem?.tinyImage.flatMap(URL.init(string:))
    }

    private func steamAppDetailsImageURL(for appID: Int) async -> URL? {
        guard var components = URLComponents(string: "https://store.steampowered.com/api/appdetails/") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "filters", value: "basic")
        ]

        guard let url = components.url,
              let data = await data(from: url),
              let response = try? decoder.decode([String: SteamAppDetailsResponse].self, from: data),
              let details = response[String(appID)]?.data else {
            return nil
        }

        let imagePath = details.capsuleImageV5 ?? details.capsuleImage ?? details.headerImage
        return imagePath.flatMap(URL.init(string:))
    }

    private func downloadImageData(from url: URL) async -> Data? {
        await data(from: url)
    }

    private func data(from url: URL) async -> Data? {
        await data(from: url, apiKey: nil)
    }

    private func data(from url: URL, apiKey: String?) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("GameNest/0.1", forHTTPHeaderField: "User-Agent")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }
            .joined()
    }
}

private struct SteamGridDBSearchResponse: Decodable {
    let data: [SteamGridDBGame]
}

private struct SteamGridDBGame: Decodable {
    let id: Int
    let name: String
}

private struct SteamGridDBGridResponse: Decodable {
    let data: [SteamGridDBGrid]
}

private struct SteamGridDBGrid: Decodable {
    let url: String
    let score: Int
}

struct CoverImage: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 104, height: 104)
            .clipped()
    }
}

private struct SteamSearchResponse: Decodable {
    let items: [SteamSearchItem]
}

private struct SteamSearchItem: Decodable {
    let id: Int
    let name: String
    let type: String?
    let tinyImage: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case tinyImage = "tiny_image"
    }
}

private struct SteamAppDetailsResponse: Decodable {
    let data: SteamAppDetails?
}

private struct SteamAppDetails: Decodable {
    let headerImage: String?
    let capsuleImage: String?
    let capsuleImageV5: String?

    enum CodingKeys: String, CodingKey {
        case headerImage = "header_image"
        case capsuleImage = "capsule_image"
        case capsuleImageV5 = "capsule_imagev5"
    }
}

private struct ArtworkModeKey: EnvironmentKey {
    static let defaultValue = ArtworkMode.covers
}

extension EnvironmentValues {
    var artworkMode: ArtworkMode {
        get { self[ArtworkModeKey.self] }
        set { self[ArtworkModeKey.self] = newValue }
    }
}

/// Drives keyboard selection (arrow keys + Enter) over the grid while the search
/// field keeps text-entry focus. Intercepts events with a local monitor and only
/// acts while the launcher panel is the key window.
@MainActor
final class LauncherKeyboard: ObservableObject {
    @Published var selectedIndex = 0
    /// Flat list in display order (games first, then launchers).
    var items: [GameItem] = []
    var columns = 3
    var onLaunch: ((GameItem) -> Void)?

    private var monitor: Any?

    var selectedID: String? {
        items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    func reset() {
        selectedIndex = 0
    }

    func updateItems(_ newItems: [GameItem]) {
        items = newItems
        if selectedIndex >= newItems.count {
            selectedIndex = max(0, newItems.count - 1)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Only navigate when the launcher panel is frontmost (not Settings or other windows).
        guard NSApp.keyWindow is KeyablePanel, !items.isEmpty else {
            return false
        }

        switch event.keyCode {
        case 123: return move(-1)             // left
        case 124: return move(1)              // right
        case 126: return move(-columns)       // up
        case 125: return move(columns)        // down
        case 36, 76:                          // return / enter
            if items.indices.contains(selectedIndex) {
                onLaunch?(items[selectedIndex])
            }
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func move(_ delta: Int) -> Bool {
        let next = selectedIndex + delta
        guard items.indices.contains(next) else { return true }
        selectedIndex = next
        return true
    }
}

struct LauncherView: View {
    @ObservedObject var store: GameStore
    let launch: (GameItem) -> Void

    @State private var searchText = ""
    @State private var isShowingSettings = false
    @FocusState private var isSearchFocused: Bool
    @StateObject private var keyboard = LauncherKeyboard()
    @AppStorage("artworkMode") private var artworkModeRawValue = ArtworkMode.covers.rawValue
    @AppStorage("sortOption") private var sortOptionRawValue = SortOption.name.rawValue

    private var sortOption: SortOption {
        get {
            SortOption(rawValue: sortOptionRawValue) ?? .name
        }
        nonmutating set {
            sortOptionRawValue = newValue.rawValue
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 128), spacing: 14)
    ]

    private var artworkMode: ArtworkMode {
        get {
            ArtworkMode(rawValue: artworkModeRawValue) ?? .covers
        }
        nonmutating set {
            artworkModeRawValue = newValue.rawValue
        }
    }

    private var displayedGames: [GameItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredGames: [GameItem]

        if query.isEmpty {
            filteredGames = store.games
        } else {
            filteredGames = store.games.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.name.localizedCaseInsensitiveContains(query)
            }
        }

        return filteredGames.sorted(by: sortGames)
    }

    /// Visible items in the exact order they render (games first, then launchers),
    /// used as the flat list for keyboard navigation.
    private var orderedItems: [GameItem] {
        let games = displayedGames.filter { $0.kind == .game }
        let launchers = displayedGames.filter { $0.kind == .launcher }
        return games + launchers
    }

    private func sortGames(_ lhs: GameItem, _ rhs: GameItem) -> Bool {
        switch sortOption {
        case .name:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        case .recent:
            return compareDescending(lhs.lastPlayedAt, rhs.lastPlayedAt, lhs: lhs, rhs: rhs)
        case .timePlayed:
            return compareDescending(lhs.timePlayedMinutes, rhs.timePlayedMinutes, lhs: lhs, rhs: rhs)
        case .progress:
            return compareDescending(lhs.progress, rhs.progress, lhs: lhs, rhs: rhs)
        }
    }

    private func compareDescending<T: Comparable>(
        _ lhsValue: T?,
        _ rhsValue: T?,
        lhs: GameItem,
        rhs: GameItem
    ) -> Bool {
        switch (lhsValue, rhsValue) {
        case let (lhsValue?, rhsValue?):
            if lhsValue == rhsValue {
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            return lhsValue > rhsValue
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                header

                if store.games.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        libraryBar

                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    let gamesOnly = displayedGames.filter { $0.kind == .game }
                                    let launchers = displayedGames.filter { $0.kind == .launcher }

                                    if !gamesOnly.isEmpty {
                                        grid(for: gamesOnly)
                                    }

                                    if !launchers.isEmpty {
                                        sectionHeader("Launchers & Tools")
                                        grid(for: launchers)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                            }
                            .onChange(of: keyboard.selectedIndex) {
                                if let id = keyboard.selectedID {
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        proxy.scrollTo(id, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 430, height: 560)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }

            CalloutPointer()
                .fill(.ultraThinMaterial)
                .frame(width: 34, height: 18)
                .overlay {
                    CalloutPointer()
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
                .offset(y: -1)
        }
        .frame(width: 430, height: 577)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .onAppear {
            keyboard.onLaunch = { game in launch(game) }
            keyboard.updateItems(orderedItems)
            keyboard.start()
            focusSearch()
        }
        .onDisappear {
            keyboard.stop()
        }
        .onChange(of: orderedItems.map(\.id)) {
            keyboard.updateItems(orderedItems)
        }
        .onChange(of: searchText) {
            keyboard.reset()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gameNestPanelDidOpen)) { _ in
            searchText = ""
            keyboard.reset()
            focusSearch()
        }
    }

    private func focusSearch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isSearchFocused = true
        }
    }

    private var libraryBar: some View {
        HStack {
            Text("Games".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            sortMenu
        }
        .padding(.horizontal, 16)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortOption.allCases.filter { $0 != sortOption }) { option in
                Button {
                    sortOption = option
                } label: {
                    Text(option.title)
                }
            }
        } label: {
            Label(sortOption.title, systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort games")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(for items: [GameItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(items) { game in
                GameButton(
                    game: game,
                    isSelected: keyboard.selectedID == game.id,
                    action: { launch(game) },
                    onReveal: { store.revealInFinder(game) },
                    onChooseCover: { chooseCover(for: game) },
                    onRefreshCover: { store.refreshCover(for: game) },
                    onRename: { renameItem(game) },
                    onResetName: { store.clearDisplayName(for: game) },
                    onRemove: { store.remove(game) }
                )
                .id(game.id)
                .environment(\.artworkMode, artworkMode)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("GameNest")
                    .font(.system(size: 20, weight: .semibold))

                Spacer()

                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search games", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit {
                        // Prefer a real game over a launcher when Return is pressed.
                        let candidate = displayedGames.first { $0.kind == .game } ?? displayedGames.first
                        if let candidate {
                            launch(candidate)
                        }
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.black.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding([.top, .horizontal], 16)
    }

    private func openGamesFolder() {
        let games = GameNestPaths.gamesDirectory
        try? FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        NSWorkspace.shared.open(games)
    }

    private func chooseCover(for game: GameItem) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a square cover for \(game.displayName)"

        if panel.runModal() == .OK, let url = panel.url {
            store.installManualCover(from: url, for: game)
        }
    }

    private func renameItem(_ game: GameItem) {
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Display name for this item (leave empty to reset)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = game.displayName
        field.placeholderString = game.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            store.setDisplayName(field.stringValue, for: game)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("No games found")
                .font(.headline)

            Text("/Applications/Games")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                openGamesFolder()
            } label: {
                Label("Open Games Folder", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Captures a single modifier+key combination for the optional global shortcut.
@MainActor
final class HotKeyRecorder: ObservableObject {
    @Published var isRecording = false
    /// Called with (virtual key code, Carbon modifier mask, display string).
    var onCapture: ((UInt32, UInt32, String) -> Void)?

    private var monitor: Any?

    func toggle() {
        isRecording ? cancel() : begin()
    }

    func begin() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if Int(event.keyCode) == kVK_Escape {
                self.cancel()
                return nil
            }

            let carbon = HotKeyUtil.carbonModifiers(from: event.modifierFlags)
            guard carbon != 0 else { return nil } // require at least one modifier

            let display = HotKeyUtil.symbols(from: event.modifierFlags) + HotKeyUtil.keyLabel(for: event)
            self.onCapture?(UInt32(event.keyCode), carbon, display)
            self.cancel()
            return nil
        }
    }

    func cancel() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

enum AppInfo {
    static let repo = "smithplus/GameNest"

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static var releasesURL: URL {
        URL(string: "https://github.com/\(repo)/releases/latest")!
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case downloading(version: String)
        case readyToInstall(version: String, url: URL)
        case failed(String)
    }

    @Published var state: State = .idle

    private let lastCheckKey = "lastUpdateCheck"

    private init() {}

    /// Silent background check, at most once per day. Shows an alert if a newer release exists.
    func checkSilentlyIfDue() {
        let defaults = UserDefaults.standard
        let now = Date()
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           now.timeIntervalSince(last) < 60 * 60 * 24 {
            return
        }
        defaults.set(now, forKey: lastCheckKey)

        Task { [weak self] in
            guard let self else { return }
            let result = await self.fetchLatest()
            if case let .available(version, url) = result {
                self.state = result
                self.presentAlert(version: version, url: url)
            }
        }
    }

    /// Manual check triggered from Settings. Always updates the published state.
    func checkNow() {
        state = .checking
        Task { [weak self] in
            guard let self else { return }
            self.state = await self.fetchLatest()
        }
    }

    private func fetchLatest() async -> State {
        guard let api = URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest") else {
            return .failed("Bad URL.")
        }
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GameNest", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed("GitHub returned an error.")
            }
            return Self.state(fromLatestReleaseData: data, currentVersion: AppInfo.currentVersion)
        } catch {
            return .failed("Could not reach GitHub.")
        }
    }

    nonisolated static func state(fromLatestReleaseData data: Data, currentVersion: String) -> State {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            return .failed("Unexpected response.")
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        var downloadURL = (json["html_url"] as? String).flatMap { URL(string: $0) } ?? AppInfo.releasesURL
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                   let urlString = asset["browser_download_url"] as? String,
                   let url = URL(string: urlString) {
                    downloadURL = url
                    break
                }
            }
        }

        if Self.isNewer(latest, than: currentVersion) {
            return .available(version: latest, url: downloadURL)
        } else {
            return .upToDate
        }
    }

    func downloadAndOpen(version: String, url: URL) {
        guard url.pathExtension.lowercased() == "dmg" else {
            NSWorkspace.shared.open(url)
            return
        }

        state = .downloading(version: version)

        Task { [weak self] in
            guard let self else { return }
            do {
                let fileURL = try await Self.downloadDMG(from: url, version: version)
                self.state = .readyToInstall(version: version, url: fileURL)
                NSWorkspace.shared.open(fileURL)
            } catch {
                self.state = .failed("Could not download update.")
            }
        }
    }

    private nonisolated static func downloadDMG(from url: URL, version: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("GameNest", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = downloads.appendingPathComponent("GameNest-\(version).dmg")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    /// Numeric, dot-separated version compare (e.g. "0.2.0" vs "0.10.1").
    nonisolated static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func presentAlert(version: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "GameNest \(version) is available. You're on \(AppInfo.currentVersion)."
        alert.addButton(withTitle: url.pathExtension.lowercased() == "dmg" ? "Download & Open" : "Open Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndOpen(version: version, url: url)
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("artworkMode") private var artworkModeRawValue = ArtworkMode.covers.rawValue
    @AppStorage(HotKeyDefaults.code) private var hotKeyCode = 0
    @AppStorage(HotKeyDefaults.modifiers) private var hotKeyModifiers = 0
    @AppStorage(HotKeyDefaults.display) private var hotKeyDisplay = ""
    @StateObject private var recorder = HotKeyRecorder()
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var steamGridDBAPIKey = ""
    @State private var saveStatus: SaveStatus?

    private var artworkMode: ArtworkMode {
        get { ArtworkMode(rawValue: artworkModeRawValue) ?? .covers }
        nonmutating set { artworkModeRawValue = newValue.rawValue }
    }

    private var isSteamGridDBConfigured: Bool {
        let envKey = ProcessInfo.processInfo.environment["STEAMGRIDDB_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envKey, !envKey.isEmpty { return true }
        let fileKey = (try? String(contentsOf: steamGridDBKeyURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fileKey?.isEmpty == false
    }

    private enum SaveStatus {
        case saved
        case failed

        var message: String {
            switch self {
            case .saved:
                return "API key saved. Refresh games to fetch covers."
            case .failed:
                return "Could not save API key."
            }
        }

        var color: Color {
            switch self {
            case .saved:
                return .green
            case .failed:
                return .red
            }
        }
    }

    private var supportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameNest", isDirectory: true)
    }

    private var steamGridDBKeyURL: URL {
        supportDirectory.appendingPathComponent("steamgriddb.key")
    }

    private var manualCoversDirectory: URL {
        URL(fileURLWithPath: "/Applications/Games/Covers", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Artwork")
                    .font(.system(size: 13, weight: .semibold))

                Picker("Artwork", selection: Binding(
                    get: { artworkMode },
                    set: { artworkMode = $0 }
                )) {
                    ForEach(ArtworkMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Global Shortcut")
                    .font(.system(size: 13, weight: .semibold))

                Text("Optional. Set a system-wide shortcut to open GameNest from anywhere.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text(recorder.isRecording ? "Press keys…" : (hotKeyDisplay.isEmpty ? "None" : hotKeyDisplay))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .frame(minWidth: 90, alignment: .leading)
                        .foregroundStyle(recorder.isRecording ? Color.accentColor : .primary)

                    Button(recorder.isRecording ? "Cancel (Esc)" : "Record Shortcut") {
                        recorder.toggle()
                    }

                    if !hotKeyDisplay.isEmpty && !recorder.isRecording {
                        Button("Clear") {
                            clearGlobalHotKey()
                        }
                    }

                    Spacer()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SteamGridDB API Key")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Label(
                        isSteamGridDBConfigured ? "Ready" : "Key Missing",
                        systemImage: isSteamGridDBConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSteamGridDBConfigured ? Color.green : Color.orange)
                }

                SecureField("Paste API key", text: $steamGridDBAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: steamGridDBAPIKey) {
                        saveStatus = nil
                    }

                HStack {
                    Button {
                        openSteamGridDBAPIPage()
                    } label: {
                        Label("Get API Key", systemImage: "safari")
                    }

                    Button {
                        saveSteamGridDBAPIKey()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .keyboardShortcut(.defaultAction)

                    Spacer()
                }

                if let saveStatus {
                    Label(saveStatus.message, systemImage: saveStatus == .saved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(saveStatus.color)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Manual Covers")
                    .font(.system(size: 13, weight: .semibold))

                Button {
                    openManualCoversFolder()
                } label: {
                    Label("Open Covers Folder", systemImage: "folder")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Updates")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Text("v\(AppInfo.currentVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        updateChecker.checkNow()
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }

                    updateStatusView

                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            loadSteamGridDBAPIKey()
            recorder.onCapture = { code, modifiers, display in
                hotKeyCode = Int(code)
                hotKeyModifiers = Int(modifiers)
                hotKeyDisplay = display
                GlobalHotKeyManager.shared.update(keyCode: code, carbonModifiers: modifiers)
            }
        }
        .onDisappear {
            recorder.cancel()
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateChecker.state {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        case let .available(version, url):
            Button {
                updateChecker.downloadAndOpen(version: version, url: url)
            } label: {
                Label(url.pathExtension.lowercased() == "dmg" ? "Download & Open v\(version)" : "Open v\(version)", systemImage: "arrow.down.circle.fill")
            }
            .foregroundStyle(Color.accentColor)
        case let .downloading(version):
            Label("Downloading v\(version)…", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
        case let .readyToInstall(version, _):
            Label("Opened installer v\(version)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        }
    }

    private func clearGlobalHotKey() {
        hotKeyCode = 0
        hotKeyModifiers = 0
        hotKeyDisplay = ""
        GlobalHotKeyManager.shared.update(keyCode: 0, carbonModifiers: 0)
    }

    private func loadSteamGridDBAPIKey() {
        steamGridDBAPIKey = (try? String(contentsOf: steamGridDBKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    private func saveSteamGridDBAPIKey() {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let key = steamGridDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try key.write(to: steamGridDBKeyURL, atomically: true, encoding: .utf8)
            saveStatus = .saved
        } catch {
            saveStatus = .failed
        }
    }

    private func openSteamGridDBAPIPage() {
        if let url = URL(string: "https://www.steamgriddb.com/profile/preferences/api") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openManualCoversFolder() {
        try? FileManager.default.createDirectory(at: manualCoversDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(manualCoversDirectory)
    }
}

struct CalloutPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct GameButton: View {
    let game: GameItem
    var isSelected: Bool = false
    let action: () -> Void
    let onReveal: () -> Void
    let onChooseCover: () -> Void
    let onRefreshCover: () -> Void
    let onRename: () -> Void
    let onResetName: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                GameCoverView(game: game)
                    .frame(width: 104, height: 104)

                Text(game.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 32, alignment: .top)
            }
            .frame(width: 116, height: 148)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.12 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(GameButtonStyle())
        .help(game.displayName)
        .contextMenu {
            Button("Show in Finder", action: onReveal)
            Divider()
            Button("Rename…", action: onRename)
            if game.hasCustomName {
                Button("Reset Name", action: onResetName)
            }
            Divider()
            Button("Choose Cover…", action: onChooseCover)
            Button("Refresh Cover", action: onRefreshCover)
            if game.canRemove {
                Divider()
                Button("Remove from Launcher", role: .destructive, action: onRemove)
            }
        }
    }
}

struct GameCoverView: View {
    let game: GameItem

    @Environment(\.artworkMode) private var artworkMode

    var body: some View {
        ZStack {
            if artworkMode == .appIcons {
                AppIconImage(image: game.appIcon)
            } else if let coverImage = game.coverImage {
                CoverImage(image: coverImage)
            } else if game.kind == .launcher {
                AppIconImage(image: game.appIcon)
            } else if game.isFetchingCover {
                SkeletonCover()
            } else {
                GeneratedCover(name: game.displayName)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if let formattedTimePlayed = game.formattedTimePlayed {
                Text(formattedTimePlayed)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(.black.opacity(0.58))
                    .clipShape(Capsule())
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
    }
}

struct AppIconImage: View {
    let image: NSImage

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.08))

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(18)
        }
    }
}

/// Shimmering placeholder shown while a cover is being fetched online.
struct SkeletonCover: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.06))

            LinearGradient(
                colors: [
                    .white.opacity(0),
                    .white.opacity(0.18),
                    .white.opacity(0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .rotationEffect(.degrees(20))
            .offset(x: animate ? 160 : -160)

            Image(systemName: "photo")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.18))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

struct GeneratedCover: View {
    let name: String

    private var initials: String {
        let words = name.split(separator: " ")
        let letters = words.prefix(2).compactMap(\.first)
        let value = String(letters).uppercased()
        return value.isEmpty ? "GN" : value
    }

    private var palette: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.10, green: 0.33, blue: 0.37), Color(red: 0.86, green: 0.36, blue: 0.24)],
            [Color(red: 0.22, green: 0.18, blue: 0.42), Color(red: 0.18, green: 0.58, blue: 0.77)],
            [Color(red: 0.15, green: 0.34, blue: 0.22), Color(red: 0.88, green: 0.68, blue: 0.29)],
            [Color(red: 0.37, green: 0.15, blue: 0.22), Color(red: 0.72, green: 0.30, blue: 0.55)],
            [Color(red: 0.12, green: 0.20, blue: 0.31), Color(red: 0.20, green: 0.68, blue: 0.50)]
        ]

        let value = name.unicodeScalars.reduce(0) { result, scalar in
            result &+ Int(scalar.value)
        }
        let index = value % palettes.count
        return palettes[index]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.18))
                .offset(x: 26, y: -26)

            Text(initials)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

struct GameButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? .white.opacity(0.16) : .white.opacity(0.06))
            )
    }
}

/// Borderless panels can't become key by default, which blocks the search field from
/// receiving focus. This subclass opts back in so autofocus and keyboard input work.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = GameStore()
    private var panel: NSPanel?
    private var isHidingPanel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = buildMenu()
        setupGlobalHotKey()
        showPanel()
        MainActor.assumeIsolated {
            UpdateChecker.shared.checkSilentlyIfDue()
        }
    }

    private func setupGlobalHotKey() {
        NotificationCenter.default.addObserver(
            forName: .gameNestToggleHotKey,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.togglePanel()
            }
        }

        let defaults = UserDefaults.standard
        let code = UInt32(defaults.integer(forKey: HotKeyDefaults.code))
        let modifiers = UInt32(defaults.integer(forKey: HotKeyDefaults.modifiers))
        GlobalHotKeyManager.shared.update(keyCode: code, carbonModifiers: modifiers)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Dock clicks are handled by applicationShouldHandleReopen so they can toggle the panel.
    }

    func applicationDidResignActive(_ notification: Notification) {
        hidePanelAnimated()
    }

    func windowDidResignKey(_ notification: Notification) {
        hidePanelAnimated()
    }

    private func showPanel() {
        store.reload()

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let finalFrame = panelFrame(for: panel)
        let wasVisible = panel.isVisible
        panel.setFrame(finalFrame, display: false)

        if !wasVisible {
            panel.alphaValue = 0
            panel.setFrame(entryFrame(from: finalFrame), display: false)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .gameNestPanelDidOpen, object: nil)

        guard !wasVisible else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    private func togglePanel() {
        if panel?.isVisible == true {
            hidePanelAnimated()
        } else {
            showPanel()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 577),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: LauncherView(store: store) { [weak self] game in
                self?.store.recordLaunch(game)
                if let emulatorURL = game.emulatorURL {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.arguments = game.launchArguments
                    NSWorkspace.shared.openApplication(at: emulatorURL, configuration: configuration)
                } else {
                    NSWorkspace.shared.open(game.launchURL)
                }
                self?.hidePanelAnimated()
            }
        )

        return panel
    }

    private func hidePanelAnimated() {
        guard let panel, panel.isVisible, !isHidingPanel else {
            return
        }

        // Keep the launcher open while a modal dialog (e.g. the cover picker) is in front.
        if NSApp.modalWindow != nil {
            return
        }

        // Keep the launcher open while a sheet (e.g. Settings) is attached to it.
        if panel.attachedSheet != nil {
            return
        }

        isHidingPanel = true
        let finalFrame = panel.frame
        let exitFrame = entryFrame(from: finalFrame)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(exitFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                panel?.orderOut(nil)
                panel?.alphaValue = 1
                panel?.setFrame(finalFrame, display: false)
                self?.isHidingPanel = false
            }
        }
    }

    private func panelFrame(for panel: NSPanel) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation

        guard let screen = screen(containing: mouseLocation) ?? NSScreen.main else {
            return panel.frame
        }

        let frame = screen.visibleFrame
        let fullFrame = screen.frame
        let size = panel.frame.size
        let margin: CGFloat = 12
        let dockHitArea: CGFloat = 96

        let proposedOrigin: NSPoint
        if mouseLocation.y <= frame.minY + dockHitArea {
            proposedOrigin = NSPoint(
                x: mouseLocation.x - (size.width / 2),
                y: frame.minY + margin
            )
        } else if mouseLocation.x <= fullFrame.minX + dockHitArea {
            proposedOrigin = NSPoint(
                x: frame.minX + margin,
                y: mouseLocation.y - (size.height / 2)
            )
        } else if mouseLocation.x >= fullFrame.maxX - dockHitArea {
            proposedOrigin = NSPoint(
                x: frame.maxX - size.width - margin,
                y: mouseLocation.y - (size.height / 2)
            )
        } else {
            proposedOrigin = NSPoint(
                x: mouseLocation.x - (size.width / 2),
                y: mouseLocation.y + 20
            )
        }

        let origin = clampedOrigin(proposedOrigin, panelSize: size, visibleFrame: frame, margin: margin)
        return NSRect(origin: origin, size: size)
    }

    private func entryFrame(from finalFrame: NSRect) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let offset: CGFloat = 14

        guard let screen = screen(containing: mouseLocation) ?? NSScreen.main else {
            return finalFrame.offsetBy(dx: 0, dy: -offset)
        }

        let visibleFrame = screen.visibleFrame
        let fullFrame = screen.frame

        if mouseLocation.y <= visibleFrame.minY + 96 {
            return finalFrame.offsetBy(dx: 0, dy: -offset)
        } else if mouseLocation.x <= fullFrame.minX + 96 {
            return finalFrame.offsetBy(dx: -offset, dy: 0)
        } else if mouseLocation.x >= fullFrame.maxX - 96 {
            return finalFrame.offsetBy(dx: offset, dy: 0)
        } else {
            return finalFrame.offsetBy(dx: 0, dy: -offset)
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        }
    }

    private func clampedOrigin(
        _ origin: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect,
        margin: CGFloat
    ) -> NSPoint {
        NSPoint(
            x: min(
                max(origin.x, visibleFrame.minX + margin),
                visibleFrame.maxX - panelSize.width - margin
            ),
            y: min(
                max(origin.y, visibleFrame.minY + margin),
                visibleFrame.maxY - panelSize.height - margin
            )
        )
    }

    private func buildMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        appMenu.addItem(
            NSMenuItem(
                title: "Refresh Games",
                action: #selector(refreshGames),
                keyEquivalent: "r"
            )
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit GameNest",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )

        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        editMenu.addItem(
            NSMenuItem(
                title: "Cut",
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x"
            )
        )
        editMenu.addItem(
            NSMenuItem(
                title: "Copy",
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c"
            )
        )
        editMenu.addItem(
            NSMenuItem(
                title: "Paste",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v"
            )
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            NSMenuItem(
                title: "Select All",
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"
            )
        )

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        return mainMenu
    }

    @objc private func refreshGames() {
        store.rescan()
        showPanel()
    }
}

let app = NSApplication.shared
let bundleIdentifier = "local.gamenest.app"
let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
let existingInstances = NSRunningApplication
    .runningApplications(withBundleIdentifier: bundleIdentifier)
    .filter { $0.processIdentifier != currentProcessIdentifier }

if let existingInstance = existingInstances.first {
    existingInstance.activate(options: [.activateAllWindows])
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
