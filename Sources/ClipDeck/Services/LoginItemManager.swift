import Combine
import Foundation
import ServiceManagement

/// Manages the native main-app login item and safely retires ClipDeck's old LaunchAgent.
@MainActor
final class LoginItemManager: ObservableObject {
    static let legacyLabel = "com.qiaoni.clipdeck.login"

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    @Published private(set) var migrationMessage: String?

    var isEnabled: Bool {
        status == .enabled
    }

    var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var canManageLoginItem: Bool {
        Self.isRunningInstalledApplication
    }

    private static let legacyConfiguredKey =
        "com.qiaoni.ClipDeck.nativeLoginItemConfigured"
    private static let desiredEnabledKey =
        "com.qiaoni.ClipDeck.desiredLoginItemEnabled"
    private static let registeredVersionKey =
        "com.qiaoni.ClipDeck.registeredLoginItemVersion"
    private static let installedApplicationPath = "/Applications/ClipDeck.app"

    private let service: SMAppService
    private let fileManager: FileManager
    private let defaults: UserDefaults

    init(
        service: SMAppService = .mainApp,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.fileManager = fileManager
        self.defaults = defaults
        self.status = service.status

        guard canManageLoginItem else {
            return
        }

        initializeDesiredPreferenceIfNeeded()
        resumeMigrationOrReconcile()
    }

    /// Refreshes both native status and any interrupted legacy migration.
    func refresh() {
        refreshStatus()
        guard canManageLoginItem else {
            return
        }
        resumeMigrationOrReconcile()
    }

    func setEnabled(_ enabled: Bool) {
        guard canManageLoginItem else {
            errorMessage = "请先把 ClipDeck 安装到“应用程序”文件夹，再设置登录时启动。"
            return
        }

        defaults.set(enabled, forKey: Self.desiredEnabledKey)
        defaults.set(true, forKey: Self.legacyConfiguredKey)
        migrationMessage = nil

        if enabled {
            resumeMigrationOrReconcile()
        } else {
            let didDisableLegacy = disableValidatedLegacyLaunchAgentIfPresent()
            let legacyError = errorMessage
            unregisterNativeService()
            if !didDisableLegacy {
                errorMessage = legacyError
                    ?? "无法关闭旧版启动项，请在系统设置的登录项中检查 ClipDeck。"
            }
        }
    }

    func retry() {
        refreshStatus()
        if requiresApproval {
            openSystemSettings()
            return
        }
        resumeMigrationOrReconcile()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var desiredEnabled: Bool {
        defaults.bool(forKey: Self.desiredEnabledKey)
    }

    private func initializeDesiredPreferenceIfNeeded() {
        guard defaults.object(forKey: Self.desiredEnabledKey) == nil else {
            return
        }

        if defaults.object(forKey: Self.legacyConfiguredKey) != nil {
            defaults.set(isRegistered, forKey: Self.desiredEnabledKey)
        } else {
            // ClipDeck has historically enabled launch-at-login by default.
            defaults.set(true, forKey: Self.desiredEnabledKey)
        }
    }

    private func resumeMigrationOrReconcile() {
        switch validatedLegacyLaunchAgent() {
        case .valid(let legacyURL):
            if desiredEnabled {
                migrateLegacyLaunchAgent(at: legacyURL)
            } else {
                let didDisableLegacy = disableValidatedLegacyLaunchAgent(at: legacyURL)
                let legacyError = errorMessage
                unregisterNativeService()
                if !didDisableLegacy {
                    errorMessage = legacyError
                }
            }
        case .invalid:
            let legacyWarning = "发现同名旧启动项，但内容不符合 ClipDeck 的安全迁移规则；已保留原文件。"
            reconcileNativeService()
            if errorMessage == nil {
                errorMessage = legacyWarning
            }
        case .missing:
            reconcileNativeService()
        }
    }

    private func reconcileNativeService() {
        refreshStatus()

        guard desiredEnabled else {
            unregisterNativeService()
            return
        }

        if requiresApproval {
            errorMessage = "需要在“系统设置 > 通用 > 登录项”中允许 ClipDeck。"
            return
        }

        if isEnabled {
            if registeredVersion != currentBundleVersion {
                refreshRegistrationForCurrentBuild()
            } else {
                errorMessage = nil
            }
            return
        }

        registerNativeService()
    }

    private func registerNativeService() {
        refreshStatus()
        if isEnabled {
            markRegistrationCurrent()
            errorMessage = nil
            return
        }
        if requiresApproval {
            errorMessage = "需要在“系统设置 > 通用 > 登录项”中允许 ClipDeck。"
            return
        }

        do {
            try service.register()
            refreshStatus()
            if isEnabled {
                markRegistrationCurrent()
                errorMessage = nil
            } else if requiresApproval {
                errorMessage = "需要在“系统设置 > 通用 > 登录项”中允许 ClipDeck。"
            } else {
                errorMessage = "系统没有启用 ClipDeck 登录项，请稍后重试。"
            }
        } catch {
            refreshStatus()
            errorMessage = "无法启用登录时启动：\(error.localizedDescription)"
        }
    }

    private func unregisterNativeService() {
        refreshStatus()
        guard isRegistered else {
            defaults.removeObject(forKey: Self.registeredVersionKey)
            if errorMessage?.contains("旧版启动项") != true {
                errorMessage = nil
            }
            return
        }

        do {
            try service.unregister()
            refreshStatus()
            defaults.removeObject(forKey: Self.registeredVersionKey)
            if errorMessage?.contains("旧版启动项") != true {
                errorMessage = nil
            }
        } catch {
            refreshStatus()
            errorMessage = "无法关闭登录时启动：\(error.localizedDescription)"
        }
    }

    /// Ad-hoc signatures have a changing designated requirement after updates.
    /// Re-register once per installed build so ServiceManagement follows the new binary.
    private func refreshRegistrationForCurrentBuild() {
        do {
            try service.unregister()
            refreshStatus()
            try service.register()
            refreshStatus()
            guard isEnabled else {
                if requiresApproval {
                    errorMessage = "需要在“系统设置 > 通用 > 登录项”中允许 ClipDeck。"
                } else {
                    errorMessage = "更新登录项后系统未确认启用，请重试。"
                }
                return
            }
            markRegistrationCurrent()
            errorMessage = nil
        } catch {
            refreshStatus()
            errorMessage = "更新登录项失败：\(error.localizedDescription)"
        }
    }

    private enum LegacyLaunchAgentValidation {
        case missing
        case invalid
        case valid(URL)
    }

    private func validatedLegacyLaunchAgent() -> LegacyLaunchAgentValidation {
        guard let libraryDirectory = fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first else {
            return .missing
        }

        let legacyURL = libraryDirectory
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.legacyLabel).plist", isDirectory: false)

        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return .missing
        }

