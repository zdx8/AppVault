import Foundation
import AppKit

public struct DiscoveredDataCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let hostRelativePath: String
    public let vaultRelativePath: String
    public let sizeBytes: Int64
    public var selected: Bool

    public init(
        id: String = UUID().uuidString,
        label: String,
        hostRelativePath: String,
        vaultRelativePath: String,
        sizeBytes: Int64,
        selected: Bool = true
    ) {
        self.id = id
        self.label = label
        self.hostRelativePath = hostRelativePath
        self.vaultRelativePath = vaultRelativePath
        self.sizeBytes = sizeBytes
        self.selected = selected
    }
}

public struct AppInspectionResult: Equatable, Sendable {
    public let appURL: URL
    public let displayName: String
    public let bundleId: String
    public let version: String
    public let appSizeBytes: Int64
    public let isSystemProtected: Bool
    public let isSandboxed: Bool
    public let candidates: [DiscoveredDataCandidate]

    public var isEligibleForMove: Bool {
        !isSystemProtected && !isSandboxed
    }

    public var isEligibleForClone: Bool {
        !isSystemProtected
    }
}

public enum AppIngestError: LocalizedError {
    case invalidAppBundle(String)
    case systemAppNotAllowed
    case sandboxedAppBlocked(String)
    case appCurrentlyRunning(String)
    case moveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAppBundle(let path):
            return "无效的 macOS .app 应用包：\(path)"
        case .systemAppNotAllowed:
            return "受 SIP 保护的系统内置应用不可移入保险箱。"
        case .sandboxedAppBlocked(let name):
            return "\(name) 为 Mac App Store 沙盒应用（com.apple.security.app-sandbox），MVP 阶段已阻止跨卷软链迁移以防数据异常。"
        case .appCurrentlyRunning(let name):
            return "\(name) 正在运行，请先完全退出后再执行移入或还原操作。"
        case .moveFailed(let reason):
            return "文件迁移失败：\(reason)"
        }
    }
}

/// 负责解析目标 .app、检测 SIP 与沙盒权限、扫描 ~/Library 数据、迁入加密卷并注销 LaunchServices，以及一键还原。
public final class AppIngestService {
    private let engine: SparseBundleEngine
    private let homeDirectory: URL
    private let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public init(
        engine: SparseBundleEngine = SparseBundleEngine(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.engine = engine
        self.homeDirectory = homeDirectory
    }

    /// 扫描目标 .app 信息、沙盒状态与 ~/Library 关联数据候选列表。
    public func inspectApp(at appURL: URL) throws -> AppInspectionResult {
        let normalizedURL = appURL.standardizedFileURL
        guard normalizedURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: normalizedURL),
              let bundleId = bundle.bundleIdentifier,
              !bundleId.isEmpty else {
            throw AppIngestError.invalidAppBundle(normalizedURL.path)
        }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? normalizedURL.deletingPathExtension().lastPathComponent
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let isSystem = normalizedURL.path.hasPrefix("/System/")
        let isSandboxed = detectAppSandbox(at: normalizedURL)
        let appSize = SparseBundleEngine.directorySize(at: normalizedURL)
        let candidates = discoverLibraryData(displayName: displayName, bundleId: bundleId)

        return AppInspectionResult(
            appURL: normalizedURL,
            displayName: displayName,
            bundleId: bundleId,
            version: version,
            appSizeBytes: appSize,
            isSystemProtected: isSystem,
            isSandboxed: isSandboxed,
            candidates: candidates
        )
    }

    /// 通过 codesign 检测 com.apple.security.app-sandbox 权限标记。
    public func detectAppSandbox(at appURL: URL) -> Bool {
        guard let result = try? engine.runProcess(
            "/usr/bin/codesign",
            arguments: ["-d", "--entitlements", ":-", appURL.path]
        ) else {
            return false
        }
        let combined = result.stdout + "\n" + result.stderr
        if let range = combined.range(of: "com.apple.security.app-sandbox") {
            let tail = combined[range.upperBound...].prefix(60)
            return tail.contains("<true/>")
        }
        return false
    }

