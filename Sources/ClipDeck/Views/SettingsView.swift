import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var hotKeyManager: GlobalHotKeyManager

    var body: some View {
        TabView {
            GeneralSettingsPane(hotKeyManager: hotKeyManager)
                .tabItem {
                    Label(L10n.string("通用"), systemImage: "gearshape")
                }

            PrivacySettingsPane()
                .tabItem {
                    Label(L10n.string("隐私"), systemImage: "hand.raised")
                }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var loginItemManager: LoginItemManager
    @EnvironmentObject private var windowCoordinator: WindowCoordinator
    @ObservedObject var hotKeyManager: GlobalHotKeyManager

    var body: some View {
        Form {
            Section(L10n.string("记录")) {
                Toggle(L10n.string("记录新的剪贴板内容"), isOn: $store.isMonitoring)

                Text(L10n.string("暂停只影响之后的新内容；当前会话中已有的历史仍会保留。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.string("全局快捷键")) {
                ShortcutRecorderView(hotKeyManager: hotKeyManager)
            }

            Section(L10n.string("使用体验")) {
                Toggle(
                    L10n.string("复制后关闭窗口并返回上一个应用"),
                    isOn: $windowCoordinator.closesWindowAfterCopy
                )

                Text(
                    L10n.string(
                        "监听和清空历史不会更改当前剪贴板；从历史复制会替换当前内容，但不会自动粘贴，也不需要辅助功能权限。"
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    L10n.string(
                        "按 ⌃⇧⌘4 将选区截图复制到剪贴板，按 ⌃⇧⌘3 复制全屏；ClipDeck 会自动记录。若要长期启用，请按 ⇧⌘5，并在“选项 > 存储到”中选择“剪贴板”。"
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.string("启动")) {
                Toggle(L10n.string("登录时启动 ClipDeck"), isOn: loginItemBinding)
                    .disabled(!loginItemManager.canManageLoginItem)

                loginItemStatus
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("ClipDeck")
                    Spacer()
                    Text(AppVersion.current.displayText)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .frame(height: 39)
            }
            .background(.bar)
        }
        .frame(height: 660)
        .onAppear {
            loginItemManager.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            loginItemManager.refresh()
        }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItemManager.isRegistered },
            set: { loginItemManager.setEnabled($0) }
        )
    }

    @ViewBuilder
    private var loginItemStatus: some View {
        if !loginItemManager.canManageLoginItem {
            Text(L10n.string("安装到“应用程序”文件夹后可设置登录时启动。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if loginItemManager.requiresApproval {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    L10n.string("需要在系统设置中允许"),
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)

                Spacer()

                Button(L10n.string("打开系统设置")) {
                    loginItemManager.openSystemSettings()
                }
                .controlSize(.small)
            }
        } else if let errorMessage = loginItemManager.errorMessage {
            HStack(alignment: .firstTextBaseline) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button(L10n.string("重试")) {
                    loginItemManager.retry()
                }
                .controlSize(.small)
            }
        } else if let migrationMessage = loginItemManager.migrationMessage {
            Label(migrationMessage, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(
                loginItemManager.isEnabled
                    ? L10n.string("已由 macOS 原生登录项管理。")
                    : L10n.string("登录时不会自动启动。")
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PrivacySettingsPane: View {
    @EnvironmentObject private var privacySettings: CapturePrivacySettings

    var body: some View {
        Form {
            Section(L10n.string("敏感内容")) {
                Toggle(
                    L10n.string("跳过密码管理器等标记为机密或临时的内容"),
                    isOn: $privacySettings.skipsMarkedContent
                )

                Text(
                    L10n.string(
                        "遵循 nspasteboard.org 约定：1Password、KeePassXC 等复制的密码，以及文本扩展工具的临时内容不会进入历史。ClipDeck 只看来源应用的标记，不分析内容本身。"
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.string("忽略的应用")) {
                if privacySettings.ignoredBundleIdentifiers.isEmpty {
                    Text(L10n.string("没有忽略的应用。"))
                        .foregroundStyle(.secondary)
                }

                ForEach(privacySettings.ignoredBundleIdentifiers, id: \.self) { identifier in
                    IgnoredApplicationRow(
                        info: IgnoredApplicationInfo(bundleIdentifier: identifier),
                        onRemove: { privacySettings.stopIgnoring(bundleIdentifier: identifier) }
                    )
                }

                HStack {
                    Button(L10n.string("添加应用…"), action: addApplications)

                    Spacer()

                    if !privacySettings.usesDefaultIgnoredApplications {
                        Button(L10n.string("恢复默认")) {
                            privacySettings.restoreDefaultIgnoredApplications()
                        }
                    }
                }

                Text(
                    L10n.string(
                        "这些应用复制的内容不会被记录。若来源应用没有声明身份，以复制时的前台应用为准。"
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.string("数据")) {
                Text(
                    L10n.string(
                        "支持文字、富文本、链接、图片、PDF 和文件引用；同次复制的多项内容一起保存。文件本体不会读入；历史只存在内存中，退出后清空，不会上传。不支持或超限的内容会明确提示。"
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(height: 590)
    }

    private func addApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = L10n.string("忽略")
        panel.message = L10n.string("选择不想记录剪贴板内容的应用")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            privacySettings.ignoreApplication(at: url)
        }
    }
}

private struct IgnoredApplicationRow: View {
    let info: IgnoredApplicationInfo
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = info.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(info.name)
                if !info.isInstalled {
                    Text(L10n.string("未安装"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("不再忽略"))
            .accessibilityLabel(L10n.string("不再忽略 %@", info.name))
        }
    }
}
