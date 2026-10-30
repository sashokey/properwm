import Foundation

/// 反馈附件（截图 / 录屏）的纯类型与校验，外加手写的 multipart 编码器。
///
/// 三组上限与服务端 `functions/_lib/feedback-attachments.js` 是**同一组数**——
/// 客户端先挡明显超限的，省一次 40MB 的无谓上行；真校验永远在服务端（那边还查魔数，
/// 这边不查：本地选的文件改名没有意义，用户不是自己的攻击者）。
struct FeedbackAttachment: Equatable, Identifiable {
    let id: UUID
    /// 用户选中的原文件。发送时才读内容——中途被删被移走就整单失败，不静默丢附件。
    let url: URL
    let name: String
    let byteCount: Int
    let mimeType: String

    init(id: UUID = UUID(), url: URL, name: String, byteCount: Int, mimeType: String) {
        self.id = id
        self.url = url
        self.name = name
        self.byteCount = byteCount
        self.mimeType = mimeType
    }

    /// 胶囊上显示的大小。刻意短（`9.8 MB` / `320 KB`）——一行里还要挤文件名和 ✕。
    var sizeLabel: String {
        let megabytes = Double(byteCount) / (1024 * 1024)
        if megabytes >= 1 {
            return String(format: "%.1f MB", megabytes)
        }
        return String(format: "%.0f KB", max(1, Double(byteCount) / 1024))
    }
}

enum FeedbackAttachmentCheck {
    static let maximumCount = 3
    static let imageMaximumBytes = 10 * 1024 * 1024
    static let videoMaximumBytes = 30 * 1024 * 1024
    static let totalMaximumBytes = 40 * 1024 * 1024

    enum Kind: Equatable {
        case image
        case video
    }

    enum Rejection: Equatable {
        case tooMany
        case unsupportedType
        case tooLarge(Kind)
        case totalTooLarge
        case unreadable
    }

    /// 扩展名是唯一的类型来源：它决定档位（进而决定单文件上限）与上传时报的 Content-Type。
    /// 与服务端的白名单逐条对齐——这边多放一种，那边就会以 400 拒收，用户只看到「无法发送」。
    private static let types: [String: (kind: Kind, mimeType: String)] = [
        "png": (.image, "image/png"),
        "jpg": (.image, "image/jpeg"),
        "jpeg": (.image, "image/jpeg"),
        "gif": (.image, "image/gif"),
        "heic": (.image, "image/heic"),
        "mp4": (.video, "video/mp4"),
        "mov": (.video, "video/quicktime")
    ]

    static func kind(forFileName name: String) -> Kind? {
        descriptor(forFileName: name)?.kind
    }

    static func mimeType(forFileName name: String) -> String? {
        descriptor(forFileName: name)?.mimeType
    }

    static func maximumBytes(for kind: Kind) -> Int {
        kind == .video ? videoMaximumBytes : imageMaximumBytes
    }

    /// 追加一个附件前的整组校验：个数 → 类型 → 单文件 → 总量。返回 nil 表示可以加。
    /// 顺序有意：先报「已经 3 个了」比先报「这个太大」更贴近用户当下的处境。
    static func validate(
        adding name: String,
        byteCount: Int,
        to existing: [FeedbackAttachment]
    ) -> Rejection? {
        guard existing.count < maximumCount else { return .tooMany }
        guard let descriptor = descriptor(forFileName: name) else { return .unsupportedType }
        guard byteCount > 0 else { return .unreadable }
        guard byteCount <= maximumBytes(for: descriptor.kind) else { return .tooLarge(descriptor.kind) }
        let total = existing.reduce(0) { $0 + $1.byteCount } + byteCount
        guard total <= totalMaximumBytes else { return .totalTooLarge }
        return nil
    }

    private static func descriptor(forFileName name: String) -> (kind: Kind, mimeType: String)? {
        let extensionName = (name as NSString).pathExtension.lowercased()
        guard !extensionName.isEmpty else { return nil }
        return types[extensionName]
    }
}

/// 手写的 multipart/form-data 编码器。只做反馈接口需要的两件事：一个文本字段
/// （`payload`，就是原来那份 JSON）和最多三个文件字段（`file0..file2`）。
///
/// 不用 URLSession 的上传任务拼：那条路要么落磁盘临时文件、要么还是得自己拼 body，
/// 而请求形状是要被单测逐段核对的（`FeedbackAttachmentTests`）。
struct MultipartFormBody {
    let boundary: String
    private var body = Data()

    init(boundary: String = "TungstenEdge-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func append(field name: String, value: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(Self.escaped(name))\"\r\n\r\n")
        appendString(value)
        appendString("\r\n")
    }

    mutating func append(file name: String, filename: String, mimeType: String, data: Data) {
        appendString("--\(boundary)\r\n")
        appendString(
            "Content-Disposition: form-data; name=\"\(Self.escaped(name))\";"
                + " filename=\"\(Self.escaped(filename))\"\r\n"
        )
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        appendString("\r\n")
    }

    /// 收尾的结束分隔符。调用后再 append 会拼出坏 body，所以这里是取值不是变值。
    func encoded() -> Data {
        var finished = body
        finished.append(Data("--\(boundary)--\r\n".utf8))
        return finished
    }

    /// 文件名里的引号和换行会把 Content-Disposition 头拆坏（中文文件名本身没问题，
    /// UTF-8 直接进头部，服务端 `request.formData()` 认得）。
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private mutating func appendString(_ string: String) {
        body.append(Data(string.utf8))
    }
}
