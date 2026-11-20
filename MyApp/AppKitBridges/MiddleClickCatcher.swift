import AppKit
import SwiftUI

/// Transparent overlay that only claims middle-clicks, so the tab's SwiftUI click
/// handling keeps working for left and right clicks.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MiddleClickView, context: Context) {
        nsView.action = action
    }

    final class MiddleClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .otherMouseDown, .otherMouseUp:
                return event.buttonNumber == 2 ? self : nil
            default:
                return nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return }
            action?()
        }
    }
}
