import CoreGraphics
import Foundation
import OSLog

/// 访达窗口的 AppleEvents 目标（标题 + 屏幕 frame），供唯一匹配用。
struct FinderWindowAppleEventsTarget: Sendable {
    let title: String
    let cocoaFrame: CGRect
}

/// AppleScript 枚举出的一个访达窗口（名字 + frame + 目标路径）。
struct AEFinderWindow {
    let name: String
    let cocoaFrame: CGRect
    let url: URL
}

/// 解析 AppleScript 输出的结果（含用于日志的计数与首个错误摘要）。
struct AEFinderWindowParseResult {
    let windows: [AEFinderWindow]
    let rawLineCount: Int
    let validURLCount: Int
    let firstErrorSummary: String?
}

/// 访达窗口路径反查的**纯逻辑**层：AppleScript 脚本文本、输出解析、按「标题 + 位置」唯一匹配。
/// 从 `FinderWindowContentsReader` 的 AX / AppleEvent I/O 里抽出来，为的是**可纯单测**、且不把 AX
/// 依赖拖进测试靶。行为已由 spike#2 真机验证；单测锁住防回归。
enum FinderAppleEventMatcher {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caye.macosdockcc.v2",
        category: "FinderContents"
    )

    static func appleEventWindowListingScript() -> String {
        """
        tell application "Finder"
          with timeout of 2 seconds
            set out to ""
            set finderWindows to (get Finder windows)
            repeat with w in finderWindows
              set rowName to ""
              set leftValue to ""
              set topValue to ""
              set rightValue to ""
              set bottomValue to ""
              set targetValue to ""
              set fieldErrors to ""

              try
                set rowName to (name of w as text)
              on error errMsg number errNum
                set fieldErrors to fieldErrors & "name:" & (errNum as text) & ";"
              end try

              try
                set b to bounds of w
                set leftValue to (item 1 of b as text)
                set topValue to (item 2 of b as text)
                set rightValue to (item 3 of b as text)
                set bottomValue to (item 4 of b as text)
              on error errMsg number errNum
                set fieldErrors to fieldErrors & "bounds:" & (errNum as text) & ";"
              end try

              try
                set t to target of w
                try
                  set targetValue to ((URL of t) as text)
                on error urlErrMsg number urlErrNum
                  try
                    set targetValue to POSIX path of (t as alias)
                  on error pathErrMsg number pathErrNum
                    set fieldErrors to fieldErrors & "url:" & (urlErrNum as text) & ";path:" & (pathErrNum as text) & ";"
                  end try
                end try
              on error errMsg number errNum
                set fieldErrors to fieldErrors & "target:" & (errNum as text) & ";"
              end try

              set out to out & rowName & tab & leftValue & tab & topValue & tab & rightValue & tab & bottomValue & tab & targetValue & tab & fieldErrors & linefeed
            end repeat
            return out
          end timeout
        end tell
        """
    }

    static func parseAppleEventWindowOutput(_ output: String) -> AEFinderWindowParseResult {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var windows: [AEFinderWindow] = []
        var validURLCount = 0
        var firstErrorSummary: String?

        for line in lines {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 7 else {
                firstErrorSummary = firstErrorSummary ?? "bad-field-count"
                continue
            }

            let fieldErrors = parts[6]
            if !fieldErrors.isEmpty {
                firstErrorSummary = firstErrorSummary ?? fieldErrors
            }

            guard let left = Double(parts[1]),
                  let top = Double(parts[2]),
                  let right = Double(parts[3]),
                  let bottom = Double(parts[4]) else {
                firstErrorSummary = firstErrorSummary ?? "bad-bounds"
                continue
            }

            guard let url = fileURL(fromAppleEventValue: parts[5]) else {
                firstErrorSummary = firstErrorSummary ?? "invalid-target-url"
                continue
            }
            guard validDirectoryURL(url) != nil else {
                firstErrorSummary = firstErrorSummary ?? "unsupported-target-url"
                continue
            }
            validURLCount += 1

            windows.append(
                AEFinderWindow(
                    name: parts[0],
                    cocoaFrame: comparableFrameFromFinderBounds(
                        left: CGFloat(left),
                        top: CGFloat(top),
                        right: CGFloat(right),
                        bottom: CGFloat(bottom)
                    ),
                    url: url
                )
            )
        }

        return AEFinderWindowParseResult(
            windows: windows,
            rawLineCount: lines.count,
            validURLCount: validURLCount,
            firstErrorSummary: firstErrorSummary
        )
    }

    static func matchAppleEventWindow(target: FinderWindowAppleEventsTarget, candidates: [AEFinderWindow], requestID: String = "test") -> AEFinderWindow? {
        let matches = candidates.filter { candidate in
            candidate.name == target.title &&
            framesMatch(target.cocoaFrame, candidate.cocoaFrame, tolerance: 8)
        }
        logger.info("ae-match request=\(requestID, privacy: .public) candidateCount=\(candidates.count, privacy: .public) matchCount=\(matches.count, privacy: .public) title=\(target.title, privacy: .public)")
        return matches.count == 1 ? matches[0] : nil
    }

    static func fileURL(fromAppleEventValue rawValue: String) -> URL? {
        guard rawValue.isEmpty == false else { return nil }
        if rawValue.hasPrefix("file://") {
            return URL(string: rawValue)
        }
        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue)
        }
        return nil
    }

    static func validDirectoryURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return url
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
        abs(lhs.minY - rhs.minY) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
    }

    private static func comparableFrameFromFinderBounds(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> CGRect {
        CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
