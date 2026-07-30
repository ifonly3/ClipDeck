import AppKit
import SwiftUI

/// A narrow AppKit bridge for Escape, which SwiftUI's onExitCommand does not
/// consistently deliver when the window itself or a toolbar field is focused.
struct WindowKeyboardBridge: NSViewRepresentable {
    let onEscape: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var onEscape: @MainActor () -> Void
        nonisolated(unsafe) private var monitor: Any?

        init(onEscape: @escaping @MainActor () -> Void) {
            self.onEscape = onEscape
        }

        func installMonitor() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard event.keyCode == 53,
                      let self,
                      let hostWindow = self.hostView?.window,
                      event.window === hostWindow,
                      hostWindow.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else {
                    return event
                }

                if let textView = hostWindow.firstResponder as? NSTextView,
                   textView.hasMarkedText() {
                    return event
                }

                self.onEscape()
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
