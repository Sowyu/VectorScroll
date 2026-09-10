# VectorScroll

<img src="docs/icon.png" alt="VectorScroll icon" width="96" height="96">

Middle-button autoscrolling for macOS, with a native AppKit settings window. Move your pointer away from the starting point to control scrolling direction and speed.

Built with Swift and system frameworks. No Electron, web views, or third-party dependencies. One universal app supports Intel and Apple Silicon Macs running macOS 14 or later.

## Install

1. Download `VectorScroll.dmg` from the [latest release](https://github.com/Sowyu/VectorScroll/releases/latest).
2. Open the DMG and drag VectorScroll into Applications.
3. Open VectorScroll. Enable Accessibility and Input Monitoring in System Settings when prompted.

Settings opens by default. You can also choose **Settings…** from the menu bar icon.

## Scrolling

Choose a mode in Settings:

- **Scroll while holding the middle button:** release the button to stop.
- **Keep scrolling until the next click:** scrolling continues after release. Click any mouse button to stop.

The second mode has an optional hold requirement to prevent accidental activation. Adjust it from 50 to 1,000 ms in 50 ms steps. The default is 200 ms. Turn it off to start with a normal middle-click.

The click that stops scrolling also reaches the app under your pointer. Clicking a link or button will activate it. Stop over empty space to avoid that.

## Settings

Change the indicator's light/dark appearance and size, set launch at login, or check for updates. Changes save immediately.

Two toggles control how you access the app:

- **Open settings whenever VectorScroll opens** shows the window on launch and when you reopen the running app.
- **Show menu bar icon** keeps Settings and Quit available from the menu bar.

Both start enabled. They cannot both be off. Hiding the icon enables opening settings; disabling automatic settings opening restores the icon if needed. Closing the window keeps scrolling available.

If the icon is hidden, reopen VectorScroll from Applications or run:

```sh
open -a VectorScroll
```

## Updates

VectorScroll checks GitHub at launch and every 24 hours while running. Choose **Check for Updates…** in Settings, then **Install Update**.

The app downloads the DMG, verifies its SHA-256 checksum against GitHub, checks the app's identity, version, signature, and processor support, then installs and restarts automatically. Your settings remain saved.

The previous app is kept in a hidden `.VectorScroll-update-…` folder beside the installed app, named `Previous.app`. A failed replacement or launch restores the previous copy when possible. Update files and backups are retained, never permanently deleted by the updater.

Automatic installation requires the app to be in a writable folder, usually Applications. If you are running it from a DMG, move it into Applications first. Versions before 1.4.0 need one manual upgrade to gain automatic installation.

Background checks do not show dialogs, and no GitHub account is required.

## Build and check

Requires macOS and a Swift 6 toolchain. Run from the repository root:

```sh
swift build -c release
./scripts/build-app.sh
```

The bundle script builds both architectures, generates icons at fixed pixel sizes, and creates an ad-hoc-signed `dist/VectorScroll.app`. It refuses to replace an existing app. Move the previous build to Trash before rebuilding.

Run the native settings, access-toggle, scrolling, and update checks:

```sh
python3 scripts/check-hold.py
swiftc -swift-version 6 -warnings-as-errors -parse-as-library Sources/VectorScroll/Updates.swift scripts/check-updates.swift -o .build/check-updates
.build/check-updates
```

GitHub Actions also tests automatic installation and relaunch using a signed fixture app, replacement and launch rollback, checksum and signature failures, and a live GitHub download. It verifies the universal app, icon dimensions, signature, and DMG.
