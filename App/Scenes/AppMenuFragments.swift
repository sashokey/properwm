import AppKit
import SwiftUI

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

final class MenuHostNSView: NSView {
    var builder: (() -> NSMenu)?
    var popUpHandler: ((NSEvent, NSView) -> Void)?
    var shouldClaim: ((CGPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil, let e = NSApp.currentEvent else { return nil }
        if let shouldClaim, !shouldClaim(NSEvent.mouseLocation) { return nil }
        switch e.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return self
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return e.modifierFlags.contains(.control) ? self : nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { popUp(event) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { popUp(event) }
        else { super.mouseDown(with: event) }
    }

    private func popUp(_ event: NSEvent) {
        if let popUpHandler {
            popUpHandler(event, self)
            return
        }
        guard let menu = builder?(), !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct NativeMenuHost: NSViewRepresentable {
    var builder: (() -> NSMenu)?
    var popUpHandler: ((NSEvent, NSView) -> Void)?
    var shouldClaim: ((CGPoint) -> Bool)?

    init(builder: @escaping () -> NSMenu) {
        self.builder = builder
    }

    init(
        popUpHandler: @escaping (NSEvent, NSView) -> Void,
        shouldClaim: ((CGPoint) -> Bool)? = nil
    ) {
        self.popUpHandler = popUpHandler
        self.shouldClaim = shouldClaim
    }

    func makeNSView(context: Context) -> MenuHostNSView {
        let v = MenuHostNSView()
        v.builder = builder
        v.popUpHandler = popUpHandler
        v.shouldClaim = shouldClaim
        return v
    }
    func updateNSView(_ v: MenuHostNSView, context: Context) {
        v.builder = builder
        v.popUpHandler = popUpHandler
        v.shouldClaim = shouldClaim
    }
}

extension View {
    func nativeContextMenu(_ builder: @escaping () -> NSMenu) -> some View {
        overlay(NativeMenuHost(builder: builder))
    }
}

