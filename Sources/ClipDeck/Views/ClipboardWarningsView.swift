import SwiftUI

struct ClipboardWarningsView: View {
    let hotKeyError: String?
    let accessStatus: String?
    let storageWarning: String?
    let captureWarning: String?
    let isCompact: Bool
    let onRetryHotKey: () -> Void

    var body: some View {
        if hasWarnings {
            VStack(spacing: isCompact ? 6 : 8) {
                if let hotKeyError {
                    WarningBanner(
                        message: hotKeyError,
                        systemImage: "keyboard.badge.exclamationmark",
                        isCompact: isCompact,
                        actionTitle: L10n.string("重试"),
                        action: onRetryHotKey
                    )
                }

                if let accessStatus {
                    WarningBanner(
                        message: accessStatus,
                        systemImage: "lock.trianglebadge.exclamationmark",
                        isCompact: isCompact
                    )
                }

                if let storageWarning {
                    WarningBanner(
                        message: storageWarning,
                        systemImage: "externaldrive.badge.exclamationmark",
                        isCompact: isCompact
                    )
                }

                if let captureWarning {
                    WarningBanner(
                        message: captureWarning,
                        systemImage: "photo.badge.exclamationmark",
                        isCompact: isCompact
                    )
                }
            }
            .padding(.horizontal, isCompact ? 0 : 14)
            .padding(.bottom, isCompact ? 0 : 10)
        }
    }

    private var hasWarnings: Bool {
        hotKeyError != nil
            || accessStatus != nil
            || storageWarning != nil
            || captureWarning != nil
    }
}

private struct WarningBanner: View {
    let message: String
    let systemImage: String
    let isCompact: Bool
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .accessibilityHint(L10n.string("再次尝试启用全局快捷键"))
            }
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 6 : 8)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.orange.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