    /// 扫描 ~/Library 下与目标应用匹配的 Application Support / Preferences / Caches 目录。
    public func discoverLibraryData(displayName: String, bundleId: String) -> [DiscoveredDataCandidate] {
        let fm = FileManager.default
        let safeBundle = bundleId.replacingOccurrences(of: "/", with: "_")
        var results: [DiscoveredDataCandidate] = []
        var seenHostPaths = Set<String>()

        let probeList: [(label: String, relPath: String, vaultSub: String)] = [
            ("App Support", "Library/Application Support/\(displayName)", "data/\(safeBundle)/AppSupport"),
            ("App Support", "Library/Application Support/\(bundleId)", "data/\(safeBundle)/AppSupportBundleId"),
            ("App Support", "Library/Application Support/\(displayName.lowercased())", "data/\(safeBundle)/AppSupportLower"),
            ("Preferences", "Library/Preferences/\(bundleId).plist", "data/\(safeBundle)/Preferences.plist"),
            ("Caches", "Library/Caches/\(bundleId)", "data/\(safeBundle)/Caches")
        ]

        for probe in probeList {
            let hostURL = homeDirectory.appendingPathComponent(probe.relPath)
            let canonical = hostURL.standardizedFileURL.path
            let dedupKey = canonical.lowercased()
            guard !seenHostPaths.contains(dedupKey) else { continue }
            guard fm.fileExists(atPath: canonical) else { continue }
            if let attrs = try? fm.attributesOfItem(atPath: canonical),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                continue
            }
            seenHostPaths.insert(dedupKey)
            let size = SparseBundleEngine.directorySize(at: hostURL)
            results.append(DiscoveredDataCandidate(
                label: probe.label,
                hostRelativePath: probe.relPath,
                vaultRelativePath: probe.vaultSub,
                sizeBytes: size,
                selected: true
            ))
        }
        return results
    }

    /// 将目标 .app 及选中的关联数据迁入已挂载的加密卷，并注销原路径的 LaunchServices 缓存。
    public func ingestApp(
        inspection: AppInspectionResult,
        selectedCandidates: [DiscoveredDataCandidate],
        mountPoint: URL
    ) throws -> VaultAppRecord {
        if inspection.isSystemProtected {
            throw AppIngestError.systemAppNotAllowed
        }
        if inspection.isSandboxed {
            throw AppIngestError.sandboxedAppBlocked(inspection.displayName)
        }
        if isAppRunning(bundleId: inspection.bundleId) {
            throw AppIngestError.appCurrentlyRunning(inspection.displayName)
        }

        let fm = FileManager.default
        let appsDir = mountPoint.appendingPathComponent("apps", isDirectory: true)
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)

        let appFileName = inspection.appURL.lastPathComponent
        let destAppURL = appsDir.appendingPathComponent(appFileName)

        // 1. 先复制到加密卷
        if fm.fileExists(atPath: destAppURL.path) {
            try fm.removeItem(at: destAppURL)
        }
        do {
            try fm.copyItem(at: inspection.appURL, to: destAppURL)
        } catch {
            throw AppIngestError.moveFailed("复制应用包到加密卷失败：\(error.localizedDescription)")
        }

        // 2. 先移除原 .app（若 /Applications 需管理员权限，自动触发 macOS 原生提权弹窗）；若取消则清理卷内副本且不动 ~/Library
        do {
            try removeItemWithAdminFallback(at: inspection.appURL)
        } catch {
            try? fm.removeItem(at: destAppURL)
            throw AppIngestError.moveFailed("移除原路径 \(inspection.appURL.path) 失败（如取消了管理员授权请重试）：\(error.localizedDescription)")
        }
        unregisterFromLaunchServices(path: inspection.appURL.path)

        // 3. 迁移选中的 ~/Library 关联数据
        var migratedMappings: [DataMapping] = []
        var mappedVaultPaths = Set<String>()
        for candidate in selectedCandidates where candidate.selected {
            let srcURL = homeDirectory.appendingPathComponent(candidate.hostRelativePath)
            let dstURL = mountPoint.appendingPathComponent(candidate.vaultRelativePath)
            guard fm.fileExists(atPath: srcURL.path) else { continue }
            try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dstURL.path) {
                try fm.removeItem(at: dstURL)
            }
            try fm.copyItem(at: srcURL, to: dstURL)
            try fm.removeItem(at: srcURL)

            migratedMappings.append(DataMapping(
                label: candidate.label,
                hostRelativePath: candidate.hostRelativePath,
                vaultRelativePath: candidate.vaultRelativePath,
                sizeBytes: candidate.sizeBytes
            ))
            mappedVaultPaths.insert(candidate.vaultRelativePath)
        }

        // 4. 兼容上次中断重试：若卷内已存在该应用的已迁移数据目录，自动接续映射，避免数据孤立
        let safeBundle = inspection.bundleId.replacingOccurrences(of: "/", with: "_")
        let recoveryProbes: [(label: String, hostRel: String, vaultRel: String)] = [
            ("App Support", "Library/Application Support/\(inspection.displayName)", "data/\(safeBundle)/AppSupport"),
            ("App Support", "Library/Application Support/\(inspection.bundleId)", "data/\(safeBundle)/AppSupportBundleId"),
            ("App Support", "Library/Application Support/\(inspection.displayName.lowercased())", "data/\(safeBundle)/AppSupportLower"),
            ("Preferences", "Library/Preferences/\(inspection.bundleId).plist", "data/\(safeBundle)/Preferences.plist"),
            ("Caches", "Library/Caches/\(inspection.bundleId)", "data/\(safeBundle)/Caches")
        ]
        for probe in recoveryProbes where !mappedVaultPaths.contains(probe.vaultRel) {
            let existingVaultURL = mountPoint.appendingPathComponent(probe.vaultRel)
            let hostURL = homeDirectory.appendingPathComponent(probe.hostRel)
            if fm.fileExists(atPath: existingVaultURL.path) && !fm.fileExists(atPath: hostURL.path) {
                migratedMappings.append(DataMapping(
                    label: probe.label,
                    hostRelativePath: probe.hostRel,
                    vaultRelativePath: probe.vaultRel,
                    sizeBytes: SparseBundleEngine.directorySize(at: existingVaultURL)
                ))
                mappedVaultPaths.insert(probe.vaultRel)
            }
        }

        return VaultAppRecord(
            displayName: inspection.displayName,
            bundleId: inspection.bundleId,
            version: inspection.version,
            originalAppPath: inspection.appURL.path,
            vaultAppRelativePath: "apps/\(appFileName)",
            appSizeBytes: inspection.appSizeBytes,
            dataMappings: migratedMappings
        )
    }

    /// 一键移出还原：撤除软链后，将 .app 与数据完整迁回原位置并重新注册 LaunchServices。
    public func restoreApp(
        record: VaultAppRecord,
        mountPoint: URL,
        symlinkBridge: SymlinkBridge
    ) throws {
        if isAppRunning(bundleId: record.bundleId) {
            throw AppIngestError.appCurrentlyRunning(record.displayName)
        }

        let fm = FileManager.default
        symlinkBridge.deactivateMappings(record.dataMappings, mountPoint: mountPoint)

        // 1. 恢复 .app（若写回 /Applications 需管理员权限，自动触发原生提权弹窗）
        let vaultAppURL = mountPoint.appendingPathComponent(record.vaultAppRelativePath)
        let originalURL = URL(fileURLWithPath: record.originalAppPath)
        if fm.fileExists(atPath: vaultAppURL.path) {
            try copyAppWithAdminFallback(from: vaultAppURL, to: originalURL)
            try fm.removeItem(at: vaultAppURL)
            registerInLaunchServices(path: originalURL.path)
        }

        // 2. 恢复关联数据目录
        for mapping in record.dataMappings {
            let vaultDataURL = mapping.resolvedVaultURL(mountPoint: mountPoint)
            let hostDataURL = mapping.resolvedHostURL(homeDirectory: homeDirectory)
            guard fm.fileExists(atPath: vaultDataURL.path) else { continue }
            if fm.fileExists(atPath: hostDataURL.path) {
                try fm.removeItem(at: hostDataURL)
            }
            try fm.createDirectory(at: hostDataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: vaultDataURL, to: hostDataURL)
            try fm.removeItem(at: vaultDataURL)
        }
    }

    /// 创建加密容器内的应用分身：使用 ditto 完整保留原版 Apple 签名与 Info.plist（防止改 BundleID/重签名导致 Telegram 等应用启动闪退），
    /// 并通过独立加密 HOME 目录 + createsNewApplicationInstance + 精确 PID 追踪实现双开隔离。
    public func cloneApp(
        inspection: AppInspectionResult,
        customDisplayName: String?,
        mountPoint: URL
    ) throws -> VaultAppRecord {
        if inspection.isSystemProtected {
            throw AppIngestError.systemAppNotAllowed
        }

        let fm = FileManager.default
        let cloneUUID = UUID().uuidString.lowercased()
        let shortId = String(cloneUUID.prefix(8))
        let cloneDirRel = "clones/\(shortId)"
        let appFileName = inspection.appURL.lastPathComponent
        let vaultAppRel = "\(cloneDirRel)/\(appFileName)"
        let homeRel = "homes/\(shortId)"

        let destAppURL = mountPoint.appendingPathComponent(vaultAppRel, isDirectory: true)
        let cloneHomeURL = mountPoint.appendingPathComponent(homeRel, isDirectory: true)

        try fm.createDirectory(at: destAppURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destAppURL.path) {
            try fm.removeItem(at: destAppURL)
        }

        // 用 ditto 复制 .app，完整保留原代码签名、符号链接与扩展属性，不破坏应用自校验
        let copyRes = try engine.runProcess("/usr/bin/ditto", arguments: [inspection.appURL.path, destAppURL.path])
        if copyRes.exitCode != 0 {
            try? fm.removeItem(at: destAppURL.deletingLastPathComponent())
            throw AppIngestError.moveFailed("复制分身应用包到加密卷失败：\(copyRes.stderr)")
        }

        let finalDisplayName: String = {
            let trimmed = (customDisplayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(inspection.displayName) (分身)" : trimmed
        }()

        // 初始化分身专属加密 HOME 目录树
        let subDirs = [
            "Library/Application Support",
            "Library/Preferences",
            "Library/Caches",
            "Library/Containers",
            "Documents",
            "Downloads",
            "Desktop"
        ]
        for sub in subDirs {
            try fm.createDirectory(at: cloneHomeURL.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }

        return VaultAppRecord(
            id: cloneUUID,
            displayName: finalDisplayName,
            bundleId: inspection.bundleId,
            version: inspection.version,
            originalAppPath: inspection.appURL.path,
            vaultAppRelativePath: vaultAppRel,
            appSizeBytes: SparseBundleEngine.directorySize(at: destAppURL),
            dataMappings: [],
            mode: .clone,
            cloneHomeRelativePath: homeRel
        )
    }

    /// 删除容器内的分身副本及隔离 HOME 目录（绝不影响原位应用）。
    public func deleteClone(record: VaultAppRecord, mountPoint: URL) throws {
        let fm = FileManager.default
        let appURL = mountPoint.appendingPathComponent(record.vaultAppRelativePath)
        let cloneFolder = appURL.deletingLastPathComponent()
        if fm.fileExists(atPath: cloneFolder.path) && cloneFolder.lastPathComponent != "apps" {
            try fm.removeItem(at: cloneFolder)
        } else if fm.fileExists(atPath: appURL.path) {
            try fm.removeItem(at: appURL)
        }
        if let homeRel = record.cloneHomeRelativePath {
            let homeURL = mountPoint.appendingPathComponent(homeRel)
            if fm.fileExists(atPath: homeURL.path) {
                try fm.removeItem(at: homeURL)
            }
        }
    }

    /// 严格校验允许提权删除/覆盖的路径，防止误删系统或非 .app 目录。
    private func validateAppBundlePathForAdminOp(_ url: URL) throws -> String {
        let path = url.standardizedFileURL.path
        guard !path.contains("\0"),
              path.hasSuffix(".app"),
              path != "/",
              path != "/Applications",
              !path.hasPrefix("/System/"),
              !path.hasPrefix("/usr/"),
              !path.hasPrefix("/bin/"),
              !path.hasPrefix("/sbin/") else {
            throw AppIngestError.moveFailed("安全校验拒绝提权操作非标准 .app 路径：\(path)")
        }
        return path
    }

    private func removeItemWithAdminFallback(at url: URL) throws {
        let safePath = try validateAppBundlePathForAdminOp(url)
        let fm = FileManager.default
        do {
            try fm.removeItem(atPath: safePath)
            return
        } catch {
            let res = try engine.runProcess(
                "/usr/bin/osascript",
                arguments: [
                    "-e", "on run argv",
                    "-e", "do shell script \"/bin/rm -rf \" & quoted form of (item 1 of argv) with administrator privileges",
                    "-e", "end run",
                    "--", safePath
                ]
            )
            guard res.exitCode == 0 else {
                let errText = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppIngestError.moveFailed(errText.isEmpty ? error.localizedDescription : errText)
            }
        }
    }

    private func copyAppWithAdminFallback(from srcURL: URL, to dstURL: URL) throws {
        let safeDst = try validateAppBundlePathForAdminOp(dstURL)
        let safeSrc = srcURL.standardizedFileURL.path
        guard !safeSrc.contains("\0"), safeSrc.hasSuffix(".app") else {
            throw AppIngestError.moveFailed("安全校验拒绝还原非 .app 源路径：\(safeSrc)")
        }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: safeDst) {
                try fm.removeItem(atPath: safeDst)
            }
            try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(atPath: safeSrc, toPath: safeDst)
            return
        } catch {
            let res = try engine.runProcess(
                "/usr/bin/osascript",
                arguments: [
                    "-e", "on run argv",
                    "-e", "do shell script \"/bin/rm -rf \" & quoted form of (item 2 of argv) & \" && /usr/bin/ditto \" & quoted form of (item 1 of argv) & \" \" & quoted form of (item 2 of argv) with administrator privileges",
                    "-e", "end run",
                    "--", safeSrc, safeDst
                ]
            )
            guard res.exitCode == 0 else {
                let errText = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AppIngestError.moveFailed(errText.isEmpty ? error.localizedDescription : errText)
            }
        }
    }

    public func isAppRunning(bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    private func unregisterFromLaunchServices(path: String) {
        _ = try? engine.runProcess(lsregisterPath, arguments: ["-u", path])
    }

    private func registerInLaunchServices(path: String) {
        _ = try? engine.runProcess(lsregisterPath, arguments: ["-f", path])
    }
}
