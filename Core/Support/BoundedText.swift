import Foundation

enum BoundedText {
    static func utf8(_ value: String, maximumBytes: Int = 4096) -> String {
        var bytes = Array(value.utf8.prefix(max(0, maximumBytes)))
        while !bytes.isEmpty {
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            bytes.removeLast()
        }
        return ""
    }
}
