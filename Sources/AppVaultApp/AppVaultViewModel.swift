import Foundation
import SwiftUI
import AppKit
import ServiceManagement
import VaultCore

enum ManagerTab: String, CaseIterable, Identifiable {
    case apps = "保险箱应用"
    case ingest = "导入应用"
    case security = "安全与自动锁"
    case logs = "活动日志"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .ingest: return "tray.and.arrow.down"
        case .security: return "shield"
        case .logs: return "waveform.path.ecg"
        }
    }
}

@MainActor
@Observable
final class AppVaultViewModel {
    // Services
    let store = VaultStorageStore()
    let engine = SparseBundleEngine()
    let authService = KeychainAuthService()
    let symlinkBridge = SymlinkBridge()
    let ingestService: AppIngestService
    let watcher = ProcessWatcher()

    // Core State
    var hostConfig: HostVaultConfig?
    var isUnlocked: Bool = false
    var currentMountPoint: URL?
    var manifest: EncryptedVaultManifest = EncryptedVaultManifest()
    var runningPIDs: [String: pid_t] = [:] // key = VaultAppRecord.id，精确按 PID 追踪分身与移入实例
    var allocatedContainerBytes: Int64 = 0
    var volumeUsedBytes: Int64 = 0
    private var needsCompactOnLock: Bool = false

    func isAppRunning(_ app: VaultAppRecord) -> Bool {
        runningPIDs[app.id] != nil
    }

    // UI Navigation & Sheets
    var selectedTab: ManagerTab = .apps
    var searchText: String = ""
    var showUnlockSheet: Bool = false
    var showSetupSheet: Bool = false
    var showChangePasswordSheet: Bool = false
    var showEnableTouchIDSheet: Bool = false
    var inspectingMappingApp: VaultAppRecord?
    var busyProcessesAlert: [String] = []
    var showBusyAlert: Bool = false

    // Ingest State
    var showIngestSheet: Bool = false
    var currentInspection: AppInspectionResult?
    var ingestCandidates: [DiscoveredDataCandidate] = []
    var ingestMode: VaultAppMode = .move
    var cloneCustomName: String = ""

    // Theme, Security & Feedback
    var themeMode: AppThemeMode = .light
    var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    var isWorking: Bool = false
    var statusBanner: String?
    var errorMessage: String?
    var logs: [VaultLogEntry] = []
    var enableTouchIDPassword: String = ""
    private var failedUnlockAttempts: Int = 0
    private var unlockBlockedUntil: Date? = nil
    private var integrityTimer: Timer? = nil
    private var isLockingInProgress: Bool = false

    // Sheet Form States (避免依赖 SwiftUIMacros @State 插件)
    var sheetLocalError: String?
    var setupPassword: String = ""
    var setupConfirmPassword: String = ""
    var setupMaxSizeGB: Int = 20
    var setupEnableTouchID: Bool = true
    var unlockAuthMode: Int = 0
    var unlockPasswordInput: String = ""
    var unlockCapsLockOn: Bool = false
    var unlockInputSourceName: String = "ABC"
    var changeOldPwd: String = ""
    var changeNewPwd: String = ""
    var changeConfirmPwd: String = ""

    func refreshUnlockHints() {
        let hints = KeychainAuthService.currentInputHints()
        unlockCapsLockOn = hints.capsLockOn
        unlockInputSourceName = hints.inputSourceName
        unlockAuthMode = (hostConfig?.touchIDEnabled == true && hasTouchIDKeyStored) ? 0 : 1
    }

    var hasVaultConfigured: Bool {
        guard let cfg = hostConfig else { return false }
        return FileManager.default.fileExists(atPath: cfg.containerPath)
    }

