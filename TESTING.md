# Verification

Tests describe the agreed behavior and independently observed reference scenarios. A failing assertion is a reason to investigate the implementation, not to weaken the expectation. Change an expectation only when the requirement or verified reference behavior changes, and explain why in the commit.

## Automated checks

Run the tooling checks, ordinary `xcodebuild test` with coverage, constrained-executor lifecycle checks, deployment-availability checks, and an arm64 Release build before publishing. CI also validates the release ZIP, signature, bundle identity, legal notices, architecture, deployment minimum, and checksums. Test and build logs must be retained when a check fails.

Use the newest stable Xcode and the newest available macOS. Local builds and tests are supported. Keep DerivedData and XCTest runtime data in a location Xcode can access; a background test runner may be denied access to a test bundle inside a protected Documents folder even when compilation succeeds. Do not change system privacy settings to work around this silently.

The suite covers:

- Window identity, inventory admission, minimized/hidden retention, native tabs, activation, focus handoff, and permission recovery.
- Ordered window-command execution, cancellation between external operations, rapid minimize/activate replacement, independent close requests, and draining in-flight commands across runtime stop/restart. Tests assert external effects as well as published state.
- Background AX observer creation and registration, windows discovered during registration, stop or window retirement/replacement during a blocked call, subscription cleanup, and rejection of late callbacks from a replaced session.
- Failed or unverifiable frame restoration stays pending; bounded retries complete confirmed writes and preserve unresolved state. Permission uncertainty cancels and drains restoration without dropping saved geometry; cancellation after a read prevents the next write. Changed process identities and user-moved windows are never overwritten.
- Unknown fullscreen observations preserve the previous state; periodic checks also run while the bar is visible. Geometry events trigger coalesced checks without input observation.
- Current-Space filtering per display, fullscreen-window removal from its former Desktop, shared Spaces, retained minimized-window membership, failed Space reads, coalesced background reads, stop/restart, and preserved manual order. Combined close actions only contain windows on the visible Space. Display-only inventory changes refresh Space membership without waiting for the periodic fallback. Two offscreen presenters exercise transfer in both directions with polling disabled; rapid transfers coalesce, stale reads cannot overwrite current membership, and same-display geometry/title/focus changes do not trigger extra Space reads.
- Native transient panels hide in Mission Control; a windowed AX result from system UI cannot reveal a panel while its display remains in a fullscreen Space.
- No-screen startup, display disconnect/reconnect, and separate handling of missing display UUIDs. Native panel creation is replaced in lifecycle tests so no window is shown.
- Bounded process-generation caching and cleanup after process termination.
- System-only initial permission prompting, continued waiting without a guide or repeated prompt, late grants, grants arriving during startup, and quitting before a grant. Confirmed runtime recovery and transient-install guides remain covered separately.
- Display attribution, topology changes, state-based fullscreen visibility, and maximized-window clearance. The measured Chrome fullscreen-return case keeps its menu-bar inset even when NSScreen reports a larger visible frame; recognition accepts both system layouts without moving the window top or relaxing the other edge checks. Side/bottom Dock reservations and camera safe areas remain covered. Suppression recovery replays the measured return-to-Desktop frame, its first lift, and a subsequent maximize with a different top inset. Changed eligible geometry retains the retry budget, including delayed changes and repeated alternation; floating frames and permission-freeze suppression remain protected. Restoration uses the newly accepted geometry.
- Separate labeled buttons, content-sized short captions including the exact `.` reference, the measured 74-point compressed width for long captions, pixel rounding, combining under crowding, expansion after space returns, and accessible overflow.
- Whole-application group moves selected by the dragged leading/trailing edge crossing the neighboring group midpoint, unequal widths and different grab positions, stable repeated pointer events, round trips without persistence, preserved member order, mouse-up outside, Escape cancellation within ProperWM, and windows/apps or available width changing during a drag.
- No hover popup for separate buttons; icon/title lists for combined groups and overflow only.
- Popup dismissal on its own window losing keyboard focus, own-view pointer/drag presence, and stale focus notifications from replaced panels.
- Native AppKit context-menu items and action dispatch, exact-window activation and close actions, Close all windows for a combined group, and Quit as a separate application action.
- File-drag hover activation, cancelled delays, stale targets, and list disposal.
- Detached AppKit rendering and input routing through an injected popup presenter. These tests must never display windows over the user's desktop or request screen capture. Native mouse-tracking checks may attach views to a panel that is never ordered on screen. Detached image rendering checks control geometry and content; it does not establish WindowServer glass refraction or transparency against the real desktop.
- Native controls with preserved icon/text alignment, neutral hover/active feedback, lower indicators, animated-state settling, Reduce Motion, transparent native list backgrounds, native table mouse tracking, keyboard scrolling and exact-row close dispatch.
- The manually observed Windows state hierarchy, applied to both AppKit appearances: similar hover/active body fill, stronger active edge, stronger fill on active hover, and darker held presses. The active underline is 11 by 2 points with a one-point bottom gap, centered beneath the icon and aligned at 1x and 2x backing scales.
- Bottom-edge hit testing and hover tracking at 1x and 2x, exact-window clicks, combined/overflow lists, file-hover activation, preserved horizontal gaps, and cancelled clicks outside the bar. Raster comparisons verify that larger hit targets do not change the 28-point visible buttons.
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
| Group dragging and cancellation | The whole group stays inside the 32-point bar even when the pointer leaves it. A wide group swaps with a narrow neighbor when its edge crosses that neighbor's midpoint, regardless of which member or side was grabbed. Its members cannot be reordered independently. Release outside restores the original order. Esc is handled only when delivered to ProperWM; no keyboard events from other apps are observed. |
| Separate-window click | Activate/restore the exact window; clicking the active window minimizes it. |
| Separate-window hover | Neutral Apple selection color within the Windows button shape. Hover must not overpower active: similar fill, stronger active edge and 11-by-2-point underline; active hover increases fill, and held press darkens it. The lower inactive dot is 4 by 2; both sit one point above the button bottom. No solid accent-filled button or nested glass. Smooth transitions; immediate changes under Reduce Motion. No popup, tooltip, thumbnail, or extra title. |
| Combined-group click/hover | Native Apple rows over public Liquid Glass, with the preserved 216-point width, 40-point rows, icon/title/close placement, and window order. No captured window images. |
| Overflow | Remaining windows stay reachable through an icon/title list. |
| Click outside a window list | A clicked list closes when its own panel loses keyboard focus; hover/drag lists use their own pointer-exit grace period. No mouse events from other apps are monitored. |
| Individual context menu | Native macOS menu: Close window, then Quit. Closing a window does not quit the app. |
| Combined context menu | Native macOS menu: Close all windows, then Quit. Window actions affect the represented display's group. |
| Unsaved documents | Normal application confirmation is honored; Quit never force-terminates the target. |
| Finder file drag over a separate button | Delayed restoration/activation; leaving early cancels it. ProperWM does not accept or open the file. |
| Finder file drag over a combined button | Open the icon/title list; hovering a row restores that exact window so the file can be dropped into it. |
| Fixed bar geometry | Full display width, attached to the bottom, 32 points high; first button starts 10 points from the left. |
| Pointer at the bottom display edge | Buttons still highlight and respond to clicks, context menus, and file hover at the last screen pixel, including combined and overflow buttons. Visible button geometry stays at y=2, height=28; the extra two points are only an interaction area. Horizontal gaps and empty taskbar space remain background targets. |
| Retina, light/dark, accessibility display options | Geometry follows scale; system font and public Liquid Glass remain legible. |
| Background/menu-bar menu | Open at Login, Hide Status Bar Icon, separator, then Quit, which exits ProperWM normally. No size setting or native Dock controls. |
| Hide status icon and restart | The icon disappears while taskbar operation continues; the choice survives application restart and login/reboot. |
| Reopen the running app from Applications | The same status item reappears; its visible state is saved. No second taskbar instance or new document window appears. |
| Open the taskbar menu while the icon is hidden | Hide Status Bar Icon stays enabled and checked. Selecting it restores the icon and clears the checkmark; selecting it again hides the icon. Opening or refreshing the menu alone does not change visibility. Open at Login and Quit remain independent. |
| Chrome window created from fullscreen | Create a new Chrome window while another Chrome window is fullscreen, leave the new window's fullscreen Space, then maximize it on the Desktop with ProperWM. Check both a quick maximize immediately after its first height adjustment and another after a pause. Repeat maximize/restore: an earlier adjustment must not permanently suppress the new geometry. Its bottom clears the taskbar while its menu-bar inset, top, left and width remain unchanged. The fullscreen sibling is untouched. |
| Maximize, restore, manual move/resize | Maximized windows avoid the 32-point bar; manual geometry remains respected. Repeated maximization at user pace reapplies the reserved height. Titlebar double-clicks are handled by the target app; ProperWM no longer infers a request to restore a smaller frame from global click counts. |
| Two displays, Spaces and moving windows | Each bar shows windows on the current Space of that display, including minimized windows assigned there. Windows on other Spaces, including fullscreen Spaces, are omitted. Move a window between displays in both directions: its button appears on the destination without waiting for the periodic Space refresh, and unrelated buttons retain their manual order. Switching back restores the buttons in their manual order; grouping and close actions use only the visible windows. |
| Mission Control from Desktop or fullscreen | The taskbar is hidden on both monitors by native AppKit transient-window behavior. On leaving Mission Control, it returns on regular Desktops and stays hidden on fullscreen Spaces. No input observation is used. |
| Disconnect/reconnect, sleep/wake | No stale panels, duplicate buttons, or inaccessible windows after attribution settles. |
| Fullscreen and Spaces transitions | The bar follows actual window/Space state and returns after the transition; pending popups/actions are cancelled. A brief appearance during the transition animation is possible because input-based prehiding has been removed. |
| Accessibility revoked/restored | Panels and pending actions suspend safely; operation resumes after permission recovery. No global event tap or input monitor exists to retry or retain. Never revoke permission on the working desktop during automated tests. |
| Native Dock | Its preferences and process remain untouched. |

