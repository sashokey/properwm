import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct AXElementKey: Hashable, @unchecked Sendable {
    let e: AXUIElement

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool { CFEqual(lhs.e, rhs.e) }

    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(e)) }
}

enum AXWindowTitleRead: Equatable {
    case value(String)
    case empty
    case unread(AXError)

    var title: String? {
        if case .value(let title) = self { return title }
        return nil
    }

    func resolvedTitle(previousTitle: String? = nil) -> String {
        switch self {
        case .value(let title): return title
        case .empty: return ""
        case .unread: return previousTitle ?? ""
        }
    }

    static func classify(result: AXError, value: CFTypeRef?) -> Self {
        switch result {
        case .success:
            guard let text = value as? String else { return .unread(.failure) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .empty : .value(text)
        case .attributeUnsupported, .noValue:
            return .empty
        default:
            return .unread(result)
        }
    }
}

struct AXWindowSnapshot {
    let pid: Int32
    let cgWindowID: UInt32?
    let titleRead: AXWindowTitleRead
    let bounds: CGRect?
    let role: String?
    let subrole: String?
    let isMinimized: Bool
    var isFocusedWindow: Bool
    let element: AXUIElement

    let isMinimizedRead: Bool?
    let focusReadUptime: TimeInterval?
    let isModal: Bool?
    let isTopLevel: Bool?

    var title: String? { titleRead.title }

    init(pid: Int32, cgWindowID: UInt32?, titleRead: AXWindowTitleRead, bounds: CGRect?,
         role: String?, subrole: String?, isMinimized: Bool, isFocusedWindow: Bool, element: AXUIElement,
         isMinimizedRead: Bool? = nil, focusReadUptime: TimeInterval? = nil,
         isModal: Bool? = nil, isTopLevel: Bool? = nil) {
        self.pid = pid
        self.cgWindowID = cgWindowID
        self.titleRead = titleRead
        self.bounds = bounds
        self.role = role
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.isFocusedWindow = isFocusedWindow
        self.element = element
        self.isMinimizedRead = isMinimizedRead
        self.focusReadUptime = focusReadUptime
        self.isModal = isModal
        self.isTopLevel = isTopLevel
    }
}

struct AXWindowTarget {
    let pid: Int32
    let title: String?
    let bounds: CGRect?
    var cgWindowID: CGWindowID? = nil
    var expectedElement: AXElementKey? = nil
}

struct AXWindowHandle {
    let pid: Int32
    let title: String?
    let bounds: CGRect?
    let element: AXUIElement
}

enum AXWindowFrameAttribute: Equatable {
    case position
    case size
}

enum AXWindowAttributeSettableStatus: Equatable {
    case settable
    case notSettable
    case unread(AXError)

    var isSettable: Bool {
        if case .settable = self { return true }
        return false
    }
}

struct AXWindowFrameSettableStatus: Equatable {
    let position: AXWindowAttributeSettableStatus
    let size: AXWindowAttributeSettableStatus
}

enum AXWindowFrameWriteFailure: Error, Equatable {
    case invalidGeometry
    case initialFrameUnavailable
    case initialFrameMismatch(expected: CGRect, actual: CGRect)
    case windowIdentityChanged
    case capabilityQueryFailed(attribute: AXWindowFrameAttribute, error: AXError)
    case attributeNotSettable(AXWindowFrameAttribute)
    case valueCreationFailed(AXWindowFrameAttribute)
    case operationBudgetExhausted
    case writeFailed(attribute: AXWindowFrameAttribute, error: AXError)
    case verificationUnavailable
    case verificationMismatch(expected: CGRect, actual: CGRect)

    var mayHaveMutatedWindow: Bool {
        switch self {
        case .writeFailed, .verificationUnavailable, .verificationMismatch:
            return true
        case .invalidGeometry,
             .initialFrameUnavailable,
             .initialFrameMismatch,
             .windowIdentityChanged,
             .capabilityQueryFailed,
             .attributeNotSettable,
             .valueCreationFailed,
             .operationBudgetExhausted:
            return false
        }
    }
}

enum AXWindowFrameRollbackPolicy {
    static func accepts(_ actual: CGRect, attemptedFrames: [CGRect], tolerance: CGFloat) -> Bool {
        attemptedFrames.contains { WindowFrameMatchPolicy.areClose(actual, $0, tolerance: tolerance) }
    }
}

enum AXWindowFrameRollbackResult: Equatable {
    case notRequested
    case restored(actualFrame: CGRect)
    case failed(reason: AXWindowFrameWriteFailure, actualFrame: CGRect?)
}

enum AXWindowFrameWriteResult: Equatable {
    case success(actualFrame: CGRect)
    case failure(reason: AXWindowFrameWriteFailure, rollback: AXWindowFrameRollbackResult)
}

enum AXWindowReadResult {
    case success([AXWindowSnapshot])
    case unread(AXError)

