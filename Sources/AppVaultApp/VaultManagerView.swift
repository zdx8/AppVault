import SwiftUI
import UniformTypeIdentifiers
import AppKit
import VaultCore

struct VaultManagerView: View {
    @Bindable var vm: AppVaultViewModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            mainContent
        }
        .frame(minWidth: 880, minHeight: 580)
        .background(ShadcnTokens.background)
        .background(WindowTitlebarStyler(themeMode: vm.themeMode))
        .preferredColorScheme(vm.themeMode.colorScheme)
        .sheet(isPresented: $vm.showSetupSheet) {
            SetupVaultSheetView(vm: vm)
        }
        .sheet(isPresented: $vm.showUnlockSheet) {
            UnlockSheetView(vm: vm)
        }
        .sheet(isPresented: $vm.showChangePasswordSheet) {
            ChangePasswordSheetView(vm: vm)
        }
        .sheet(isPresented: $vm.showEnableTouchIDSheet) {
            EnableTouchIDSheetView(vm: vm)
        }
        .sheet(isPresented: $vm.showIngestSheet) {
            IngestConfirmSheetView(vm: vm)
        }
        .sheet(item: $vm.inspectingMappingApp) { app in
            MappingDetailSheetView(app: app) {
                vm.inspectingMappingApp = nil
            }
            .preferredColorScheme(vm.themeMode.colorScheme)
        }
        .alert("加密容器仍有进程占用", isPresented: $vm.showBusyAlert) {
            Button("优雅终止进程并强制锁定", role: .destructive) {
                Task { await vm.lockVault(reason: "用户确认终止占用进程后锁定", force: true) }
            }
            Button("稍后重试", role: .cancel) {}
        } message: {
            Text("检测到以下应用或进程仍在运行/占用卷句柄：\(vm.busyProcessesAlert.joined(separator: "、"))。\n建议先保存数据并退出应用，或选择直接终止并锁定。")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Container Status Card
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("主加密容器")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("APFS")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                }

                let maxBytes = Int64(vm.hostConfig?.maxSizeMB ?? 20480) * 1024 * 1024
                let displayUsed = vm.isUnlocked ? vm.volumeUsedBytes : vm.allocatedContainerBytes
                let ratio = maxBytes > 0 ? min(1.0, Double(displayUsed) / Double(maxBytes)) : 0
                Text("已用 \(ByteFormatter.string(from: displayUsed)) / 上限 \(ByteFormatter.string(from: maxBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(ShadcnTokens.mutedForeground)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ShadcnTokens.foreground.opacity(0.14))
                        Capsule()
                            .fill(ShadcnTokens.primary)
                            .frame(width: max(6, geo.size.width * ratio))
                    }
                }
                .frame(height: 5)
                .padding(.top, 2)

                HStack(spacing: 5) {
                    tagPill("-nobrowse")
                    tagPill("无索引")
                }
                .padding(.top, 2)
            }
            .padding(12)
            .background(ShadcnTokens.muted, in: RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
            .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))

            // Navigation
            VStack(spacing: 3) {
                ForEach(ManagerTab.allCases) { tab in
                    let isSelected = vm.selectedTab == tab
                    Button {
                        vm.selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13))
                                .frame(width: 16)
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            Spacer()
                            if tab == .apps && vm.isUnlocked {
                                Text("\(vm.manifest.apps.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(ShadcnTokens.mutedForeground)
                            }
                        }
                        .foregroundStyle(isSelected ? ShadcnTokens.foreground : ShadcnTokens.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? ShadcnTokens.secondary : Color.clear, in: RoundedRectangle(cornerRadius: ShadcnTokens.radiusSM))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Lock / Unlock CTA
            VStack(spacing: 8) {
                Button {
                    if vm.isUnlocked {
                        Task { await vm.lockVault(reason: "主窗口手动锁定") }
                    } else if vm.hasVaultConfigured {
                        vm.showUnlockSheet = true
                    } else {
                        vm.showSetupSheet = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: vm.isUnlocked ? "lock.fill" : "lock.open.fill")
                        Text(vm.isUnlocked ? "立即锁定并隐藏" : "解锁容器")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ShadcnButtonStyle(variant: .primary))
                .disabled(vm.isWorking)

                Text("紧急锁定快捷键 ⌃⌥⌘L")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ShadcnTokens.mutedForeground)
            }
        }
        .padding(14)
        .frame(width: 228)
        .background(ShadcnTokens.background)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Top Status Bar inside content
                HStack {
                    ShadcnBadge(
                        text: vm.isUnlocked ? "AES-256 私有挂载" : "已锁定隐藏",
                        tone: vm.isUnlocked ? .emerald : .neutral,
                        showDot: true
                    )
                    if let err = vm.errorMessage {
                        Text(err)
                            .font(.system(size: 11.5))
                            .foregroundStyle(ShadcnTokens.redFg)
                            .lineLimit(1)
                            .padding(.leading, 8)
                    }
                    Spacer()
                    if vm.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        vm.toggleTheme()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: vm.themeMode.toggleIcon)
                                .font(.system(size: 11.5))
                            Text(vm.themeMode == .light ? "深色模式" : "浅色模式")
                        }
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
                    .help("切换浅色 / 深色主题")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(ShadcnTokens.background)

                Divider()

                if !vm.hasVaultConfigured {
                    uninitializedCurtain
                } else if !vm.isUnlocked && (vm.selectedTab == .apps || vm.selectedTab == .ingest) {
                    lockedCurtain
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            switch vm.selectedTab {
                            case .apps: appsView
                            case .ingest: ingestView
                            case .security: securityView
                            case .logs: logsView
                            }
                        }
                        .padding(24)
                    }
                }
            }

            if let banner = vm.statusBanner {
                Text(banner)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ShadcnTokens.primaryForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(ShadcnTokens.primary, in: RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .padding(20)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Curtains

    private var uninitializedCurtain: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .padding(16)
                .background(ShadcnTokens.muted, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ShadcnTokens.border, lineWidth: 1))
            Text("欢迎使用 AppVault")
                .font(.system(size: 16, weight: .semibold))
            Text("首次使用需创建一个 AES-256 APFS 加密稀疏卷，用于隐身存储你的应用及关联数据。")
                .font(.system(size: 12.5))
                .foregroundStyle(ShadcnTokens.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("初始化加密容器") { vm.showSetupSheet = true }
                .buttonStyle(ShadcnButtonStyle(variant: .primary))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lockedCurtain: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .padding(16)
                .background(ShadcnTokens.muted, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ShadcnTokens.border, lineWidth: 1))
            Text("保险箱已锁定")
                .font(.system(size: 16, weight: .semibold))
            Text("加密卷已安全卸载，~/Library 软链已撤除。受管应用清单仅存于 AES-256 密文卷内，宿主机不暴露任何应用名称。")
                .font(.system(size: 12.5))
                .foregroundStyle(ShadcnTokens.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                if vm.hostConfig?.touchIDEnabled == true && vm.hasTouchIDKeyStored {
                    Button {
                        Task { await vm.unlockWithTouchID() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "touchid")
                            Text("Touch ID 解锁")
                        }
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .primary))
                }
                Button("输入主密码") { vm.showUnlockSheet = true }
                    .buttonStyle(ShadcnButtonStyle(variant: .outline))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - View 1: Apps

    private var appsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("保险箱应用")
                        .font(.system(size: 16, weight: .semibold))
                    Text("仅在解锁挂载期间通过软链桥接运行，所有受管进程退出后自动撤链并卸载容器。")
                        .font(.system(size: 12))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                }
                Spacer()
                HStack(spacing: 8) {
                    TextField("搜索受管应用...", text: $vm.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                    Button("+ 导入 .app") { vm.selectedTab = .ingest }
                        .buttonStyle(ShadcnButtonStyle(variant: .primary, compact: true))
                }
            }

            // KPI Grid
            HStack(spacing: 10) {
                kpiCard(label: "已隐身应用", value: "\(vm.manifest.apps.count)", sub: "Launchpad 已注销")
                kpiCard(
                    label: "运行中进程",
                    value: "\(vm.runningPIDs.count)",
                    sub: vm.runningPIDs.isEmpty ? "当前无活跃进程" : "退出全部后自动重锁"
                )
                kpiCard(
                    label: "卷内实际占用",
                    value: ByteFormatter.string(from: vm.volumeUsedBytes),
                    sub: vm.allocatedContainerBytes > vm.volumeUsedBytes + 64 * 1024 * 1024
                        ? "主机占 \(ByteFormatter.string(from: vm.allocatedContainerBytes)) · 锁定自动回收"
                        : "主机占 \(ByteFormatter.string(from: vm.allocatedContainerBytes))"
                )
                kpiCard(label: "挂载隐身状态", value: "三重隐身", sub: "Finder / Spotlight 不可见")
            }

            if vm.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Text(vm.manifest.apps.isEmpty ? "保险箱内还没有应用" : "未找到匹配的应用")
                        .font(.system(size: 13, weight: .medium))
                    Text("点击右上角「+ 导入 .app」将第三方独立应用及数据移入加密卷。")
                        .font(.system(size: 12))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .background(ShadcnTokens.card, in: RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
                .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.filteredApps) { app in
                        appRowCard(app)
                    }
                }
            }
        }
    }

    private func appRowCard(_ app: VaultAppRecord) -> some View {
        let isRunning = vm.isAppRunning(app)
        return HStack(spacing: 12) {
            Text(app.initials)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(ShadcnTokens.secondary, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ShadcnTokens.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(app.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("v\(app.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                    if app.mode == .clone {
                        ShadcnBadge(text: "分身", tone: .amber)
                    }
                    ShadcnBadge(
                        text: isRunning ? "运行中" : "已隐身",
                        tone: isRunning ? .emerald : .neutral,
                        showDot: isRunning
                    )
                }
                HStack(spacing: 6) {
                    Text(app.bundleId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                    Text(ByteFormatter.string(from: app.totalSizeBytes))
                        .font(.system(size: 11))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                    if app.mode == .clone {
                        tagPill("独立隔离 HOME")
                    } else {
                        ForEach(app.dataMappings.prefix(3)) { m in
                            tagPill(m.label)
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if app.mode == .move {
                    Button("映射") { vm.inspectingMappingApp = app }
                        .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
                }
                Button(isRunning ? "退出应用" : "启动") {
                    if isRunning { vm.quitApp(app) } else { vm.launchApp(app) }
                }
                .buttonStyle(ShadcnButtonStyle(variant: isRunning ? .secondary : .primary, compact: true))
                if app.mode == .clone {
                    Button("删除分身") {
                        Task { await vm.deleteCloneFromVault(app) }
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .ghost, compact: true))
                    .disabled(isRunning || vm.isWorking)
                } else {
                    Button("还原") {
                        Task { await vm.restoreAppToSystem(app) }
                    }
                    .buttonStyle(ShadcnButtonStyle(variant: .ghost, compact: true))
                    .disabled(isRunning || vm.isWorking)
                }
            }
        }
        .padding(12)
        .background(ShadcnTokens.card, in: RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
        .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))
    }

    // MARK: - View 2: Ingest

    private var ingestView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("导入应用到保险箱")
                    .font(.system(size: 16, weight: .semibold))
                Text("拖入或选择第三方非沙盒 .app，自动识别 Bundle ID 与 ~/Library 数据路径并迁入加密容器。")
                    .font(.system(size: 12))
                    .foregroundStyle(ShadcnTokens.mutedForeground)
            }

            // Dropzone
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 22))
                    .foregroundStyle(ShadcnTokens.mutedForeground)
                Text("拖拽 .app 应用包到此处，或手动选择")
                    .font(.system(size: 13, weight: .semibold))
                Text("自动检测 SIP 系统保护、App Sandbox 沙盒标记与关联数据体积")
                    .font(.system(size: 11.5))
                    .foregroundStyle(ShadcnTokens.mutedForeground)
                Button("从 /Applications 选择 .app") {
                    pickAppFromPanel()
                }
                .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(ShadcnTokens.muted, in: RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
            .overlay(
                RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD)
                    .strokeBorder(ShadcnTokens.border, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }

            // 扫描后自动以弹窗（IngestConfirmSheetView）展示模式选择与确认
        }
    }

    // MARK: - View 3: Security

    private var securityView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("安全与自动锁定")
                    .font(.system(size: 16, weight: .semibold))
                Text("主密码经 stdin 管道直通 hdiutil，不写入日志、配置或剪贴板。")
                    .font(.system(size: 12))
                    .foregroundStyle(ShadcnTokens.mutedForeground)
            }

            if let cfg = vm.hostConfig {
                VStack(spacing: 0) {
                    settingToggleRow(
                        title: "启用 Touch ID 硬件解锁",
                        help: "使用 Secure Enclave 钥匙串（.biometryCurrentSet）封装卷密码，指纹变更自动失效",
                        isOn: Binding(
                            get: { cfg.touchIDEnabled },
                            set: { vm.toggleTouchID($0) }
                        )
                    )
                    Divider()
                    settingToggleRow(
                        title: "目标应用全部退出即自动重锁",
                        help: "退出后等待 1.5s 校验 lsof 句柄，无残留进程时立即撤除软链并 detach 容器",
                        isOn: Binding(
                            get: { cfg.autoLockOnQuit },
                            set: { v in vm.updateHostConfig { $0.autoLockOnQuit = v } }
                        )
                    )
                    Divider()
                    settingToggleRow(
                        title: "系统休眠或锁屏时立即锁定",
                        help: "订阅 willSleep 与 screenIsLocked 通知，优雅终止保险箱内应用并卸载",
                        isOn: Binding(
                            get: { cfg.lockOnSleepOrScreenLock },
                            set: { v in vm.updateHostConfig { $0.lockOnSleepOrScreenLock = v } }
                        )
                    )
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("空闲自动锁定超时").font(.system(size: 13, weight: .medium))
                            Text("无键鼠操作达到设定时长后自动安全卸载").font(.system(size: 11.5)).foregroundStyle(ShadcnTokens.mutedForeground)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { cfg.idleTimeoutMinutes },
                            set: { v in vm.updateHostConfig { $0.idleTimeoutMinutes = v } }
                        )) {
                            Text("5 分钟").tag(5)
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                            Text("关闭").tag(0)
                        }
                        .frame(width: 110)
                    }
                    .padding(14)
                    Divider()
                    settingToggleRow(
                        title: "锁定时顺带清理 QuickLook 缩略图缓存",
                        help: "执行 qlmanage -r cache，减少系统预览缓存中的缩略图残留",
                        isOn: Binding(
                            get: { cfg.clearQuickLookOnLock },
                            set: { v in vm.updateHostConfig { $0.clearQuickLookOnLock = v } }
                        )
                    )
                    Divider()
                    settingToggleRow(
                        title: "登录时自动启动 AppVault",
                        help: "通过 macOS 原生 SMAppService 注册登录项（建议将 AppVault.app 放入 /Applications）",
                        isOn: Binding(
                            get: { vm.launchAtLogin },
                            set: { vm.setLaunchAtLogin($0) }
                        )
                    )
                }
                .background(ShadcnTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
                .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))

                // Maintenance card
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("容器维护与备份").font(.system(size: 13, weight: .medium))
                        Text("定位 .sparsebundle 便于手动备份；压缩空间与改密需在锁定状态执行")
                            .font(.system(size: 11.5))
                            .foregroundStyle(ShadcnTokens.mutedForeground)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("定位容器") {
                            vm.revealContainerInFinder()
                        }
                        .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))

                        Button("压缩空间") {
                            Task { await vm.compactContainer() }
                        }
                        .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
                        .disabled(vm.isWorking)

                        Button("修改主密码") {
                            if vm.isUnlocked {
                                vm.errorMessage = "请先锁定容器后再修改主密码。"
                            } else {
                                vm.showChangePasswordSheet = true
                            }
                        }
                        .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
                    }
                }
                .padding(14)
                .background(ShadcnTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
                .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))
            }
        }
    }

    // MARK: - View 4: Logs

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("活动日志（仅内存保留）")
                        .font(.system(size: 16, weight: .semibold))
                    Text("脱敏记录挂载、软链桥接与锁定事件，应用退出后自动清空。")
                        .font(.system(size: 12))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                }
                Spacer()
                Button("清空记录") { vm.logs.removeAll() }
                    .buttonStyle(ShadcnButtonStyle(variant: .outline, compact: true))
            }

            VStack(spacing: 0) {
                if vm.logs.isEmpty {
                    Text("暂无内存日志记录")
                        .font(.system(size: 12))
                        .foregroundStyle(ShadcnTokens.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    ForEach(vm.logs) { entry in
                        HStack(spacing: 10) {
                            ShadcnBadge(
                                text: badgeLabel(entry.level),
                                tone: badgeTone(entry.level)
                            )
                            Text(entry.message)
                                .font(.system(size: 12))
                            Spacer()
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ShadcnTokens.mutedForeground)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        if entry.id != vm.logs.last?.id { Divider() }
                    }
                }
            }
            .background(ShadcnTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
            .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))
        }
    }

    // MARK: - Helpers

    private func kpiCard(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(ShadcnTokens.mutedForeground)
            Text(value).font(.system(size: 16, weight: .semibold))
            Text(sub).font(.system(size: 10.5)).foregroundStyle(ShadcnTokens.mutedForeground).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(ShadcnTokens.card, in: RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD))
        .overlay(RoundedRectangle(cornerRadius: ShadcnTokens.radiusMD).stroke(ShadcnTokens.border, lineWidth: 1))
    }

    private func tagPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(ShadcnTokens.mutedForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(ShadcnTokens.muted, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ShadcnTokens.border, lineWidth: 1))
    }

    private func settingToggleRow(title: String, help: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(help).font(.system(size: 11.5)).foregroundStyle(ShadcnTokens.mutedForeground)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(14)
    }

    private func badgeLabel(_ level: VaultLogEntry.Level) -> String {
        switch level {
        case .unlock: return "解锁"
        case .lock: return "锁定"
        case .info: return "事件"
        case .warning: return "提示"
        }
    }

    private func badgeTone(_ level: VaultLogEntry.Level) -> ShadcnBadgeTone {
        switch level {
        case .unlock: return .emerald
        case .lock: return .amber
        case .info: return .neutral
        case .warning: return .red
        }
    }

    private func pickAppFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "扫描应用"
        if panel.runModal() == .OK, let url = panel.url {
            vm.inspectAppForIngest(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                vm.inspectAppForIngest(url: url)
            }
        }
        return true
    }
}