macOS 26 remains the deployment minimum without a dedicated compatibility matrix. Automated testing uses the newest hosted macOS available in GitHub Actions; physical Mac acceptance uses the newest installed macOS. Record OS, scale, display arrangement, version, source commit, steps, and observed results for failures.

## Accessory application admission

Run the inventory lifecycle tests with injected application metadata; fixtures must pass through the production activation-policy gate. A Stats-shaped standalone accessory bundle with a standard Dashboard window must be admitted through seed, scan, and launch retry. Reject ProperWM itself, prohibited processes, unknown accessory bundle ownership, and embedded helper bundles, including Steam's recorded nested helper layout. Preserve per-window filtering for empty, untitled, undersized, and floating utility surfaces. Closing and reopening a tracked accessory window must work through the window event read without periodic admission or an app-only taskbar button. No live permissions or desktop windows are required for these tests.

## Review regression coverage

Use the production lifecycle controllers with injected AX sessions, a monotonic clock, window probes, and restoration operations. Keep the test views offscreen and do not revoke live Accessibility permission.

- Geometry observer: blocked startup/registration/read, rapid app and focus changes, stop, stale callbacks, transient read and registration failure, retry recovery, and absence of immediate retry loops.
- Context isolation: remove a display, change its geometry, reorder displays, retain unaffected sessions, and await a second cancelled writer while a first restoration is in flight.
- Quiet state: a long-settled session has no fast per-window queries; fast probes include only transitioning windows and expire after the response interval. Verify event-driven refresh and fallback discovery of external geometry changes with a fake clock and counted probe calls.
- Inventory: closing the last window leaves no synthetic card and retains the application observer; process churn releases mutation generations; a late response from an old process cannot consume a replacement process's in-flight read.
- Icons: unresolved lookup retries on launch and activation, repeated renders use the cache, resolver lifetime is independent of notifications, and icon recovery refreshes an existing button without an inventory update.

The constrained Swift-executor CI pass includes the geometry/context and icon regressions. Retain behavior tests for window order, native tabs, actions, rendering, display attribution, permissions, restoration, and the Chrome fullscreen-return geometry. Remove assertions only for intentionally removed app-only card contracts and unused model fields.
