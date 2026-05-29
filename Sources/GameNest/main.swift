import AppKit
import SwiftUI

struct GameItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let icon: NSImage
}

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var games: [GameItem] = []

    private let gamesDirectory = URL(fileURLWithPath: "/Applications/Games", isDirectory: true)

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
            .map { url in
                GameItem(
                    name: Self.cleanName(for: url),
                    url: url,
                    icon: NSWorkspace.shared.icon(forFile: url.path)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
}

struct LauncherView: View {
    @ObservedObject var store: GameStore
    let launch: (GameItem) -> Void

    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 86, maximum: 112), spacing: 14)
    ]

    private var filteredGames: [GameItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return store.games
        }

        return store.games.filter {
            $0.name.localizedCaseInsensitiveContains(query)
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
                            ForEach(filteredGames) { game in
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
            VStack(spacing: 8) {
                Image(nsImage: game.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)

                Text(game.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 32, alignment: .top)
            }
            .frame(width: 96, height: 108)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(GameButtonStyle())
        .help(game.name)
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
