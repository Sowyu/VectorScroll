# Settings polish

This pass applies specific recommendations to the native settings window:

- [Sindre Sorhus's community guidelines](https://github.com/sindresorhus/human-interface-guidelines-extras#settings-window) recommend grouping related controls. Settings use padded groups with left-aligned labels and right-aligned native switches. A compact appearance picker replaces the loose indicator radio buttons, and the update footer replaces the redundant section heading.
- [Apple's help guidance](https://developer.apple.com/design/human-interface-guidelines/offering-help) recommends contextual help. Native tooltips explain speed, start delay, indicator appearance, and the two ways to reopen settings. Custom mode descriptions also appear in accessibility help.
- [Apple's layout guidance](https://developer.apple.com/design/tips/#organization) places controls near the content they change. The indicator now has an actual-size preview beside its color and size controls, using the same drawing code as the scrolling indicator.
- [Apple's feedback guidance](https://developer.apple.com/design/human-interface-guidelines/feedback) favors status near the relevant control. Update checks show inline results and a native busy indicator. Successful checks no longer require dismissing a dialog, and manual results are announced to assistive technology.
- [Apple's accessibility value guidance](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilityvaluedescription()) recommends meaningful descriptions of raw values. Sliders expose percent and millisecond units.

The existing macOS CI exercises real pointer clicks, both indicator appearances at every supported size, slider value descriptions, update busy states, and small-window scrolling. It also captures the settings in light and dark appearances.
