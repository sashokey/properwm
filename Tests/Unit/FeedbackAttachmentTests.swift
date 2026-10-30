import XCTest

final class FeedbackAttachmentTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FeedbackAttachmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func writeFile(named name: String, byteCount: Int) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        return url
    }

    private func attachment(_ name: String, _ byteCount: Int) -> FeedbackAttachment {
        FeedbackAttachment(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            byteCount: byteCount,
            mimeType: FeedbackAttachmentCheck.mimeType(forFileName: name) ?? "application/octet-stream"
        )
    }

    // MARK: 白名单与档位

    func testExtensionWhitelistMatchesTheServerSet() {
        for name in ["a.png", "a.PNG", "a.jpg", "a.jpeg", "a.gif", "a.heic"] {
            XCTAssertEqual(FeedbackAttachmentCheck.kind(forFileName: name), .image, name)
        }
        for name in ["a.mp4", "a.mov", "a.MOV"] {
            XCTAssertEqual(FeedbackAttachmentCheck.kind(forFileName: name), .video, name)
        }
        for name in ["a.pdf", "a.zip", "a.webp", "noextension", "a."] {
            XCTAssertNil(FeedbackAttachmentCheck.kind(forFileName: name), name)
        }
    }

    func testMimeTypesAreTheOnesTheServerWhitelists() {
        XCTAssertEqual(FeedbackAttachmentCheck.mimeType(forFileName: "a.png"), "image/png")
        XCTAssertEqual(FeedbackAttachmentCheck.mimeType(forFileName: "a.jpg"), "image/jpeg")
        XCTAssertEqual(FeedbackAttachmentCheck.mimeType(forFileName: "a.jpeg"), "image/jpeg")
        XCTAssertEqual(FeedbackAttachmentCheck.mimeType(forFileName: "a.gif"), "image/gif")
        XCTAssertEqual(FeedbackAttachmentCheck.mimeType(forFileName: "a.heic"), "image/heic")
        XCTAssertEqual(FeedbackAttachmentCheck.mimeType(forFileName: "a.mp4"), "video/mp4")
        XCTAssertEqual(FeedbackAttachmentCheck.mimeType(forFileName: "a.mov"), "video/quicktime")
        XCTAssertNil(FeedbackAttachmentCheck.mimeType(forFileName: "a.pdf"))
    }

    // MARK: 三组上限（与服务端同一组数）

    func testLimitsAreTheSameNumbersAsTheServer() {
        XCTAssertEqual(FeedbackAttachmentCheck.maximumCount, 3)
        XCTAssertEqual(FeedbackAttachmentCheck.imageMaximumBytes, 10 * 1024 * 1024)
        XCTAssertEqual(FeedbackAttachmentCheck.videoMaximumBytes, 30 * 1024 * 1024)
        XCTAssertEqual(FeedbackAttachmentCheck.totalMaximumBytes, 40 * 1024 * 1024)
    }

    func testCountLimitIsCheckedBeforeAnythingElse() {
        let existing = [attachment("a.png", 1), attachment("b.png", 1), attachment("c.png", 1)]
        XCTAssertEqual(
            FeedbackAttachmentCheck.validate(adding: "huge.pdf", byteCount: .max, to: existing),
            .tooMany,
            "已经 3 个了 —— 比「类型不支持」更贴近用户当下的处境"
        )
    }

    func testSingleFileBoundaries() {
        XCTAssertNil(FeedbackAttachmentCheck.validate(
            adding: "shot.png", byteCount: 10 * 1024 * 1024, to: []
        ))
        XCTAssertEqual(
            FeedbackAttachmentCheck.validate(adding: "shot.png", byteCount: 10 * 1024 * 1024 + 1, to: []),
            .tooLarge(.image)
        )
        XCTAssertNil(FeedbackAttachmentCheck.validate(
            adding: "rec.mov", byteCount: 30 * 1024 * 1024, to: []
        ))
        XCTAssertEqual(
            FeedbackAttachmentCheck.validate(adding: "rec.mov", byteCount: 30 * 1024 * 1024 + 1, to: []),
            .tooLarge(.video)
        )
        XCTAssertEqual(
            FeedbackAttachmentCheck.validate(adding: "empty.png", byteCount: 0, to: []),
            .unreadable
        )
        XCTAssertEqual(
            FeedbackAttachmentCheck.validate(adding: "notes.pdf", byteCount: 10, to: []),
            .unsupportedType
        )
    }

    func testTotalBoundary() {
        let existing = [attachment("rec.mov", 30 * 1024 * 1024)]
        XCTAssertNil(
            FeedbackAttachmentCheck.validate(adding: "shot.png", byteCount: 10 * 1024 * 1024, to: existing),
            "30 + 10 = 40MB 恰好放行"
        )
        XCTAssertEqual(
            FeedbackAttachmentCheck.validate(adding: "shot.png", byteCount: 10 * 1024 * 1024 + 1, to: existing),
            .tooLarge(.image),
            "单文件先超，先报单文件"
        )
        let two = [attachment("rec.mov", 30 * 1024 * 1024), attachment("a.png", 9 * 1024 * 1024)]
        XCTAssertEqual(
            FeedbackAttachmentCheck.validate(adding: "b.png", byteCount: 2 * 1024 * 1024, to: two),
            .totalTooLarge
        )
    }

    func testSizeLabelStaysShortEnoughForTheChip() {
        XCTAssertEqual(attachment("a.png", 512 * 1024).sizeLabel, "512 KB")
        XCTAssertEqual(attachment("a.mov", 10 * 1024 * 1024 + 512 * 1024).sizeLabel, "10.5 MB")
        XCTAssertEqual(attachment("a.png", 1).sizeLabel, "1 KB", "不足 1KB 也不显示 0 KB")
    }

    // MARK: 每种拒绝都有自己的文案

    func testEveryRejectionHasItsOwnCopyAndNoneClaimsSuccess() {
        let rejections: [FeedbackAttachmentCheck.Rejection] = [
            .tooMany, .unsupportedType, .tooLarge(.image), .tooLarge(.video), .totalTooLarge, .unreadable
        ]
        let contents = rejections.map { FeedbackAlertContent(attachmentRejection: $0) }
        XCTAssertEqual(Set(contents.map(\.message)).count, rejections.count, "文案不能重复")
        for content in contents {
            XCTAssertTrue(content.isWarning)
            XCTAssertFalse(content.didSend)
        }
    }

    // MARK: multipart 编码器

    func testMultipartBodyShape() {
        var form = MultipartFormBody(boundary: "TESTBOUNDARY")
        form.append(field: "payload", value: "{\"message\":\"hi\"}")
        form.append(file: "file0", filename: "截图.png", mimeType: "image/png", data: Data([0x89, 0x50]))
        let text = String(decoding: form.encoded(), as: UTF8.self)

        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=TESTBOUNDARY")
        XCTAssertTrue(text.hasPrefix("--TESTBOUNDARY\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"payload\"\r\n\r\n{\"message\":\"hi\"}\r\n"))
        XCTAssertTrue(text.contains(
            "Content-Disposition: form-data; name=\"file0\"; filename=\"截图.png\"\r\nContent-Type: image/png\r\n\r\n"
        ))
        XCTAssertTrue(text.hasSuffix("--TESTBOUNDARY--\r\n"), "必须以结束分隔符收尾")
    }

    func testMultipartEscapesQuotesAndNewlinesInFileNames() {
        var form = MultipartFormBody(boundary: "B")
        form.append(file: "file0", filename: "a\"b\nc.png", mimeType: "image/png", data: Data())
        let text = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"a_bc.png\""), "引号和换行会把头拆坏")
    }

    // MARK: 请求形状：有附件走 multipart，无附件逐字节还是老 JSON

    func testAttachmentSubmissionUsesMultipartWithPayloadAndFileFields() async throws {
        let png = try writeFile(named: "shot.png", byteCount: 32)
        let mov = try writeFile(named: "rec.mov", byteCount: 48)
        var captured: URLRequest?
        let submitter = WebsiteFeedbackSubmitter { request in
            captured = request
            return (Data(), HTTPURLResponse(
                url: WebsiteFeedbackSubmitter.endpointURL, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }

        try await submitter.submit(FeedbackDraft(
            message: "点了没反应",
            contact: nil,
            appVersion: "版本 0.9.6",
            macosVersion: "macOS 15.5",
            lang: "zh",
            attachments: [
                FeedbackAttachment(url: png, name: "shot.png", byteCount: 32, mimeType: "image/png"),
                FeedbackAttachment(url: mov, name: "rec.mov", byteCount: 48, mimeType: "video/quicktime")
            ]
        ))

        let request = try XCTUnwrap(captured)
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tungsten-Client"), "app")
        XCTAssertEqual(request.timeoutInterval, WebsiteFeedbackSubmitter.attachmentRequestTimeout)

        let text = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"payload\""))
        XCTAssertTrue(text.contains("name=\"file0\"; filename=\"shot.png\""))
        XCTAssertTrue(text.contains("name=\"file1\"; filename=\"rec.mov\""))
        XCTAssertFalse(text.contains("name=\"file2\""))

        // payload 段就是那五个字段的 JSON，一字不多——附件是第六项，不进 JSON。
        let payloadStart = try XCTUnwrap(text.range(of: "name=\"payload\"\r\n\r\n")).upperBound
        let payloadEnd = try XCTUnwrap(text.range(of: "\r\n--", range: payloadStart..<text.endIndex)).lowerBound
        let payload = String(text[payloadStart..<payloadEnd])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["appVersion", "lang", "macosVersion", "message"])
    }

    func testDraftWithoutAttachmentsStillSendsTheUnchangedJSONRequest() async throws {
        var captured: URLRequest?
        let submitter = WebsiteFeedbackSubmitter { request in
            captured = request
            return (Data(), HTTPURLResponse(
                url: WebsiteFeedbackSubmitter.endpointURL, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }

        try await submitter.submit(FeedbackDraft(
            message: "hi", contact: nil, appVersion: nil, macosVersion: nil, lang: "en"
        ))

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, WebsiteFeedbackSubmitter.requestTimeout)
    }

    func testMissingFileAtSendTimeFailsTheWholeSubmission() async {
        let missing = temporaryDirectory.appendingPathComponent("gone.png")
        var reachedLoader = false
        let submitter = WebsiteFeedbackSubmitter { _ in
            reachedLoader = true
            return (Data(), HTTPURLResponse(
                url: WebsiteFeedbackSubmitter.endpointURL, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }

        do {
            try await submitter.submit(FeedbackDraft(
                message: "hi", contact: nil, appVersion: nil, macosVersion: nil, lang: "zh",
                attachments: [FeedbackAttachment(
                    url: missing, name: "gone.png", byteCount: 10, mimeType: "image/png"
                )]
            ))
            XCTFail("读不出附件必须整单失败")
        } catch let error as FeedbackError {
            XCTAssertEqual(error, .attachmentUnreadable)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        XCTAssertFalse(reachedLoader, "读不出来就不该发出请求")
    }

    /// The drafts outlive the settings window, so a successful send is the only thing that
    /// empties them — all four, or the next feedback goes out with last time's attachment.
    @MainActor
    func testClearingTheDraftResetsAllFourFields() {
        let draft = FeedbackDraftState()
        draft.message = "条在外接屏上不出来"
        draft.contact = "someone@example.com"
        draft.category = .suggestion
        draft.attachments = [attachment("shot.png", 1024)]

        draft.clear()

        XCTAssertEqual(draft.message, "")
        XCTAssertEqual(draft.contact, "")
        XCTAssertEqual(draft.category, .bug)
        XCTAssertEqual(draft.attachments, [])
    }
}