    var windowsOrEmpty: [AXWindowSnapshot] {
        switch self {
        case .success(let windows): return windows
        case .unread: return []
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

enum AXFocusedWindowRead: Equatable, Sendable {
    case window(CGWindowID)
    case none
    case unread(AXError)
}

struct AXFocusedWindowObservation: Sendable {
    let result: AXFocusedWindowRead
    let observedAt: TimeInterval
    init(result: AXFocusedWindowRead, observedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.result = result
        self.observedAt = observedAt
    }
}

enum AXSystemFocusedWindowRead: Equatable, Sendable {
    case window(pid: pid_t, windowID: CGWindowID)
    case none
    case unread(AXError)
}

struct AXSystemFocusedWindowObservation: Sendable {
    let result: AXSystemFocusedWindowRead
    let windowElement: AXElementKey?

    init(result: AXSystemFocusedWindowRead, windowElement: AXElementKey? = nil) {
        self.result = result
        self.windowElement = windowElement
    }
}

protocol AppTrackerWindowReading: Sendable {
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot]
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXWindowReadResult
    func focusedWindowRead(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXFocusedWindowObservation
    func systemFocusedWindowRead(messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXSystemFocusedWindowObservation
}

extension AppTrackerWindowReading {
    func systemFocusedWindowRead(messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXSystemFocusedWindowObservation {
        .init(result: .unread(.notImplemented))
    }

    func focusedWindowRead(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXFocusedWindowObservation {
        AXFocusedWindowObservation(result: .unread(.notImplemented))
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXWindowReadResult {
        guard !cancellation.isCancelled else { return .unread(.cannotComplete) }
        return inventoryWindows(forPID: pid, messagingTimeout: messagingTimeout)
    }
}

protocol AccessibilityOperations: Sendable {
    func isTrusted() -> Bool
    func application(_ pid: pid_t) -> AXUIElement
    func systemWide() -> AXUIElement?
    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?)
    func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> (AXError, [CFTypeRef]?)
    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError
    func perform(_ element: AXUIElement, _ action: CFString) -> AXError
    func pid(_ element: AXUIElement) -> pid_t?
    func windowID(_ element: AXUIElement) -> CGWindowID?
    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool)
}

extension AccessibilityOperations {
    func systemWide() -> AXUIElement? { nil }
    func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> (AXError, [CFTypeRef]?) {
        (.notImplemented, nil)
    }
}

struct NativeAccessibilityOperations: AccessibilityOperations {
    func isTrusted() -> Bool { AXIsProcessTrusted() }
    func application(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    func systemWide() -> AXUIElement? { AXUIElementCreateSystemWide() }
    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (error, value)
    }
    func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> (AXError, [CFTypeRef]?) {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values)
        return (error, values as? [CFTypeRef])
    }
    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute, value)
    }
    func perform(_ element: AXUIElement, _ action: CFString) -> AXError { AXUIElementPerformAction(element, action) }
    func pid(_ element: AXUIElement) -> pid_t? {
        var value: pid_t = 0
        return AXUIElementGetPid(element, &value) == .success ? value : nil
    }
    func windowID(_ element: AXUIElement) -> CGWindowID? { AXWindowIDBridge.cgWindowID(for: element) }
    func setTimeout(_ element: AXUIElement, _ timeout: Float) -> AXError { AXUIElementSetMessagingTimeout(element, timeout) }
    func isSettable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool) {
        var value = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute, &value)
        return (error, value.boolValue)
    }
}

struct AXWindowReader: AppTrackerWindowReading, Sendable {
    private typealias AttributeRead = (error: AXError, value: CFTypeRef?)
    private enum GeometryWrite {
        case size(CGSize)
        case frame(CGRect)
    }

    private struct GeometryWriteSample {
        let frame: CGRect
        var windowIDs: [CGWindowID?] = []
    }

    private static let geometryWriteAttributes = [kAXPositionAttribute, kAXSizeAttribute].map { $0 as String }
        + AXWindowIDBridge.fallbackAttributeNames
    private static let inventoryAttributes = [
        kAXMinimizedAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXRoleAttribute, kAXSubroleAttribute,
    ].map { $0 as String }

    let accessibility: any AccessibilityOperations
    private var budget: OperationReadBudget?
    private var readMessagingTimeout: TimeInterval = 0.1

    init(accessibility: any AccessibilityOperations = NativeAccessibilityOperations()) { self.accessibility = accessibility }

    func withOperationBudget(_ budget: OperationReadBudget) -> Self {
        var reader = self
        reader.budget = budget
        return reader
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXWindowReadResult {
        readWindows(forPID: pid, messagingTimeout: messagingTimeout, cancellation: cancellation)
    }

    func focusedWindowRead(forPID pid: pid_t, messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXFocusedWindowObservation {
        guard messagingTimeout.isFinite, messagingTimeout > 0 else { return .init(result: .unread(.illegalArgument)) }
        guard accessibility.isTrusted() else { return .init(result: .unread(.apiDisabled)) }
        var reader = self
        reader.readMessagingTimeout = messagingTimeout
        reader.budget = OperationReadBudget(maximumDuration: messagingTimeout * 2, cancellation: cancellation)
        let application = accessibility.application(pid)
        var value: CFTypeRef?
        let error = reader.copyAttributeValue(kAXFocusedWindowAttribute as CFString, from: application,
                                             into: &value, maxAttempts: 1)
        let observedAt = ProcessInfo.processInfo.systemUptime
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        if error == .noValue { return .init(result: .none, observedAt: observedAt) }
        guard error == .success else { return .init(result: .unread(error)) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .init(result: .unread(.failure)) }
        let element = value as! AXUIElement
        guard accessibility.pid(element) == pid else { return .init(result: .unread(.invalidUIElement)) }
        guard let remaining = reader.budget?.remaining, remaining > 0 else { return .init(result: .unread(.cannotComplete)) }
        reader.applyMessagingTimeout(min(messagingTimeout, remaining), to: element)
        guard let id = reader.cgWindowID(for: element, maxAttempts: 1), id != 0 else { return .init(result: .unread(.failure)) }
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        return .init(result: .window(id), observedAt: observedAt)
    }

    func systemFocusedWindowRead(messagingTimeout: TimeInterval, cancellation: OperationCancellation) -> AXSystemFocusedWindowObservation {
        guard messagingTimeout.isFinite, messagingTimeout > 0 else { return .init(result: .unread(.illegalArgument)) }
        guard accessibility.isTrusted() else { return .init(result: .unread(.apiDisabled)) }
        var reader = self
        reader.readMessagingTimeout = messagingTimeout
        reader.budget = OperationReadBudget(maximumDuration: messagingTimeout * 2, cancellation: cancellation)
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        guard let system = accessibility.systemWide() else { return .init(result: .unread(.notImplemented)) }
        let (error, value) = accessibility.copy(system, kAXFocusedUIElementAttribute as CFString)
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        if error == .noValue { return .init(result: .none) }
        guard error == .success else { return .init(result: .unread(error)) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .init(result: .unread(.failure)) }
        let focused = value as! AXUIElement
        guard let pid = accessibility.pid(focused) else { return .init(result: .unread(.invalidUIElement)) }
        var role: CFTypeRef?
        let roleError = reader.copyAttributeValue(kAXRoleAttribute as CFString, from: focused, into: &role, maxAttempts: 1)
        guard roleError == .success else { return .init(result: .unread(roleError)) }
        let window: AXUIElement
        if role as? String == kAXWindowRole as String {
            window = focused
        } else {
            var windowValue: CFTypeRef?
            let windowError = reader.copyAttributeValue(kAXWindowAttribute as CFString, from: focused, into: &windowValue, maxAttempts: 1)
            if windowError == .noValue { return .init(result: .none) }
            guard windowError == .success else { return .init(result: .unread(windowError)) }
            guard let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return .init(result: .unread(.failure)) }
            window = windowValue as! AXUIElement
        }
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        guard accessibility.pid(window) == pid else { return .init(result: .unread(.invalidUIElement)) }
        guard let remaining = reader.budget?.remaining, remaining > 0 else { return .init(result: .unread(.cannotComplete)) }
        reader.applyMessagingTimeout(min(messagingTimeout, remaining), to: window)
        guard let id = reader.cgWindowID(for: window, maxAttempts: 1), id != 0 else { return .init(result: .unread(.failure)) }
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        let (latestError, latest) = accessibility.copy(system, kAXFocusedUIElementAttribute as CFString)
        guard reader.budget?.canContinue == true else { return .init(result: .unread(.cannotComplete)) }
        guard latestError == .success else { return .init(result: .unread(latestError)) }
        guard let latest, CFEqual(latest, focused), accessibility.pid(focused) == pid,
              accessibility.pid(window) == pid else { return .init(result: .unread(.invalidUIElement)) }
        return .init(result: .window(pid: pid, windowID: id), windowElement: AXElementKey(e: window))
    }

    static func validatedElements(_ value: CFTypeRef?, budget: OperationReadBudget? = nil) -> [AXUIElement]? {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID(), let values = value as? [AnyObject] else { return nil }
        var result: [AXUIElement] = []
        for element in values {
            guard budget?.canContinue ?? true, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
            result.append(unsafeBitCast(element, to: AXUIElement.self))
        }
        return result
    }

    func windows(for app: NSRunningApplication) -> [AXWindowSnapshot] {
        windows(forPID: app.processIdentifier)
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] {
        windowReadResult(forPID: pid).windowsOrEmpty
    }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        readWindows(forPID: pid, messagingTimeout: nil)
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        readWindows(forPID: pid, messagingTimeout: messagingTimeout)
    }

