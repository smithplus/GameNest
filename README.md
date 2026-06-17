# GameNest

GameNest is a small native macOS game launcher for the Dock. It reads the contents of `/Applications/Games` and shows them in a compact popover-style panel when the Dock icon is clicked.

The app is intended to work alongside macOS Dock Stacks: `/Applications/Games` remains the source of truth, while GameNest gives the same folder a more polished quick-launch UI.

## Current Behavior

- On first launch it creates `/Applications/Games` (plus `Covers/` and a hidden `.metadata/` folder) if they do not exist.
- It auto-detects installed games and populates `/Applications/Games`:
  - Steam games are read from local `appmanifest_*.acf` files and exposed as `.webloc` launchers pointing at `steam://rungameid/<id>`.
  - Real `.app` games (GOG, itch.io, emulators, standalone apps) are detected by their app category and exposed as Finder aliases.
  - Emulator ROMs are detected in-memory from the emulator's own configured game directories (currently Ryujinx, read from `Config.json`) and shown as regular games that launch the emulator with the ROM path. ROM entries are not files in the Games folder, so they cannot be removed/trashed from the launcher.
  - Detection is idempotent: existing entries are never duplicated, so manually added aliases are preserved.
- Runs as a normal Dock app.
- Clicking the Dock icon toggles the games drawer:
  - closed -> opens
  - open -> closes
- Clicking outside the drawer closes it.
- The drawer opens near the current mouse position, which makes Dock clicks feel anchored to the app icon.
- The drawer uses a native translucent material, a small callout pointer, and short fade/slide animations.
- Games are shown in a searchable grid using square cover art with the game name below.
- Items are split into two sections in the same drawer: real games first, then a "Launchers & Tools" section for storefronts, launchers, emulators, and streaming/controller utilities (detected by name via `GameClassifier`).
- Launchers/tools use their real app icon instead of online game art (name matches are unreliable for generic tool names); only an explicit manual cover overrides it.
- When the drawer opens, the search field is focused automatically and pressing Return launches the first matching game (preferring a real game over a launcher).
- The grid supports keyboard navigation: arrow keys move a highlighted selection (with autoscroll) while the search field keeps text-entry focus, and Return launches the selected tile.
- An optional, user-defined global shortcut (set in Settings, no default) opens/closes GameNest system-wide via a Carbon hotkey.
- Tiles show a shimmering skeleton placeholder while their cover art is being fetched online, falling back to the generated cover if none is found.
- Each tile has a right-click context menu: show in Finder, rename (and reset name), choose a cover manually, refresh the online cover, or remove the item from the launcher (moved to Trash).
- Items can be renamed for display without touching the underlying file; overrides are stored in `.metadata/names.json` so they survive rescans and never trigger duplicate auto-detection.
- The grid can be sorted by name, recent, time played, or progress; the chosen sort is remembered across sessions.
- Recently launched games are remembered locally (in `.metadata/recents.json`) to power the "Recent" sort.
- The library auto-refreshes when `/Applications/Games` changes on disk (files added, renamed, or removed), so manual edits show up without restarting.
- The empty state offers a button to open the games folder directly.
- Steam playtime is read locally from Steam's `localconfig.vdf` and installed app manifests when available.
- The toolbar shows the app name ("GameNest"), a refresh button, and a gear button that opens a single Settings sheet.
- The sort control sits inline with the "Games" section label directly below the search field.
- Settings is one place for everything: artwork mode (game covers vs macOS app icons), the optional global shortcut, the SteamGridDB API key with a ready/missing status indicator, quick access to the manual covers folder, and the current version with a "Check for Updates" button.
- Missing local cover art is fetched from Steam Store when possible, cached locally, and then falls back to a generated GameNest cover.
- Clicking a game opens it with `NSWorkspace.shared.open`.
- Only one instance should remain running. If a second instance starts, it activates the existing one and exits.
- GameNest checks GitHub for a newer release: silently on launch (at most once per day) and on demand via a "Check for Updates" button in Settings. When a newer version exists it shows the version and a button to download the `.dmg`; it never replaces itself automatically.

## Data Source

The app scans:

```text
/Applications/Games
```

Every visible file in that folder is treated as a launchable item. This works well with macOS alias files that point to apps, emulators, or launchers. Broken aliases are ignored on refresh, so uninstalling a target app does not leave a dead tile in GameNest. `.webloc` files are treated as URL-scheme launchers: GameNest reads the URL inside and opens it directly, which is how Steam games (`steam://rungameid/<id>`) are launched without a real `.app` to alias.

Cover art is loaded locally from:

```text
/Applications/Games/Covers
```

Name each cover after the cleaned game name:

```text
/Applications/Games/Covers/Factorio.jpg
/Applications/Games/Covers/Dota 2.png
```

Supported cover formats are `png`, `jpg`, `jpeg`, `heic`, and `tiff`.

