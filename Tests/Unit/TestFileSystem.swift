import Foundation

enum TestFileSystem {
    static var temporaryDirectory: URL {
        if let directory = ProcessInfo.processInfo.environment["PROPERWM_TEST_DIRECTORY"], !directory.isEmpty {
            return URL(fileURLWithPath: directory, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }
}
