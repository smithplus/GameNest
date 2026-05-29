import AppKit
import SwiftUI

struct GameItem: Identifiable {
    var id: String { url.path }
    let name: String
    let url: URL
    var coverImage: NSImage?
    var timePlayedMinutes: Int?
    var progress: Double?
}

enum SortOption: String, CaseIterable, Identifiable {
    case name
    case timePlayed
    case progress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return "Name"
        case .timePlayed:
            return "Time Played"
        case .progress:
            return "Progress"
        }
    }
}

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var games: [GameItem] = []

    private let gamesDirectory = URL(fileURLWithPath: "/Applications/Games", isDirectory: true)
    private let coverService = OnlineCoverService()
    private var coversDirectory: URL {
        gamesDirectory.appendingPathComponent("Covers", isDirectory: true)
    }
    private var cacheDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameNest/Covers/v3", isDirectory: true)
    }

    init() {
        reload()
    }

    func reload() {
        let fileManager = FileManager.default

        guard let urls = try? fileManager.contentsOfDirectory(
            at: gamesDirectory,
            includingPropertiesForKeys: [.isHiddenKey, .localizedNameKey],
            options: [.skipsHiddenFiles]
        ) else {
            games = []
            return
        }

        games = urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .filter { $0.lastPathComponent != "Covers" }
            .map { url in
                let name = Self.cleanName(for: url)
                return GameItem(
                    name: name,
                    url: url,
                    coverImage: Self.coverImage(named: name, in: coversDirectory)
                        ?? Self.coverImage(named: name, in: cacheDirectory),
                    timePlayedMinutes: nil,
                    progress: nil
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        Task {
            await fetchMissingCovers()
        }
    }

    private static func cleanName(for url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(" alias") {
            name.removeLast(" alias".count)
        }
        if name.hasSuffix(".app") {
            name.removeLast(".app".count)
        }
        return name
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
        let missingGames = games.filter { $0.coverImage == nil }
        guard !missingGames.isEmpty else {
            return
        }

        for game in missingGames {
            guard let coverData = await coverService.fetchCoverData(named: game.name),
                  Self.isSquareCoverData(coverData),
                  let coverImage = NSImage(data: coverData) else {
                continue
            }

            Self.writeCoverData(coverData, named: game.name, in: cacheDirectory)

            if let index = games.firstIndex(where: { $0.id == game.id }) {
                games[index].coverImage = coverImage
            }
        }
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

actor OnlineCoverService {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchCoverData(named name: String) async -> Data? {
        guard let imageURL = await steamCoverURL(for: name),
              let imageData = await downloadImageData(from: imageURL) else {
            return nil
        }

        return imageData
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
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("GameNest/0.1", forHTTPHeaderField: "User-Agent")

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

struct LauncherView: View {
    @ObservedObject var store: GameStore
    let launch: (GameItem) -> Void

    @State private var searchText = ""
    @State private var sortOption: SortOption = .name

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 128), spacing: 14)
    ]

    private var displayedGames: [GameItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredGames: [GameItem]

        if query.isEmpty {
            filteredGames = store.games
        } else {
            filteredGames = store.games.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
        }

        return filteredGames.sorted(by: sortGames)
    }

    private func sortGames(_ lhs: GameItem, _ rhs: GameItem) -> Bool {
        switch sortOption {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(displayedGames) { game in
                                GameButton(game: game) {
                                    launch(game)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
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
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Games")
                    .font(.system(size: 20, weight: .semibold))

                Spacer()

                Menu {
                    Picker("Sort by", selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label(sortOption.title, systemImage: "arrow.up.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort games")

                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search games", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.black.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding([.top, .horizontal], 16)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                GameCoverView(game: game)
                    .frame(width: 104, height: 104)

                Text(game.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 32, alignment: .top)
            }
            .frame(width: 116, height: 148)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(GameButtonStyle())
        .help(game.name)
    }
}

struct GameCoverView: View {
    let game: GameItem

    var body: some View {
        ZStack {
            if let coverImage = game.coverImage {
                CoverImage(image: coverImage)
            } else {
                GeneratedCover(name: game.name)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = GameStore()
    private var panel: NSPanel?
    private var isHidingPanel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = buildMenu()
        showPanel()
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
        let panel = NSPanel(
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
                NSWorkspace.shared.open(game.url)
                self?.hidePanelAnimated()
            }
        )

        return panel
    }

    private func hidePanelAnimated() {
        guard let panel, panel.isVisible, !isHidingPanel else {
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
        return mainMenu
    }

    @objc private func refreshGames() {
        store.reload()
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
