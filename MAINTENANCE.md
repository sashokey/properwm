# Maintenance

The imported baseline is source version 0.18.4, commit `825924c8019945bb0b620702f8a274a249e9c8f6`. ProperWM's independent root snapshot is `3dab8e2b88687ce7d758a221f51f69a268bc2f40`.

The original source remains in repository history. Removed features can be restored from that snapshot, including their models, services, views, resources, project references, and tests. Restoration requires an explicit scope decision; copying a view alone may omit dependencies or bring back unwanted behavior.

For future source-project fixes:

1. Compare with the recorded baseline and identify the bug and affected retained subsystem.
2. Transfer the smallest applicable fix and its regression test.
3. Adapt it to ProperWM's window-only model and fixed behavior.
4. Check for reintroduced launchers, file operations, Dock writes, settings, author services, and product branding.
5. Run CI and relevant Mac acceptance scenarios.
6. Record the source commit, rationale, adaptations, and verification in the ProperWM commit message.

Track source changes manually when requested; there is no automatic merge or background update service. GitHub's standard Source code archives for each release tag and this repository history provide the corresponding source for distributed binaries.

Keep commits focused and explain what changed, why it was needed, what behavior was preserved, and how it was verified. Code changes follow SOLID, KISS, and DRY.

Validate nontrivial code changes on a working branch. Move them to master after the relevant CI checks pass. This protects the main branch from intermediate migration failures; code review, meaningful tests, and Mac acceptance checks establish the behavior itself.

## Platform and toolchain policy

The deployment minimum is macOS 26 on Apple Silicon. Keep its compatibility without adding a dedicated macOS 26 test matrix or special behavior. Tests run on the newest hosted macOS family available in GitHub Actions, currently `xcode-27`; its patch version follows GitHub's image updates. A newer Apple release can precede availability in hosted runners. Move the label forward when GitHub provides a newer family.

Select the newest installed stable Xcode, resolving application symlinks before excluding beta and release-candidate bundles. Compile all targets in Swift 6 language mode. Node.js and Python are resolved to the newest stable releases for each CI run; their actual versions, Xcode, Swift, and macOS are recorded in the build log.

Official GitHub Actions are pinned to full release commit SHAs. Dependabot checks them daily and opens update pull requests; merge those updates after CI passes. Keep the source, release workflow, and packaging free of third-party runtime packages. The system frameworks are supplied by macOS and the selected Xcode SDK.

## Artifact storage

Build and test artifacts expire after seven days. Artifact maintenance runs after CI or Release completes and when its policy changes. It tests the deletion policy before using Actions write permission.

For each managed name (`ProperWM`, `test-results`, and legacy `xcodebuild-test-log`), keep the three newest completed artifacts and the newest successful result. Also keep artifacts from active runs, the triggering run, unknown runs, and unrelated artifact names. The maintenance workflow reads trusted `master` code and does not run for fork or pull-request completion events.

Only GitHub Actions artifacts are deleted. Published release assets, tags, source, workflow runs, and their logs are not deletion targets.

## Taskbar reference and boundaries

The UI reference is Windows 11 Pro 26H2 (26300.9711), 1920×1080 at 100%, dark theme, Small taskbar, bottom, left aligned, with combining set to When taskbar is full and window buttons shown on the taskbar where the window is open. Inspect the real UI as well as Microsoft's [current taskbar settings documentation](https://support.microsoft.com/en-us/windows/experience/personalization/customize-the-taskbar-in-windows). The [Win32 taskbar design guide](https://learn.microsoft.com/en-us/windows/win32/uxguide/winenv-taskbar) explicitly describes Windows 7; its screenshots are not the current visual reference.

Retain only the open-window area. The observed taskbar height is 32, button height 28, top/bottom inset 2, icon size 16, and Start's outer left inset 10. Translate these to macOS points, not unscaled Retina pixels. Use the macOS system font and native app icons. The bar fills the screen width and touches its bottom edge.

