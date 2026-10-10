import AppKit
import Carbon
import SwiftUI

/// Records a new global shortcut from the next key press in Settings.
struct ShortcutRecorderView: View {
    @ObservedObject var hotKeyManager: GlobalHotKeyManager
    @StateObject private var recorder = KeyPressRecorder()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggleRecording) {
                    Text(buttonTitle)
                        .monospacedDigit()
                        .frame(minWidth: 150)
                }
                .help(L10n.string("点击后按下新的快捷键"))
                .accessibilityLabel(L10n.string("全局快捷键：%@", buttonTitle))

                if hotKeyManager.shortcut != .default {
                    Button(L10n.string("恢复默认")) {
                        apply(.default)
                    }
                }

                if hotKeyManager.shortcut != nil {
                    Button(L10n.string("关闭")) {
                        apply(nil)
                    }
                    .help(L10n.string("关闭全局快捷键，仍可从菜单栏打开历史"))
                }
            }

            Text(message ?? L10n.string(
                "需包含 ⌃，或 ⌘ 加另一个修饰键；F1–F20 可单独使用。再次按下可关闭历史窗口。"
            ))
            .font(.caption)
            .foregroundStyle(message == nil ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear(perform: cancelRecording)
    }

    private var buttonTitle: String {
        if recorder.isRecording {
            return L10n.string("请按下新的快捷键…")
        }
        return hotKeyManager.shortcutDescription ?? L10n.string("已关闭")
    }

    private func toggleRecording() {
        if recorder.isRecording {
            cancelRecording()
            return
        }
        message = nil
        // Release the current shortcut so pressing it again can be recorded.
        hotKeyManager.suspendForRecording()
        recorder.start { event in
            handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            cancelRecording()
            return
        }
        switch HotKeyShortcut.make(from: event) {
        case .success(let shortcut):
            recorder.stop()
            message = hotKeyManager.updateShortcut(shortcut)
        case .failure(.interferesWithTyping):
            message = L10n.string("这个组合会影响正常输入或常用命令。请加上 ⌃，或用 ⌘ 搭配另一个修饰键。")
        case .failure(.unsupportedKey):
            message = L10n.string("无法使用这个按键，请换一个。")
        }
    }

    private func cancelRecording() {
        guard recorder.isRecording else { return }
        recorder.stop()
        hotKeyManager.resumeAfterRecording()
    }

    private func apply(_ shortcut: HotKeyShortcut?) {
        cancelRecording()
        message = hotKeyManager.updateShortcut(shortcut)
    }
}

/// Swallows key presses in ClipDeck's windows while a shortcut is recorded.
@MainActor
private final class KeyPressRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    nonisolated(unsafe) private var monitor: Any?

    func start(_ handler: @escaping (NSEvent) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
