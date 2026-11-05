import CoreGraphics
import Foundation
import QuartzCore

enum HoverTrace {
    static let isEnabled = DebugSwitch.hoverTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    static let widthProbesEnabled = isEnabled || DebugSwitch.labelProbe.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let queue = BoundedDiagnosticQueue(label: "io.github.sashokey.properwm.hovertrace")
    private static let file = PrivateJSONLinesFile(directory: PrivateJSONLinesFile.liveDirectory, name: "hover-trace.jsonl")

    private static func record(_ kind: String, _ fields: @autoclosure () -> [String: DiagnosticValue] = [:], enabled: Bool = isEnabled) {
        guard enabled else { return }
        var values = fields()
        values["kind"] = .text(kind)
        values["t"] = .number((CACurrentMediaTime() * 10_000).rounded() / 10)
        guard let data = DiagnosticJSON.line(values) else { return }
        queue.submit { try? file.append(data) }
    }

    static func mainLoopStall(lateMs: Double) {
        if lateMs >= 12 { record("stall", ["lateMs": .number(lateMs)]) }
    }
    static func action(_ kind: String, phase: String) {
        record("action", ["what": .text(kind), "phase": .text(phase)], enabled: widthProbesEnabled)
    }
}
