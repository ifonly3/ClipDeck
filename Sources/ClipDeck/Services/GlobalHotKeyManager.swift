import Carbon
import Combine
import Foundation

/// Registers one system-wide shortcut, while leaving window creation to SwiftUI.
@MainActor
final class GlobalHotKeyManager: NSObject, ObservableObject {
    enum RegistrationState: Equatable {
        case notRegistered
        case registered
        case failed(OSStatus)
    }

    static let shortcutDescription = "⌃⌥V"

    @Published private(set) var errorMessage: String?
    @Published private(set) var registrationState: RegistrationState = .notRegistered

    var isRegistered: Bool {
        registrationState == .registered
    }

    // Carbon callbacks and teardown are process-local. Registration mutations are
    // main-actor isolated; `nonisolated(unsafe)` only lets deinit release the C refs.
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    private var action: (() -> Void)?

    func register(action: @escaping () -> Void) {
        self.action = action

        guard hotKey == nil else {
            registrationState = .registered
            errorMessage = nil
            return
        }

        performRegistration()
    }

    /// Re-attempts registration after a shortcut collision or transient Carbon error.
    func retry() {
        guard action != nil else {
            registrationState = .notRegistered
            errorMessage = "主窗口尚未准备好，暂时无法启用全局快捷键。"
            return
        }

        removeCarbonRegistration()
        performRegistration()
    }

    /// Removes the Carbon registration while retaining the action for a later retry.
    func unregister() {
        removeCarbonRegistration()
        registrationState = .notRegistered
        errorMessage = nil
    }

    private func performRegistration() {
        guard eventHandler == nil, hotKey == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return noErr
                }

                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor [weak manager] in
                    manager?.invokeAction()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard handlerStatus == noErr else {
            reportFailure(handlerStatus)
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x434C5044), // CLPD
            id: 1
        )
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )

        guard registrationStatus == noErr else {
            removeCarbonRegistration()
            reportFailure(registrationStatus)
            return
        }

        registrationState = .registered
        errorMessage = nil
    }

    private func invokeAction() {
        action?()
    }

    private func reportFailure(_ status: OSStatus) {
        registrationState = .failed(status)
        errorMessage = "无法启用全局快捷键（错误码 \(status)）。请检查快捷键冲突后重试。"
    }

    private func removeCarbonRegistration() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
