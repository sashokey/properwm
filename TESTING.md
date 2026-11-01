# Verification

Tests describe the agreed behavior and independently observed reference scenarios. A failing assertion is a reason to investigate the implementation, not to weaken the expectation. Change an expectation only when the requirement or verified reference behavior changes, and explain why in the commit.

## Automated checks

Run the tooling checks, ordinary `xcodebuild test` with coverage, deployment-availability checks, and an arm64 Release build before publishing. CI also validates the release ZIP, signature, bundle identity, legal notices, architecture, deployment minimum, and checksums. Test and build logs must be retained when a check fails.

Use the newest stable Xcode and the newest available macOS. Local builds and tests are supported. Keep DerivedData and XCTest runtime data in a location Xcode can access; a background test runner may be denied access to a test bundle inside a protected Documents folder even when compilation succeeds. Do not change system privacy settings to work around this silently.

The suite covers:

- Window identity, inventory admission, minimized/hidden retention, native tabs, activation, focus handoff, and permission recovery.
- System-only initial permission prompting, continued waiting without a guide or repeated prompt, late grants, grants arriving during startup, and quitting before a grant. Confirmed runtime recovery and transient-install guides remain covered separately.
- Display attribution, topology changes, fullscreen prediction, and maximized-window clearance.
- Separate labeled buttons, content-sized short captions including the exact `.` reference, the measured 74-point compressed width for long captions, pixel rounding, combining under crowding, expansion after space returns, and accessible overflow.
- Whole-application group moves selected by the dragged leading/trailing edge crossing the neighboring group midpoint, unequal widths and different grab positions, stable repeated pointer events, round trips without persistence, preserved member order, mouse-up outside, Escape cancellation, and windows/apps or available width changing during a drag.
- No hover popup for separate buttons; icon/title lists for combined groups and overflow only.
- Native AppKit context-menu items and action dispatch, exact-window activation and close actions, Close all windows for a combined group, and Quit as a separate application action.
- File-drag hover activation, cancelled delays, stale targets, and list disposal.
- Detached AppKit rendering and input routing through an injected popup presenter. These tests must never display windows over the user's desktop or request screen capture. Native mouse-tracking checks may attach views to a panel that is never ordered on screen. Detached image rendering checks control geometry and content; it does not establish WindowServer glass refraction or transparency against the real desktop.
- Native controls with preserved icon/text alignment, neutral hover/active feedback, lower indicators, animated-state settling, Reduce Motion, transparent native list backgrounds, native table mouse tracking, keyboard scrolling and exact-row close dispatch.
- The manually observed Windows state hierarchy, applied to both AppKit appearances: similar hover/active body fill, stronger active edge, stronger fill on active hover, and darker held presses. The active underline is 11 by 2 points with a one-point bottom gap, centered beneath the icon and aligned at 1x and 2x backing scales.
- The ordered Open at Login / Hide Status Bar Icon / Quit menu, checked visibility toggling in both directions, native-restored visibility, icon restoration, and independent login/quit actions.
- Launch-at-login state, localization, debug-switch registration, stable toolchain selection, release publication, and artifact cleanup.

Coverage reports identify untested paths; a count or percentage alone does not establish correct behavior. Automated tests cannot establish real Accessibility interoperability, native WindowServer animation, or hot-plug behavior on every Mac.

## Mac acceptance

Use the app from the exact tested commit. Verify real desktop interactions only during an explicitly agreed test session; ordinary automated checks remain in the background.

| Scenario | Expected result |
| --- | --- |
| First launch | Only the native Accessibility prompt appears; no ProperWM permission window or extra Dock presence. No Screen Recording request. |
| Initial permission still missing | Waiting, denial, and elapsed time do not open a guide or repeat the system prompt. A later grant starts the taskbar once without relaunching; Quit prevents a delayed startup. |
| Transient installation or confirmed recovery failure | Show the relevant explanation for the actual problem. Do not infer a broken permission record from initial waiting alone. |
| Running app without windows | No launcher or pinned button appears. |
| Several windows of one app | Separate labeled buttons while space remains, adjacent in stable discovery order. |
| Activate, minimize, restore, rename, close, create | Surviving siblings keep their order; a new window joins its app group. |
| Crowding and freeing space | Long buttons shrink to the measured 74-point limit before combining. Short captions keep their content-sized widths. Groups separate again when space permits. |
| Group dragging and cancellation | The whole group stays inside the 32-point bar even when the pointer leaves it. A wide group swaps with a narrow neighbor when its edge crosses that neighbor's midpoint, regardless of which member or side was grabbed. Its members cannot be reordered independently. Escape or release outside restores the original order. |
| Separate-window click | Activate/restore the exact window; clicking the active window minimizes it. |
| Separate-window hover | Neutral Apple selection color within the Windows button shape. Hover must not overpower active: similar fill, stronger active edge and 11-by-2-point underline; active hover increases fill, and held press darkens it. The lower inactive dot is 4 by 2; both sit one point above the button bottom. No solid accent-filled button or nested glass. Smooth transitions; immediate changes under Reduce Motion. No popup, tooltip, thumbnail, or extra title. |
| Combined-group click/hover | Native Apple rows over public Liquid Glass, with the preserved 216-point width, 40-point rows, icon/title/close placement, and window order. No captured window images. |
| Overflow | Remaining windows stay reachable through an icon/title list. |
| Individual context menu | Native macOS menu: Close window, then Quit. Closing a window does not quit the app. |
| Combined context menu | Native macOS menu: Close all windows, then Quit. Window actions affect the represented display's group. |
| Unsaved documents | Normal application confirmation is honored; Quit never force-terminates the target. |
| Finder file drag over a separate button | Delayed restoration/activation; leaving early cancels it. ProperWM does not accept or open the file. |
| Finder file drag over a combined button | Open the icon/title list; hovering a row restores that exact window so the file can be dropped into it. |
| Fixed bar geometry | Full display width, attached to the bottom, 32 points high; first button starts 10 points from the left. |
| Retina, light/dark, accessibility display options | Geometry follows scale; system font and public Liquid Glass remain legible. |
| Background/menu-bar menu | Open at Login, Hide Status Bar Icon, separator, then Quit, which exits ProperWM normally. No size setting or native Dock controls. |
| Hide status icon and restart | The icon disappears while taskbar operation continues; the choice survives application restart and login/reboot. |
| Reopen the running app from Applications | The same status item reappears; its visible state is saved. No second taskbar instance or new document window appears. |
| Open the taskbar menu while the icon is hidden | Hide Status Bar Icon stays enabled and checked. Selecting it restores the icon and clears the checkmark; selecting it again hides the icon. Opening or refreshing the menu alone does not change visibility. Open at Login and Quit remain independent. |
| Maximize, restore, manual move/resize | Maximized windows avoid the 32-point bar; manual geometry remains respected. |
| Two displays and moving windows | Each bar shows windows on that display; combining is calculated separately for its available width. |
| Disconnect/reconnect, sleep/wake | No stale panels, duplicate buttons, or inaccessible windows after attribution settles. |
| Fullscreen and Spaces transitions | The bar prehides without flashing and returns after the transition; pending popups/actions are cancelled. |
| Accessibility revoked/restored | Panels and pending actions suspend safely; operation resumes after permission recovery. |
| Native Dock | Its preferences and process remain untouched. |

macOS 26 remains the deployment minimum without a dedicated compatibility matrix. Automated testing uses the newest hosted macOS available in GitHub Actions; physical Mac acceptance uses the newest installed macOS. Record OS, scale, display arrangement, version, source commit, steps, and observed results for failures.
