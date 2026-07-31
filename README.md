# VectorScroll

<img src="docs/icon.png" alt="VectorScroll icon" width="128" height="128">

A tiny native macOS menu-bar utility that recreates Windows/Firefox-style vector scrolling. Built directly on Swift and AppKit with no external dependencies or frameworks (no Electron, no bundled runtimes). The whole app ships as a ~400 KB download, runs as a single lightweight process, and uses
negligible CPU and memory while idle.


The app appears in the macOS menu bar.

## Use

- Middle-click to start scrolling; move the pointer away from the anchor to control direction and speed.
- Pick a scroll mode in the menu: `Hold to Scroll` (scrolling starts on middle-click and stops when you release it) or `Hold to Start` (hold middle-click for 200ms to start scrolling, then click any mouse button to stop; a quick middle-click does nothing).
- The on-screen indicator marks the anchor while scrolling is active.
- Use `Light Mode` or `Dark Mode` to choose the indicator style.
- Use the `Size` menu to choose `28`, `32`, `40`, or `48` px.
- Use `Launch at Startup` to control whether the app opens when you log in.
- Use `Hide Menu Bar Icon` to remove the status-item icon; reopen the app (e.g. `open -a VectorScroll`) to bring it back.
- Indicator style, indicator size, and scroll mode are saved between launches.

In `Hold to Start`, the click that stops scrolling is also delivered to whatever is under the
pointer. VectorScroll observes input with a listen-only event tap and never swallows events, so
stopping on a button or a link will also activate it. Stop over empty space to avoid this.

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
