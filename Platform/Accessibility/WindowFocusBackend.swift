import ApplicationServices
import Foundation

protocol WindowFocusRequesting: Sendable {
    func setFrontmost(pid: pid_t, windowID: CGWindowID, mode: UInt32) -> Bool
    func makeKey(pid: pid_t, windowID: CGWindowID) -> Bool
}

struct SkyLightWindowFocus: WindowFocusRequesting {
    private let frontRequest: @Sendable (pid_t, CGWindowID, UInt32) -> Int32?
    private let keyRequest: @Sendable (pid_t, CGWindowID) -> Int32?

    init(frontRequest: (@Sendable (pid_t, CGWindowID, UInt32) -> Int32?)? = nil,
         keyRequest: (@Sendable (pid_t, CGWindowID) -> Int32?)? = nil) {
        self.frontRequest = frontRequest ?? Self.setFrontmostNative
        self.keyRequest = keyRequest ?? Self.makeKeyNative
    }

    func setFrontmost(pid: pid_t, windowID: CGWindowID, mode: UInt32) -> Bool {
        frontRequest(pid, windowID, mode) == CGError.success.rawValue
    }

    func makeKey(pid: pid_t, windowID: CGWindowID) -> Bool {
        keyRequest(pid, windowID) == CGError.success.rawValue
    }

    private typealias GetProcess = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFront = @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostEvent = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32

    private static let getProcess: GetProcess? = {
        for path in ["/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                     "/System/Library/Frameworks/CoreServices.framework/CoreServices"] {
            guard let library = dlopen(path, RTLD_LAZY) else { continue }
            if let symbol = dlsym(library, "GetProcessForPID") { return unsafeBitCast(symbol, to: GetProcess.self) }
            dlclose(library)
        }
        return nil
    }()

    private static let functions: (front: SetFront, post: PostEvent)? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let front = dlsym(library, "_SLPSSetFrontProcessWithOptions"),
              let post = dlsym(library, "SLPSPostEventRecordTo") else {
            dlclose(library)
            return nil
        }
        return (unsafeBitCast(front, to: SetFront.self), unsafeBitCast(post, to: PostEvent.self))
    }()

    private static let serialNumbers = ProcessGenerationCache<ProcessSerialNumber>()

    private static func serialNumber(for pid: pid_t) -> ProcessSerialNumber? {
        guard let getProcess else { return nil }
        var serial = ProcessSerialNumber()
        if getProcess(pid, &serial) == noErr {
            serialNumbers.remember(serial, for: pid)
            return serial
        }
        return serialNumbers.value(for: pid)
    }

    private static func setFrontmostNative(pid: pid_t, windowID: CGWindowID, mode: UInt32) -> Int32? {
        guard let functions, var serial = serialNumber(for: pid) else { return nil }
        return withUnsafePointer(to: &serial) { functions.front($0, windowID, mode) }
    }

    private static func makeKeyNative(pid: pid_t, windowID: CGWindowID) -> Int32? {
        guard let functions, var serial = serialNumber(for: pid) else { return nil }
        var event = [UInt8](repeating: 0, count: 0x100)
        event[0x04] = 0xf8
        event[0x08] = 0x01
        event[0x3a] = 0x10
        var windowID = windowID
        withUnsafeBytes(of: &windowID) { bytes in
            for index in 0..<4 { event[0x3c + index] = bytes[index] }
        }
        var offContentPoint = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &offContentPoint) { bytes in
            for index in 0..<16 { event[0x20 + index] = bytes[index] }
        }
        return withUnsafePointer(to: &serial) { pointer in
            event.withUnsafeBufferPointer { functions.post(pointer, $0.baseAddress!) }
        }
    }
}

enum WindowActivationAttempt {
    static func run(requestPrivateFocus: () -> Bool, raise: () -> Void,
                    activateApplication: () -> Void, confirm: (TimeInterval) -> Bool,
                    timeout: TimeInterval) -> Bool {
        let accepted = requestPrivateFocus()
        raise()
        if confirm(accepted ? min(0.1, timeout) : 0) { return true }
        activateApplication()
        raise()
        return confirm(timeout)
    }
}
