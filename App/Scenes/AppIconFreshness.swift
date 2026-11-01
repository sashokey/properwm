import Combine
import Darwin
import Foundation

struct AppIconStamp: Equatable, Sendable {
    let bundleInode: UInt64
    let bundleChangeSeconds: Int
    let bundleChangeNanoseconds: Int
    let infoPlistExists: Bool
    let infoPlistInode: UInt64
    let infoPlistModificationSeconds: Int
    let infoPlistModificationNanoseconds: Int

    static func stamp(atPath path: String) -> AppIconStamp? {
        var bundle = stat()
        guard stat(path, &bundle) == 0 else { return nil }
        var infoPlist = stat()
        let infoPlistExists = stat(path + "/Contents/Info.plist", &infoPlist) == 0
        return AppIconStamp(
            bundleInode: bundle.st_ino,
            bundleChangeSeconds: bundle.st_ctimespec.tv_sec,
            bundleChangeNanoseconds: bundle.st_ctimespec.tv_nsec,
            infoPlistExists: infoPlistExists,
            infoPlistInode: infoPlistExists ? infoPlist.st_ino : 0,
            infoPlistModificationSeconds: infoPlistExists ? infoPlist.st_mtimespec.tv_sec : 0,
            infoPlistModificationNanoseconds: infoPlistExists ? infoPlist.st_mtimespec.tv_nsec : 0
        )
    }
}

@MainActor
final class AppIconFreshnessChecker {
    struct Entry: Sendable {
        let key: String
        let path: String
        let stamp: AppIconStamp?
    }

    private let queue = DispatchQueue(label: "io.github.sashokey.properwm.app-icon-freshness", qos: .utility)
    private let snapshot: @MainActor () -> [Entry]
    private let didCheck: @MainActor ([Entry]) -> Void
    private var isChecking = false
    private var needsAnotherCheck = false

    init(snapshot: @escaping @MainActor () -> [Entry],
         didCheck: @escaping @MainActor ([Entry]) -> Void) {
        self.snapshot = snapshot
        self.didCheck = didCheck
    }

    func requestCheck() {
        guard !isChecking else {
            needsAnotherCheck = true
            return
        }
        let entries = snapshot()
        guard !entries.isEmpty else { return }
        isChecking = true
        queue.async {
            let checked = entries.map {
                Entry(key: $0.key, path: $0.path, stamp: AppIconStamp.stamp(atPath: $0.path))
            }
            DispatchQueue.main.async {
                self.didCheck(checked)
                self.isChecking = false
                if self.needsAnotherCheck {
                    self.needsAnotherCheck = false
                    self.requestCheck()
                }
            }
        }
    }
}
