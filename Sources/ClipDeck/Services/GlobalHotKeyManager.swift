import Carbon
import Combine
import Foundation

/// Registers one system-wide shortcut, while leaving window creation to SwiftUI.
@MainActor
final class GlobalHotKeyManager: NSObject, ObservableObject {
    enum RegistrationState: Equatable {
        case notRegistered
        case registered
        case disabled
        case failed(OSStatus)
    }

    static let shortcutDefaultsKey = "com.qiaoni.ClipDeck.globalShortcut"
    static let shortcutDisabledDefaultsKey = "com.qiaoni.ClipDeck.globalShortcutDisabled"

    @Published private(set) var errorMessage: String?
    @Published private(set) var registrationState: RegistrationState = .notRegistered
    /// nil when the user turned the global shortcut off.
    @Published private(set) var shortcut: HotKeyShortcut?

    var isRegistered: Bool {
        registrationState == .registered
    }

    var shortcutDescription: String? {
        shortcut?.displayString
    }

    // Carbon callbacks and teardown are process-local. Registration mutations are
    // main-actor isolated; `nonisolated(unsafe)` only lets deinit release the C refs.
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    private var action: (() -> Void)?
    private let enablesSystemRegistration: Bool
    private let defaults: UserDefaults

    init(enablesSystemRegistration: Bool = true, defaults: UserDefaults = .standard) {
        self.enablesSystemRegistration = enablesSystemRegistration
        self.defaults = defaults
        self.shortcut = Self.storedShortcut(in: defaults)
        super.init()
    }

    /// Called once at launch, independent of which window or menu appears first.
    func register(action: @escaping () -> Void) {
        self.action = action
        guard enablesSystemRegistration else { return }

        guard hotKey == nil else {
            registrationState = .registered
            errorMessage = nil
            return
        }

        performRegistration()
    }

    /// Re-attempts registration after a shortcut collision or transient Carbon error.
    func retry() {
        guard enablesSystemRegistration else { return }
        guard action != nil else {
            registrationState = .notRegistered
            errorMessage = L10n.string("主窗口尚未准备好，暂时无法启用全局快捷键。")
            return
        }

        removeHotKeyRegistration()
        performRegistration()
    }

    /// Removes the Carbon registration while retaining the action for a later retry.
    func unregister() {
        removeHotKeyRegistration()
        registrationState = .notRegistered
        errorMessage = nil
    }

    /// Applies a new shortcut; nil turns the global shortcut off. When macOS
    /// refuses the new combination, the previous one is restored and the error
    /// message is returned for the recorder to show.
    @discardableResult
    func updateShortcut(_ newShortcut: HotKeyShortcut?) -> String? {
        let previous = shortcut
        shortcut = newShortcut
        guard enablesSystemRegistration, action != nil else {
            persist(newShortcut)
            return nil
        }

        removeHotKeyRegistration()
        performRegistration()
        if case .failed = registrationState, newShortcut != nil {
            let message = errorMessage
            shortcut = previous
            performRegistration()
            return message
        }
        persist(newShortcut)
        return nil
    }

    /// Releases the shortcut so the recorder can receive the same key press.
    func suspendForRecording() {
        removeHotKeyRegistration()
    }

    func resumeAfterRecording() {
        guard enablesSystemRegistration, action != nil, hotKey == nil else { return }
        performRegistration()
    }

    private func performRegistration() {
        guard let shortcut else {
            registrationState = .disabled
            errorMessage = nil
            return
        }
        guard hotKey == nil else {
            return
        }

        if eventHandler == nil {
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
                eventHandler = nil
                reportFailure(handlerStatus)
                return
            }
        }

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x434C5044), // CLPD
            id: 1
        )
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )

        guard registrationStatus == noErr else {
            hotKey = nil
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
        errorMessage = L10n.string(
            "无法启用全局快捷键 %@（错误码 %d）。它可能已被其他应用占用，请在设置中更换。",
            shortcut?.displayString ?? "",
            status
        )
    }

    private func removeHotKeyRegistration() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    private func persist(_ shortcut: HotKeyShortcut?) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: Self.shortcutDefaultsKey)
            defaults.set(false, forKey: Self.shortcutDisabledDefaultsKey)
        } else {
            defaults.set(true, forKey: Self.shortcutDisabledDefaultsKey)
        }
    }

    static func storedShortcut(in defaults: UserDefaults) -> HotKeyShortcut? {
        if defaults.bool(forKey: shortcutDisabledDefaultsKey) {
            return nil
        }
        guard let data = defaults.data(forKey: shortcutDefaultsKey),
              let stored = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              HotKeyShortcut.validate(keyCode: stored.keyCode, carbonModifiers: stored.carbonModifiers) == nil else {
            return .default
        }
        return stored
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
