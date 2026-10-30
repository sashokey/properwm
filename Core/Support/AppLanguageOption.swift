import Foundation

/// 界面语言选单的档位（2026-09-01 由三档收成两档、删掉「跟随系统」，owner 拍板；
/// 2026-09-24 扩到六档，加繁中 / 日 / 德 / 法；三档那版见 `Docs/27`）。
/// Sixteen tiers since Russian / Turkish / Hindi / Vietnamese joined: Spanish and Portuguese
/// each ship two regional files (`es` + `es-419`, `pt-BR` + `pt-PT`) so every region sees the
/// system words of its own Mac.
///
/// 机制：写**应用自己域**的 `AppleLanguages`——这正是 macOS 13+「系统设置 → 通用 →
/// 语言与地区 → 应用程序」逐 App 语言写的同一个键，两条路互通，顺带把逐 App 语言
/// 能力带到了 macOS 12。**下次启动生效**：SwiftUI + 手搭 AppKit 菜单 + 多个常驻
/// NSHostingView 的热切换要重建所有面板，不值得；业界惯例也是重启。
///
/// ⚠️ **删掉的是选项，不是机制。** 「跟随系统」= 该键不存在，而这仍然是**没选过语言的人
/// 的真实状态**：他们的界面照旧由 macOS 按系统语言决定，一个字都没变。选单只是把
/// 「此刻实际生效的是哪一档」显示出来，读取路径**绝不回写**——一旦有人在读的时候顺手
/// `set`，就等于替所有从没选过的用户把语言钉死，英文系统装上的人会被钉在推断值上。
/// 只有用户主动点选才写键。
///
/// 档位顺序就是选单顺序：先中文两档，再英文，再按 `.lproj` 加入的顺序。
enum AppLanguageOption: String, CaseIterable, Equatable {
    case zhHans
    case zhHant
    case english
    case japanese
    case german
    case french
    case spanish
    case spanishLatinAmerica
    case portugueseBrazil
    case portuguesePortugal
    case italian
    case korean
    case russian
    case turkish
    case hindi
    case vietnamese

    /// 当前该显示哪一档。
    ///
    /// - `appDomainValue`: 从**本 app 域**读出的 `AppleLanguages`。⚠️ 调用方不能用
    ///   `UserDefaults.standard.array(forKey:)` 取值——它会继承全局域（系统语言列表永远非空），
    ///   分不清「没设过」和「显式设置」。要用 `CFPreferencesCopyAppValue` /
    ///   `persistentDomain(forName:)` 取本域值传进来。
    /// - `effectiveLocalization`: 此刻**真正加载的那份 `.lproj`**（`Bundle.main.preferredLocalizations.first`）。
    ///   没设过、或域里是我们没有的语言（用户在系统设置里给本 app 选了阿拉伯语这类）时按它回答：
    ///   a language we do not ship really falls back to English, so the menu shows English too.
    ///
    /// **兜底方向是英文，不是中文**：只有认得出的语言码才命中对应档。写反了会让英文系统的用户
    /// 在选单里看到「简体中文」——单测钉的就是这一条。
    static func current(appDomainValue: [String]?, effectiveLocalization: String) -> AppLanguageOption {
        if let explicit = appDomainValue?.first, let option = option(matching: explicit) {
            return option
        }
        return option(matching: effectiveLocalization) ?? .english
    }

    /// 把一个语言码（`zh-Hans` / `zh-TW` / `zh_HK` / `ja-JP` / `de` / `fr-CA` / `en-US` …）
    /// 归到我们有的档；认不出返回 nil，由调用方决定兜底。
    ///
    /// 繁中的判定要走在「zh 开头」之前：`zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO` 都归繁中，
    /// 其余 `zh` 开头（`zh` / `zh-Hans` / `zh-CN` / `zh-SG`）归简中。香港系统的
    /// 语言码是 `zh-Hant-HK` / `zh-HK`，两种写法都要认。
    static func option(matching code: String) -> AppLanguageOption? {
        let normalized = code.lowercased().replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first else { return nil }
        switch language {
        case "zh":
            let tags = Set(parts.dropFirst())
            let isTraditional = !tags.isDisjoint(with: ["hant", "tw", "hk", "mo"])
            return isTraditional ? .zhHant : .zhHans
        case "en": return .english
        case "ja": return .japanese
        case "de": return .german
        case "fr": return .french
        case "it": return .italian
        case "ko": return .korean
        case "ru": return .russian
        case "tr": return .turkish
        // Hindi in Latin script (`hi-Latn`) is a language of its own to the system, which loads
        // English for it rather than our Devanagari `hi.lproj`.
        case "hi": return parts.contains("latn") ? nil : .hindi
        case "vi": return .vietnamese
        case "es": return regionalVariant(of: code, among: [.spanish, .spanishLatinAmerica])
        case "pt": return regionalVariant(of: code, among: [.portugueseBrazil, .portuguesePortugal])
        default: return nil
        }
    }

    /// Which of a language's regional files the system would load for `code` (`es-MX` → `es-419`,
    /// `pt-AO` → `pt-PT`). Asks Foundation's own matcher instead of keeping a list of region codes,
    /// so the menu names the same file the system actually loads. Only call it once the language
    /// subtag is known to match: for an unrelated code the matcher still returns its first candidate.
    private static func regionalVariant(of code: String, among variants: [AppLanguageOption]) -> AppLanguageOption? {
        let identifiers = variants.map(\.localizationIdentifier)
        guard let match = Bundle.preferredLocalizations(from: identifiers, forPreferences: [code]).first else {
            return variants.first
        }
        return variants.first { $0.localizationIdentifier == match } ?? variants.first
    }

    /// 该写进 `AppleLanguages` 的值，同时也是 `.lproj` 的目录名。每档都是显式值——
    /// 「删键」那条路随「跟随系统」一起没了。
    var appleLanguagesValue: [String] {
        [localizationIdentifier]
    }

    /// 对应的 `.lproj` 名，与 `knownRegions` 和 `Localizable.xcstrings` 里的语言块一致。
    var localizationIdentifier: String {
        switch self {
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .english: return "en"
        case .japanese: return "ja"
        case .german: return "de"
        case .french: return "fr"
        case .spanish: return "es"
        case .spanishLatinAmerica: return "es-419"
        case .portugueseBrazil: return "pt-BR"
        case .portuguesePortugal: return "pt-PT"
        case .italian: return "it"
        case .korean: return "ko"
        case .russian: return "ru"
        case .turkish: return "tr"
        case .hindi: return "hi"
        case .vietnamese: return "vi"
        }
    }

    /// 展示名。**每档都用它自己的语言写死**（语言选单的通用惯例），所以这里没有任何
    /// 需要本地化的字符串——every UI language shows the same rows. The two Spanish and two
    /// Portuguese rows carry their region so the menu never shows two identical names.
    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español (España)"
        case .spanishLatinAmerica: return "Español (Latinoamérica)"
        case .portugueseBrazil: return "Português (Brasil)"
        case .portuguesePortugal: return "Português (Portugal)"
        case .italian: return "Italiano"
        case .korean: return "한국어"
        case .russian: return "Русский"
        case .turkish: return "Türkçe"
        case .hindi: return "हिन्दी"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}