    private func readWindows(forPID pid: pid_t, messagingTimeout: TimeInterval?,
                             cancellation: OperationCancellation = OperationCancellation(),
                             expectedElement: AXElementKey? = nil) -> AXWindowReadResult {
        var reader = self
        if let messagingTimeout {
            guard messagingTimeout.isFinite, messagingTimeout > 0 else { return .unread(.illegalArgument) }
            reader.readMessagingTimeout = messagingTimeout
        }
        reader.budget = budget?.limited(to: 2)
            ?? OperationReadBudget(maximumDuration: 2, cancellation: cancellation)
        return reader.readWindowsWithinBudget(forPID: pid, messagingTimeout: messagingTimeout,
                                              expectedElement: expectedElement)
    }

    private func readWindowsWithinBudget(forPID pid: pid_t, messagingTimeout: TimeInterval?,
                                         expectedElement: AXElementKey?) -> AXWindowReadResult {
        guard budget?.canContinue ?? true else { return .unread(.cannotComplete) }
        let appElement = accessibility.application(pid)
        applyMessagingTimeout(messagingTimeout, to: appElement)

        var rawWindows: CFTypeRef?
        let maxAttempts = messagingTimeout == nil ? 2 : 1
        let result = copyAttributeValue(
            kAXWindowsAttribute as CFString,
            from: appElement,
            into: &rawWindows,
            maxAttempts: maxAttempts
        )
        guard result == .success else { return .unread(result) }
        guard var elements = Self.validatedElements(rawWindows, budget: budget) else {
            return .unread(budget?.canContinue == false ? .cannotComplete : .failure)
        }

        var focusedValue: CFTypeRef?
        let focusedError = copyAttributeValue(kAXFocusedWindowAttribute as CFString, from: appElement,
                                             into: &focusedValue, maxAttempts: maxAttempts)
        let focusedElement: AXUIElement?
        if focusedError == .success, let value = focusedValue, CFGetTypeID(value) == AXUIElementGetTypeID() {
            focusedElement = value as! AXUIElement
        } else { focusedElement = nil }
        let focusReadUptime: TimeInterval? = focusedElement != nil || focusedError == .noValue
            ? ProcessInfo.processInfo.systemUptime : nil
        let mainElement = elementAttribute(kAXMainWindowAttribute as CFString, from: appElement, maxAttempts: maxAttempts)
        for element in [focusedElement, mainElement].compactMap({ $0 }) {
            guard !elements.contains(where: { CFEqual($0, element) }) else { continue }
            elements.append(element)
        }
        if let expectedElement {
            guard let element = elements.first(where: { AXElementKey(e: $0) == expectedElement }) else {
                return .success([])
            }
            elements = [element]
        }
        var snapshots: [AXWindowSnapshot] = []
        for element in elements {
            guard budget?.canContinue ?? true else { return .unread(.cannotComplete) }
            guard let ownerPID = accessibility.pid(element) else { return .unread(.cannotComplete) }
            guard ownerPID == pid else { continue }
            let batch = readInventoryAttributes(from: element)
            func attribute(_ name: String) -> AttributeRead {
                if let read = batch[name] { return read }
                var value: CFTypeRef?
                let error = copyAttributeValue(name as CFString, from: element, into: &value, maxAttempts: maxAttempts)
                return (error, error == .success ? value : nil)
            }
            let minimizedRead = attribute(kAXMinimizedAttribute as String)
            let minimized: Bool?
            switch minimizedRead.error {
            case .success:
                guard let value = minimizedRead.value as? NSNumber else { return .unread(.failure) }
                minimized = value.boolValue
            case .attributeUnsupported, .noValue:
                minimized = nil
            default:
                return .unread(minimizedRead.error)
            }
            let windowID = cgWindowID(for: element, maxAttempts: maxAttempts)
            let titleRead = attribute(kAXTitleAttribute as String)
            let title = AXWindowTitleRead.classify(result: titleRead.error, value: titleRead.value)
            let position = attribute(kAXPositionAttribute as String).value
            let bounds = position.flatMap { position in
                frame(position: position, size: attribute(kAXSizeAttribute as String).value)
            }
            let role = normalizedString(attribute(kAXRoleAttribute as String).value)
            let subrole = normalizedString(attribute(kAXSubroleAttribute as String).value)
            var isModal: Bool?
            var isTopLevel: Bool?
            if subrole == kAXDialogSubrole as String || subrole == kAXUnknownSubrole as String {
                isModal = boolAttribute(kAXModalAttribute as CFString, from: element, maxAttempts: maxAttempts)
                if let parent = elementAttribute(kAXParentAttribute as CFString, from: element, maxAttempts: maxAttempts) {
                    isTopLevel = accessibility.pid(parent) == pid
                        && stringAttribute(kAXRoleAttribute as CFString, from: parent, maxAttempts: maxAttempts) == kAXApplicationRole as String
                }
            }
            snapshots.append(AXWindowSnapshot(
                pid: pid,
                cgWindowID: windowID,
                titleRead: title,
                bounds: bounds,
                role: role,
                subrole: subrole,
                isMinimized: minimized ?? false,
                isFocusedWindow: focusedElement.map { CFEqual($0, element) } ?? false,
                element: element,
                isMinimizedRead: minimized,
                focusReadUptime: focusReadUptime,
                isModal: isModal, isTopLevel: isTopLevel
            ))
        }
        guard budget?.canContinue ?? true else { return .unread(.cannotComplete) }
        return .success(snapshots)
    }

