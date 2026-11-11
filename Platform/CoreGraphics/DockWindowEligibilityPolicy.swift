import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

struct DockWindowEligibilityPolicy {
    static let selfBundleIdentifier = "io.github.sashokey.properwm"

    enum Decision: Equatable {
        case keep
        case filter
    }

    enum Verdict: String, Equatable, CaseIterable {
        case eligible, selfApp, transparent, invalidGeometry
        case systemSurfaceBundle, systemSurfaceAppName, systemSurfaceExtension
        case systemSurfaceExecutable, systemSurfaceTitle
        case prohibitedPolicy, accessoryWithoutTitleOrTooSmall, emptyTitleNotStandardOrTooSmall
        case belowNormalLayer, feishuNotMainWindow, finderNotTrackable, notMainWindow
    }

    struct Candidate {
        let bundleIdentifier: String?
        let appName: String
        let title: String?
        let subrole: String?
        let bounds: CGRect?
        let alpha: Double?
        let activationPolicy: NSApplication.ActivationPolicy
        let executablePath: String?
        var allowsUntitledWindow = false
    }

    func evaluate(_ candidate: Candidate) -> Decision {
        verdict(candidate) == .eligible ? .keep : .filter
    }

    func verdict(_ candidate: Candidate) -> Verdict {
        let verdict = classify(candidate)
        if verdict == .eligible, let bounds = candidate.bounds, !WindowFrameMatchPolicy.isValid(bounds) { return .invalidGeometry }
        return verdict
    }

    private func classify(_ candidate: Candidate) -> Verdict {
        if candidate.bundleIdentifier == Self.selfBundleIdentifier {
            return .selfApp
        }

        if candidate.alpha == 0 {
            return .transparent
        }

        if FeishuBundleRules.isFeishu(bundleIdentifier: candidate.bundleIdentifier) {
            return .eligible
        }

        if let rejection = systemSurfaceVerdict(candidate) { return rejection }

        switch candidate.activationPolicy {
        case .prohibited:
            return .prohibitedPolicy
        case .accessory:
            guard hasTitle(candidate.title),
                  hasMinimumFrame(candidate.bounds) else {
                return .accessoryWithoutTitleOrTooSmall
            }
            return .eligible
        case .regular:
            if hasTitle(candidate.title) {
                return .eligible
            }
            guard candidate.subrole == (kAXStandardWindowSubrole as String) || candidate.allowsUntitledWindow,
                  hasMinimumFrame(candidate.bounds) else {
                return .emptyTitleNotStandardOrTooSmall
            }
            return .eligible
        @unknown default:
            return hasTitle(candidate.title) ? .eligible : .emptyTitleNotStandardOrTooSmall
        }
    }

    private func systemSurfaceVerdict(_ candidate: Candidate) -> Verdict? {
        if let bundleIdentifier = candidate.bundleIdentifier,
           filteredBundleIdentifiers.contains(bundleIdentifier) {
            return .systemSurfaceBundle
        }

        if filteredAppNames.contains(candidate.appName) {
            return .systemSurfaceAppName
        }

        if let executablePath = candidate.executablePath {
            if executablePath.contains(".appex/") {
                return .systemSurfaceExtension
            }

            if filteredExecutablePathFragments.contains(where: { executablePath.contains($0) }) {
                return .systemSurfaceExecutable
            }
        }

        if let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           filteredTitles.contains(title) {
            return .systemSurfaceTitle
        }

        return nil
    }

    private func hasTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func hasMinimumFrame(_ bounds: CGRect?) -> Bool {
        guard let bounds else { return false }
        return bounds.width >= 80 && bounds.height >= 40
    }

    private let filteredBundleIdentifiers: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter"
    ]

    private let filteredAppNames: Set<String> = [
        "Notification Center",
        "Control Center"
    ]

    private let filteredTitles: Set<String> = [
        "Notification Center",
        "通知中心"
    ]

    private let filteredExecutablePathFragments: [String] = [
        "ThemeWidgetControlViewService.xpc",
        "ChronoCore.framework/Support/chronod",
        "DockHelper.xpc",
        "com.apple.dock.extra.xpc",
        "ControlCenterHelper.xpc"
    ]
}

/// Production adapter for the inventory-first AppTracker path. Keeping the AX shape check and the
/// shared deny policy in one pure decision prevents incomplete metadata wiring from opening a seat.
struct AppTrackerWindowEligibility {
    struct Application: Sendable {
        let bundleIdentifier: String?
        let appName: String
        let activationPolicy: NSApplication.ActivationPolicy
        let executablePath: String?
        let bundleURL: URL?

        init(bundleIdentifier: String?, appName: String, activationPolicy: NSApplication.ActivationPolicy,
             executablePath: String?, bundleURL: URL? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.appName = appName
            self.activationPolicy = activationPolicy
            self.executablePath = executablePath
            self.bundleURL = bundleURL
        }

        var isEmbeddedHelper: Bool {
            guard activationPolicy == .accessory,
                  bundleIdentifier != DockWindowEligibilityPolicy.selfBundleIdentifier,
                  let bundleURL, bundleURL.isFileURL, bundleURL.pathExtension.lowercased() == "app" else { return false }
            return bundleURL.deletingLastPathComponent().pathComponents.contains("Contents")
        }

