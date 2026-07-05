# VectorScroll

<img src="docs/icon.png" alt="VectorScroll icon" width="128" height="128">

A tiny native macOS menu-bar utility that recreates Windows/Firefox-style vector scrolling. Built directly on Swift and AppKit with no external dependencies or frameworks (no Electron, no bundled runtimes). The whole app ships as a ~400 KB download, runs as a single lightweight process, and uses
negligible CPU and memory while idle.


The app appears in the macOS menu bar.

## Use

- Middle-click to start scrolling; move the pointer away from the anchor to control direction and speed.
- Pick a stop mode in the menu: `Hold to Scroll` (release middle-click to stop) or `Hold to Start` (hold briefly, release to start scrolling, click again to stop).
- The on-screen indicator marks the anchor while scrolling is active.
- Use `Light Mode` or `Dark Mode` to choose the indicator style.
- Use the `Size` menu to choose `28`, `32`, `40`, or `48` px.
- Use `Launch at Startup` to control whether the app opens when you log in.
- Indicator style and size are saved between launches.

macOS may prompt for Accessibility/Input Monitoring permission. If it does not work immediately, enable the app in:

`System Settings -> Privacy & Security -> Accessibility`

and, if needed:

`System Settings -> Privacy & Security -> Input Monitoring`

The menu-bar icon uses Apple's native SF Symbols.