A follow-up measurement kept five Terminal windows, two File Explorer windows, and fifteen Notepad windows separate in a 1,676-pixel button area. Compressed long buttons painted at 74–75 pixels with 2-pixel gaps; adding another Notepad window combined Terminal. A short Clock caption painted at 66 pixels while space was available. A separate Windows Terminal window titled exactly `.` used a 39-pixel button and a 41-pixel pitch to the next icon; the label starts at 28 with an 8-pixel trailing inset. Keep natural caption width separate from the compression limit, and distribute fractional width across buttons without accumulating empty pixels. These are measurements of the configured reference, not Microsoft-documented universal constants.

Right-click actions use AppKit NSMenu and ordinary NSMenuItem rendering. The application menu contains Open at Login, Hide Status Bar Icon, a separator, and Quit. Internal reordering moves the existing button views within the taskbar; it must not create a detached system drag image. Use those same constrained group bounds to select an insertion position: the leading edge crosses a left neighbor's midpoint or the trailing edge crosses a right neighbor's midpoint. Do not require the pointer to enter another button. Compare with complete neighboring groups and their current layout slots, keeping the result stable during animation and repeated pointer events. Returning to the original slot must not persist a reorder. Hover and active transitions respect Reduce Motion. Keep the Windows-shaped neutral highlight and lower active underline/inactive dot; do not replace them with an accent-filled macOS toggle or pill shape.

The taskbar and combined/overflow list use Apple's public [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview), with content inside `contentView`. Buttons compose public NSButton, NSTextField, NSImageView, and NSBox controls: AppKit draws the controls, while ProperWM supplies the measured Windows geometry and interaction state. The highlight uses `unemphasizedSelectedContentBackgroundColor`, with the original four-point corner radius and no filled accent color. Only the lower active indicator uses the system accent. Do not layer separate Liquid Glass surfaces on the buttons. Use the text field's alignment rectangle to retain the measured label insets rather than adding its intrinsic margins to them. The list uses NSTableView, native row selection, NSScrollView, and standard symbol close buttons over the glass; keep all intervening backgrounds clear. The permission-recovery hint uses a SwiftUI GroupBox. Do not restore private glass selectors, a separate fake blur layer, or the former floating capsule/resize grip. Preserve existing window tracking, native tabs, display attribution, fullscreen prediction, and maximized-window avoidance.

The status icon uses public [NSStatusItem.isVisible](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible) with the stable autosave name `ProperWM.StatusBarIcon`, so AppKit preserves visibility across launches. Do not reset visibility on startup or ordinary activation. Handle [Finder reopen events](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)) by showing the existing status item and returning false to suppress default window creation. Reopening an already running installed app restores the icon and its saved visible state without restarting the taskbar. Keep transient-install guidance unchanged.

No thumbnails or screen capture are allowed. A separate button has no hover popup. Combined groups and overflow use only window titles and application icons, including during file dragging. Closing the popup cancels pending row actions. ScreenCaptureKit and Screen Recording permission must not be reintroduced for these lists.

Accessibility remains necessary for window management. App Sandbox is incompatible with the retained cross-application Accessibility operations; see [Apple's restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox). Do not add privacy permissions to solve unrelated implementation issues. Existing fullscreen prediction observes global input events and recognizes specific keys, clicks, and gestures without recording typed text. Treat window titles and diagnostic reports as potentially sensitive; they must not be uploaded automatically.

## Deferred Steam ownership investigation

A read-only check found Steam's visible main window owned by `com.valvesoftware.steam.helper`, an accessory process, while `com.valvesoftware.steam` was the regular application. The inventory intentionally admits regular applications, so that helper window is currently absent. Admitting every helper window would also admit menus and utility surfaces. A fix needs explicit helper-to-parent ownership, window filtering, and separate routing of window actions and application Quit. That broader change is deferred; do not add privacy permissions or indiscriminately admit accessory processes as a shortcut.
