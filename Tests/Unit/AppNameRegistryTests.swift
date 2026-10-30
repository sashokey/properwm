import XCTest
@testable import macos_dock_cc_v2

/// 消息区吸收判据「窗口标题 == 应用名」的名字侧。
///
/// 本组测试的存在理由是一次实机 bug（2026-08-11）：应用名过去每帧现查 LaunchServices，
/// 一次瞬时查空就让飞书和微信**同时**掉出吸收 → 两个 app 各自在消息区和实时区渲染一张卡
/// → 整行变宽把右边推走，且失配态会粘住到下一次无关重排。QQ 因为包内派生名里就有 `qq`
/// 而从未受影响——这个不对称正是定位根因的证据。
final class AppNameRegistryTests: XCTestCase {

    /// 可控的双加载器：包内名固定，运行名可以随时「抽风」。
    private final class Env {
        var bundleNames: [String: Set<String>] = [:]
        var runningNames: [String: String] = [:]
        private(set) var bundleLoadCount = 0
        private(set) var runningLoadCount = 0

        func makeRegistry() -> AppNameRegistry {
            AppNameRegistry(
                bundleNamesLoader: { [unowned self] bid in
                    self.bundleLoadCount += 1
                    return self.bundleNames[bid] ?? []
                },
                runningNameLoader: { [unowned self] bid in
                    self.runningLoadCount += 1
                    return self.runningNames[bid]
                }
            )
        }
    }

    // MARK: - 产品别名（2026-08-23）

    /// 英文界面的微信主窗口叫 `Weixin`：包内名只有 wechat、运行名是「微信」，三者都不等于它。
    /// 别名表必须在**两条**建条目的路径上都生效（先 matches / 先 observe）。
    func testProductAliasMatchesWeixinTitle() {
        let env = Env()
        env.bundleNames["com.tencent.xinWeChat"] = ["wechat"]
        env.runningNames["com.tencent.xinWeChat"] = "微信"
        let registry = env.makeRegistry()
        XCTAssertTrue(registry.matches(title: "Weixin", bundleID: "com.tencent.xinWeChat"))
        XCTAssertTrue(registry.matches(title: " weixin ", bundleID: "com.tencent.xinWeChat"), "别名同样走归一化")
        XCTAssertTrue(registry.matches(title: "微信", bundleID: "com.tencent.xinWeChat"), "别名是加法，原有名字不受影响")

        let observedFirst = env.makeRegistry()
        observedFirst.observe(name: "微信", for: "com.tencent.xinWeChat")
        XCTAssertTrue(observedFirst.matches(title: "Weixin", bundleID: "com.tencent.xinWeChat"))
    }

