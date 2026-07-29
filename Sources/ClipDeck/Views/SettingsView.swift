import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var loginItemManager: LoginItemManager
    @EnvironmentObject private var windowCoordinator: WindowCoordinator

    var body: some View {
        Form {
            Section("记录") {
                Toggle("记录新的剪贴板内容", isOn: $store.isMonitoring)

                Text("暂停只影响之后的新内容；当前会话中已有的历史仍会保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("使用体验") {
                Toggle(
                    "复制后关闭窗口并返回上一个应用",
                    isOn: $windowCoordinator.closesWindowAfterCopy
                )

                Text("只恢复剪贴板，不会自动粘贴，也不需要辅助功能权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle("登录时启动 ClipDeck", isOn: loginItemBinding)
                    .disabled(!loginItemManager.canManageLoginItem)

                loginItemStatus
            }

            Section("数据") {
                Text("文字和图片都按相同规则记录。历史只存在当前运行会话的内存中，退出 ClipDeck 后自动清空，不会上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 390)
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
            Text("安装到“应用程序”文件夹后可设置登录时启动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if loginItemManager.requiresApproval {
            HStack(alignment: .firstTextBaseline) {
                Label("需要在系统设置中允许", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Spacer()

                Button("打开系统设置") {
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

                Button("重试") {
                    loginItemManager.retry()
                }
                .controlSize(.small)
            }
        } else if let migrationMessage = loginItemManager.migrationMessage {
            Label(migrationMessage, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(loginItemManager.isEnabled ? "已由 macOS 原生登录项管理。" : "登录时不会自动启动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
