import AppKit
import Foundation
import Synchronization
import XCTest

final class ApplicationOwnershipTests: XCTestCase {
    private func application(_ pid: pid_t, root: String, identifier: String, helper: Bool = false,
                             executable: String? = nil, seconds: Int64? = 10) -> ApplicationOwnerRead {
        (.init(pid: pid, startTimeSec: seconds, startTimeUsec: 1, bundleID: identifier),
         .init(bundleIdentifier: identifier, appName: helper ? "Helper" : "Host",
               activationPolicy: helper ? .accessory : .regular,
               executablePath: executable ?? root + "/Contents/MacOS/Executable",
               bundleURL: URL(fileURLWithPath: root)))
    }

    private var host: ApplicationOwnerRead { application(30, root: "/Applications/Host", identifier: "test.any-vendor.host") }
    private var helper: ApplicationOwnerRead {
        application(31, root: "/Applications/Host/Contents/MacOS/Frameworks/Renderer.app",
                    identifier: "test.independent-helper-name", helper: true)
    }

    private func resolver(_ applications: [ApplicationOwnerRead], teams: [pid_t: String] = [30: "VENDOR", 31: "VENDOR"]) -> ApplicationOwnership {
        ApplicationOwnership(applications: { applications }, identity: { pid, identifier in
            applications.first { $0.identity.pid == pid }?.identity
                ?? .init(pid: pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identifier)
        }, signingTeam: { pid, _ in teams[pid] })
    }

    func testNestedHelperResolvesToOneSignedRunningHostWithoutApplicationNameRules() {
        let result = resolver([helper, host]).owner(for: 31)
        XCTAssertEqual(result?.identity.pid, 30)
        XCTAssertEqual(result?.application.bundleIdentifier, "test.any-vendor.host")
        XCTAssertEqual(result?.application.bundleURL?.path, "/Applications/Host")
    }

    func testOwnershipBatchEnumeratesApplicationsOnceForMultipleHelpersAndAMissingPID() {
        let another = application(32, root: "/Applications/Host/Contents/Frameworks/Other.app",
                                  identifier: "test.other-helper", helper: true)
        let applications = [host, helper, another]
        let enumerations = Mutex(0)
        let ownership = ApplicationOwnership(applications: {
            enumerations.withLock { $0 += 1 }
            return applications
        }, identity: { pid, identifier in
            applications.first { $0.identity.pid == pid }?.identity
                ?? .init(pid: pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identifier)
        }, signingTeam: { _, _ in "VENDOR" })

        let result = ownership.owners(for: [31, 32, 999])

        XCTAssertEqual(Set(result.keys), [31, 32])
        XCTAssertEqual(result[31]?.identity.pid, 30)
        XCTAssertEqual(result[32]?.identity.pid, 30)
        XCTAssertEqual(enumerations.withLock { $0 }, 1)
    }

