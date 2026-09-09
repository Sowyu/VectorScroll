# Bug audit

Audited commit `0554953` on 2026-09-10. Reviewed the complete application source, package manifest, both build scripts, settings and lifecycle paths, and README behavior claims. Application code is unchanged.

Eight findings below are based on source inspection and Apple API documentation. Native reproduction remains outstanding. This machine runs Linux and has no Swift compiler or macOS frameworks. P1 means high priority; P2 means normal priority.

## P1: Icon generation can delete an unrelated directory

Location: [make-icons.swift:3](../scripts/make-icons.swift#L3), [build-app.sh:12](../scripts/build-app.sh#L12).

The icon generator accepts an arbitrary output path and immediately calls `FileManager.default.removeItem` on it. Passing an existing directory containing other files recursively deletes those files before rendering starts. There is no output-directory validation, ownership check, or recoverable removal. The error is also discarded with `try?`.

The bundle script permanently removes the previous app before icon generation and signing succeed. A later failure leaves the previous working artifact lost and a partial replacement in its place. Both removal paths violate this workspace's Trash policy. Neither script was executed during the audit.

Fix: render into a fresh directory, refuse unsafe destinations, and preserve existing output until the replacement has passed validation. Any necessary removals must use the required recoverable Trash command.

## P1: Permission UI hides an unmet scrolling requirement

Location: [main.swift:253](../Sources/VectorScroll/main.swift#L253), [main.swift:425](../Sources/VectorScroll/main.swift#L425).

Grant Input Monitoring but leave Accessibility denied. `updatePermissionMenuItem` hides the only permission action as soon as listening is allowed. `startScrolling` notices missing Accessibility but only refreshes that already-hidden item, then shows the marker and starts posting events anyway. The app can appear ready and active while scrolling does nothing. After the initial prompt, `accessibilityPromptedThisRun` prevents another prompt for the rest of the process lifetime.

Apple documents separate authorization for listening and synthetic input, including discarded events without Accessibility approval in [Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/).

Fix: show the missing permission explicitly, check posting access before starting, and provide a route to the relevant Settings page after the first prompt.

## P2: Lost input leaves scrolling active after release

Location: [main.swift:364](../Sources/VectorScroll/main.swift#L364), [main.swift:349](../Sources/VectorScroll/main.swift#L349), [main.swift:458](../Sources/VectorScroll/main.swift#L458).

In Hold to Scroll, start scrolling, interrupt delivery from the event tap, and release the middle button before delivery resumes. The disabled-tap handler only re-enables the tap. It preserves `isActive`, the scroll timer, and any armed hold. The polling path also never stops scrolling when Input Monitoring is unavailable. No tick checks whether the middle button is still down.

If the release was missed, the app continues generating scroll events even though the button is up. A subsequent middle-button release or quitting is required to clear the active state. An armed hold can similarly activate after input monitoring has failed.

Fix: cancel pending engagement and stop scrolling on tap disablement or permission loss. Reconcile button state when recovering. The common cancellation function must cancel pending work even when `isActive` is false; the current `stopScrolling` guard prevents that.

## P2: Quick clicks can become locked scrolling under load

Location: [main.swift:396](../Sources/VectorScroll/main.swift#L396), [main.swift:406](../Sources/VectorScroll/main.swift#L406).

The 200 ms delay itself is intentional. Commit `1fdfe1b` explicitly says a brief middle-click does nothing, holding past the threshold engages scrolling, and release after engagement does not stop it. The finding concerns a physical click shorter than 200 ms whose release is processed late, not the designed hold delay.

The hold duration uses the wall-clock time when callbacks run, rather than the physical event timestamps. Process the middle-down event, stall the main thread, and physically release within 200 ms. When the queued release is processed after 200 ms, the cancellation condition is false. If the delayed work runs first, it starts scrolling and the active Hold to Start branch ignores the release instead. Either ordering can turn a short click into locked scrolling.

The delayed work never verifies that the middle button remains down. Wall-clock changes can also distort the comparison because `Date` and the dispatch deadline use different clock semantics.

Fix: track event timestamps for the gesture, validate button state before delayed engagement, and reconcile delayed releases with the engagement decision. Add a test with a 100 ms physical press whose release callback arrives after 250 ms.

## P2: Changing scroll mode changes an ongoing gesture

Location: [main.swift:184](../Sources/VectorScroll/main.swift#L184), [main.swift:371](../Sources/VectorScroll/main.swift#L371).

Begin Hold to Scroll, keep the middle button down, and use the left button to select Hold to Start from the menu. Left clicks do not stop an active Hold to Scroll gesture. The selector changes `holdToLockMode` without clearing activity. Releasing the middle button now enters the Hold to Start branch and is ignored, leaving the previous gesture locked.

The selectors also leave pending engagement work intact. If a mode change occurs while a hold is armed, that old work can start scrolling using the new mode.

Fix: cancel pending work and stop the current gesture before changing modes, or store the mode with the gesture so its stop rule cannot change midway.

## P2: Accessibility calls can freeze the app's input processing

Location: [main.swift:430](../Sources/VectorScroll/main.swift#L430), [main.swift:502](../Sources/VectorScroll/main.swift#L502), [main.swift:522](../Sources/VectorScroll/main.swift#L522).

Starting a scroll performs cross-process accessibility lookup, activation, and up to ten attempts to raise an ancestor, with parent queries between attempts. This all runs on the main thread, directly inside the event callback in Hold to Scroll. A target application that is slow or unresponsive can hold up the menu, release processing, and scrolling startup until accessibility requests time out. The code sets no application-specific timeout or total deadline.

Apple provides [AXUIElementSetMessagingTimeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout) to control these request timeouts. The user-visible stall is inferred from the synchronous call path; its duration needs measurement on macOS.

Fix: keep slow accessibility queries out of the event callback, use a bounded timeout, and discard stale results if the user has released or canceled the gesture while focus work was pending. Keep AppKit activation on the main actor.

## P2: Icon output dimensions depend on the build display

Location: [make-icons.swift:22](../scripts/make-icons.swift#L22), [make-icons.swift:33](../scripts/make-icons.swift#L33).

The icon generator treats `NSImage` sizes in points as pixel sizes, uses `lockFocus`, and serializes the resulting bitmap without checking its dimensions. On a 2x drawing context, a nominal 16-pixel icon can become 32 pixels and the nominal 1024-pixel image can become 2048 pixels. The resulting PNGs do not match their iconset filenames, so packaging can fail or produce incorrect representations.

Apple explicitly documents unexpected doubled bitmap dimensions with this drawing method in its [high-resolution drawing guidance](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/CapturingScreenContents/CapturingScreenContents.html). This finding still needs a generated-output check on a Retina Mac.

Fix: render into an `NSBitmapImageRep` with explicit pixel dimensions. Assert the PNG width and height for all ten iconset entries before invoking `iconutil`.

## P2: Startup toggle cannot handle a service awaiting approval

Location: [main.swift:203](../Sources/VectorScroll/main.swift#L203), [main.swift:268](../Sources/VectorScroll/main.swift#L268).

When the login item has status `requiresApproval`, the menu displays it as off and clicking it calls `register()` again. Apple defines that status as already registered but awaiting user action, including when the user has revoked consent in Settings. Registering again does not guide the user through that approval, and errors only produce a beep. The toggle offers no way to remove this pending registration because it only unregisters the `enabled` state.

The checkmark also remains stale if the user changes approval in Settings while the application is running, because it is refreshed only during menu construction and after clicking the item.

Fix: handle each service status explicitly, offer Settings for required approval, allow pending registration to be canceled, and refresh status when the menu opens. See Apple's [requiresApproval definition](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval) and [registration documentation](https://developer.apple.com/documentation/servicemanagement/smappservice/register()).

## Validation and limits

`sh -n scripts/build-app.sh` passed. Python's `plistlib` parsed the embedded Info.plist successfully; the executable name and minimum macOS version match the package. All callers of gesture start, stop, arming, cancellation, permission installation, and mode selection were traced. The repository contains no test target or test files.

No build scripts, deletion paths, native app, signing, or login registration were executed. Native compilation, real mouse-event timing, TCC permission recovery, Retina rendering, full-screen and multiple-display behavior still require macOS verification. The audit does not establish that those untested paths are otherwise bug-free.
