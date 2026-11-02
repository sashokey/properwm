import AppKit
import Foundation
import Security

struct ApplicationOwnership: Sendable {
    let applications: @Sendable () -> [ApplicationOwnerRead]
    let identity: @Sendable (pid_t, String?) -> ScanAdmissionDecision.ProcessIdentity
    let signingTeam: @Sendable (pid_t, String) -> String?

    init(applications: @escaping @Sendable () -> [ApplicationOwnerRead] = ApplicationOwnership.runningApplications,
         identity: @escaping @Sendable (pid_t, String?) -> ScanAdmissionDecision.ProcessIdentity = {
             LiveAppTrackerProcessProvider().identity(pid: $0, bundleID: $1)
         }, signingTeam: @escaping @Sendable (pid_t, String) -> String? = ApplicationOwnership.verifiedSigningTeam) {
        self.applications = applications
        self.identity = identity
        self.signingTeam = signingTeam
    }

    func owner(for pid: pid_t) -> ApplicationOwnerRead? {
        guard pid > 0 else { return nil }
        let applications = applications()
        guard let helper = applications.first(where: { $0.identity.pid == pid }),
              helper.application.isEmbeddedHelper, let helperBundle = bundleComponents(helper.application),
              let helperID = helper.application.bundleIdentifier,
              isCurrent(helper) else { return nil }
        let candidates = applications.filter { candidate in
            guard candidate.identity.pid != pid, candidate.application.activationPolicy == .regular,
                  candidate.application.canOwnTaskbarWindows, let parent = bundleComponents(candidate.application),
                  helperBundle.count > parent.count + 1, helperBundle.starts(with: parent),
                  helperBundle[parent.count] == "Contents", isCurrent(candidate) else { return false }
            return true
        }
        guard candidates.count == 1, let candidate = candidates.first,
              let candidateID = candidate.application.bundleIdentifier,
              let helperTeam = signingTeam(pid, helperID), !helperTeam.isEmpty,
              let parentTeam = signingTeam(candidate.identity.pid, candidateID), parentTeam == helperTeam,
              isCurrent(helper), isCurrent(candidate) else { return nil }
        return candidate
    }

    private func isCurrent(_ application: ApplicationOwnerRead) -> Bool {
        guard application.identity.bundleID == application.application.bundleIdentifier else { return false }
        return ScanAdmissionDecision.ProcessIdentity.matches(probed: application.identity,
            current: identity(application.identity.pid, application.application.bundleIdentifier))
    }

    private func bundleComponents(_ application: AppTrackerWindowEligibility.Application) -> [String]? {
        guard let origin = ApplicationOrigin(bundleURL: application.bundleURL),
              let executablePath = application.executablePath, executablePath.hasPrefix("/") else { return nil }
        let bundle = URL(fileURLWithPath: origin.bundlePath).pathComponents
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let directory = bundle + ["Contents", "MacOS"]
        guard executable.count > directory.count, executable.starts(with: directory) else { return nil }
        return bundle
    }

    private static func runningApplications() -> [ApplicationOwnerRead] {
        let process = LiveAppTrackerProcessProvider()
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated else { return nil }
            let profile = AppTrackerWindowEligibility.Application(bundleIdentifier: application.bundleIdentifier,
                appName: application.localizedName ?? application.bundleIdentifier ?? "",
                activationPolicy: application.activationPolicy, executablePath: application.executableURL?.path,
                bundleURL: application.bundleURL)
            return (process.identity(pid: application.processIdentifier, bundleID: profile.bundleIdentifier), profile)
        }
    }

    static func verifiedSigningTeam(pid: pid_t, identifier: String) -> String? {
        guard pid > 0, !identifier.isEmpty else { return nil }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              information[kSecCodeInfoIdentifier as String] as? String == identifier,
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }
}
