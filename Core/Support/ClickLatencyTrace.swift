import Foundation

enum ClickLatencyTrace {
    static let isEnabled = DebugSwitch.clickTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let runtime = Runtime()

    static func begin(windowID: String, kind: String, status: String, bundleID: String?) {
        guard isEnabled else { return }
        runtime.begin(windowID: windowID, kind: kind, status: status, bundleID: bundleID,
                      at: ProcessInfo.processInfo.systemUptime)
    }

    static func mark(windowID: String?, _ stage: String, detail: String? = nil) {
        guard isEnabled, let windowID else { return }
        runtime.mark(windowID: windowID, stage: stage, detail: detail, at: ProcessInfo.processInfo.systemUptime)
    }

    static func end(windowID: String?, success: Bool) {
        guard isEnabled, let windowID else { return }
        runtime.end(windowID: windowID, success: success, at: ProcessInfo.processInfo.systemUptime)
    }

    private final class Runtime: @unchecked Sendable {
        private let queue = BoundedDiagnosticQueue(label: "io.github.sashokey.properwm.click-latency-trace")
        private let file = PrivateJSONLinesFile(directory: PrivateJSONLinesFile.liveDirectory, name: "click-latency.jsonl")
        private var sessions: [String: Session] = [:]

        private struct Session {
            let kind: String
            let status: String
            let bundleID: String?
            let startedAt: TimeInterval
            var stages: [(String, TimeInterval, String?)] = []
        }

        func begin(windowID: String, kind: String, status: String, bundleID: String?, at: TimeInterval) {
            queue.submit { [self] in
                if sessions.count >= 128, let oldest = sessions.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
                    sessions.removeValue(forKey: oldest)
                }
                sessions[windowID] = Session(kind: kind, status: status, bundleID: bundleID, startedAt: at)
            }
        }

        func mark(windowID: String, stage: String, detail: String?, at: TimeInterval) {
            queue.submit { [self] in
                guard let session = sessions[windowID], session.stages.count < 32 else { return }
                sessions[windowID]?.stages.append((stage, at, detail))
            }
        }

        func end(windowID: String, success: Bool, at: TimeInterval) {
            queue.submit { [self] in
                guard let session = sessions.removeValue(forKey: windowID) else { return }
                func ms(_ time: TimeInterval) -> DiagnosticValue { .number(((time - session.startedAt) * 100_000).rounded() / 100) }
                var fields: [String: DiagnosticValue] = ["kind": .text(session.kind), "status": .text(session.status),
                    "bundleID": session.bundleID.map(DiagnosticValue.text) ?? .null,
                    "success": .flag(success), "totalMs": ms(at)]
                for (stage, at, detail) in session.stages {
                    fields[stage + "Ms"] = ms(at)
                    if let detail { fields[stage + "Detail"] = .text(detail) }
                }
                if let data = DiagnosticJSON.line(fields) { try? file.append(data) }
            }
        }
    }
}