When a local cover is missing for a real game, GameNest tries SteamGridDB (when an API key is configured). It accepts both square grids and the more common portrait box-art (`600x900` and similar), center-cropping portrait art to a square tile, and falls back to the game's SteamGridDB icon when no grid exists. Name matching prefers an exact match but falls back to the best-ranked search result so titles like "Prince of Persia Lost Crown" still resolve "Prince of Persia: The Lost Crown". If SteamGridDB has nothing, it falls back to Steam Store images only when they are already naturally square; rectangular store headers/capsules are discarded instead of being cropped or padded.

Launchers and tools never use online game art (matches on generic names like "Steam" or "Controller" are unreliable). They show their real app icon unless an explicit manual cover is added in `Covers/`.

When an online lookup fails, a small zero-byte marker is written to `/Applications/Games/.metadata/nocover` so the same game is not re-fetched on every reload. The marker expires after seven days, and choosing or refreshing a cover manually clears it immediately.

Fetched covers are saved next to the games themselves, inside a hidden metadata folder, so they live with the library instead of in a separate Library cache:

```text
/Applications/Games/.metadata/covers
```

The first time the app runs, any covers from the old cache location (`~/Library/Application Support/GameNest/Covers/v3`) are migrated into the new metadata folder automatically.

Local covers always take priority over saved or online covers. The lookup order is: manual `Covers/` → saved `.metadata/covers/` → online. For the most reliable result, add a manually selected 1:1 cover in `/Applications/Games/Covers`.

To enable SteamGridDB lookup, create this file with your API key:

```text
~/Library/Application Support/GameNest/steamgriddb.key
```

You can also set `STEAMGRIDDB_API_KEY` in the launch environment, but the key file works better for Dock-launched apps.

The settings panel lets users switch artwork mode, paste and save their SteamGridDB API key (with a ready/missing status indicator), shows save feedback, opens the SteamGridDB API page, and opens the manual covers folder.

Alias naming cleanup is intentionally simple:

- Removes a trailing ` alias`
- Removes a trailing `.app`

Examples:

- `Factorio.app alias` -> `Factorio`
- `Dota 2.app` -> `Dota 2`

## Project Layout

```text
GameNest/
├── Package.swift
├── Info.plist
├── README.md
├── package_app.sh
├── Resources/
│   └── AppIcon.icns   # bundled Dock/app icon
├── Scripts/
│   ├── Game Alias Builder.applescript
│   └── make_icon.swift            # regenerates Resources/AppIcon.icns
├── Sources/
│   └── GameNest/
│       └── main.swift
├── build/          # generated app bundle
└── .build/         # SwiftPM build artifacts
```

Important files:

- `Sources/GameNest/main.swift`: all app logic and UI for now.
- `Package.swift`: Swift Package executable definition.
- `Info.plist`: macOS app bundle metadata.
- `package_app.sh`: builds the Swift executable and packages `build/GameNest.app`.
- `Scripts/Game Alias Builder.applescript`: helper script that creates known game aliases in `/Applications/Games`.
- `Scripts/make_icon.swift`: CoreGraphics generator that renders the app icon and writes a 1024px PNG; combined with `sips`/`iconutil` it produces `Resources/AppIcon.icns`.

## Architecture Notes

The app is intentionally compact and currently lives in a single Swift file.

Main components:

- `GameItem`: launchable item model, including the resolved `launchURL` (the item itself for apps/aliases, or the parsed URL for `.webloc` launchers) and `lastPlayedAt`.
- `GameNestPaths`: central definition of the games folder, manual covers, hidden `.metadata` folders, the no-cover marker folder, the recents file, and the names file.
- `GameClassifier`: lightweight, name-based classifier that separates real games from launchers/storefronts/emulators/utilities.
- `RecentsStore`: persists recently launched games to `.metadata/recents.json`.
- `DisplayNameStore`: persists per-item display-name overrides to `.metadata/names.json`, keyed by normalized base name.
- `FolderWatcher`: watches `/Applications/Games` with a debounced file-system source and triggers a reload on change.
- `GameNaming`: shared name cleanup and normalization (strips ` alias`, `.app`, `.webloc`).
- `GameLibraryBootstrap`: creates the folder structure and migrates the legacy cover cache.
- `GameInstaller`: runs detection and writes Finder aliases / `.webloc` launchers into the games folder, idempotently.
- `SteamInstalledGames`: detects installed Steam games from local manifests.
- `InstalledApplications`: detects installed `.app` games by app category (GOG, itch.io, emulators, standalone).
- `EmulatorROMs`: detects ROMs from an emulator's configured game directories (Ryujinx) and exposes them as in-memory games launched via the emulator.
- `GameStore`: scans `/Applications/Games`, merges detected emulator ROMs, resolves local/saved cover art, sorts items, and triggers detection via `rescan()`.
- `GameMetadataRegistry`: merges optional platform metadata providers without requiring any one store to exist.
- `SteamMetadataProvider`: reads local Steam playtime metadata when games can be matched by name.
- `OnlineCoverService`: fetches and caches missing cover art from SteamGridDB and Steam Store.
- `LauncherView`: SwiftUI drawer UI with search and grid.
- `GameButton`: individual game tile.
- `GameCoverView`: square cover renderer with generated fallback art.
- `ArtworkMode`: persisted setting for switching between covers and app icons.
- `LauncherKeyboard`: drives arrow-key grid navigation (highlighted selection + autoscroll) while the search field keeps text-entry focus.
- `GlobalHotKeyManager`: registers the optional user-defined system-wide hotkey via Carbon and posts a toggle notification.
- `HotKeyRecorder`: captures a key combination in Settings for the global shortcut.
- `SkeletonCover`: shimmering placeholder shown while a cover is being fetched online.
- `AppInfo`: central app metadata (GitHub repo, current version, releases URL).
- `UpdateChecker`: checks GitHub's latest release against the bundle version (silently on launch, ≤1×/day, and on demand) and surfaces a download prompt; never self-replaces.
- `CalloutPointer`: triangle pointer at the bottom of the drawer.
- `AppDelegate`: AppKit lifecycle, Dock toggle behavior, panel positioning, animations, single-instance guard, global-hotkey wiring, and the launch-time update check.

