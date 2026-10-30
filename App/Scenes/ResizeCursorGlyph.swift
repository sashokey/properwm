import AppKit
import SwiftUI

@MainActor
struct ResizeCursorGlyph: View {
    private static let cursor = NSCursor.frameResize(position: .top, directions: .all)

    static var size: CGSize { cursor.image.size }
    static var hotSpot: CGPoint { cursor.hotSpot }
    static var image: NSImage { cursor.image }

    var body: some View {
        Image(nsImage: Self.image)
            .frame(width: Self.size.width, height: Self.size.height)
    }
}