    private func readInventoryAttributes(from element: AXUIElement) -> [String: AttributeRead] {
        let attributes = Self.inventoryAttributes
        guard budget?.canContinue ?? true else {
            return [kAXMinimizedAttribute as String: (.cannotComplete, nil)]
        }
        applyMessagingTimeout(min(readMessagingTimeout, budget?.remaining ?? readMessagingTimeout), to: element)
        let (error, values) = accessibility.copyAttributes(element, attributes)
        switch error {
        case .notImplemented, .attributeUnsupported, .illegalArgument, .failure:
            return [:]
        case .success:
            guard let values, values.count == attributes.count else { return [:] }
            var result: [String: AttributeRead] = [:]
            for (attribute, value) in zip(attributes, values) {
                let type = CFGetTypeID(value)
                if type == CFNullGetTypeID() { continue }
                var error = AXError.failure
                if type == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .axError, &error) {
                    result[attribute] = (error, nil)
                } else {
                    result[attribute] = (.success, value)
                }
            }
            return result
        default:
            return [kAXMinimizedAttribute as String: (error, nil)]
        }
    }

    func captureHandle(
        for target: AXWindowTarget,
        attempts: Int = 1,
        retryIntervalMicroseconds: useconds_t = 0,
        messagingTimeout: TimeInterval? = nil,
        cancellation: OperationCancellation = OperationCancellation()
    ) -> AXWindowHandle? {
        guard !cancellation.isCancelled, accessibility.isTrusted(), budget?.canContinue != false else { return nil }
        let boundedAttempts = max(1, attempts)

        for attempt in 0..<boundedAttempts {
            guard !cancellation.isCancelled, budget?.canContinue != false else { return nil }
            let candidates: [AXWindowSnapshot]
            switch readWindows(forPID: target.pid, messagingTimeout: messagingTimeout,
                               cancellation: cancellation, expectedElement: target.expectedElement) {
            case .success(let snapshots): candidates = snapshots
            case .unread: candidates = []
            }
            guard !cancellation.isCancelled, budget?.canContinue != false else { return nil }
            if let snapshot = bestMatch(for: target, from: candidates) {
                return AXWindowHandle(
                    pid: target.pid,
                    title: snapshot.title,
                    bounds: snapshot.bounds,
                    element: snapshot.element
                )
            }

            if attempt < boundedAttempts - 1, retryIntervalMicroseconds > 0 {
                let interval = Double(retryIntervalMicroseconds) / 1_000_000
                let wait = min(interval, budget?.remaining ?? interval)
                if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
            }
        }

        return nil
    }

    func captureHandle(
        forPID pid: pid_t,
        cgWindowID: CGWindowID,
        messagingTimeout: TimeInterval = 0.1,
        expectedElement: AXElementKey? = nil
    ) -> AXWindowHandle? {
        guard budget?.canContinue != false, accessibility.isTrusted(),
              cgWindowID != 0,
              messagingTimeout.isFinite,
              messagingTimeout > 0 else {
            return nil
        }

        let deadline = ProcessInfo.processInfo.systemUptime + min(messagingTimeout, budget?.remaining ?? messagingTimeout)
        let appElement = accessibility.application(pid)

        func remainingTimeout() -> TimeInterval? {
            guard budget?.canContinue != false else { return nil }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            return remaining > 0 ? remaining : nil
        }

        func matches(_ element: AXUIElement) -> Bool {
            if let expectedElement, AXElementKey(e: element) != expectedElement { return false }
            guard accessibility.pid(element) == pid, let timeout = remainingTimeout() else { return false }
            applyMessagingTimeout(timeout, to: element)
            if let bridgedID = accessibility.windowID(element) {
                return bridgedID == cgWindowID
            }

            for attribute in AXWindowIDBridge.fallbackAttributeNames {
                guard let timeout = remainingTimeout() else { return false }
                applyMessagingTimeout(timeout, to: element)
                if let id = numericWindowIDAttribute(attribute as CFString, from: element, maxAttempts: 1) {
                    return id == cgWindowID
                }
            }
            return false
        }

        func elementAttributeWithinDeadline(_ attribute: CFString) -> AXUIElement? {
            guard let timeout = remainingTimeout() else { return nil }
            applyMessagingTimeout(timeout, to: appElement)
            return elementAttribute(attribute, from: appElement, maxAttempts: 1)
        }

        if let focused = elementAttributeWithinDeadline(kAXFocusedWindowAttribute as CFString),
           matches(focused) {
            return AXWindowHandle(pid: pid, title: nil, bounds: nil, element: focused)
        }
        if let main = elementAttributeWithinDeadline(kAXMainWindowAttribute as CFString),
           matches(main) {
            return AXWindowHandle(pid: pid, title: nil, bounds: nil, element: main)
        }

        guard let timeout = remainingTimeout() else { return nil }
        applyMessagingTimeout(timeout, to: appElement)
        var rawWindows: CFTypeRef?
        guard copyAttributeValue(
            kAXWindowsAttribute as CFString,
            from: appElement,
            into: &rawWindows,
            maxAttempts: 1
        ) == .success,
              let elements = Self.validatedElements(rawWindows, budget: budget),
              let element = elements.first(where: matches) else {
            return nil
        }

        return AXWindowHandle(
            pid: pid,
            title: nil,
            bounds: nil,
            element: element
        )
    }

    func focusedWindow(forPID pid: pid_t, messagingTimeout: TimeInterval? = nil) -> AXUIElement? {
        let app = accessibility.application(pid)
        applyMessagingTimeout(messagingTimeout, to: app)
        return elementAttribute(kAXFocusedWindowAttribute as CFString, from: app,
                                maxAttempts: messagingTimeout == nil ? 2 : 1)
    }

