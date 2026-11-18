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
        let generation: UInt64
        let stamp: AppIconStamp?
    }

    private let queue = DispatchQueue(label: "io.github.sashokey.properwm.app-icon-freshness", qos: .utility)
    private let snapshot: @MainActor (Bool) -> [Entry]
    private let didCheck: @MainActor ([Entry]) -> Void
    private let stampAtPath: @Sendable (String) -> AppIconStamp?
    private var isChecking = false
    private var needsAnotherCheck = false
    private var needsFullCheck = false

    init(snapshot: @escaping @MainActor (Bool) -> [Entry],
         didCheck: @escaping @MainActor ([Entry]) -> Void,
         stampAtPath: @escaping @Sendable (String) -> AppIconStamp? = AppIconStamp.stamp(atPath:)) {
        self.snapshot = snapshot
        self.didCheck = didCheck
        self.stampAtPath = stampAtPath
    }

    func requestCheck(onlyUninitialized: Bool = false) {
        guard !isChecking else {
            needsAnotherCheck = true
            needsFullCheck = needsFullCheck || !onlyUninitialized
            return
        }
        let entries = snapshot(onlyUninitialized)
        guard !entries.isEmpty else { return }
        isChecking = true
        queue.async { [stampAtPath] in
            let checked = entries.map {
                Entry(key: $0.key, path: $0.path, generation: $0.generation, stamp: stampAtPath($0.path))
            }
            DispatchQueue.main.async {
                self.didCheck(checked)
                self.isChecking = false
                if self.needsAnotherCheck {
                    let onlyUninitialized = !self.needsFullCheck
                    self.needsAnotherCheck = false
                    self.needsFullCheck = false
                    self.requestCheck(onlyUninitialized: onlyUninitialized)
                }
            }
        }
    }
}
