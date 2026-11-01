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

    private static func point(_ point: CGPoint) -> DiagnosticValue { .list([.number(point.x), .number(point.y)]) }
    static func now() -> CFTimeInterval { isEnabled ? CACurrentMediaTime() : 0 }
    static func barArrowCursor(surface: String, decision: String) {
        record("barArrowCursor", ["surface": .text(surface), "decision": .text(decision)])
    }
    static func hover(chipID: String, entered: Bool) { record("hover", ["chip": .text(chipID), "in": .flag(entered)]) }
    static func present(chipID: String, cold: Bool, elapsed: CFTimeInterval) {
        record("present", ["chip": .text(chipID), "cold": .flag(cold), "ms": .number(elapsed * 1000)])
    }
    static func pointer(x: CGFloat, chip: String?) { record("pointer", ["x": .number(x), "chip": chip.map(DiagnosticValue.text) ?? .null]) }
    static func mainLoopStall(lateMs: Double) {
        if lateMs >= 12 { record("stall", ["lateMs": .number(lateMs)]) }
    }
    static func stripBody(items: Int, surface: String) { record("stripBody", ["items": .number(Double(items)), "surface": .text(surface)]) }
    static func stripInput(_ name: String, surface: String, changed: @autoclosure () -> Bool) {
        guard isEnabled else { return }
        record("stripInput", ["name": .text(name), "surface": .text(surface), "changed": .flag(changed())])
    }
    static func span(_ name: String, since start: CFTimeInterval) {
        guard isEnabled else { return }
        let ms = (CACurrentMediaTime() - start) * 1000
        if ms >= 1 { record("span", ["name": .text(name), "ms": .number(ms)]) }
    }
    static func landingPublish() { record("landingPublish") }
    static func relayout(measureMs: CFTimeInterval, width: CGFloat, changed: Bool, animated: Bool, timing: String = "standard") {
        record("relayout", ["measureMs": .number(measureMs * 1000), "width": .number(width), "changed": .flag(changed),
                            "animated": .flag(animated), "timing": .text(timing)], enabled: widthProbesEnabled)
    }
    static func width(_ who: String, _ width: CGFloat) {
        record("width", ["who": .text(who), "w": .number(width)], enabled: widthProbesEnabled)
    }
    static func action(_ kind: String, phase: String) {
        record("action", ["what": .text(kind), "phase": .text(phase)], enabled: widthProbesEnabled)
    }
    static func dragStart(totalMs: Double, carrierMs: Double, carrierCreated: Bool, prepared: Bool) {
        record("dragStart", ["ms": .number(totalMs), "carrierMs": .number(carrierMs), "created": .flag(carrierCreated), "prepared": .flag(prepared)])
    }
    static func landingDelta(dx: CGFloat, dy: CGFloat) {
        if hypot(dx, dy) > 0.5 { record("landingDelta", ["dx": .number(dx), "dy": .number(dy)]) }
    }
    static func landingAnchor(owner: String, rect: CGRect?) {
        record("landingAnchor", ["owner": .text(owner), "rect": rect.map { .list([.number($0.minX), .number($0.minY), .number($0.width), .number($0.height)]) } ?? .null])
    }
    static func landingRetarget(from: CGPoint, to: CGPoint, previous: CGPoint) {
        record("landingRetarget", ["from": point(from), "to": point(to), "prev": point(previous), "shift": .number(hypot(to.x - previous.x, to.y - previous.y))])
    }
    static func orderSync(count: Int, carriedID: String?, hasCarried: Bool) {
        record("orderSync", ["n": .number(Double(count)), "carried": carriedID.map(DiagnosticValue.text) ?? .null, "has": .flag(hasCarried)])
    }
    static func liveOrder(_ ids: [String]) { record("liveOrder", ["ids": .list(ids.prefix(256).map(DiagnosticValue.text))]) }
    static func landing(from: CGPoint, to: CGPoint?, source: String) {
        record("landing", ["from": point(from), "to": to.map(point) ?? .null, "src": .text(source)])
    }
}