The drawer is an `NSPanel` containing a SwiftUI `NSHostingView`. AppKit is used because SwiftUI alone does not expose enough control for Dock-style panel behavior.

## Build

From the project folder:

```bash
swift build
```

To create the `.app` bundle:

```bash
./package_app.sh
```

The generated app will be:

```text
build/GameNest.app
```

## Run

```bash
open build/GameNest.app
```

For Dock usage, drag `build/GameNest.app` into the Dock.

## App Icon

The icon is generated, not hand-drawn. `Scripts/make_icon.swift` renders a
1024px master (dark glossy squircle, indigo→violet gradient, glassy top
reflection, controller glyph), then `sips` produces every required size and
`iconutil` packs them into `Resources/AppIcon.icns`:

```bash
swift Scripts/make_icon.swift icon_1024.png
mkdir AppIcon.iconset
for s in 16 32 32 64 128 256 256 512 512 1024; do :; done   # see commit history for the size map
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
```

The `.icns` must contain all sizes (16→1024); a single-size `.icns` renders
blank in the Dock.

## Releases & Updates

GameNest is distributed as a `.dmg` attached to a public GitHub release. The
repository must be public so the unauthenticated GitHub API and the asset
download URLs work for end users.

To cut a release:

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Info.plist`.
2. `./package_app.sh` to build `build/GameNest.app`.
3. Stage the app with an `/Applications` symlink and build the disk image:

   ```bash
   hdiutil create -volname "GameNest" -srcfolder <stage-dir> -ov -format UDZO GameNest-<version>.dmg
   ```

4. `gh release create v<version> GameNest-<version>.dmg --title "GameNest v<version>" --notes "…"`.

The app checks `https://api.github.com/repos/<repo>/releases/latest`, compares
the release tag (minus a leading `v`) against its own version with a numeric,
dot-separated comparison, and — when a newer version exists — shows the version
and a button that opens the `.dmg`. It never replaces itself automatically
(the app is unsigned, so a self-replacing updater would fight Gatekeeper).

## Alias Helper

`Scripts/Game Alias Builder.applescript` is a companion script for maintaining `/Applications/Games`.

It currently knows about local apps and launchers such as Clone Hero, Factorio, League of Legends, Prince of Persia, Dota 2, Steam, Epic Games Launcher, Heroic, GameHub, Ryujinx, BlueStacksMIM, Moonlight, and Controller.

Run it manually with:

```bash
osascript "Scripts/Game Alias Builder.applescript"
```

The script is idempotent: it skips aliases that already exist and creates missing ones when the target app is present.

## Development Notes

- This project targets macOS 14+ in `Package.swift`.
- The bundle identifier is `local.gamenest.app`.
- The panel position is based on `NSEvent.mouseLocation`. macOS does not expose the exact Dock icon coordinates, so this uses the click position as the anchor.
- The current UI assumes a bottom pointer. If supporting left/right Dock with matching side pointers becomes important, `CalloutPointer` and `LauncherView` should be made orientation-aware.
- Generated folders `.build/` and `build/` can be deleted and regenerated.

## Future Ideas

- Add a settings view for the games folder path.
- Extend ROM/auto-detection to more emulators and launchers (Heroic, Epic, other emulators) beyond Steam, category-tagged apps, and Ryujinx ROMs.
- Add favorites.
- Expand time played and progress support beyond local Steam metadata.
- Optionally support a semi-automatic update flow (download + mount the `.dmg`) once code signing is in place.
- Split `main.swift` into smaller files once the app grows.
