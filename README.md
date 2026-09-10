# VectorScroll

<img src="docs/icon.png" alt="VectorScroll icon" width="128" height="128">

A tiny native macOS menu-bar utility that recreates Windows/Firefox-style vector scrolling. Built directly on Swift and AppKit with no external dependencies or frameworks (no Electron, no bundled runtimes). The whole app ships as a ~400 KB download, runs as a single lightweight process, and uses
negligible CPU and memory while idle.


The app appears in the macOS menu bar.

## Use

- Middle-click to start scrolling; move the pointer away from the anchor to control direction and speed.
- Choose `Scroll While Holding` to scroll while the middle mouse button is down. Release it to stop.
- Choose `Scroll Until Next Click` to keep scrolling after releasing the middle button. Click any mouse button to stop.
- In `Scroll Until Next Click`, open `Hold Before Starting` to set how long to hold the middle button before scrolling begins. Toggle `Require a Hold to Start` off to start with a normal middle-click. The slider ranges from `50` to `1,000` ms, with a default of `200` ms. Settings are saved between launches.
- Open `Indicator Appearance` to choose a light or dark indicator and change its size.
- Use `Launch at Startup` to control whether the app opens when you log in.
- Use `Hide Menu Bar Icon` to remove the status-item icon; reopen the app (e.g. `open -a VectorScroll`) to bring it back.
- Indicator style, indicator size, and scroll mode are saved between launches.

In `Scroll Until Next Click`, the click that stops scrolling is also delivered to whatever is under the
pointer. VectorScroll observes input with a listen-only event tap and never swallows events, so
stopping on a button or a link will also activate it. Stop over empty space to avoid this.

## Updates

VectorScroll checks GitHub for a stable release at launch and every 24 hours while running. Use `Check for Updates…` in the menu bar to check immediately. When a newer version exists, `Download Update` opens its DMG in your browser. Quit the app and replace it in Applications to install the update. The installed version appears in the menu.

Background checks do not show dialogs. Failed checks leave the app running and can be retried from the menu. No GitHub account is required.

## Build

```
swift build -c release      # binary only
./scripts/build-app.sh      # bundles VectorScroll.app into dist/
```

`build-app.sh` invokes `scripts/make-icons.swift` to render the iconset, then `iconutil` to pack it
into `VectorScroll.icns`, so the icon is generated at build time rather than checked in.

macOS may prompt for Accessibility/Input Monitoring permission. If it does not work immediately, enable the app in:

`System Settings -> Privacy & Security -> Accessibility`

and, if needed:

`System Settings -> Privacy & Security -> Input Monitoring`

The menu-bar icon uses Apple's native SF Symbols.