    var filteredApps: [VaultAppRecord] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return manifest.apps }
        return manifest.apps.filter {
            $0.displayName.lowercased().contains(q) || $0.bundleId.lowercased().contains(q)
        }
    }

    var biometryAvailable: Bool {
        authService.isBiometryAvailable().available
    }

    /// 不在启动或 SwiftUI 渲染期调用 SecItemCopyMatching（避免 Ad-Hoc 签名在旧版登录钥匙串上每次启动都弹出授权密码框）。
    var hasTouchIDKeyStored: Bool {
        hostConfig?.touchIDEnabled == true
    }

    init() {
        self.ingestService = AppIngestService(engine: engine)
        bootstrap()
    }

    func bootstrap() {
        do {
            try store.ensureDirectories()
            hostConfig = try store.loadHostConfig()
            if let saved = hostConfig?.themeMode, let mode = AppThemeMode(rawValue: saved) {
                themeMode = mode
            } else {
                themeMode = .light
            }
            failedUnlockAttempts = hostConfig?.failedUnlockAttempts ?? 0
            unlockBlockedUntil = hostConfig?.unlockBlockedUntil
        } catch {
            errorMessage = "初始化配置失败：\(error.localizedDescription)"
        }

        // 异常退出自检：清理残留挂载点与失效软链
        if var cfg = hostConfig, let stalePath = cfg.lastMountPoint {
            let staleURL = URL(fileURLWithPath: stalePath)
            if engine.isMounted(mountPoint: staleURL) {
                try? engine.unmountVault(mountPoint: staleURL, force: true)
                appendLog(.warning, "启动自检发现异常残留挂载点，已自动安全卸载")
            }
            cfg.lastMountPoint = nil
            try? store.saveHostConfig(cfg)
            hostConfig = cfg
        }

        let cleanedLinks = symlinkBridge.cleanupOrphanedSymlinks()
        if cleanedLinks > 0 {
            appendLog(.warning, "启动自检已清理 \(cleanedLinks) 条异常残留失效软链")
        }

        refreshContainerUsage()
        configureWatcher()

        if !hasVaultConfigured {
            showSetupSheet = true
        }
    }

    // MARK: - Vault Setup

    func createInitialVault(passphrase: String, maxSizeGB: Int, enableTouchID: Bool) async {
        guard !passphrase.isEmpty else {
            errorMessage = "请设置主密码。"
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let vaultId = UUID().uuidString.lowercased()
        let imageURL = store.defaultContainerURL(vaultId: vaultId)
        let maxSizeMB = max(1, maxSizeGB) * 1024

        do {
            try await Task.detached(priority: .userInitiated) { [engine] in
                try engine.createVault(at: imageURL, maxSizeMB: maxSizeMB, passphrase: passphrase)
            }.value

            var touchStored = false
            if enableTouchID && biometryAvailable {
                do {
                    try authService.savePassphrase(passphrase, forVaultId: vaultId)
                    touchStored = true
                } catch {
                    appendLog(.warning, "Touch ID 钥匙串写入未完成（\(error.localizedDescription)），已回退主密码模式")
                }
            }

            let config = HostVaultConfig(
                vaultId: vaultId,
                containerPath: imageURL.path,
                maxSizeMB: maxSizeMB,
                touchIDEnabled: touchStored
            )
            try store.saveHostConfig(config)
            hostConfig = config
            showSetupSheet = false
            refreshContainerUsage()
            appendLog(.info, "已创建 AES-256 APFS 加密容器（上限 \(maxSizeGB) GB）")

            // 创建完成后自动解锁进入主界面
            await unlockWithPassphrase(passphrase, methodLabel: "初始化主密码")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Unlock & Lock

    private func checkSecurityBeforeUnlock() -> Bool {
        if let until = unlockBlockedUntil, until > Date() {
            let remain = Int(ceil(until.timeIntervalSinceNow))
            errorMessage = "密码错误次数过多，请 \(remain) 秒后重试。"
            return false
        }
        if case .failed(let reason) = SecurityHardening.shared.runRuntimeIntegrityCheck() {
            errorMessage = reason
            appendLog(.warning, "运行时防破解自检拦截：\(reason)")
            return false
        }
        return true
    }

    private func recordFailedUnlockAttempt() {
        failedUnlockAttempts += 1
        if failedUnlockAttempts >= 8 {
            unlockBlockedUntil = Date().addingTimeInterval(120)
        } else if failedUnlockAttempts >= 5 {
            unlockBlockedUntil = Date().addingTimeInterval(30)
        } else if failedUnlockAttempts >= 3 {
            unlockBlockedUntil = Date().addingTimeInterval(5)
        }
        if var cfg = hostConfig {
            cfg.failedUnlockAttempts = failedUnlockAttempts
            cfg.unlockBlockedUntil = unlockBlockedUntil
            try? store.saveHostConfig(cfg)
            hostConfig = cfg
        }
    }

    private func startRuntimeIntegrityWatchdog() {
        integrityTimer?.invalidate()
        integrityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isUnlocked else { return }
                if case .failed(let reason) = SecurityHardening.shared.runRuntimeIntegrityCheck() {
                    await self.lockVault(reason: "防破解监控触发自动锁定（\(reason)）", force: true)
                }
            }
        }
    }

    func unlockWithTouchID() async {
        guard let cfg = hostConfig else { return }
        guard checkSecurityBeforeUnlock() else { return }
        isWorking = true
        errorMessage = nil
        do {
            let password = try await authService.retrievePassphraseWithTouchID(forVaultId: cfg.vaultId)
            await unlockWithPassphrase(password, methodLabel: "Touch ID")
        } catch KeychainAuthError.itemNotFound {
            isWorking = false
            showUnlockSheet = false
            showEnableTouchIDSheet = true
            errorMessage = "钥匙串尚未保存该容器密码，请先输入一次主密码完成 Touch ID 绑定。"
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }

    func unlockWithPassphrase(_ passphrase: String, methodLabel: String = "主密码") async {
        guard var cfg = hostConfig else { return }
        guard checkSecurityBeforeUnlock() else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let imageURL = URL(fileURLWithPath: cfg.containerPath)
        let mountPoint = engine.makePrivateMountPoint()

        do {
            try await Task.detached(priority: .userInitiated) { [engine] in
                try engine.mountVault(imageURL: imageURL, mountPoint: mountPoint, passphrase: passphrase)
            }.value

            failedUnlockAttempts = 0
            unlockBlockedUntil = nil

            let loadedManifest = try store.loadManifest(in: mountPoint)
            cfg.lastMountPoint = mountPoint.path
            cfg.failedUnlockAttempts = 0
            cfg.unlockBlockedUntil = nil
            try? store.saveHostConfig(cfg)

            hostConfig = cfg
            currentMountPoint = mountPoint
            manifest = loadedManifest
            isUnlocked = true
            showUnlockSheet = false
            syncRunningState()
            refreshContainerUsage()
            watcher.setIdleTimerActive(true)
            startRuntimeIntegrityWatchdog()
            appendLog(.unlock, "\(methodLabel) 验证通过，已私有隐藏挂载（-nobrowse，0700）")
            notifyBanner("保险箱已解锁")
        } catch {
            recordFailedUnlockAttempt()
            errorMessage = error.localizedDescription
        }
    }

    func lockVault(reason: String = "手动锁定", force: Bool = false) async {
        guard isUnlocked, !isLockingInProgress, let mountPoint = currentMountPoint, var cfg = hostConfig else { return }
        isLockingInProgress = true
        isWorking = true
        errorMessage = nil
        defer {
            isLockingInProgress = false
            isWorking = false
        }
        integrityTimer?.invalidate()
        integrityTimer = nil

        // 强制锁定/退出软件/休眠场景：先优雅关闭所有受管应用，超时后强杀残留进程确保容器可卸载
        if force {
            await terminateAllManagedAppsGracefully()
        } else if !runningPIDs.isEmpty {
            let runningNames = manifest.apps.filter { runningPIDs[$0.id] != nil }.map(\.displayName)
            busyProcessesAlert = runningNames
            showBusyAlert = true
            return
        }

        // 1. 撤除所有已映射的软链
        for app in manifest.apps {
            symlinkBridge.deactivateMappings(app.dataMappings, mountPoint: mountPoint)
        }

        // 2. 卸载加密卷
        do {
            try await Task.detached(priority: .userInitiated) { [engine] in
                try engine.unmountVault(mountPoint: mountPoint, force: force)
            }.value

            if cfg.clearQuickLookOnLock {
                Task.detached(priority: .utility) { [engine] in
                    engine.clearQuickLookCache()
                }
            }

            cfg.lastMountPoint = nil
            try? store.saveHostConfig(cfg)
            hostConfig = cfg
            currentMountPoint = nil
            manifest = EncryptedVaultManifest()
            runningPIDs.removeAll()
            volumeUsedBytes = 0
            isUnlocked = false
            showBusyAlert = false
            watcher.setIdleTimerActive(false)
            appendLog(.lock, "\(reason)：已撤除软链并安全卸载加密容器")
            notifyBanner("保险箱已锁定隐藏")

            if needsCompactOnLock {
                needsCompactOnLock = false
                let imageURL = URL(fileURLWithPath: cfg.containerPath)
                let before = engine.containerAllocatedBytes(at: imageURL)
                Task.detached(priority: .utility) { [engine] in
                    try? engine.compactVault(imageURL: imageURL)
                    let after = engine.containerAllocatedBytes(at: imageURL)
                    let reclaimed = max(0, before - after)
                    await MainActor.run { [weak self] in
                        self?.allocatedContainerBytes = after
                        if reclaimed > 0 {
                            self?.appendLog(.info, "锁定后已自动压缩稀疏卷，回收主机磁盘 \(ByteFormatter.string(from: reclaimed))")
                        }
                    }
                }
            } else {
                refreshContainerUsage()
            }
        } catch VaultEngineError.volumeBusy(let procs) {
            busyProcessesAlert = procs
            showBusyAlert = true
            appendLog(.warning, "卸载受阻：仍有进程占用容器（\(procs.joined(separator: ", "))）")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Launch & Monitor Managed Apps

    func launchApp(_ app: VaultAppRecord) {
        guard isUnlocked, let mountPoint = currentMountPoint else { return }
        do {
            let appURL = mountPoint.appendingPathComponent(app.vaultAppRelativePath)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true

            if app.mode == .clone {
                config.createsNewApplicationInstance = true
                if let homeRel = app.cloneHomeRelativePath {
                    let cloneHomeURL = mountPoint.appendingPathComponent(homeRel, isDirectory: true)
                    try FileManager.default.createDirectory(at: cloneHomeURL, withIntermediateDirectories: true)
                    config.environment = [
                        "HOME": cloneHomeURL.path,
                        "XDG_CONFIG_HOME": cloneHomeURL.appendingPathComponent(".config").path,
                        "XDG_DATA_HOME": cloneHomeURL.appendingPathComponent(".local/share").path,
                        "XDG_CACHE_HOME": cloneHomeURL.appendingPathComponent("Library/Caches").path
                    ]
                }
            } else {
                try symlinkBridge.activateMappings(app.dataMappings, mountPoint: mountPoint)
            }

            let recordId = app.id
            let displayName = app.displayName
            let isClone = (app.mode == .clone)
            let mappingCount = app.dataMappings.count

            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] runningApp, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.errorMessage = "启动 \(displayName) 失败：\(error.localizedDescription)"
                    } else {
                        if let pid = runningApp?.processIdentifier {
                            self.runningPIDs[recordId] = pid
                        }
                        if isClone {
                            self.appendLog(.info, "已启动分身 \(displayName)（独立加密 HOME，PID \(runningApp?.processIdentifier ?? 0)）")
                        } else {
                            self.appendLog(.info, "已建立 \(displayName) 数据软链（\(mappingCount) 项）并启动")
                        }
                        self.notifyBanner("已启动 \(displayName)")
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func quitApp(_ app: VaultAppRecord) {
        if let pid = runningPIDs[app.id], let running = NSRunningApplication(processIdentifier: pid) {
            running.terminate()
            return
        }
        if app.mode == .move {
            for running in NSWorkspace.shared.runningApplications where running.bundleIdentifier == app.bundleId {
                running.terminate()
            }
        }
    }

    private func terminateAllManagedAppsGracefully() async {
        var targets: [NSRunningApplication] = []
        for pid in runningPIDs.values {
            if let proc = NSRunningApplication(processIdentifier: pid), !proc.isTerminated {
                targets.append(proc)
            }
        }
        let moveBundleIds = Set(manifest.apps.filter { $0.mode == .move }.map(\.bundleId))
        for running in NSWorkspace.shared.runningApplications {
            if let bid = running.bundleIdentifier, moveBundleIds.contains(bid),
               !targets.contains(where: { $0.processIdentifier == running.processIdentifier }) {
                targets.append(running)
            }
        }
        guard !targets.isEmpty else { return }
        for app in targets { app.terminate() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        for app in targets where !app.isTerminated {
            app.forceTerminate()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func syncRunningState() {
        guard let mountPath = currentMountPoint?.standardizedFileURL.path else {
            runningPIDs.removeAll()
            return
        }
        var active: [String: pid_t] = [:]
        for running in NSWorkspace.shared.runningApplications {
            guard let bundlePath = running.bundleURL?.standardizedFileURL.path,
                  bundlePath.hasPrefix(mountPath) else { continue }
            if let matched = manifest.apps.first(where: { app in
                bundlePath == currentMountPoint?.appendingPathComponent(app.vaultAppRelativePath).standardizedFileURL.path
            }) {
                active[matched.id] = running.processIdentifier
            }
        }
        runningPIDs = active
    }

    private func handleAppTerminated(bundleId: String, pid: pid_t) {
        guard isUnlocked else { return }
        var matchedRecordId: String? = runningPIDs.first(where: { $0.value == pid })?.key
        if matchedRecordId == nil {
            matchedRecordId = manifest.apps.first(where: { $0.mode == .move && $0.bundleId == bundleId })?.id
        }
        guard let recordId = matchedRecordId else { return }

        runningPIDs.removeValue(forKey: recordId)
        let name = manifest.apps.first(where: { $0.id == recordId })?.displayName ?? bundleId
        appendLog(.info, "检测到保险箱应用 \(name) 已退出（PID \(pid)）")

        guard hostConfig?.autoLockOnQuit == true, runningPIDs.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard self.isUnlocked, self.runningPIDs.isEmpty else { return }
            await self.lockVault(reason: "目标应用已全部退出，自动重锁")
        }
    }

    // MARK: - Ingest & Restore

    func inspectAppForIngest(url: URL) {
        errorMessage = nil
        do {
            let result = try ingestService.inspectApp(at: url)
            currentInspection = result
            ingestCandidates = result.candidates
            cloneCustomName = "\(result.displayName) (分身)"
            // 沙盒应用（如微信）自动切到加密分身模式
            if result.isSandboxed {
                ingestMode = .clone
            }
            showIngestSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelIngest() {
        showIngestSheet = false
        currentInspection = nil
        ingestCandidates = []
        cloneCustomName = ""
    }

    func confirmIngestCurrentApp() async {
        guard isUnlocked, let mountPoint = currentMountPoint, let inspection = currentInspection else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let chosen = ingestCandidates
        let mode = ingestMode
        let customName = cloneCustomName
        do {
            let record: VaultAppRecord
            if mode == .clone {
                record = try await Task.detached(priority: .userInitiated) { [ingestService] in
                    try ingestService.cloneApp(inspection: inspection, customDisplayName: customName, mountPoint: mountPoint)
                }.value
            } else {
                record = try await Task.detached(priority: .userInitiated) { [ingestService] in
                    try ingestService.ingestApp(inspection: inspection, selectedCandidates: chosen, mountPoint: mountPoint)
                }.value
            }

            manifest.apps.removeAll { $0.bundleId == record.bundleId }
            manifest.apps.append(record)
            try store.saveManifest(manifest, in: mountPoint)

            showIngestSheet = false
            currentInspection = nil
            ingestCandidates = []
            cloneCustomName = ""
            selectedTab = .apps
            refreshContainerUsage()
            if mode == .clone {
                appendLog(.info, "已创建加密分身 \(record.displayName)（原应用保留在原位，分身数据隔离于加密卷）")
                notifyBanner("已创建分身 \(record.displayName)")
            } else {
                appendLog(.info, "已将 \(record.displayName) 及 \(record.dataMappings.count) 项数据迁入加密容器并注销 Launchpad")
                notifyBanner("已隐身收容 \(record.displayName)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreAppToSystem(_ record: VaultAppRecord) async {
        guard isUnlocked, let mountPoint = currentMountPoint else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await Task.detached(priority: .userInitiated) { [ingestService, symlinkBridge] in
                try ingestService.restoreApp(record: record, mountPoint: mountPoint, symlinkBridge: symlinkBridge)
            }.value

            manifest.apps.removeAll { $0.id == record.id }
            try store.saveManifest(manifest, in: mountPoint)
            needsCompactOnLock = true
            refreshContainerUsage()
            appendLog(.info, "已将 \(record.displayName) 与关联数据还原回系统（锁定后将自动回收主机磁盘空间）")
            notifyBanner("已还原 \(record.displayName)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteCloneFromVault(_ record: VaultAppRecord) async {
        guard isUnlocked, let mountPoint = currentMountPoint else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await Task.detached(priority: .userInitiated) { [ingestService] in
                try ingestService.deleteClone(record: record, mountPoint: mountPoint)
            }.value

            manifest.apps.removeAll { $0.id == record.id }
            try store.saveManifest(manifest, in: mountPoint)
            needsCompactOnLock = true
            refreshContainerUsage()
            appendLog(.info, "已删除分身 \(record.displayName) 及其卷内隔离数据（锁定后将自动压缩回收主机磁盘）")
            notifyBanner("已删除分身 \(record.displayName)，锁定后自动回收主机空间")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Settings & Maintenance

    func toggleTheme() {
        themeMode = (themeMode == .light) ? .dark : .light
        NSApp?.appearance = themeMode.nsAppearance
        if hostConfig != nil {
            updateHostConfig { $0.themeMode = self.themeMode.rawValue }
        }
    }

    func updateHostConfig(_ mutate: (inout HostVaultConfig) -> Void) {
        guard var cfg = hostConfig else { return }
        mutate(&cfg)
        do {
            try store.saveHostConfig(cfg)
            hostConfig = cfg
            configureWatcher()
        } catch {
            errorMessage = "保存设置失败：\(error.localizedDescription)"
        }
    }

    func toggleTouchID(_ enabled: Bool, currentPassphrase: String? = nil) {
        guard let cfg = hostConfig else { return }
        if !enabled {
            authService.deletePassphrase(forVaultId: cfg.vaultId)
            updateHostConfig { $0.touchIDEnabled = false }
            appendLog(.info, "已关闭 Touch ID 并清除钥匙串中的容器密钥")
            return
        }
        if let pwd = currentPassphrase, !pwd.isEmpty {
            confirmEnableTouchID(passphrase: pwd)
        } else {
            sheetLocalError = nil
            enableTouchIDPassword = ""
            showEnableTouchIDSheet = true
        }
    }

    func confirmEnableTouchID(passphrase: String) {
        guard let cfg = hostConfig, !passphrase.isEmpty else { return }
        do {
            try authService.savePassphrase(passphrase, forVaultId: cfg.vaultId)
            updateHostConfig { $0.touchIDEnabled = true }
            showEnableTouchIDSheet = false
            sheetLocalError = nil
            appendLog(.info, "已将主密码写入系统钥匙串并启用 Touch ID 解锁")
            notifyBanner("已启用 Touch ID 解锁")
        } catch {
            sheetLocalError = error.localizedDescription
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            appendLog(.info, launchAtLogin ? "已开启登录时自动启动" : "已关闭登录时自动启动")
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            errorMessage = "设置登录自启失败（建议将 AppVault.app 放入 /Applications 后重试）：\(error.localizedDescription)"
        }
    }

    func revealContainerInFinder() {
        guard let path = hostConfig?.containerPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func compactContainer() async {
        guard let cfg = hostConfig else { return }
        guard !isUnlocked else {
            errorMessage = "请先锁定容器后再执行空间压缩（hdiutil compact）。"
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let before = engine.containerAllocatedBytes(at: URL(fileURLWithPath: cfg.containerPath))
        do {
            try await Task.detached(priority: .utility) { [engine] in
                try engine.compactVault(imageURL: URL(fileURLWithPath: cfg.containerPath))
            }.value
            refreshContainerUsage()
            let reclaimed = max(0, before - allocatedContainerBytes)
            appendLog(.info, "已执行稀疏卷压缩，回收 \(ByteFormatter.string(from: reclaimed))")
            notifyBanner("空间压缩完成")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func changeMasterPassword(oldPassword: String, newPassword: String) async {
        guard let cfg = hostConfig else { return }
        guard !isUnlocked else {
            errorMessage = "请先锁定容器后再修改主密码。"
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await Task.detached(priority: .userInitiated) { [engine] in
                try engine.changePassphrase(
                    imageURL: URL(fileURLWithPath: cfg.containerPath),
                    oldPassphrase: oldPassword,
                    newPassphrase: newPassword
                )
            }.value
            if cfg.touchIDEnabled {
                try? authService.savePassphrase(newPassword, forVaultId: cfg.vaultId)
            }
            showChangePasswordSheet = false
            appendLog(.info, "已更新加密容器主密码并同步 Touch ID 密钥")
            notifyBanner("主密码已更新")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func configureWatcher() {
        let cfg = hostConfig
        watcher.onManagedAppTerminated = { [weak self] bundleId, pid in
            self?.handleAppTerminated(bundleId: bundleId, pid: pid)
        }
        watcher.onSystemSleepOrLock = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.isUnlocked else { return }
                await self.lockVault(reason: "\(reason)自动锁定", force: true)
            }
        }
        watcher.onIdleTimeout = { [weak self] in
            Task { @MainActor in
                guard let self, self.isUnlocked else { return }
                await self.lockVault(reason: "空闲超时自动锁定", force: false)
            }
        }
        watcher.onPanicHotkey = { [weak self] in
            Task { @MainActor in
                guard let self, self.isUnlocked else { return }
                await self.lockVault(reason: "紧急快捷键（⌃⌥⌘L）触发锁定", force: true)
            }
        }
        watcher.startMonitoring(
            idleTimeoutMinutes: cfg?.idleTimeoutMinutes ?? 15,
            enableSleepAndLock: cfg?.lockOnSleepOrScreenLock ?? true,
            enablePanicHotkey: cfg?.panicHotkeyEnabled ?? true
        )
        watcher.setIdleTimerActive(isUnlocked)
    }

    func refreshContainerUsage() {
        guard let cfg = hostConfig else { return }
        let imageURL = URL(fileURLWithPath: cfg.containerPath)
        let mountPoint = isUnlocked ? currentMountPoint : nil
        Task.detached(priority: .utility) { [engine] in
            let alloc = engine.containerAllocatedBytes(at: imageURL)
            let used = mountPoint.map { engine.volumeUsedBytes(at: $0) }
            await MainActor.run { [weak self] in
                self?.allocatedContainerBytes = alloc
                if let used, self?.isUnlocked == true {
                    self?.volumeUsedBytes = used
                }
            }
        }
    }

    func appendLog(_ level: VaultLogEntry.Level, _ message: String) {
        logs.insert(VaultLogEntry(level: level, message: message), at: 0)
        if logs.count > 100 { logs.removeLast() }
    }

    func notifyBanner(_ text: String) {
        statusBanner = text
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if self.statusBanner == text { self.statusBanner = nil }
        }
    }
}
