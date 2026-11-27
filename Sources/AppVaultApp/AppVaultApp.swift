import SwiftUI
import AppKit
import VaultCore

@MainActor
final class AppVaultDelegate: NSObject, NSApplicationDelegate {
    var hideDockWhenWindowClosed: Bool = true
    var onReopenManager: (() -> Void)?
    weak var viewModel: AppVaultViewModel?
    private var isTerminatingWithLock = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Release 模式下启用 XNU PT_DENY_ATTACH 反调试保护
        SecurityHardening.shared.denyDebuggerAttach()

        // 首次启动直接显示主窗口并置前
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDockIcon()
        if !flag {
            onReopenManager?()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出 AppVault 时，自动退出所有从保险箱打开的应用、撤除软链并卸载加密容器（带 5 秒超时兜底，防止退出卡死）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = viewModel, vm.isUnlocked else {
            return .terminateNow
        }
        if isTerminatingWithLock {
            return .terminateLater
        }
        isTerminatingWithLock = true

        var replied = false
        let finishQuit: @MainActor () -> Void = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        Task { @MainActor in
            await vm.lockVault(reason: "AppVault 退出，已自动关闭受管应用并锁定隐藏容器", force: true)
            finishQuit()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            finishQuit()
        }
        return .terminateLater
    }

    func showDockIcon() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideDockIconIfNoVisibleWindow() {
        guard hideDockWhenWindowClosed else { return }
        let hasMainWindow = NSApp.windows.contains { win in
            win.isVisible && win.canBecomeMain && win.className != "NSStatusBarWindow"
        }
        if !hasMainWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@main
struct AppVaultApp: App {
    @NSApplicationDelegateAdaptor(AppVaultDelegate.self) private var appDelegate
    private let vm = AppVaultViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("AppVault", id: "manager") {
            VaultManagerView(vm: vm)
                .onAppear {
                    appDelegate.viewModel = vm
                    appDelegate.hideDockWhenWindowClosed = vm.hostConfig?.hideDockWhenWindowClosed ?? true
                    appDelegate.onReopenManager = {
                        openWindow(id: "manager")
                    }
                    appDelegate.showDockIcon()
                }
                .onDisappear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        appDelegate.hideDockIconIfNoVisibleWindow()
                    }
                }
        }
        .defaultSize(width: 920, height: 600)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarPopoverView(vm: vm) {
                openManagerWindow()
            }
        } label: {
            Image(systemName: vm.isUnlocked ? "lock.open.fill" : "lock.fill")
                .accessibilityLabel(vm.isUnlocked ? "AppVault 已解锁" : "AppVault 已锁定")
        }
        .menuBarExtraStyle(.window)
    }

    private func openManagerWindow() {
        appDelegate.viewModel = vm
        appDelegate.showDockIcon()
        openWindow(id: "manager")
        NSApp.activate(ignoringOtherApps: true)
    }
}