    func testOwnershipBatchRevalidatesTheHostGenerationForEachHelper() {
        let another = application(32, root: "/Applications/Host/Contents/Frameworks/Other.app",
                                  identifier: "test.other-helper", helper: true)
        let applications = [host, helper, another]
        let parentSignatures = Mutex(0)
        let ownership = ApplicationOwnership(applications: { applications }, identity: { pid, identifier in
            let replaced = pid == 30 && parentSignatures.withLock { $0 >= 2 }
            return .init(pid: pid, startTimeSec: replaced ? 11 : 10, startTimeUsec: 1, bundleID: identifier)
        }, signingTeam: { pid, _ in
            if pid == 30 { parentSignatures.withLock { $0 += 1 } }
            return "VENDOR"
        })

        let result = ownership.owners(for: [31, 32])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.values.first?.identity.pid, 30)
        XCTAssertEqual(parentSignatures.withLock { $0 }, 2)
    }

    func testCancelledOwnershipBatchDoesNotEnumerateOrCheckSignatures() {
        let operations = Mutex(0)
        let ownership = ApplicationOwnership(applications: { operations.withLock { $0 += 1 }; return [] },
                                             signingTeam: { _, _ in operations.withLock { $0 += 1 }; return nil })
        let cancellation = OperationCancellation()
        cancellation.cancel()

        XCTAssertTrue(ownership.owners(for: [31, 32], cancellation: cancellation).isEmpty)
        XCTAssertEqual(operations.withLock { $0 }, 0)
    }

    func testMissingOrDifferentVerifiedSignersRejectTheBinding() {
        for teams: [pid_t: String] in [[:], [30: "VENDOR"], [31: "VENDOR"], [30: "OTHER", 31: "VENDOR"]] {
            XCTAssertNil(resolver([helper, host], teams: teams).owner(for: 31))
        }
    }

    func testPathPrefixLookalikesCannotClaimTheHost() {
        let impostor = application(31, root: "/Applications/Host-copy/Contents/Frameworks/Renderer.app",
                                  identifier: "test.independent-helper-name", helper: true)
        XCTAssertNil(resolver([impostor, host]).owner(for: 31))
    }

    func testAnExecutableOutsideItsClaimedBundleCannotEstablishOwnership() {
        let outsideHelper = application(31, root: helper.application.bundleURL!.path,
            identifier: "test.independent-helper-name", helper: true, executable: "/Elsewhere/Renderer")
        let outsideHost = application(30, root: "/Applications/Host", identifier: "test.any-vendor.host",
                                      executable: "/Elsewhere/Host")
        XCTAssertNil(resolver([outsideHelper, host]).owner(for: 31))
        XCTAssertNil(resolver([helper, outsideHost]).owner(for: 31))
    }

    func testTwoContainingRunningHostsAreAmbiguous() {
        let outer = application(29, root: "/Applications/Outer.app", identifier: "test.outer")
        let inner = application(30, root: "/Applications/Outer.app/Contents/Host.app", identifier: "test.inner")
        let embedded = application(31, root: "/Applications/Outer.app/Contents/Host.app/Contents/Helpers/Renderer.app",
                                   identifier: "test.helper", helper: true)
        XCTAssertNil(resolver([embedded, inner, outer], teams: [29: "VENDOR", 30: "VENDOR", 31: "VENDOR"]).owner(for: 31))
    }

    func testMissingProcessGenerationsCannotEstablishOwnership() {
        let unknown = application(31, root: helper.application.bundleURL!.path,
                                  identifier: "test.independent-helper-name", helper: true, seconds: nil)
        XCTAssertNil(resolver([unknown, host]).owner(for: 31))
    }

    func testProcessReplacementDuringSigningValidationRejectsTheBinding() {
        for replacedPID: pid_t in [30, 31] {
            let applications = [helper, host]
            let replaced = Mutex(false)
            let ownership = ApplicationOwnership(applications: { applications }, identity: { pid, identifier in
                let seconds: Int64 = replaced.withLock { $0 } && pid == replacedPID ? 11 : 10
                return .init(pid: pid, startTimeSec: seconds, startTimeUsec: 1, bundleID: identifier)
            }, signingTeam: { _, _ in
                replaced.withLock { $0 = true }
                return "VENDOR"
            })
            XCTAssertNil(ownership.owner(for: 31))
        }
    }

    func testASymlinkOutsideTheHostCannotEstablishOwnership() throws {
        let directory = TestFileSystem.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostURL = directory.appendingPathComponent("Host.app")
        let outside = directory.appendingPathComponent("Outside.app")
        let link = hostURL.appendingPathComponent("Contents/Helpers/Renderer.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let parent = application(30, root: hostURL.path, identifier: "test.host")
        let embedded = application(31, root: link.path, identifier: "test.helper", helper: true)
        XCTAssertNil(resolver([embedded, parent]).owner(for: 31))
    }

    func testStandaloneApplicationsDoNotTriggerSigningWork() {
        let signingCalls = Mutex(0)
        let applications = [host]
        let ownership = ApplicationOwnership(applications: { applications }, identity: { _, _ in applications[0].identity },
            signingTeam: { _, _ in signingCalls.withLock { $0 += 1 }; return "VENDOR" })
        XCTAssertNil(ownership.owner(for: 30))
        XCTAssertEqual(signingCalls.withLock { $0 }, 0)
    }
}
