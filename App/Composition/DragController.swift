import AppKit
import Combine
import SwiftUI

private final class CarrierContainerView: NSView {
    var grabRegion: (@MainActor () -> CGRect?)?
    var onGrab: (@MainActor (CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let region = grabRegion?(), region.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) { onGrab?(NSEvent.mouseLocation) }
}

enum DragSource { case strip }

enum DragVisualKind { case stripChip }

struct DragPayload {
    let source: DragSource
    let id: String          // strip = item.id（chip token）；drawer = bundleID
    let bundleID: String
    let item: StripItem?     // 仅任务条窗口卡有
    let visualKind: DragVisualKind
}

@MainActor
final class DragController: ObservableObject {
    @Published private(set) var draggingPayload: DragPayload?

    private(set) var globalLocation: CGPoint = .zero
    private let pointerSubject = CurrentValueSubject<CGPoint, Never>(.zero)
    let carrierClicks: AnyPublisher<DragPayload, Never>
    private let carrierClickSubject = PassthroughSubject<DragPayload, Never>()
    let pointerMoves: AnyPublisher<CGPoint, Never>

    private(set) var grabOffset: CGSize = .zero
    private(set) var carrierScreenFrame: CGRect = .zero

    struct Landing: Equatable {
        enum Kind { case returnToSlot }
        let token: Int
        let payload: DragPayload
        let kind: Kind
        var flight: DragLandingFlight

        static func == (lhs: Landing, rhs: Landing) -> Bool {
            lhs.token == rhs.token && lhs.kind == rhs.kind && lhs.flight == rhs.flight
        }
    }
    private(set) var landing: Landing? {
        willSet {
            guard landing?.token != newValue?.token else { return }
            HoverTrace.landingPublish()
            objectWillChange.send()
        }
    }

    var carriedPayload: DragPayload? { draggingPayload ?? landing?.payload }

    var hiddenSlotPayload: DragPayload? {
        if draggingPayload != nil { return carrierArmed ? draggingPayload : nil }
        return landing?.payload
    }

    private(set) var carrierRetiring = false

    @Published private(set) var carrierArmed = false

    var isCarrying: Bool { carriedPayload != nil || carrierRetiring }

    var hoverFrozen: Bool { draggingPayload != nil && !carrierArmed }

    var hoverSuppressed: Bool { draggingPayload != nil && carrierArmed }

    var hoverExemptPayload: DragPayload? { landing?.payload ?? hoverHoldPayload }

    var hoverGate: HoverGate {
        HoverGate(suppressed: hoverSuppressed, exemptID: hoverExemptPayload?.id,
                  exemptSource: hoverExemptPayload?.source)
    }
    struct HoverGate: Equatable {
        let suppressed: Bool
        let exemptID: String?
        let exemptSource: DragSource?
    }

    @Published private(set) var hoverHoldPayload: DragPayload?
    private var hoverHoldTimer: Timer?
    private var hoverHoldOrigin: CGPoint = .zero
    private var hoverHoldStartedAt: CFTimeInterval = 0

    var carriedScale: CGFloat { DragLandingPlan.carriedScale }
    private var carrierVisualScale: CGFloat { carriedScale }
    private var carrierVisualOpacity: Float { 1 }

    enum LandingAnchorOwner { case strip }
    private var landingAnchor: (owner: LandingAnchorOwner, rect: CGRect)?
    private var landingTimer: Timer?
    private var landingLaunched = false
    private var landingLaunchTask: DispatchWorkItem?
    private var landingAnimation = 0
    private var dragBeganAt: CFTimeInterval = 0
    private var landingToken = 0
    private var landingDeadline: CFTimeInterval = 0

    func setLandingAnchor(_ rect: CGRect?, owner: LandingAnchorOwner) {
        if let rect {
            landingAnchor = (owner, rect)
            if owner == .strip { lastKnownSlotAnchor = rect }
        } else if landingAnchor?.owner == owner {
            landingAnchor = nil
        }
        if landing != nil {
            HoverTrace.landingAnchor(owner: "\(owner)", rect: landingAnchor?.rect)
        }
        retargetLandingIfNeeded()
    }