    func testProductAliasIsScopedToItsBundle() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        XCTAssertFalse(env.makeRegistry().matches(title: "Weixin", bundleID: "com.electron.lark"))
    }

    // MARK: - 本 bug 的回归锁

    /// 成功观测到一次运行名之后，LaunchServices 再怎么抽风都必须继续匹配。
    /// 这条挂了 = 飞书/微信重复成卡的 bug 回来了。
    func testObservedNameSurvivesLaterLookupFailure() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]   // 实测：中文名不在包内
        env.runningNames["com.electron.lark"] = "飞书"
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))

        // LaunchServices 抽风：查询开始返回 nil。
        env.runningNames.removeValue(forKey: "com.electron.lark")

        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"),
                      "已经记住的名字不能因为一次查询失败就丢掉")
    }

    /// 观测成功后不再查询——既是修复的一部分，也是每帧零 LaunchServices I/O 的依据。
    func testRunningLookupStopsAfterFirstSuccess() {
        let env = Env()
        env.bundleNames["com.tencent.xinWeChat"] = ["wechat"]
        env.runningNames["com.tencent.xinWeChat"] = "微信"
        let registry = env.makeRegistry()

        for _ in 0..<5 {
            XCTAssertTrue(registry.matches(title: "微信", bundleID: "com.tencent.xinWeChat"))
        }
        XCTAssertEqual(env.runningLoadCount, 1)
        XCTAssertEqual(env.bundleLoadCount, 1, "包内名也只读一次盘")
    }

    // MARK: - 自愈：残缺集合不能被当成完整缓存

    /// 冷启动第一帧恰好抽风时，不能把「只有包内名」的残缺集合永久钉死——
    /// 那会把一次瞬时故障变成永久故障，比修之前更糟。必须每次重试直到观测成功。
    func testKeepsRetryingUntilFirstSuccessfulObservation() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        XCTAssertEqual(env.runningLoadCount, 2, "还没观测成功就得继续重试")

        env.runningNames["com.electron.lark"] = "飞书"
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    /// 空串 / 纯空白的运行名不算观测成功，否则会把重试之路堵死。
    func testBlankRunningNameDoesNotCountAsObserved() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["lark"]
        env.runningNames["com.electron.lark"] = "   "
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        env.runningNames["com.electron.lark"] = "飞书"
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    // MARK: - 包内派生名这条独立的路（QQ 从不失配的原因）

    func testBundleDerivedNameMatchesWithoutAnySuccessfulLookup() {
        let env = Env()
        env.bundleNames["com.tencent.qq"] = ["qq"]     // 运行名永远查不到
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "QQ", bundleID: "com.tencent.qq"))
    }

    // MARK: - 外部直接投喂（NSWorkspace 启动通知白拿的名字）

    func testObserveSeedsBothBundleAndRunningNamesWithoutLookup() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        let registry = env.makeRegistry()

        registry.observe(name: "飞书", for: "com.electron.lark")

        XCTAssertEqual(registry.knownNames(for: "com.electron.lark"), ["feishu", "lark", "飞书"],
                       "投喂时必须把包内名一起带上，否则包内名再也补不回来")
        XCTAssertEqual(env.runningLoadCount, 0, "已经有权威名字了,不该再查")
    }

    func testObserveIsMonotonic() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = []
        let registry = env.makeRegistry()

        registry.observe(name: "Foo", for: "com.foo.bar")
        registry.observe(name: "福", for: "com.foo.bar")

        XCTAssertEqual(registry.knownNames(for: "com.foo.bar"), ["foo", "福"])
    }

    func testObserveIgnoresBlankName() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = ["bar"]
        env.runningNames["com.foo.bar"] = "Bar"
        let registry = env.makeRegistry()

        registry.observe(name: "  ", for: "com.foo.bar")
        // 空投喂不能算观测成功,否则真名字就再也补不上了。
        XCTAssertTrue(registry.matches(title: "Bar", bundleID: "com.foo.bar"))
    }

    // MARK: - 失效

    func testInvalidateClearsEverythingAndRelearns() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["lark"]
        env.runningNames["com.electron.lark"] = "飞书"
        let registry = env.makeRegistry()
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))

        // app 换了个版本、名字也改了。
        registry.invalidate(bundleID: "com.electron.lark")
        env.runningNames["com.electron.lark"] = "Lark"

        XCTAssertEqual(registry.knownNames(for: "com.electron.lark"), ["lark"])
        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    // MARK: - 归一化与空标题

    func testEmptyOrBlankTitleNeverMatches() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = ["bar", ""]
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "", bundleID: "com.foo.bar"))
        XCTAssertFalse(registry.matches(title: "   \n ", bundleID: "com.foo.bar"))
    }

    func testMatchingTrimsAndLowercases() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = []
        env.runningNames["com.foo.bar"] = "  MyApp  "
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "myapp", bundleID: "com.foo.bar"))
        XCTAssertTrue(registry.matches(title: " MYAPP ", bundleID: "com.foo.bar"))
        XCTAssertFalse(registry.matches(title: "my app", bundleID: "com.foo.bar"))
    }

    func testUnknownBundleMatchesNothing() {
        let env = Env()
        let registry = env.makeRegistry()
        XCTAssertFalse(registry.matches(title: "Whatever", bundleID: "com.unknown"))
    }
}