    func stringAttribute(_ attribute: CFString, from element: AXUIElement, maxAttempts: Int = 2) -> String? {
        normalizedString(copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts))
    }

    private func normalizedString(_ value: CFTypeRef?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func titleAttribute(from element: AXUIElement, maxAttempts: Int = 2) -> AXWindowTitleRead {
        var value: CFTypeRef?
        let result = copyAttributeValue(
            kAXTitleAttribute as CFString,
            from: element,
            into: &value,
            maxAttempts: maxAttempts
        )
        return AXWindowTitleRead.classify(result: result, value: value)
    }

    func boolAttribute(_ attribute: CFString, from element: AXUIElement, maxAttempts: Int = 2) -> Bool? {
        guard let value = copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    func cgWindowID(for element: AXUIElement, maxAttempts: Int = 2, messagingTimeout: TimeInterval? = nil) -> UInt32? {
        guard budget?.canContinue != false else { return nil }
        applyMessagingTimeout(messagingTimeout, to: element)
        if let bridgedID = accessibility.windowID(element) {
            return bridgedID
        }

        for attribute in AXWindowIDBridge.fallbackAttributeNames {
            if let id = numericWindowIDAttribute(attribute as CFString, from: element, maxAttempts: maxAttempts) {
                return id
            }
        }

        return nil
    }

    /// 校验一个**缓存下来的** AX 元素是否仍指向期望的窗口。三态，不折叠：
    /// - `true`：确认是同一个窗口，可以直接用。
    /// - `false`：读到了、但换了窗口（cgWindowID 复用）——缓存条目必须作废。
    /// - `nil`：**没读到**（App 打盹 / 超时）。这不是陈旧的证据，调用方只该回落到既有捕获链，
    ///   **不要因此删缓存**——把一次瞬时超时固化成永久失效，比原来的 bug 更糟
    ///   （同 `AppNameRegistry` 那条教训）。
    func matchesCGWindowID(
        _ expected: CGWindowID,
        element: AXUIElement,
        messagingTimeout: TimeInterval
    ) -> Bool? {
        applyMessagingTimeout(messagingTimeout, to: element)
        guard let actual = accessibility.windowID(element) else { return nil }
        return actual == expected
    }

    func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        maxAttempts: Int = 2
    ) -> AXUIElement? {
        guard let value = copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func frame(of element: AXUIElement, maxAttempts: Int = 2) -> CGRect? {
        guard let positionAX = copyAttributeValue(kAXPositionAttribute as CFString, from: element, maxAttempts: maxAttempts),
              let sizeAX = copyAttributeValue(kAXSizeAttribute as CFString, from: element, maxAttempts: maxAttempts) else {
            return nil
        }

        return frame(position: positionAX, size: sizeAX)
    }

    private func frame(position positionAX: CFTypeRef, size sizeAX: CFTypeRef?) -> CGRect? {
        guard let sizeAX, let position = axValue(from: positionAX),
              let sizeValueRef = axValue(from: sizeAX) else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(position) == .cgPoint,
              AXValueGetType(sizeValueRef) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(sizeValueRef, .cgSize, &size) else {
            return nil
        }

        let frame = CGRect(origin: point, size: size)
        return WindowFrameMatchPolicy.isValid(frame) ? frame : nil
    }

    func frame(of element: AXUIElement, messagingTimeout: TimeInterval) -> CGRect? {
        applyMessagingTimeout(messagingTimeout, to: element)
        return frame(of: element, maxAttempts: 1)
    }

    func frameSettableStatus(
        of element: AXUIElement,
        messagingTimeout: TimeInterval = 0.1
    ) -> AXWindowFrameSettableStatus {
        applyMessagingTimeout(messagingTimeout, to: element)
        return AXWindowFrameSettableStatus(
            position: settableStatus(kAXPositionAttribute as CFString, on: element),
            size: settableStatus(kAXSizeAttribute as CFString, on: element)
        )
    }

    func setSize(
        _ size: CGSize,
        for element: AXUIElement,
        messagingTimeout: TimeInterval = 0.1,
        verificationTolerance: CGFloat = 1,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect? = nil,
        restoreOnFailureTo restoreFrame: CGRect? = nil,
        expectedWindowID: CGWindowID? = nil,
        onAttempt: (CGRect) -> Void = { _ in },
        checkWriteAdmission: () -> AXWindowFrameWriteFailure? = { nil }
    ) -> AXWindowFrameWriteResult {
        performGeometryWrite(
            .size(size), for: element, messagingTimeout: messagingTimeout,
            verificationTolerance: verificationTolerance,
            onlyIfCurrentMatches: expectedCurrentFrame,
            restoreOnFailureTo: restoreFrame,
            expectedWindowID: expectedWindowID,
            onAttempt: onAttempt,
            checkWriteAdmission: checkWriteAdmission
        )
    }

    func setFrame(
        _ frame: CGRect,
        for element: AXUIElement,
        messagingTimeout: TimeInterval = 0.1,
        verificationTolerance: CGFloat = 1,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect? = nil,
        restoreOnFailureTo restoreFrame: CGRect? = nil,
        expectedWindowID: CGWindowID? = nil,
        onAttempt: (CGRect) -> Void = { _ in },
        checkWriteAdmission: () -> AXWindowFrameWriteFailure? = { nil }
    ) -> AXWindowFrameWriteResult {
        performGeometryWrite(
            .frame(frame), for: element, messagingTimeout: messagingTimeout,
            verificationTolerance: verificationTolerance,
            onlyIfCurrentMatches: expectedCurrentFrame,
            restoreOnFailureTo: restoreFrame,
            expectedWindowID: expectedWindowID,
            onAttempt: onAttempt,
            checkWriteAdmission: checkWriteAdmission
        )
    }

    private func performGeometryWrite(
        _ geometry: GeometryWrite,
        for element: AXUIElement,
        messagingTimeout: TimeInterval,
        verificationTolerance: CGFloat,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect?,
        restoreOnFailureTo restoreFrame: CGRect?,
        expectedWindowID: CGWindowID?,
        onAttempt: (CGRect) -> Void,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?
    ) -> AXWindowFrameWriteResult {
        applyMessagingTimeout(messagingTimeout, to: element)
        guard isValid(geometry), isValid(tolerance: verificationTolerance),
              expectedCurrentFrame.map(isValid(frame:)) ?? true,
              restoreFrame.map(isValid(frame:)) ?? true else {
            return .failure(reason: .invalidGeometry, rollback: .notRequested)
        }

        var attemptedFrames: [CGRect] = []
        func recordAttempt(_ frame: CGRect) {
            attemptedFrames.append(frame)
            onAttempt(frame)
        }
        let result: Result<CGRect, AXWindowFrameWriteFailure>
        switch geometry {
        case let .size(size):
            result = writeSize(
                size, to: element, verificationTolerance: verificationTolerance,
                onlyIfCurrentMatches: expectedCurrentFrame, expectedWindowID: expectedWindowID,
                checkWriteAdmission: checkWriteAdmission, recordAttempt: recordAttempt
            )
        case let .frame(frame):
            result = writeFrame(
                frame, to: element, verificationTolerance: verificationTolerance,
                onlyIfCurrentMatches: expectedCurrentFrame, expectedWindowID: expectedWindowID,
                checkWriteAdmission: checkWriteAdmission, recordAttempt: recordAttempt
            )
        }
        switch result {
        case let .success(actualFrame):
            return .success(actualFrame: actualFrame)
        case let .failure(reason):
            return .failure(
                reason: reason,
                rollback: rollbackResult(
                    after: reason,
                    to: restoreFrame,
                    for: element,
                    attemptedFrames: attemptedFrames,
                    verificationTolerance: verificationTolerance,
                    expectedWindowID: expectedWindowID,
                    checkWriteAdmission: checkWriteAdmission
                )
            )
        }
    }

    func setMinimized(_ minimized: Bool, for handle: AXWindowHandle) -> Bool {
        let value: CFTypeRef = minimized ? kCFBooleanTrue : kCFBooleanFalse
        let result = accessibility.set(
            handle.element,
            kAXMinimizedAttribute as CFString,
            value
        )
        return result == .success
    }

    func copyAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement,
        maxAttempts: Int = 2
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = copyAttributeValue(attribute, from: element, into: &value, maxAttempts: maxAttempts)
        return result == .success ? value : nil
    }

    @discardableResult
    func copyAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement,
        into value: inout CFTypeRef?,
        maxAttempts: Int = 2
    ) -> AXError {
        var attempt = 0
        var lastResult: AXError = .failure
        while attempt < maxAttempts {
            if let budget {
                guard budget.canContinue else { return .cannotComplete }
                applyMessagingTimeout(min(readMessagingTimeout, budget.remaining), to: element)
            }
            let result: AXError
            (result, value) = accessibility.copy(element, attribute)
            if result == .success {
                return result
            }

            lastResult = result
            if result != .cannotComplete {
                return result
            }

            attempt += 1
        }

        return lastResult
    }

    private func numericWindowIDAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        maxAttempts: Int
    ) -> UInt32? {
        guard let value = copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts) else {
            return nil
        }
        return AXWindowIDBridge.cgWindowID(from: value)
    }

    private func axValue(from value: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private func settableStatus(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> AXWindowAttributeSettableStatus {
        guard budget?.canContinue ?? true else { return .unread(.cannotComplete) }
        if let budget { applyMessagingTimeout(min(readMessagingTimeout, budget.remaining), to: element) }
        let (result, isSettable) = accessibility.isSettable(element, attribute)
        guard result == .success else { return .unread(result) }
        return isSettable ? .settable : .notSettable
    }

    private func windowIdentityFailure(_ expectedWindowID: CGWindowID?, for element: AXUIElement) -> AXWindowFrameWriteFailure? {
        guard let expectedWindowID else { return nil }
        guard budget?.canContinue != false else { return .operationBudgetExhausted }
        guard let actualWindowID = cgWindowID(for: element, maxAttempts: 1) else {
            return budget?.canContinue == false ? .operationBudgetExhausted : .initialFrameUnavailable
        }
        return actualWindowID == expectedWindowID ? nil : .windowIdentityChanged
    }

    private func geometryWriteSample(
        for element: AXUIElement, expectedWindowID: CGWindowID?, maxAttempts: Int
    ) -> GeometryWriteSample? {
        if expectedWindowID != nil {
            guard budget?.canContinue != false else { return nil }
            if let budget { applyMessagingTimeout(min(readMessagingTimeout, budget.remaining), to: element) }
            let attributes = Self.geometryWriteAttributes
            let (error, values) = accessibility.copyAttributes(element, attributes)
            switch error {
            case .success:
                if let values, values.count == attributes.count,
                   let frame = frame(position: values[0], size: values[1]) {
                    return GeometryWriteSample(frame: frame, windowIDs: values.dropFirst(2).map(AXWindowIDBridge.cgWindowID))
                }
            case .notImplemented, .attributeUnsupported, .illegalArgument, .failure:
                break
            default:
                return nil
            }
        }
        return frame(of: element, maxAttempts: maxAttempts).map { GeometryWriteSample(frame: $0) }
    }

    private func writeGeometryAttribute(
        _ attribute: AXWindowFrameAttribute, to element: AXUIElement, value: CFTypeRef,
        expectedWindowID: CGWindowID?, sample: GeometryWriteSample,
        onlyIfCurrentMatches expectedFrame: CGRect?, verificationTolerance: CGFloat,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?, onAttempt: (CGRect) -> Void
    ) -> AXWindowFrameWriteFailure? {
        guard budget?.canContinue != false else { return .operationBudgetExhausted }
        if let budget { applyMessagingTimeout(min(readMessagingTimeout, budget.remaining), to: element) }
        if let failure = windowIdentityFailure(expectedWindowID, for: element) { return failure }
        var admittedFrame = sample.frame
        if let expectedWindowID, let expectedFrame {
            guard let current = geometryWriteSample(for: element, expectedWindowID: expectedWindowID, maxAttempts: 1) else {
                if budget?.canContinue == false { return .operationBudgetExhausted }
                return attribute == .position ? .verificationUnavailable : .initialFrameUnavailable
            }
            for (index, id) in sample.windowIDs.enumerated() where id == expectedWindowID {
                guard current.windowIDs.indices.contains(index), current.windowIDs[index] == expectedWindowID else {
                    return .windowIdentityChanged
                }
            }
            guard framesMatch(current.frame, expectedFrame, tolerance: verificationTolerance) else {
                return attribute == .position
                    ? .verificationUnavailable
                    : .initialFrameMismatch(expected: expectedFrame, actual: current.frame)
            }
            admittedFrame = current.frame
        }
        if let failure = checkWriteAdmission() { return failure }
        guard budget?.canContinue != false else { return .operationBudgetExhausted }
        onAttempt(admittedFrame)
        let name = attribute == .size ? kAXSizeAttribute : kAXPositionAttribute
        let result = accessibility.set(element, name as CFString, value)
        return result == .success ? nil : .writeFailed(attribute: attribute, error: result)
    }

    private func writeSize(
        _ size: CGSize,
        to element: AXUIElement,
        verificationTolerance: CGFloat,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect? = nil,
        expectedWindowID: CGWindowID?,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?,
        recordAttempt: (CGRect) -> Void = { _ in }
    ) -> Result<CGRect, AXWindowFrameWriteFailure> {
        guard let initialFrame = frame(of: element, maxAttempts: 1) else {
            return .failure(budget?.canContinue == false ? .operationBudgetExhausted : .initialFrameUnavailable)
        }
        if let expectedCurrentFrame,
           !framesMatch(initialFrame, expectedCurrentFrame, tolerance: verificationTolerance) {
            return .failure(.initialFrameMismatch(expected: expectedCurrentFrame, actual: initialFrame))
        }

        if sizesMatch(initialFrame.size, size, tolerance: verificationTolerance) {
            return .success(initialFrame)
        }

        switch settableStatus(kAXSizeAttribute as CFString, on: element) {
        case .settable:
            break
        case .notSettable:
            return .failure(.attributeNotSettable(.size))
        case let .unread(error):
            return .failure(.capabilityQueryFailed(attribute: .size, error: error))
        }

        var mutableSize = size
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else {
            return .failure(.valueCreationFailed(.size))
        }
        if let failure = windowIdentityFailure(expectedWindowID, for: element) {
            return .failure(failure)
        }
        var sample = GeometryWriteSample(frame: initialFrame)
        if let expectedCurrentFrame {
            guard let current = geometryWriteSample(for: element, expectedWindowID: expectedWindowID, maxAttempts: 1) else {
                return .failure(budget?.canContinue == false ? .operationBudgetExhausted : .initialFrameUnavailable)
            }
            guard framesMatch(current.frame, expectedCurrentFrame, tolerance: verificationTolerance) else {
                return .failure(.initialFrameMismatch(expected: expectedCurrentFrame, actual: current.frame))
            }
            sample = current
        }

        var expectedFrame = CGRect(origin: sample.frame.origin, size: size)
        if let failure = writeGeometryAttribute(
            .size, to: element, value: sizeValue, expectedWindowID: expectedWindowID, sample: sample,
            onlyIfCurrentMatches: expectedCurrentFrame, verificationTolerance: verificationTolerance,
            checkWriteAdmission: checkWriteAdmission,
            onAttempt: { admitted in
                expectedFrame.origin = admitted.origin
                recordAttempt(expectedFrame)
            }
        ) {
            return .failure(failure)
        }

        guard let actualFrame = frame(of: element, maxAttempts: 2) else {
            return .failure(.verificationUnavailable)
        }
        guard framesMatch(actualFrame, expectedFrame, tolerance: verificationTolerance) else {
            return .failure(.verificationMismatch(expected: expectedFrame, actual: actualFrame))
        }
        return .success(actualFrame)
    }

    private func writeFrame(
        _ targetFrame: CGRect,
        to element: AXUIElement,
        verificationTolerance: CGFloat,
        onlyIfCurrentMatches expectedCurrentFrame: CGRect? = nil,
        expectedWindowID: CGWindowID?,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?,
        recordAttempt: (CGRect) -> Void = { _ in }
    ) -> Result<CGRect, AXWindowFrameWriteFailure> {
        guard let initialFrame = frame(of: element, maxAttempts: 1) else {
            return .failure(.initialFrameUnavailable)
        }
        if let expectedCurrentFrame,
           !framesMatch(initialFrame, expectedCurrentFrame, tolerance: verificationTolerance) {
            return .failure(.initialFrameMismatch(expected: expectedCurrentFrame, actual: initialFrame))
        }
        if framesMatch(initialFrame, targetFrame, tolerance: verificationTolerance) {
            return .success(initialFrame)
        }

        let needsSize = !sizesMatch(
            initialFrame.size,
            targetFrame.size,
            tolerance: verificationTolerance
        )
        let needsPosition = !pointsMatch(
            initialFrame.origin,
            targetFrame.origin,
            tolerance: verificationTolerance
        )

        if needsSize {
            switch settableStatus(kAXSizeAttribute as CFString, on: element) {
            case .settable:
                break
            case .notSettable:
                return .failure(.attributeNotSettable(.size))
            case let .unread(error):
                return .failure(.capabilityQueryFailed(attribute: .size, error: error))
            }
        }
        if needsPosition {
            switch settableStatus(kAXPositionAttribute as CFString, on: element) {
            case .settable:
                break
            case .notSettable:
                return .failure(.attributeNotSettable(.position))
            case let .unread(error):
                return .failure(.capabilityQueryFailed(attribute: .position, error: error))
            }
        }

        var mutableSize = targetFrame.size
        let sizeValue = needsSize ? AXValueCreate(.cgSize, &mutableSize) : nil
        if needsSize, sizeValue == nil {
            return .failure(.valueCreationFailed(.size))
        }

        var mutablePosition = targetFrame.origin
        let positionValue = needsPosition ? AXValueCreate(.cgPoint, &mutablePosition) : nil
        if needsPosition, positionValue == nil {
            return .failure(.valueCreationFailed(.position))
        }
        if let failure = windowIdentityFailure(expectedWindowID, for: element) {
            return .failure(failure)
        }
        var sample = GeometryWriteSample(frame: initialFrame)
        if let expectedCurrentFrame {
            guard let current = geometryWriteSample(for: element, expectedWindowID: expectedWindowID, maxAttempts: 1) else {
                return .failure(.initialFrameUnavailable)
            }
            guard framesMatch(current.frame, expectedCurrentFrame, tolerance: verificationTolerance) else {
                return .failure(.initialFrameMismatch(expected: expectedCurrentFrame, actual: current.frame))
            }
            sample = current
        }

        var admittedFrame = sample.frame
        if let sizeValue {
            if let failure = writeGeometryAttribute(
                .size, to: element, value: sizeValue, expectedWindowID: expectedWindowID, sample: sample,
                onlyIfCurrentMatches: expectedCurrentFrame, verificationTolerance: verificationTolerance,
                checkWriteAdmission: checkWriteAdmission,
                onAttempt: { admitted in
                    admittedFrame = admitted
                    recordAttempt(CGRect(origin: admitted.origin, size: targetFrame.size))
                }
            ) {
                return .failure(failure)
            }
        }

        if let positionValue {
            if needsSize, let failure = windowIdentityFailure(expectedWindowID, for: element) {
                return .failure(failure)
            }
            let expectedPartial = CGRect(origin: admittedFrame.origin, size: needsSize ? targetFrame.size : admittedFrame.size)
            guard let current = geometryWriteSample(for: element, expectedWindowID: expectedWindowID, maxAttempts: 2),
                  framesMatch(current.frame, expectedPartial, tolerance: verificationTolerance) else {
                return .failure(.verificationUnavailable)
            }
            if let failure = writeGeometryAttribute(
                .position, to: element, value: positionValue, expectedWindowID: expectedWindowID, sample: current,
                onlyIfCurrentMatches: expectedPartial, verificationTolerance: verificationTolerance,
                checkWriteAdmission: checkWriteAdmission,
                onAttempt: { _ in recordAttempt(targetFrame) }
            ) {
                return .failure(needsSize && failure == .operationBudgetExhausted ? .verificationUnavailable : failure)
            }
        }

        guard let actualFrame = frame(of: element, maxAttempts: 2) else {
            return .failure(.verificationUnavailable)
        }
        guard framesMatch(actualFrame, targetFrame, tolerance: verificationTolerance) else {
            return .failure(.verificationMismatch(expected: targetFrame, actual: actualFrame))
        }
        return .success(actualFrame)
    }

    private func rollbackResult(
        after failure: AXWindowFrameWriteFailure,
        to restoreFrame: CGRect?,
        for element: AXUIElement,
        attemptedFrames: [CGRect],
        verificationTolerance: CGFloat,
        expectedWindowID: CGWindowID?,
        checkWriteAdmission: () -> AXWindowFrameWriteFailure?
    ) -> AXWindowFrameRollbackResult {
        guard failure.mayHaveMutatedWindow, let restoreFrame else {
            return .notRequested
        }

        guard let current = frame(of: element, maxAttempts: 1) else {
            return .failed(reason: .verificationUnavailable, actualFrame: nil)
        }
        guard AXWindowFrameRollbackPolicy.accepts(current, attemptedFrames: attemptedFrames, tolerance: verificationTolerance) else {
            return .failed(reason: .initialFrameMismatch(expected: attemptedFrames.last ?? restoreFrame, actual: current), actualFrame: current)
        }
        switch writeFrame(
            restoreFrame,
            to: element,
            verificationTolerance: verificationTolerance,
            onlyIfCurrentMatches: current,
            expectedWindowID: expectedWindowID,
            checkWriteAdmission: checkWriteAdmission
        ) {
        case let .success(actualFrame):
            return .restored(actualFrame: actualFrame)
        case let .failure(reason):
            return .failed(
                reason: reason,
                actualFrame: frame(of: element, maxAttempts: 1)
            )
        }
    }

    private func isValid(size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private func isValid(_ geometry: GeometryWrite) -> Bool {
        switch geometry {
        case let .size(size): isValid(size: size)
        case let .frame(frame): isValid(frame: frame)
        }
    }

    private func isValid(frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && isValid(size: frame.size)
    }

    private func isValid(tolerance: CGFloat) -> Bool {
        tolerance.isFinite && tolerance >= 0
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        pointsMatch(lhs.origin, rhs.origin, tolerance: tolerance)
            && sizesMatch(lhs.size, rhs.size, tolerance: tolerance)
    }

    private func pointsMatch(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    private func sizesMatch(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private func applyMessagingTimeout(_ timeout: TimeInterval?, to element: AXUIElement) {
        guard let timeout else { return }
        let boundedTimeout = min(timeout, budget?.remaining ?? timeout)
        guard boundedTimeout > 0 else { return }
        _ = accessibility.setTimeout(element, Float(boundedTimeout))
    }

    private func bestMatch(
        for target: AXWindowTarget,
        from snapshots: [AXWindowSnapshot]
    ) -> AXWindowSnapshot? {
        if target.expectedElement != nil, target.cgWindowID == nil {
            return snapshots.first
        }
        let candidates = snapshots.map {
            AXWindowMatchPolicy.Candidate(title: $0.title, bounds: $0.bounds, cgWindowID: $0.cgWindowID)
        }
        guard let index = AXWindowMatchPolicy.uniqueBestMatchIndex(
            targetTitle: target.title,
            targetBounds: target.bounds,
            candidates: candidates,
            expectedCGWindowID: target.cgWindowID
        ) else { return nil }
        return snapshots[index]
    }

}

enum AXWindowIDBridge {
    typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let fallbackAttributeNames = ["AXWindowID", "AXWindowNumber"]

    private static let getWindowFunction: GetWindowFunction? = {
        let frameworkPaths = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        ]
        let symbolNames = [
            "_AXUIElementGetWindow",
            "AXUIElementGetWindow"
        ]

        for path in frameworkPaths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            for symbolName in symbolNames {
                if let symbol = dlsym(handle, symbolName) {
                    return unsafeBitCast(symbol, to: GetWindowFunction.self)
                }
            }
            dlclose(handle)
        }

        return nil
    }()

    static func cgWindowID(for element: AXUIElement) -> UInt32? {
        guard let getWindowFunction else { return nil }

        var windowID = CGWindowID(0)
        guard getWindowFunction(element, &windowID) == .success else {
            return nil
        }
        return windowID == 0 ? nil : UInt32(windowID)
    }

    static func cgWindowID(from value: CFTypeRef) -> UInt32? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let id = UInt32(exactly: number.doubleValue), id != 0 else { return nil }
            return id
        }

        if let string = value as? String,
           let id = UInt32(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id == 0 ? nil : id
        }

        return nil
    }
}