    private func retargetLandingIfNeeded() {
        guard var current = landing,
              DragLandingPlan.allowsRetarget(
                remainingBeforeDeadline: landingDeadline - CACurrentMediaTime(),
                flightDuration: current.flight.duration)
        else { return }
        let updatedFlight: DragLandingFlight?
        switch current.kind {
        case .returnToSlot:
            var from = current.flight.from
            if !landingLaunched, let rect = landingAnchor?.rect,
               !carrierScreenFrame.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                followScreenIfNeeded(CGPoint(x: rect.midX, y: rect.midY))
                placeCarrierUnderPointer()
                from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                                grabOffset: grabOffset,
                                                                panelFrame: carrierScreenFrame)
            }
            updatedFlight = DragLandingPlan.flight(from: from,
                                                   fromScale: current.flight.fromScale,
                                                   anchorScreenRect: landingAnchor?.rect,
                                                   carrierScreenFrame: carrierScreenFrame)
        }
        guard let updated = updatedFlight,
              hypot(updated.to.x - current.flight.to.x, updated.to.y - current.flight.to.y) > 0.5
        else { return }
        HoverTrace.landingRetarget(from: updated.from, to: updated.to, previous: current.flight.to)
        guard landingLaunched else {
            current.flight = updated
            landing = current
            return
        }
        guard let timeline = flightTimeline,
              CACurrentMediaTime() - timeline.beganAt < timeline.duration else { return }
        let slid = current.flight.sliding(to: updated.to, toScale: updated.toScale)
        current.flight = slid
        landing = current
        slideLanding(to: slid, token: current.token)
    }

    private func slideLanding(to flight: DragLandingFlight, token: Int) {
        guard let layer = carrierLayer, let timeline = flightTimeline else { return }
        let destination = alignedCenter(
            DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame), on: layer)
        let toTransform = Self.scaleTransform(flight.toScale)
        landingAnimation &+= 1
        let generation = landingAnimation
        let c = timeline.curve
        let timing = CAMediaTimingFunction(controlPoints: Float(c.c0x), Float(c.c0y), Float(c.c1x), Float(c.c1y))
        let beginTime = layer.convertTime(timeline.beganAt, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // model 值直接到位；动画由下面两条显式动画负责
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.landingAnimation == generation else { return }
                self.finishLanding(token: token)
            }
        }
        let tracks: [(String, Any, Any)] = [
            ("position", NSValue(point: timeline.start.position), NSValue(point: destination)),
            ("transform", NSValue(caTransform3D: Self.scaleTransform(timeline.start.scale)),
                          NSValue(caTransform3D: toTransform))
        ]
        for (keyPath, from, to) in tracks {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = beginTime
            animation.duration = timeline.duration
            animation.timingFunction = timing
            layer.add(animation, forKey: keyPath)
        }
        layer.position = destination
        layer.transform = toTransform
        CATransaction.commit()
        flightTimeline = FlightTimeline(beganAt: timeline.beganAt, start: timeline.start,
                                        destination: LayerPose(position: destination, scale: flight.toScale),
                                        duration: timeline.duration, curve: timeline.curve)
    }

    func finishLanding(token: Int) {
        guard let current = landing, current.token == token else { return }
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("finishLanding", since: spanStart) }
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landingAnimation &+= 1
        endLandingGrabWatch()
        flightTimeline = nil
        recordLandingDelta()
        beginHoverHold(for: current.payload)   // 先按住悬停，再让卡显形——顺序反了就抖一下
        landing = nil            // ← 条 / 抽屉在本轮 SwiftUI 提交里让卡显形
        clearStripClaims()
        lastKnownSlotAnchor = nil
        hideCarrierInSlotRevealCommit()
        retireCarrierAfterHandoff()
    }

    private func hideCarrierInSlotRevealCommit() {
        guard let layer = carrierLayer else { return }
        carrierActionGate.suppressesImplicitActions = true
        layer.opacity = 0
        carrierActionGate.suppressesImplicitActions = false
    }

    private func retireCarrierAfterHandoff() {
        carrierRetiring = true
        let generation = carrierGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.carrierRetiring = false }
            guard self.carrierGeneration == generation else { return }
            self.retireCarrier()
        }
    }

    @discardableResult
    func regrabLanding(at screenPoint: CGPoint, requireHit: Bool = true) -> Bool {
        guard let current = landing, current.kind == .returnToSlot,
              let layer = carrierLayer, carrierScreenFrame.width > 0 else { return false }
        if requireHit {
            guard let iconFrame = landingIconScreenFrame(), iconFrame.contains(screenPoint) else { return false }
        }
        let elapsedMs = flightTimeline.map { (CACurrentMediaTime() - $0.beganAt) * 1000 } ?? 0
        let pose = landingPose(at: CACurrentMediaTime() + Self.grabFreezeLead)
            ?? LayerPose(position: layer.position, scale: Self.scale(of: layer.transform))
        landingTimer?.invalidate(); landingTimer = nil
        landingAnimation &+= 1          // CA 完成回调按代次丢弃
        endLandingGrabWatch()
        Self.instantly {
            layer.removeAllAnimations()
            layer.position = self.alignedCenter(pose.position, on: layer)
            layer.transform = Self.scaleTransform(pose.scale)
            layer.opacity = 1
        }
        grabOffset = DragCarrierGeometry.grabOffset(pointer: screenPoint, carriedCenter: pose.position,
                                                    panelFrame: carrierScreenFrame)
        regrabOrigin = screenPoint
        regrabPressed = ChipPressSwitches.pressDownEnabled
        let payload = current.payload
        draggingPayload = payload
        carrierArmed = true
        carrierLifted = true
        landing = nil
        carrierRetiring = false
        endHoverHold()
        dragBeganAt = CACurrentMediaTime()
        globalLocation = screenPoint
        pointerSubject.send(screenPoint)
        installMonitors()
        startPoll()
        flightTimeline = nil
        applyCarrierVisualState(animated: true)   // 按住期缩放 0.93
        HoverTrace.dragHandoff("regrab", msSinceBegin: elapsedMs)
        return true
    }
    private var regrabOrigin: CGPoint?
    private var regrabPressed = false

    private func landingIconPanelFrame() -> CGRect? {
        guard let layer = carrierLayer else { return nil }
        let now = CACurrentMediaTime()
        guard let current = landingPose(at: now), let trailing = landingPose(at: now - Self.grabTrail) else { return nil }
        func frame(_ pose: LayerPose) -> CGRect {
            let size = CGSize(width: layer.bounds.width * pose.scale, height: layer.bounds.height * pose.scale)
            return CGRect(x: pose.position.x - size.width / 2, y: pose.position.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        return frame(current).union(frame(trailing))
    }
    private static let grabTrail: CFTimeInterval = 0.034
    private static let grabFreezeLead: CFTimeInterval = 0.005

    private func landingIconScreenFrame() -> CGRect? {
        guard carrierScreenFrame.width > 0, let frame = landingIconPanelFrame() else { return nil }
        return frame.offsetBy(dx: carrierScreenFrame.minX, dy: carrierScreenFrame.minY)
    }

    private func beginLandingGrabWatch() {
        landingGrabTimer?.invalidate()
        refreshLandingGrabState()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard self.landing != nil else { timer.invalidate(); return }
                self.refreshLandingGrabState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landingGrabTimer = timer
    }

    private func endLandingGrabWatch() {
        landingGrabTimer?.invalidate(); landingGrabTimer = nil
        setCarrierAcceptsMouse(false)
    }

    private func refreshLandingGrabState() {
        let inside = landingIconScreenFrame()?.contains(NSEvent.mouseLocation) == true
        setCarrierAcceptsMouse(inside)
    }

    private func setCarrierAcceptsMouse(_ accepts: Bool) {
        for surface in surfaces {
            let ignores = !(accepts && surface.panel === carrierPanel)
            if surface.panel.ignoresMouseEvents != ignores { surface.panel.ignoresMouseEvents = ignores }
        }
    }
    private var landingGrabTimer: Timer?

    private func beginHoverHold(for payload: DragPayload) {
        hoverHoldTimer?.invalidate()
        hoverHoldPayload = payload
        hoverHoldOrigin = NSEvent.mouseLocation
        hoverHoldStartedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard self.hoverHoldPayload != nil else { timer.invalidate(); return }
                let now = NSEvent.mouseLocation
                let moved = hypot(now.x - self.hoverHoldOrigin.x, now.y - self.hoverHoldOrigin.y) > 0.5
                let expired = CACurrentMediaTime() - self.hoverHoldStartedAt > DragLandingPlan.hoverHoldMaximum
                if moved || expired { self.endHoverHold() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverHoldTimer = timer
    }

    private func endHoverHold() {
        hoverHoldTimer?.invalidate(); hoverHoldTimer = nil
        if hoverHoldPayload != nil { hoverHoldPayload = nil }
    }

    private func retireCarrier() {
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("retireCarrier", since: spanStart) }
        if let layer = carrierLayer {
            Self.instantly {
                layer.removeAllAnimations()
                layer.contents = nil
            }
        }
        carrierSnapshot = nil
        parkCarrierSurfaces()
    }

    func abortLanding() {
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landingAnimation &+= 1
        endLandingGrabWatch()
        flightTimeline = nil
        carrierRetiring = false
        clearStripClaims()
        lastKnownSlotAnchor = nil
        guard landing != nil else { return }
        landing = nil
        retireCarrier()
    }

    private(set) var activeStripSurfaceID: String?
    private var lastKnownSlotAnchor: CGRect?
    private let screensProvider: () -> [NSScreen]

    private func clearStripClaims() {
        activeStripSurfaceID = nil
    }

    private struct CarrierSurface {
        let panel: NSPanel
        let container: CarrierContainerView
        let layer: CALayer
        let frame: CGRect
    }
    private var surfaces: [CarrierSurface] = []
    private var carrierParked = true
    private static let parkedCarrierOrigin = CGPoint(x: -100_000, y: -100_000)
    private final class CarrierLayerActionGate: NSObject, CALayerDelegate {
        var suppressesImplicitActions = false
        func action(for layer: CALayer, forKey event: String) -> CAAction? {
            suppressesImplicitActions ? NSNull() : nil   // nil = 交回默认查找，平时完全不干预
        }
    }
    private let carrierActionGate = CarrierLayerActionGate()
    private var activeSurface: CarrierSurface?
    var pinCarrierWindows: (([Int]) -> Void)? {
        didSet { pinCarrierWindows?(surfaces.map { $0.panel.windowNumber }) }
    }
    private var carrierPanel: NSPanel? { activeSurface?.panel }
    private var carrierContainer: CarrierContainerView? { activeSurface?.container }
    private var carrierLayer: CALayer? { activeSurface?.layer }
    private var carrierSnapshot: CarrierSnapshot?
    private var carrierGeneration = 0

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pollTimer: Timer?

    init(screensProvider: @escaping () -> [NSScreen]) {
        self.pointerMoves = pointerSubject.eraseToAnyPublisher()
        self.carrierClicks = carrierClickSubject.eraseToAnyPublisher()
        self.screensProvider = screensProvider
    }

    private struct Candidate {
        let payloadID: String
        let snapshot: CarrierSnapshot
        let sourceScreenRect: CGRect
        let preparedAt: CFTimeInterval
    }
    private static let candidateFreshness: CFTimeInterval = 2
    private var candidate: Candidate?
    private var armTask: DispatchWorkItem?

    func prepareCandidate(payloadID: String, sourceScreenRect: CGRect,
                          snapshot: @autoclosure () -> CarrierSnapshot?) {
        guard draggingPayload == nil, landing == nil,
              sourceScreenRect.width > 0, sourceScreenRect.height > 0 else { return }
        if let current = candidate, current.payloadID == payloadID,
           CACurrentMediaTime() - current.preparedAt < Self.candidateFreshness {
            return
        }
        guard let snapshot = snapshot() else { return }
        candidate = Candidate(payloadID: payloadID, snapshot: snapshot,
                              sourceScreenRect: sourceScreenRect, preparedAt: CACurrentMediaTime())
        let frame = ensureCarrierPanel(for: CGPoint(x: sourceScreenRect.midX, y: sourceScreenRect.midY))
        guard let layer = carrierLayer, let panel = carrierPanel else { return }
        carrierGeneration &+= 1
        Self.instantly {
            layer.removeAllAnimations()
            self.apply(snapshot, to: layer)
            layer.position = self.alignedCenter(
                DragCarrierGeometry.panelCenter(ofScreenRect: sourceScreenRect, panelFrame: frame), on: layer)
            layer.transform = CATransform3DIdentity
            layer.opacity = DragLandingPlan.candidateOpacity
        }
        orderCarrierFrontIfNeeded(panel)
        HoverTrace.dragHandoff("candidatePrepared", msSinceBegin: 0)
    }

    func clearCandidate(payloadID: String) {
        guard draggingPayload == nil, landing == nil, !carrierRetiring,
              candidate?.payloadID == payloadID else { return }
        candidate = nil
        retireCarrier()
    }

    func beginDrag(payload: DragPayload,
                   stripSurfaceID: String? = nil,
                   startScreenLocation: CGPoint,
                   grabOffset: CGSize,
                   sourceScreenRect: CGRect,
                   pose: DragCarrierGeometry.PickUpPose,
                   snapshot: @autoclosure () -> CarrierSnapshot?) {
        guard draggingPayload == nil else { return }
        if let current = landing, current.payload.id == payload.id,
           regrabLanding(at: startScreenLocation, requireHit: false) {
            return
        }
        let prepared = candidate.flatMap { $0.payloadID == payload.id ? $0 : nil }
        candidate = nil
        guard let image = prepared?.snapshot ?? snapshot() else {
            HoverTrace.dragHandoff("noSnapshot", msSinceBegin: 0)
            retireCarrier()
            return
        }
        abortLanding()
        endHoverHold()
        activeStripSurfaceID = stripSurfaceID   // 放在 abortLanding 之后：中止上一趟飞行会清掉认领
        let started = CACurrentMediaTime()
        dragBeganAt = started
        let hadCarrier = carrierPanel != nil
        carrierArmed = false
        carrierLifted = false
        liftTimer?.invalidate(); liftTimer = nil
        armTask?.cancel(); armTask = nil
        self.grabOffset = grabOffset
        globalLocation = startScreenLocation
        pointerSubject.send(startScreenLocation)
        let beforeCarrier = CACurrentMediaTime()
        let slotRect = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? sourceScreenRect : (prepared?.sourceScreenRect ?? sourceScreenRect)
        presentCarrier(snapshot: image, at: slotRect, pose: pose)
        let afterCarrier = CACurrentMediaTime()
        draggingPayload = payload
        installMonitors()
        startPoll()
        if prepared != nil {
            armCarrier()
        } else {
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.draggingPayload != nil, !self.carrierArmed else { return }
                self.armCarrier()
            }
            armTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + DragLandingPlan.pickUpSettle, execute: task)
        }
        HoverTrace.dragStart(totalMs: (CACurrentMediaTime() - started) * 1000,
                             carrierMs: (afterCarrier - beforeCarrier) * 1000,
                             carrierCreated: !hadCarrier,
                             prepared: prepared != nil)
    }

    private func armCarrier() {
        guard draggingPayload != nil, !carrierArmed else { return }
        armTask?.cancel(); armTask = nil
        carrierArmed = true
        HoverTrace.dragHandoff("slotHidden", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        liftTimer?.invalidate()
        let timer = Timer(timeInterval: DragLandingPlan.liftDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil, self.carrierArmed, !self.carrierLifted else { return }
                self.liftCarrier()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // 拖动中的计时器必须 .common（AGENTS）
        liftTimer = timer
    }
    private var liftTimer: Timer?
    private(set) var carrierLifted = false

    private func update(_ loc: CGPoint) {
        globalLocation = loc
        followScreenIfNeeded(loc)
        moveCarrier()
        if regrabPressed, let origin = regrabOrigin,
           hypot(loc.x - origin.x, loc.y - origin.y) > DragLandingPlan.regrabClickSlop {
            regrabPressed = false                    // 挪过门槛 = 拖动：回到拎着的样子（等于抬起）
            applyCarrierVisualState(animated: true)
        }
        pointerSubject.send(loc)    // 副作用订阅方（条 / 抽屉），不建立视图依赖
        auditCarrierVisibility()
    }

    private func auditCarrierVisibility() {
        guard HoverTrace.isEnabled, carriedPayload != nil,
              let panel = carrierPanel, let layer = carrierLayer else { return }
        let onScreen = panel.isVisible && panel.alphaValue > 0.99
        let drawn = layer.contents != nil && layer.opacity > 0.01
        let inFrame = CGRect(origin: .zero, size: carrierScreenFrame.size)
            .insetBy(dx: -24, dy: -24).contains(layer.position)
        guard !onScreen || !drawn || !inFrame else { return }
        let reason = !panel.isVisible ? "panelHidden"
            : (panel.alphaValue <= 0.99 ? "panelFaded"
               : (!drawn ? "emptyContent" : "iconOffscreen"))
        HoverTrace.carrierGap(reason: reason, alpha: panel.alphaValue,
                              hostX: layer.position.x, hostY: layer.position.y)
    }

    func endDrag() {
        guard let payload = draggingPayload else { return }
        let isClick = regrabOrigin.map {
            hypot(globalLocation.x - $0.x, globalLocation.y - $0.y) < DragLandingPlan.regrabClickSlop
        } ?? false
        teardown(landing: plannedLanding(for: payload))
        if isClick { carrierClickSubject.send(payload) }
    }

    func cancelDrag() {
        abortLanding()
        guard draggingPayload != nil else { return }
        teardown(landing: nil)
    }

    private func plannedLanding(for payload: DragPayload) -> Landing? {
        guard DragLandingSwitches.enabled else { return nil }
        let anchor = landingAnchor?.rect ?? lastKnownSlotAnchor
        if let rect = anchor {
            followScreenIfNeeded(CGPoint(x: rect.midX, y: rect.midY))
            placeCarrierUnderPointer()
        }
        let from = DragCarrierGeometry.topLeftCarriedCenter(
            pointer: globalLocation,
            grabOffset: grabOffset,
            panelFrame: carrierScreenFrame
        )
        let flight = DragLandingPlan.flight(
            from: from,
            fromScale: carriedScale,
            anchorScreenRect: anchor,
            carrierScreenFrame: carrierScreenFrame
        ) ?? (carrierScreenFrame.width > 0
            ? DragLandingPlan.holdingFlight(at: from, scale: carriedScale)
            : nil)
        guard let flight else { return nil }
        landingToken &+= 1
        return Landing(token: landingToken, payload: payload, kind: .returnToSlot, flight: flight)
    }

    private func placeCarrierUnderPointer() {
        guard let layer = carrierLayer, carrierScreenFrame.width > 0 else { return }
        let center = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let aligned = alignedCenter(center, on: layer)
        Self.instantly { layer.position = aligned }
    }

    private func teardown(landing flight: Landing?) {
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("teardown", since: spanStart) }
        let released = draggingPayload
        if flight == nil {
            clearStripClaims()
            lastKnownSlotAnchor = nil
        }
        draggingPayload = nil
        carrierArmed = false
        carrierLifted = false
        regrabOrigin = nil
        regrabPressed = false
        liftTimer?.invalidate(); liftTimer = nil
        armTask?.cancel(); armTask = nil
        candidate = nil
        landingAnchor = nil
        removeMonitors()
        pollTimer?.invalidate(); pollTimer = nil
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landing = flight
        guard let flight else {
            if let released { beginHoverHold(for: released) }
            retireCarrierAfterHandoff()
            return
        }
        startLanding(flight)
    }

    private func startLanding(_ flight: Landing) {
        landingDeadline = CACurrentMediaTime() + DragLandingPlan.maximumDuration
        landingLaunched = false
        let token = flight.token
        let task = DispatchWorkItem { [weak self] in self?.launchLanding(token: token) }
        landingLaunchTask?.cancel()
        landingLaunchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + DragLandingPlan.landingSettle, execute: task)
        beginLandingGrabWatch()
    }

    private func launchLanding(token: Int) {
        guard !landingLaunched, let current = landing, current.token == token else { return }
        landingLaunched = true
        guard !current.flight.isStationary else { finishLanding(token: token); return }
        flyCarrier(along: current.flight, token: token)
    }

    private func scheduleLandingFinish(token: Int) {
        landingTimer?.invalidate()
        let flightDuration = landing?.flight.duration ?? DragLandingPlan.duration
        let remaining = max(0.05, min(flightDuration + DragLandingPlan.settleMargin,
                                      landingDeadline - CACurrentMediaTime()))
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finishLanding(token: token)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landingTimer = timer
    }

    func prewarmCarrier() {
        guard surfaces.isEmpty else { return }
        for frame in screensProvider().map(\.frame) { _ = surface(for: frame) }
        activeSurface = surfaces.first
        carrierScreenFrame = activeSurface?.frame ?? .zero
    }

    func closeCarrierSurfaces() {
        abortLanding()
        for surface in surfaces { surface.panel.orderOut(nil); surface.panel.close() }
        surfaces.removeAll()
        activeSurface = nil
        carrierScreenFrame = .zero
    }

    private func surface(for frame: CGRect) -> CarrierSurface {
        if let existing = surfaces.first(where: { $0.frame == frame }) { return existing }
        let made = makeCarrierSurface(frame: frame)
        surfaces.append(made)
        made.panel.orderFrontRegardless()
        pinCarrierWindows?([made.panel.windowNumber])
        if carrierParked { made.panel.setFrameOrigin(Self.parkedCarrierOrigin) }
        return made
    }

    @discardableResult
    private func ensureCarrierPanel(for point: CGPoint) -> CGRect {
        let frames = screensProvider().map(\.frame)
        for stale in surfaces where !frames.contains(stale.frame) {
            stale.panel.orderOut(nil); stale.panel.close()
            if activeSurface?.panel === stale.panel { activeSurface = nil }
        }
        surfaces.removeAll { !frames.contains($0.frame) }
        let frame = DragCarrierGeometry.screenFrame(containing: point, in: frames)
        guard frame.width > 0 else { return .zero }
        let next = surface(for: frame)
        if activeSurface?.panel !== next.panel {
            if let old = activeSurface {
                Self.instantly { old.layer.removeAllAnimations(); old.layer.contents = nil }
            }
            activeSurface = next
        }
        carrierScreenFrame = frame
        wakeCarrierSurfaces()
        return frame
    }

    private func wakeCarrierSurfaces() {
        guard carrierParked else { return }
        carrierParked = false
        for surface in surfaces { surface.panel.setFrameOrigin(surface.frame.origin) }
        pinCarrierWindows?(surfaces.map { $0.panel.windowNumber })
    }

    private func parkCarrierSurfaces() {
        guard !carrierParked else { return }
        carrierParked = true
        for surface in surfaces { surface.panel.setFrameOrigin(Self.parkedCarrierOrigin) }
    }

    private func followScreenIfNeeded(_ point: CGPoint) {
        guard carrierScreenFrame.width > 0, !carrierScreenFrame.contains(point) else { return }
        let frames = screensProvider().map(\.frame)
        guard frames.contains(where: { $0.contains(point) }) else { return }   // 屏与屏之间的缝，先不动
        ensureCarrierPanel(for: point)
        if let layer = carrierLayer, let snapshot = carrierSnapshot {
            Self.instantly { self.apply(snapshot, to: layer); layer.opacity = 1 }
            applyCarrierVisualState(animated: false)
        }
        HoverTrace.dragHandoff("screenSwitch", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
    }

    private func presentCarrier(snapshot: CarrierSnapshot, at sourceScreenRect: CGRect,
                                pose: DragCarrierGeometry.PickUpPose) {
        let anchor = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? CGPoint(x: sourceScreenRect.midX, y: sourceScreenRect.midY) : globalLocation
        let frame = ensureCarrierPanel(for: anchor)
        guard let layer = carrierLayer, let panel = carrierPanel else { return }
        carrierGeneration &+= 1
        carrierSnapshot = snapshot
        var center = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? DragCarrierGeometry.panelCenter(ofScreenRect: sourceScreenRect, panelFrame: frame)
            : DragCarrierGeometry.carriedCenter(pointer: globalLocation, grabOffset: grabOffset, panelFrame: frame)
        center.y += pose.dy
        Self.instantly {
            layer.removeAllAnimations()
            self.apply(snapshot, to: layer)          // 先换图：`alignedCenter` 要用新 bounds
            layer.position = self.alignedCenter(center, on: layer)
            layer.transform = Self.scaleTransform(pose.scale)
            layer.opacity = 1
        }
        orderCarrierFrontIfNeeded(panel)
    }

    private static func instantly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func orderCarrierFrontIfNeeded(_ panel: NSPanel) {
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    private func liftCarrier() {
        guard let layer = carrierLayer else { return }
        carrierLifted = true
        HoverTrace.dragHandoff("lift", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        let rawTarget = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let target = alignedCenter(rawTarget, on: layer)
        let from = layer.position
        Self.instantly {
            layer.position = target
            if hypot(target.x - from.x, target.y - from.y) > 0.5 {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: NSPoint(x: from.x - target.x, y: from.y - target.y))
                slide.toValue = NSValue(point: .zero)
                slide.duration = DragLandingPlan.liftDuration
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slide.isRemovedOnCompletion = true
                layer.add(slide, forKey: "lift")
            }
        }
        applyCarrierVisualState(animated: true)
    }

    private func moveCarrier() {
        guard carrierLifted, let layer = carrierLayer, carrierScreenFrame.width > 0 else { return }
        let center = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let aligned = alignedCenter(center, on: layer)   // 不对齐就是整段拖动都糊，见 `alignedCenter`
        Self.instantly { layer.position = aligned }
    }

    private func applyCarrierVisualState(animated: Bool) {
        guard carrierLifted, let layer = carrierLayer, draggingPayload != nil else { return }
        let scale = regrabPressed ? ChipPressDecision.pressedScale : carrierVisualScale
        let opacity = carrierVisualOpacity
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(DragLandingPlan.stateChangeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.transform = Self.scaleTransform(scale)
        layer.opacity = opacity
        CATransaction.commit()
    }

    private static func animate(_ layer: CALayer, _ keyPath: String, to value: Any,
                                duration: TimeInterval,
                                timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
        guard duration > 0 else { layer.removeAnimation(forKey: keyPath); return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: keyPath)
    }

    private func apply(_ snapshot: CarrierSnapshot, to layer: CALayer) {
        layer.contents = snapshot.image
        layer.contentsScale = snapshot.scale
        layer.bounds = CGRect(origin: .zero, size: snapshot.size)
    }

    private func flyCarrier(along flight: DragLandingFlight, token: Int) {
        guard let layer = carrierLayer else { return }
        let now = CACurrentMediaTime()
        let start = landingPose(at: now)
            ?? LayerPose(position: layer.position, scale: Self.scale(of: layer.transform))
        landingAnimation &+= 1
        let generation = landingAnimation
        let c = flight.curve   // 每次飞行自带曲线（近缓远快），和 duration 一样不许分开算
        let timing = CAMediaTimingFunction(controlPoints: Float(c.c0x), Float(c.c0y), Float(c.c1x), Float(c.c1y))
        let destination = alignedCenter(
            DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame), on: layer)
        CATransaction.begin()
        CATransaction.setAnimationDuration(flight.duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.landingAnimation == generation else { return }
                self.finishLanding(token: token)
            }
        }
        layer.position = destination
        layer.transform = Self.scaleTransform(flight.toScale)
        layer.opacity = flight.toOpacity        // 飞回卡槽 = 1（文件夹拖出条外的淡出要还原）；吸进胶囊 = 0
        CATransaction.commit()
        flightTimeline = FlightTimeline(beganAt: now, start: start,
                                        destination: LayerPose(position: destination, scale: flight.toScale),
                                        duration: flight.duration, curve: flight.curve)
        scheduleLandingFinish(token: token)
    }

    private struct LayerPose {
        var position: CGPoint
        var scale: CGFloat
    }

    private struct FlightTimeline {
        let beganAt: CFTimeInterval
        let start: LayerPose
        let destination: LayerPose
        let duration: TimeInterval
        let curve: DragLandingCurve
        func pose(at time: CFTimeInterval) -> LayerPose {
            let p = CGFloat(curve.progress(at: (time - beganAt) / duration))
            return LayerPose(position: CGPoint(x: start.position.x + (destination.position.x - start.position.x) * p,
                                               y: start.position.y + (destination.position.y - start.position.y) * p),
                             scale: start.scale + (destination.scale - start.scale) * p)
        }
    }
    private var flightTimeline: FlightTimeline?

    private func landingPose(at time: CFTimeInterval) -> LayerPose? {
        guard let landing, let timeline = flightTimeline else { return nil }
        guard landing.kind == .returnToSlot else { return nil }
        return timeline.pose(at: time)
    }

    private static func scale(of transform: CATransform3D) -> CGFloat { transform.m11 }

    private func recordLandingDelta() {
        guard HoverTrace.isEnabled, let layer = carrierLayer, let flight = landing?.flight else { return }
        let want = DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame)
        let got = layer.presentation()?.position ?? layer.position
        HoverTrace.landingDelta(dx: got.x - want.x, dy: got.y - want.y)
    }

    private static func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        CATransform3DMakeScale(scale, scale, 1)
    }

    private func alignedCenter(_ center: CGPoint, on layer: CALayer) -> CGPoint {
        DragCarrierGeometry.pixelAligned(center: center,
                                         size: layer.bounds.size,
                                         scale: carrierSnapshot?.scale ?? 2)
    }

    private func makeCarrierSurface(frame: CGRect) -> CarrierSurface {
        let panel = NonConstrainingPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.isFloatingPanel = true
        panel.level = PanelLevel.carrier
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true          // 纯绘制，不抢事件；唯一例外见 `refreshLandingGrabState`
        panel.alphaValue = 1                     // 恒 1：再没有任何面板级 alpha 动画
        let container = CarrierContainerView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        container.autoresizingMask = [.width, .height]
        let layer = CALayer()
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.isOpaque = false
        layer.allowsEdgeAntialiasing = true
        layer.delegate = carrierActionGate
        container.layer?.addSublayer(layer)
        container.grabRegion = { [weak self] in self?.landingIconPanelFrame() }
        container.onGrab = { [weak self] point in self?.regrabLanding(at: point) }
        panel.contentView = container
        return CarrierSurface(panel: panel, container: container, layer: layer, frame: frame)
    }

    func bringCarrierToFront() {
        guard draggingPayload != nil, let c = carrierPanel else { return }
        c.orderFrontRegardless()
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return ev }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
            return ev
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    private func startPoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil else { return }
                if NSEvent.pressedMouseButtons == 0 { self.endDrag() }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}

