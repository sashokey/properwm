import Foundation

struct IdentityRuleResult {
    let accepted: Bool
    let normalizedTitle: String?
    let fallbackIdentity: IdentityFallback?
}

private protocol IdentityRule {
    func apply(to observation: SystemObservation) -> IdentityRuleResult?
}

struct IdentityFallback {
    let windowID: WindowID
    let confidence: Confidence
    let reason: String
}

struct IdentityRuleEngine {
    private let rules: [IdentityRule] = [
        FinderIdentityRule(),
        ChromiumIdentityRule(),
        WeChatIdentityRule(),
        FeishuIdentityRule()
    ]

    func evaluate(_ observation: SystemObservation) -> IdentityRuleResult {
        for rule in rules {
            if let result = rule.apply(to: observation) {
                return result
            }
        }

        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalizedWindowTitle(observation.title),
            fallbackIdentity: nil
        )
    }
}

private struct FinderIdentityRule: IdentityRule {
    func apply(to observation: SystemObservation) -> IdentityRuleResult? {
        guard observation.bundleIdentifier == "com.apple.finder" else { return nil }
        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalizedWindowTitle(observation.title) ?? "finder-window",
            fallbackIdentity: nil
        )
    }
}

private struct ChromiumIdentityRule: IdentityRule {
    private let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev"
    ]

    func apply(to observation: SystemObservation) -> IdentityRuleResult? {
        guard let bundleIdentifier = observation.bundleIdentifier,
              bundleIDs.contains(bundleIdentifier) else { return nil }

        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalizedChromiumTitle(observation.title) ?? "chromium-window",
            fallbackIdentity: nil
        )
    }

    private func normalizedChromiumTitle(_ title: String?) -> String? {
        guard var normalized = normalizedWindowTitle(title) else { return nil }

        normalized = normalized.replacingOccurrences(
            of: #" - 属于“[^”]+”群组"#,
            with: "",
            options: .regularExpression
        )

        let browserSuffixes = [
            " - google chrome canary",
            " - google chrome beta",
            " - google chrome dev",
            " - google chrome"
        ]

        for suffix in browserSuffixes where normalized.hasSuffix(suffix) {
            normalized.removeLast(suffix.count)
            break
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct WeChatIdentityRule: IdentityRule {
    private let bundleID = "com.tencent.xinWeChat"
    private let contentTitles: Set<String> = [
        "收藏",
        "favorites",
        "朋友圈",
        "moments",
        "图片和视频",
        "images and videos"
    ]

    func apply(to observation: SystemObservation) -> IdentityRuleResult? {
        guard observation.bundleIdentifier == bundleID else { return nil }

        let normalized = normalizedWindowTitle(observation.title)
        if let normalized, contentTitles.contains(normalized) {
            return IdentityRuleResult(accepted: false, normalizedTitle: normalized, fallbackIdentity: nil)
        }

        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalized ?? "wechat-window",
            fallbackIdentity: nil
        )
    }
}

private struct FeishuIdentityRule: IdentityRule {
    private let bundleIDs: Set<String> = [
        "com.electron.lark",
        "com.feishu.app",
        "com.bytedance.lark"
    ]

    func apply(to observation: SystemObservation) -> IdentityRuleResult? {
        guard let bundleIdentifier = observation.bundleIdentifier,
              bundleIDs.contains(bundleIdentifier) else { return nil }

        let normalized = normalizedWindowTitle(observation.title)
        let missingAXBounds = observation.source == .accessibility && observation.bounds == nil
        if let normalized, normalized != "飞书", !missingAXBounds {
            return IdentityRuleResult(
                accepted: true,
                normalizedTitle: normalized,
                fallbackIdentity: nil
            )
        }

        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalized ?? "feishu-app",
            fallbackIdentity: IdentityFallback(
                windowID: WindowID(rawValue: "app-\(bundleIdentifier)-pid-\(observation.pid)"),
                confidence: .medium,
                reason: "feishu-app-fallback"
            )
        )
    }
}