        var canOwnTaskbarWindows: Bool {
            guard bundleIdentifier != DockWindowEligibilityPolicy.selfBundleIdentifier else { return false }
            switch activationPolicy {
            case .regular: return true
            case .accessory:
                guard let bundleURL, bundleURL.pathExtension.lowercased() == "app" else { return false }
                return !bundleURL.deletingLastPathComponent().pathComponents.contains("Contents")
            case .prohibited: return false
            @unknown default: return false
            }
        }
    }

    private let policy = DockWindowEligibilityPolicy()

    func isEligible(
        title: String?,
        role: String?,
        subrole: String?,
        bounds: CGRect?,
        alpha: Double?,
        isMinimized: Bool,
        isBelowNormalLayer: Bool,
        application: Application, isModal: Bool? = nil, isTopLevel: Bool? = nil,
        isNativeRoot: Bool = false, isFocusedWindow: Bool = false, isKnownWindow: Bool = false
    ) -> Bool {
        verdict(title: title, role: role, subrole: subrole, bounds: bounds, alpha: alpha,
                isMinimized: isMinimized, isBelowNormalLayer: isBelowNormalLayer,
                application: application, isModal: isModal, isTopLevel: isTopLevel,
                isNativeRoot: isNativeRoot, isFocusedWindow: isFocusedWindow, isKnownWindow: isKnownWindow) == .eligible
    }

    func verdict(
        title: String?, role: String?, subrole: String?, bounds: CGRect?, alpha: Double?,
        isMinimized: Bool, isBelowNormalLayer: Bool, application: Application,
        isModal: Bool? = nil, isTopLevel: Bool? = nil,
        isNativeRoot: Bool = false, isFocusedWindow: Bool = false, isKnownWindow: Bool = false
    ) -> DockWindowEligibilityPolicy.Verdict {
        // Desktop-layer windows (widgets, wallpaper surfaces) are not windows the user switches
        // to. No default on the parameter: an omitted layer check must not compile.
        guard !isBelowNormalLayer else { return .belowNormalLayer }
        let customWindow = AXTaskbarWindowRules.isCustomWindowRoot(role: role, subrole: subrole, bounds: bounds,
            title: title, isModal: isModal, isTopLevel: isTopLevel,
            isNativeRoot: isNativeRoot, isFocusedWindow: isFocusedWindow, isKnownWindow: isKnownWindow)
        let candidate = DockWindowEligibilityPolicy.Candidate(
            bundleIdentifier: application.bundleIdentifier,
            appName: application.appName,
            title: title,
            subrole: subrole,
            bounds: bounds,
            alpha: alpha,
            activationPolicy: application.activationPolicy,
            executablePath: application.executablePath,
            allowsUntitledWindow: customWindow
        )
        let verdict = policy.verdict(candidate)
        guard verdict == .eligible else { return verdict }

        if FeishuBundleRules.isFeishu(bundleIdentifier: application.bundleIdentifier) {
            return AXTaskbarWindowRules.isMainWindow(role: role, subrole: subrole, bounds: bounds, isModal: isModal, isTopLevel: isTopLevel)
                ? .eligible : .feishuNotMainWindow
        }

        if FinderWindowRules.isFinder(bundleIdentifier: application.bundleIdentifier) {
            return FinderWindowRules.isTrackable(
                title: title,
                role: role,
                subrole: subrole,
                bounds: bounds,
                isMinimized: isMinimized
            ) ? .eligible : .finderNotTrackable
        }

        return customWindow || AXTaskbarWindowRules.isMainWindow(role: role, subrole: subrole, bounds: bounds, isModal: isModal, isTopLevel: isTopLevel)
            ? .eligible : .notMainWindow
    }
}

enum FeishuBundleRules {
    private static let bundleIdentifiers: Set<String> = [
        "com.electron.lark",
        "com.feishu.app",
        "com.bytedance.lark"
    ]

    static func isFeishu(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }
}

enum AXTaskbarWindowRules {
    static func isCustomWindowRoot(role: String?, subrole: String?, bounds: CGRect?, title: String?,
                                   isModal: Bool?, isTopLevel: Bool?, isNativeRoot: Bool,
                                   isFocusedWindow: Bool, isKnownWindow: Bool) -> Bool {
        role == kAXWindowRole as String && subrole == kAXUnknownSubrole as String
            && isModal == false && isTopLevel == true && isNativeRoot && hasReasonableFrame(bounds)
            && (isKnownWindow || isFocusedWindow || title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    enum Decision: Equatable {
        case mainWindow
        case unconfirmedMainWindow
        case rejected

        var isAccepted: Bool {
            self != .rejected
        }
    }

    static func decision(role: String?, subrole: String?, bounds: CGRect?,
                         isModal: Bool? = nil, isTopLevel: Bool? = nil) -> Decision {
        guard role == (kAXWindowRole as String) else { return .rejected }

        if subrole == (kAXStandardWindowSubrole as String) {
            return .mainWindow
        }

        if subrole == kAXDialogSubrole as String, isModal == false, isTopLevel == true, hasReasonableFrame(bounds) {
            return .mainWindow
        }

        guard subrole == nil, hasReasonableFrame(bounds) else {
            return .rejected
        }

        return .unconfirmedMainWindow
    }

    static func isMainWindow(role: String?, subrole: String?, bounds: CGRect?,
                             isModal: Bool? = nil, isTopLevel: Bool? = nil) -> Bool {
        decision(role: role, subrole: subrole, bounds: bounds, isModal: isModal, isTopLevel: isTopLevel).isAccepted
    }

    private static func hasReasonableFrame(_ bounds: CGRect?) -> Bool {
        guard let bounds else { return false }
        return bounds.width >= 80 && bounds.height >= 40
    }
}
