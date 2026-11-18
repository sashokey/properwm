import AppKit
import XCTest

@MainActor
final class NonConstrainingPanelTests: XCTestCase {
    private func makePanel() -> NonConstrainingPanel {
        let panel = NonConstrainingPanel(contentRect: NSRect(x: 300, y: 200, width: 500, height: 60),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        return panel
    }

    func testAccessibilityPositionAndSizeAreNotSettable() {
        let panel = makePanel()
        let attributes: [NSAccessibility.Attribute] = [.position, .size]
        for attribute in attributes {
            XCTAssertFalse(panel.accessibilityIsAttributeSettable(attribute), attribute.rawValue)
        }
    }

    func testAccessibilityPositionAndSizeWritesLeaveTheFrameAlone() {
        let panel = makePanel()
        let frame = panel.frame
        let writes: [(attribute: NSAccessibility.Attribute, value: NSValue)] = [
            (.position, NSValue(point: NSPoint(x: 10, y: 10))),
            (.size, NSValue(size: NSSize(width: 10, height: 10))),
        ]
        for (attribute, value) in writes {
            panel.accessibilitySetValue(value, forAttribute: attribute)
            XCTAssertEqual(panel.frame, frame, attribute.rawValue)
        }
    }

    func testFrameIsNotConstrainedToTheScreen() {
        let panel = makePanel()
        let offscreen = NSRect(x: -5000, y: -5000, width: 500, height: 60)
        XCTAssertEqual(panel.constrainFrameRect(offscreen, to: NSScreen.main), offscreen)
    }
}