#if DEBUG
extension AXWindowFrameAttribute {
    var diagnosticDescription: String {
        switch self { case .position: return "position"; case .size: return "size" }
    }
}

extension AXWindowFrameWriteFailure {
    var diagnosticDescription: String {
        switch self {
        case .invalidGeometry: return "invalidGeometry"
        case .initialFrameUnavailable: return "initialFrameUnavailable"
        case let .initialFrameMismatch(expected, actual):
            return "initialFrameMismatch(expected:\(WindowFrameMatchPolicy.signature(for: expected)),actual:\(WindowFrameMatchPolicy.signature(for: actual)))"
        case .windowIdentityChanged: return "windowIdentityChanged"
        case let .capabilityQueryFailed(attribute, error): return "capabilityQueryFailed(\(attribute.diagnosticDescription),\(error.rawValue))"
        case let .attributeNotSettable(attribute): return "attributeNotSettable(\(attribute.diagnosticDescription))"
        case let .valueCreationFailed(attribute): return "valueCreationFailed(\(attribute.diagnosticDescription))"
        case .operationBudgetExhausted: return "operationBudgetExhausted"
        case let .writeFailed(attribute, error): return "writeFailed(\(attribute.diagnosticDescription),\(error.rawValue))"
        case .verificationUnavailable: return "verificationUnavailable"
        case let .verificationMismatch(expected, actual):
            return "verificationMismatch(expected:\(WindowFrameMatchPolicy.signature(for: expected)),actual:\(WindowFrameMatchPolicy.signature(for: actual)))"
        }
    }
}

extension AXWindowFrameRollbackResult {
    var diagnosticDescription: String {
        switch self {
        case .notRequested: return "notRequested"
        case let .restored(actual): return "restored(\(WindowFrameMatchPolicy.signature(for: actual)))"
        case let .failed(reason, actual): return "failed(\(reason.diagnosticDescription),\(WindowFrameMatchPolicy.signature(for: actual)))"
        }
    }
}
#endif
