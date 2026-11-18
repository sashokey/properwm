import Foundation

struct WindowID: Hashable, Codable, Sendable {
    let rawValue: String
}

struct AppID: Hashable, Codable, Sendable {
    let rawValue: String
}

func normalizedWindowTitle(_ title: String?) -> String? {
    guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed.lowercased()
}
