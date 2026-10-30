import XCTest
@testable import macos_dock_cc_v2

final class ProcessEnvironmentScrubTests: XCTestCase {
    /// 实测 owner 机器上微信进程带着的那套变量（终端 + Claude Code），都得清。
    func testTerminalAndAgentVariablesAreUnset() {
        let env = [
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "SHELL": "/bin/zsh",
            "TERM_PROGRAM": "ghostty", "TERM": "xterm-ghostty",
            "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_PID": "1",
        ]
        XCTAssertEqual(ProcessEnvironmentScrub.keysToUnset(in: env),
                       ["CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "LANG", "LC_ALL", "SHELL", "TERM", "TERM_PROGRAM"])
    }

    /// 自家开关、系统给的、路径类一律不碰。
    func testOwnSwitchesAndSystemVariablesSurvive() {
        let env = [
            "DOCK_LAUNCH_TRACE": "1", "DOCK_INVENTORY_LOG": "1",
            "PATH": "/usr/bin", "HOME": "/Users/x", "TMPDIR": "/tmp",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0x19:0x34", "__CFBundleIdentifier": "com.caye.macosdockcc.v2",
        ]
        XCTAssertTrue(ProcessEnvironmentScrub.keysToUnset(in: env).isEmpty)
    }

    /// 从 Launchpad / 登录项启动的正常环境：什么都不清，零影响。
    func testCleanEnvironmentIsNoOp() {
        XCTAssertTrue(ProcessEnvironmentScrub.keysToUnset(in: [:]).isEmpty)
    }

    /// 真的调 `unsetenv`：设一个假的 CLAUDE_ 变量进来再 apply，进程环境里它得没了。
    func testApplyUnsetsFromProcessEnvironment() {
        setenv("CLAUDE_SCRUB_PROBE", "1", 1)
        XCTAssertEqual(ProcessInfo.processInfo.environment["CLAUDE_SCRUB_PROBE"], "1")
        ProcessEnvironmentScrub.apply()
        XCTAssertNil(ProcessInfo.processInfo.environment["CLAUDE_SCRUB_PROBE"])
    }
}
