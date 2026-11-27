import SwiftUI
import VaultCore

struct MenuBarPopoverView: View {
    @Bindable var vm: AppVaultViewModel
    let onOpenManager: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Text("AppVault")
                        .font(.system(size: 13, weight: .semibold))
                    ShadcnBadge(
                        text: vm.isUnlocked ? "已解锁" : "已锁定",
                        tone: vm.isUnlocked ? .emerald : .neutral,
                        showDot: true
                    )
                }
                Spacer()
                Text("⌃⌥⌘L")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ShadcnTokens.mutedForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ShadcnTokens.muted, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ShadcnTokens.border, lineWidth: 1))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            // Body
            if !vm.hasVaultConfigured {
                VStack(spacing: 10) {
                    Text("尚未初始化加密容器")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("打开主窗口创建 AES-256 APFS 保险箱")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                    Button("开始初始化") {
                        vm.showSetupSheet = true
                        onOpenManager()
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .primary))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 14)
            } else if vm.isUnlocked {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("受管应用（退出即自动重锁）")
                            .font(.system(size: 11))
                            .foregroundStyle(ShadcnTokens.mutedForeground)
                        Spacer()
                        Text("\(vm.manifest.apps.count) 项")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ShadcnTokens.mutedForeground)
                    }
                    .padding(.bottom, 2)

                    if vm.manifest.apps.isEmpty {
                        Text("暂无已收容应用，请在主窗口拖入 .app")
                            .font(.system(size: 12))
                            .foregroundStyle(ShadcnTokens.mutedForeground)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(vm.manifest.apps) { app in
                            let isRunning = vm.isAppRunning(app)
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(isRunning ? ShadcnTokens.emeraldFg : ShadcnTokens.mutedForeground.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                Text(app.displayName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                Text(isRunning ? "运行中" : ByteFormatter.string(from: app.totalSizeBytes))
                                    .font(.system(size: 11))
                                    .foregroundStyle(ShadcnTokens.mutedForeground)
                                Spacer()
                                Button(isRunning ? "退出" : "启动") {
                                    if isRunning { vm.quitApp(app) } else { vm.launchApp(app) }
                                }
                                .buttonStyle(ShadcnButtonStyle(variant: isRunning ? .secondary : .outline, compact: true))
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 8) {
                    Text("加密容器已锁定隐藏")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Finder、Spotlight 与 Launchpad 均不可见")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                    Button {
                        if vm.hostConfig?.touchIDEnabled == true && vm.hasTouchIDKeyStored {
                            Task { await vm.unlockWithTouchID() }
                        } else {
                            vm.showUnlockSheet = true
                            onOpenManager()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "touchid")
                            Text("使用 Touch ID 或密码解锁")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .primary))
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.horizontal, 14)
            }

            Divider()

            // Footer
            HStack(spacing: 6) {
                Button("打开管理窗口") { onOpenManager() }
                    .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
                Spacer()
                if vm.isUnlocked {
                    Button("锁定") {
                        Task { await vm.lockVault(reason: "菜单栏手动锁定") }
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .secondary, compact: true))
                }
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(ShadcnButtonStyle(variant: .ghost, compact: true))
                .help("退出 AppVault 并关闭所有已打开的保险箱应用")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ShadcnTokens.muted)
        }
        .frame(width: 320)
        .background(ShadcnTokens.background)
        .preferredColorScheme(vm.themeMode.colorScheme)
    }
}
