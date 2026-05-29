# GameNest

GameNest is a small native macOS game launcher for the Dock. It reads the contents of `/Applications/Games` and shows them in a compact popover-style panel when the Dock icon is clicked.

The app is intended to work alongside macOS Dock Stacks: `/Applications/Games` remains the source of truth, while GameNest gives the same folder a more polished quick-launch UI.

## Current Behavior

- Runs as a normal Dock app.
- Clicking the Dock icon toggles the games drawer:
  - closed -> opens
  - open -> closes
- Clicking outside the drawer closes it.
- The drawer opens near the current mouse position, which makes Dock clicks feel anchored to the app icon.
- The drawer uses a native translucent material, a small callout pointer, and short fade/slide animations.
- Games are shown in a searchable grid using square cover art with the game name below.
- The grid can be sorted by name, time played, or progress.
- Steam playtime is read locally from Steam's `localconfig.vdf` and installed app manifests when available.
- A settings menu can switch artwork between game covers and macOS app icons.
- Missing local cover art is fetched from Steam Store when possible, cached locally, and then falls back to a generated GameNest cover.
- Clicking a game opens it with `NSWorkspace.shared.open`.
- Only one instance should remain running. If a second instance starts, it activates the existing one and exits.

## Data Source

The app scans:

```text
/Applications/Games
```

Every visible file in that folder is treated as a launchable item. This works well with macOS alias files that point to apps, Steam game bundles, emulators, or launchers.

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

When a local cover is missing, GameNest first tries SteamGridDB square grids (`512x512` or `1024x1024`) when an API key is configured, then falls back to Steam Store images only when they are already naturally square. Rectangular store headers/capsules are discarded instead of being cropped or padded.

```text
~/Library/Application Support/GameNest/Covers/v3
```

Local covers always take priority over cached or online covers. For the most reliable result, add a manually selected 1:1 cover in `/Applications/Games/Covers`.

To enable SteamGridDB lookup, create this file with your API key:

```text
~/Library/Application Support/GameNest/steamgriddb.key
```

You can also set `STEAMGRIDDB_API_KEY` in the launch environment, but the key file works better for Dock-launched apps.

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
├── Scripts/
│   └── Game Alias Builder.applescript
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

## Architecture Notes

The app is intentionally compact and currently lives in a single Swift file.

Main components:

- `GameItem`: launchable item model.
- `GameStore`: scans `/Applications/Games`, resolves local/cached cover art, sorts items.
- `GameMetadataRegistry`: merges optional platform metadata providers without requiring any one store to exist.
- `SteamMetadataProvider`: reads local Steam playtime metadata when games can be matched by name.
- `OnlineCoverService`: fetches and caches missing cover art from SteamGridDB and Steam Store.
- `LauncherView`: SwiftUI drawer UI with search and grid.
- `GameButton`: individual game tile.
- `GameCoverView`: square cover renderer with generated fallback art.
- `ArtworkMode`: persisted setting for switching between covers and app icons.
- `CalloutPointer`: triangle pointer at the bottom of the drawer.
- `AppDelegate`: AppKit lifecycle, Dock toggle behavior, panel positioning, animations, single-instance guard.

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
- Auto-generate aliases from known sources such as Steam, Heroic, Epic, Ryujinx, and `/Applications`.
- Add cover art from SteamGridDB or IGDB.
- Add favorites and recent launches.
- Expand time played and progress support beyond local Steam metadata.
- Add keyboard navigation.
- Split `main.swift` into smaller files once the app grows.
