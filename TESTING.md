# Verification

## Automated checks

Every CI run must pass before its app artifact is uploaded:

- Release workflow validation, duplicate-tag rejection, checksum rejection, and publication only after successful asset uploads.
- Localization completeness and format placeholders.
- Debug-switch registration and absence of unused switches.
- Debug build and XCTest execution with code coverage.
- Deployment-availability checks for the macOS 26 minimum.
- Universal Release build for arm64 and x86_64.
- Release binary checks for both architectures, stripped symbols, and absence of coverage instrumentation.
- Bundle identity, version, legal notices, absent updater and Automation declarations, ad-hoc signature, and ZIP checksums.

The suite covers window identity, inventory admission, minimized/hidden window retention, native tab groups, activation and focus handoff, optimistic actions, permission recovery, display attribution/topology, fullscreen prediction, window-height avoidance, persistent ordering, reorder carrier lifecycle, panel geometry, tooltip placement, and launch-at-login coordination.

The pruning adds regressions for window-only projection, fixed settings, display-topology refresh, order persistence/absence grace, cancellation and return anchors, centered taskbar geometry, rejected app-only actions, and the supported activation-recovery matrix.

Coverage is measured and uploaded; no percentage or complete UI coverage is claimed in advance. A CI runner cannot verify real Accessibility interactions, monitor hot-plug behavior, or all WindowServer animations.

## Mac acceptance checklist

Use the app ZIP from the exact successful CI commit. Do not compile locally.

| Scenario | Expected result |
| --- | --- |
| First launch and permission grant | Only the necessary permission window appears; taskbar starts after permission is granted. |
| Application running without windows | No taskbar button for that application. |
| Several windows, minimized windows, native tabs | Each physical window remains addressable; native tabs keep their established grouping. |
| Click inactive/minimized/active window | Activate or restore the target; clicking an active window minimizes it. |
| Window context menu | Only Show/Restore, Minimize when applicable, and Close Window. Closing does not quit the application. |
| Drag to reorder, cancel, regrab during return | Order remains stable, no duplicate/missing buttons, animation settles correctly. |
| Restart during the same system boot | Manual order is restored for surviving window identities. |
| Background/menu-bar context menu | Only Open at Login and Taskbar Size. |
| Resize with slider and grip | Taskbar stays centered and maximized-window clearance follows its height. |
| Maximize, restore, manually move/resize | Maximized windows avoid the taskbar; previous geometry and manual changes remain respected. |
| Two displays and window moved between them | Separate bars show their own windows; no duplicate or missing window after attribution settles. |
| Disconnect/reconnect display, sleep/wake | Bars follow current topology without stale panels. |
| Fullscreen via green button, Control-Command-F, Space keys/gesture | Taskbar prehides without flashing and returns after leaving fullscreen. |
| Hover | Application names appear; window labels remain stable. |
| Open at Login | State reflects macOS approval; installed ProperWM launches at login. |
| Revoke and restore Accessibility | Panels suspend safely; permission recovery restores operation. |
| Native Dock | Its preferences and process remain untouched by ProperWM. |

File-drag hover activation is outside this cleanup. It has not been added.

Automated results apply to the runner OS and hardware. The deployment minimum is macOS 26; compatibility is retained without a separate macOS 26 test matrix or dedicated workarounds. Automated and manual acceptance testing targets the newest macOS available in GitHub Actions and on the test Mac. Intel runtime behavior, real multi-display geometry, and visual smoothness are not established by a successful cross-compilation. Record OS, app version, source commit, steps, and observed behavior for failures.
