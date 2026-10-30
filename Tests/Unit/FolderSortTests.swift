import XCTest

/// FolderSortOrder 五种排序纯函数（FolderContentsLoader.sorted(_:by:)）。
final class FolderSortTests: XCTestCase {
    private func entry(
        _ name: String,
        isDirectory: Bool = false,
        added: TimeInterval? = nil,
        modified: TimeInterval? = nil,
        created: TimeInterval? = nil
    ) -> FolderContentsLoader.Entry {
        FolderContentsLoader.Entry(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: isDirectory,
            dateAdded: added.map { Date(timeIntervalSince1970: $0) },
            dateModified: modified.map { Date(timeIntervalSince1970: $0) },
            dateCreated: created.map { Date(timeIntervalSince1970: $0) }
        )
    }

    func testNameSortIsLocalizedNumericAware() {
        let sorted = FolderContentsLoader.sorted([
            entry("file10"), entry("file2"), entry("File1"),
        ], by: .name)
        // localizedStandardCompare：数字感知（file2 < file10）、大小写不敏感。
        XCTAssertEqual(sorted.map(\.name), ["File1", "file2", "file10"])
    }

    func testDateAddedSortMatchesLegacyOrder() {
        let entries = [
            entry("old", added: 100),
            entry("new", added: 300),
            entry("mid", added: 200),
        ]
        XCTAssertEqual(
            FolderContentsLoader.sorted(entries, by: .dateAdded),
            FolderContentsLoader.sortedByDateAdded(entries)
        )
    }

    func testDateModifiedNewestFirstWithFallbackToDateAdded() {
        let sorted = FolderContentsLoader.sorted([
            entry("modified-early", modified: 100),
            entry("modified-late", modified: 300),
            entry("no-modified-uses-added", added: 200),
        ], by: .dateModified)
        XCTAssertEqual(sorted.map(\.name),
                       ["modified-late", "no-modified-uses-added", "modified-early"])
    }

    func testDateCreatedNewestFirstWithFallbackToDateModified() {
        let sorted = FolderContentsLoader.sorted([
            entry("created-early", created: 100),
            entry("created-late", created: 300),
            entry("no-created-uses-modified", modified: 200),
        ], by: .dateCreated)
        XCTAssertEqual(sorted.map(\.name),
                       ["created-late", "no-created-uses-modified", "created-early"])
    }

    func testMenuOrderIsTheNativeOrder() {
        XCTAssertEqual(FolderSortOrder.allCases, [.name, .dateAdded, .dateModified, .dateCreated, .kind])
    }

    func testKindSortGroupsDirectoriesFirst() {
        let sorted = FolderContentsLoader.sorted([
            entry("b.png"), entry("zeta", isDirectory: true),
            entry("a.png"), entry("alpha", isDirectory: true),
        ], by: .kind)
        // 文件夹恒排最前（组内按名称），文件按种类分组。
        XCTAssertEqual(sorted.map(\.name), ["alpha", "zeta", "a.png", "b.png"])
    }

    func testKindSortGroupsSameExtensionTogether() {
        let sorted = FolderContentsLoader.sorted([
            entry("1.png"), entry("2.txt"), entry("3.png"), entry("4.txt"),
        ], by: .kind)
        // 不断言本地化种类名的具体顺序，只断言同扩展名相邻成组。
        let extensions = sorted.map { $0.url.pathExtension }
        XCTAssertEqual(Set(extensions.prefix(2)).count, 1)
        XCTAssertEqual(Set(extensions.suffix(2)).count, 1)
    }

    func testKindRankOrdersDirectoryThenFileThenNoExtension() {
        XCTAssertEqual(FolderContentsLoader.kindRank(for: entry("dir", isDirectory: true)), 0)
        XCTAssertEqual(FolderContentsLoader.kindRank(for: entry("a.png")), 1)
        XCTAssertEqual(FolderContentsLoader.kindRank(for: entry("README")), 2)
    }

    func testKindSortPutsNoExtensionFilesLast() {
        let sorted = FolderContentsLoader.sorted([
            entry("README"), entry("a.png"), entry("dir", isDirectory: true),
        ], by: .kind)
        XCTAssertEqual(sorted.map(\.name), ["dir", "a.png", "README"])
    }

    func testCoverStacksTheFirstThreeItemsOfTheSortIncludingDirectories() {
        let entries = [
            entry("zzz.png", added: 300),
            entry("aaa.png", added: 100),
            entry("newest-dir", isDirectory: true, added: 400),
            entry("mmm.png", added: 200),
        ]
        func cover(_ order: FolderSortOrder) -> [String] {
            FolderContentsLoader.coverEntries(in: FolderContentsLoader.sorted(entries, by: order)).map(\.name)
        }
        XCTAssertEqual(cover(.dateAdded), ["newest-dir", "zzz.png", "mmm.png"])
        XCTAssertEqual(cover(.name), ["aaa.png", "mmm.png", "newest-dir"])
    }
}

/// FolderDisplayMode: the default and the persisted / menu shape.
final class FolderDisplayModeTests: XCTestCase {
    func testDefaultIsStackAsOnTheNativeDock() {
        XCTAssertEqual(FolderDisplayMode.default, .stack)
    }

    func testMenuOrderIsFolderThenStack() {
        XCTAssertEqual(FolderDisplayMode.allCases, [.folder, .stack])
    }

    func testRawValuesRoundTrip() {
        for mode in FolderDisplayMode.allCases {
            XCTAssertEqual(FolderDisplayMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(FolderDisplayMode(rawValue: ""))
    }
}