        guard let data = try? Data(contentsOf: legacyURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              plist["Label"] as? String == Self.legacyLabel,
              let arguments = plist["ProgramArguments"] as? [String],
              arguments == ["/usr/bin/open", Self.installedApplicationPath] else {
            return .invalid
        }

        return .valid(legacyURL)
    }

    private func migrateLegacyLaunchAgent(at legacyURL: URL) {
        refreshStatus()
        let nativeWasEnabled = isEnabled

        if !nativeWasEnabled {
            registerNativeService()
            guard isEnabled else {
                errorMessage = "旧登录项仍然保留；\(errorMessage ?? "原生登录项尚未启用。")"
                return
            }
        } else if registeredVersion != currentBundleVersion {
            refreshRegistrationForCurrentBuild()
            guard isEnabled else {
                errorMessage = "旧登录项仍然保留；\(errorMessage ?? "无法更新原生登录项。")"
                return
            }
        }

        let legacyStatus = SMAppService.statusForLegacyPlist(at: legacyURL)
        let bootoutResult = runLaunchctl([
            "bootout",
            "gui/\(getuid())/\(Self.legacyLabel)"
        ])
        let bootoutSucceeded = bootoutResult.status == 0 || legacyStatus != .enabled

        guard bootoutSucceeded else {
            if !nativeWasEnabled {
                try? service.unregister()
                refreshStatus()
            }
            errorMessage = "旧登录项仍然保留；无法卸载旧启动任务（错误码 \(bootoutResult.status)）。"
            return
        }

        do {
            try fileManager.removeItem(at: legacyURL)
        } catch {
            let rollback = runLaunchctl([
                "bootstrap",
                "gui/\(getuid())",
                legacyURL.path
            ])
            if !nativeWasEnabled {
                try? service.unregister()
                refreshStatus()
            }
            let rollbackSuffix = rollback.status == 0 ? "" : "，且旧任务恢复失败（错误码 \(rollback.status)）"
            errorMessage = "旧登录项仍然保留；无法完成安全迁移：\(error.localizedDescription)\(rollbackSuffix)"
            return
        }

        defaults.set(true, forKey: Self.desiredEnabledKey)
        defaults.set(true, forKey: Self.legacyConfiguredKey)
        markRegistrationCurrent()
        refreshStatus()
        migrationMessage = "已迁移到 macOS 原生登录项，旧启动代理已卸载。"
        errorMessage = nil
    }

    @discardableResult
    private func disableValidatedLegacyLaunchAgentIfPresent() -> Bool {
        switch validatedLegacyLaunchAgent() {
        case .missing:
            return true
        case .invalid:
            errorMessage = "发现同名旧启动项但无法安全识别，请在系统设置中手动关闭。"
            return false
        case .valid(let legacyURL):
            return disableValidatedLegacyLaunchAgent(at: legacyURL)
        }
    }

    private func disableValidatedLegacyLaunchAgent(at legacyURL: URL) -> Bool {
        let legacyStatus = SMAppService.statusForLegacyPlist(at: legacyURL)
        let bootoutResult = runLaunchctl([
            "bootout",
            "gui/\(getuid())/\(Self.legacyLabel)"
        ])
        guard bootoutResult.status == 0 || legacyStatus != .enabled else {
            errorMessage = "无法卸载旧启动任务（错误码 \(bootoutResult.status)）。"
            return false
        }

        do {
            try fileManager.removeItem(at: legacyURL)
            return true
        } catch {
            errorMessage = "无法删除旧启动项：\(error.localizedDescription)"
            return false
        }
    }

    private func refreshStatus() {
        status = service.status
    }

    private var registeredVersion: String? {
        defaults.string(forKey: Self.registeredVersionKey)
    }

    private var currentBundleVersion: String {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let buildVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"
        return "\(shortVersion)-\(buildVersion)"
    }

    private func markRegistrationCurrent() {
        defaults.set(currentBundleVersion, forKey: Self.registeredVersionKey)
    }

    private struct LaunchctlResult {
        let status: Int32
    }

    private func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return LaunchctlResult(status: process.terminationStatus)
        } catch {
            return LaunchctlResult(status: -1)
        }
    }

    private static var isRunningInstalledApplication: Bool {
        Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path == installedApplicationPath
    }
}
