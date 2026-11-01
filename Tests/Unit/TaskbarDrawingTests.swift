import AppKit
import XCTest

@MainActor
final class TaskbarDrawingTests: XCTestCase {
    private func button(dark: Bool) -> TaskbarButtonView {
        _ = NSApplication.shared
        let button = TaskbarButtonView(frame: CGRect(x: 0, y: 0, width: 140, height: 28))
        button.reduceMotion = { true }
        button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return button
    }

    private func render(_ view: NSView, scale: CGFloat) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let cache = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: cache)
            view.displayIfNeeded()
        }
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image)).cgContext
        context.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh))
        context.translateBy(x: 0, y: CGFloat(image.pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(view.layer).render(in: context)
        return image
    }

    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        let lhs = a.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        let rhs = b.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return max(abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
                   abs(lhs.blueComponent - rhs.blueComponent))
    }

    private func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                               region: CGRect, scale: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for x in Int(region.minX * scale)..<Int(region.maxX * scale) {
                if difference(a, b, x: x, y: y) > 0.03 { points.append(CGPoint(x: x, y: y)) }
            }
        }
        return points
    }

    private func borderContrast(_ image: NSBitmapImageRep) -> CGFloat {
        var contrast: CGFloat = 0
        for x in 40..<240 {
            let interior = image.colorAt(x: x, y: 8)!.usingColorSpace(.deviceRGB)!
            for y in 0..<4 {
                let edge = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                contrast += abs(edge.redComponent - interior.redComponent)
                    + abs(edge.greenComponent - interior.greenComponent)
                    + abs(edge.blueComponent - interior.blueComponent)
            }
        }
        return contrast
    }

    func testNativeIconAndLabelActuallyDrawAtBothScales() throws {
        for dark in [false, true] {
            for scale: CGFloat in [1, 2] {
                let view = button(dark: dark)
                let empty = try render(view, scale: scale)
                view.title = "ProperWM"
                view.image = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil)
                let populated = try render(view, scale: scale)
                XCTAssertGreaterThan(changedPixels(empty, populated, region: CGRect(x: 6, y: 6, width: 16, height: 16), scale: scale).count,
                                     Int(20 * scale * scale))
                XCTAssertGreaterThan(changedPixels(empty, populated, region: CGRect(x: 28, y: 4, width: 104, height: 20), scale: scale).count,
                                     Int(30 * scale * scale))
            }
        }
    }

    func testExtendingTheHitTargetLeavesEveryVisiblePixelUnchanged() throws {
        for dark in [false, true] {
            for scale: CGFloat in [1, 2] {
                for state in 0..<3 {
                    let reference = button(dark: dark)
                    let extended = button(dark: dark)
                    extended.frame.size.height = 30
                    for view in [reference, extended] {
                        view.title = "ProperWM"
                        view.image = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil)
                        view.isActiveWindow = state == 2
                        if state == 1 {
                            view.mouseEntered(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered,
                                location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                eventNumber: 0, trackingNumber: 0, userData: nil)))
                        }
                    }
                    let original = try render(reference, scale: scale)
                    let enlarged = try render(extended, scale: scale)
                    XCTAssertTrue(changedPixels(original, enlarged, region: reference.bounds, scale: scale).isEmpty,
                                  "Visible geometry changed for dark=\(dark), scale=\(scale), state=\(state)")
                    let empty = NSView(frame: extended.bounds)
                    empty.wantsLayer = true
                    let background = try render(empty, scale: scale)
                    XCTAssertTrue(changedPixels(background, enlarged,
                        region: CGRect(x: 0, y: 28, width: 140, height: 2), scale: scale).isEmpty)
                }
            }
        }
    }

    func testPopupRowsDrawTheirIconTitleAndCloseControl() throws {
        let record = WindowRecord(id: WindowID(rawValue: "first"), appID: AppID(rawValue: "test"), pid: 42,
                                  bundleIdentifier: "test.drawing", title: "First window", bounds: nil, status: .inactive)
        let item = TaskbarWindowPresentation(item: StripItem(record: record), title: record.title, isActive: false)
        for dark in [false, true] {
            for scale: CGFloat in [1, 2] {
                let list = TaskbarWindowListView(windows: [item], availableHeight: 120,
                    icon: { _ in NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil) },
                    activate: { _ in }, close: { _ in }, fileHover: { _ in })
                list.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let row = try XCTUnwrap(list.cells.first)
                row.wantsLayer = true
                row.keyboardSelected = true
                row.imageView?.isHidden = true
                row.textField?.isHidden = true
                row.closeButton.isHidden = true
                let empty = try render(row, scale: scale)
                row.imageView?.isHidden = false
                row.textField?.isHidden = false
                row.closeButton.isHidden = false
                let populated = try render(row, scale: scale)
                for region in [CGRect(x: 8, y: 12, width: 16, height: 16),
                               CGRect(x: 32, y: 12, width: 148, height: 20),
                               CGRect(x: 180, y: 4, width: 32, height: 32)] {
                    XCTAssertGreaterThan(changedPixels(empty, populated, region: region, scale: scale).count, Int(8 * scale * scale))
                }
            }
        }
    }

    func testRenderedIndicatorIsCenteredUnderTheRenderedIcon() throws {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 56),
                            styleMask: .borderless, backing: .buffered, defer: true)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 56))
        panel.contentView = content
        for dark in [false, true] {
            for scale: CGFloat in [1, 2] {
                content.bounds.size = CGSize(width: 280 * panel.backingScaleFactor / scale,
                                             height: 56 * panel.backingScaleFactor / scale)
                for active in [false, true] {
                    let view = button(dark: dark)
                    view.frame.origin = CGPoint(x: 28, y: 2)
                    content.addSubview(view)
                    defer { view.removeFromSuperview() }
                    XCTAssertEqual(view.convertToBacking(CGRect(x: 0, y: 0, width: 1, height: 1)).width, scale)
                    view.image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
                        NSColor.systemGreen.setFill()
                        rect.fill()
                        return true
                    }
                    view.isActiveWindow = active
                    view.iconView.isHidden = true
                    view.indicator.isHidden = true
                    let empty = try render(view, scale: scale)
                    view.iconView.isHidden = false
                    let icon = try render(view, scale: scale)
                    view.iconView.isHidden = true
                    view.indicator.isHidden = false
                    let indicator = try render(view, scale: scale)
                    let iconPoints = changedPixels(empty, icon, region: view.bounds, scale: scale)
                    let indicatorPoints = changedPixels(empty, indicator, region: view.bounds, scale: scale)
                    let iconCenter = (try XCTUnwrap(iconPoints.map(\.x).min()) + XCTUnwrap(iconPoints.map(\.x).max()) + 1) / 2
                    let indicatorCenter = (try XCTUnwrap(indicatorPoints.map(\.x).min()) + XCTUnwrap(indicatorPoints.map(\.x).max()) + 1) / 2
                    XCTAssertEqual(indicatorCenter, iconCenter, accuracy: 0.000_001,
                                   "dark=\(dark), scale=\(scale), active=\(active)")
                }
            }
        }
        XCTAssertFalse(panel.isVisible)
    }

    func testRasterizedActiveIndicatorIsElevenByTwoPointsAndInactiveIsFourByTwo() throws {
        for dark in [false, true] {
            for scale: CGFloat in [1, 2] {
                for active in [false, true] {
                    let view = button(dark: dark)
                    view.isActiveWindow = active
                    view.indicator.isHidden = true
                    let without = try render(view, scale: scale)
                    view.indicator.isHidden = false
                    let with = try render(view, scale: scale)
                    let points = changedPixels(without, with, region: view.bounds, scale: scale)
                    let minX = try XCTUnwrap(points.map(\.x).min())
                    let maxX = try XCTUnwrap(points.map(\.x).max())
                    let minY = try XCTUnwrap(points.map(\.y).min())
                    let maxY = try XCTUnwrap(points.map(\.y).max())
                    XCTAssertEqual(maxX - minX + 1, (active ? 11 : 4) * scale, accuracy: 1)
                    XCTAssertEqual(maxY - minY + 1, 2 * scale, accuracy: 1)
                    XCTAssertEqual(minY, 25 * scale, accuracy: 1)
                }
            }
        }
    }

    func testHoverAndActiveDrawDistinctBordersAndPressedStateChangesPixels() throws {
        for dark in [false, true] {
            let view = button(dark: dark)
            let normal = try render(view, scale: 2)
            let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
            view.mouseEntered(with: entered)
            let hover = try render(view, scale: 2)
            let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
            view.mouseExited(with: exit)
            view.isActiveWindow = true
            let active = try render(view, scale: 2)
            let border = CGRect(x: 20, y: 0, width: 100, height: 2)
            let hoverContrast = changedPixels(normal, hover, region: border, scale: 2).count
            let activeContrast = changedPixels(normal, active, region: border, scale: 2).count
            XCTAssertGreaterThan(hoverContrast, 0)
            XCTAssertGreaterThanOrEqual(activeContrast, hoverContrast)
            XCTAssertGreaterThan(borderContrast(active), borderContrast(hover))
            view.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: CGPoint(x: 50, y: 14), modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            let pressed = try render(view, scale: 2)
            XCTAssertGreaterThan(changedPixels(active, pressed, region: CGRect(x: 30, y: 4, width: 100, height: 18), scale: 2).count, 100)
            view.cancelOperation(nil)
        }
    }
}
