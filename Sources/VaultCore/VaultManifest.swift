import Foundation

/// 宿主机明文配置（存放于 ~/Library/Application Support/com.appvault.macos/config.json，权限 0600）。
/// 绝不记录任何受管应用的名称、Bundle ID 或数据路径。
public struct HostVaultConfig: Codable, Equatable, Sendable {
    public var vaultId: String
    public var containerPath: String
    public var maxSizeMB: Int
    public var touchIDEnabled: Bool
    public var autoLockOnQuit: Bool
    public var lockOnSleepOrScreenLock: Bool
    public var idleTimeoutMinutes: Int // 0 = 关闭
    public var clearQuickLookOnLock: Bool
    public var panicHotkeyEnabled: Bool
    public var hideDockWhenWindowClosed: Bool
    public var lastMountPoint: String? // 用于异常退出后自检清理
    public var themeMode: String // "light" | "dark"，默认浅色主题
    public var failedUnlockAttempts: Int // 持久化暴力破解退避计数
    public var unlockBlockedUntil: Date? // 持久化冷却截止时间

    public init(
        vaultId: String = UUID().uuidString,
        containerPath: String,
        maxSizeMB: Int = 20480,
        touchIDEnabled: Bool = true,
        autoLockOnQuit: Bool = true,
        lockOnSleepOrScreenLock: Bool = true,
        idleTimeoutMinutes: Int = 15,
        clearQuickLookOnLock: Bool = true,
        panicHotkeyEnabled: Bool = true,
        hideDockWhenWindowClosed: Bool = true,
        lastMountPoint: String? = nil,
        themeMode: String = "light",
        failedUnlockAttempts: Int = 0,
        unlockBlockedUntil: Date? = nil
    ) {
        self.vaultId = vaultId
        self.containerPath = containerPath
        self.maxSizeMB = maxSizeMB
        self.touchIDEnabled = touchIDEnabled
        self.autoLockOnQuit = autoLockOnQuit
        self.lockOnSleepOrScreenLock = lockOnSleepOrScreenLock
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.clearQuickLookOnLock = clearQuickLookOnLock
        self.panicHotkeyEnabled = panicHotkeyEnabled
        self.hideDockWhenWindowClosed = hideDockWhenWindowClosed
        self.lastMountPoint = lastMountPoint
        self.themeMode = themeMode
        self.failedUnlockAttempts = failedUnlockAttempts
        self.unlockBlockedUntil = unlockBlockedUntil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.vaultId = try c.decode(String.self, forKey: .vaultId)
        self.containerPath = try c.decode(String.self, forKey: .containerPath)
        self.maxSizeMB = try c.decodeIfPresent(Int.self, forKey: .maxSizeMB) ?? 20480
        self.touchIDEnabled = try c.decodeIfPresent(Bool.self, forKey: .touchIDEnabled) ?? true
        self.autoLockOnQuit = try c.decodeIfPresent(Bool.self, forKey: .autoLockOnQuit) ?? true
        self.lockOnSleepOrScreenLock = try c.decodeIfPresent(Bool.self, forKey: .lockOnSleepOrScreenLock) ?? true
        self.idleTimeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .idleTimeoutMinutes) ?? 15
        self.clearQuickLookOnLock = try c.decodeIfPresent(Bool.self, forKey: .clearQuickLookOnLock) ?? true
        self.panicHotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .panicHotkeyEnabled) ?? true
        self.hideDockWhenWindowClosed = try c.decodeIfPresent(Bool.self, forKey: .hideDockWhenWindowClosed) ?? true
        self.lastMountPoint = try c.decodeIfPresent(String.self, forKey: .lastMountPoint)
        self.themeMode = try c.decodeIfPresent(String.self, forKey: .themeMode) ?? "light"
        self.failedUnlockAttempts = try c.decodeIfPresent(Int.self, forKey: .failedUnlockAttempts) ?? 0
        self.unlockBlockedUntil = try c.decodeIfPresent(Date.self, forKey: .unlockBlockedUntil)
    }
}

/// 单个关联数据路径映射（位于加密卷内 manifest.json）。
public struct DataMapping: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var hostRelativePath: String
    public var vaultRelativePath: String
    public var sizeBytes: Int64

    public init(
        id: String = UUID().uuidString,
        label: String,
        hostRelativePath: String,
        vaultRelativePath: String,
        sizeBytes: Int64 = 0
    ) {
        self.id = id
        self.label = label
        self.hostRelativePath = hostRelativePath
        self.vaultRelativePath = vaultRelativePath
        self.sizeBytes = sizeBytes
    }

    public func resolvedHostURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(hostRelativePath)
    }

    public func resolvedVaultURL(mountPoint: URL) -> URL {
        mountPoint.appendingPathComponent(vaultRelativePath)
    }
}

/// 应用在保险箱中的运行模式：移入隐藏（原位移除）或加密分身（保留原应用并隔离运行）。
public enum VaultAppMode: String, Codable, Equatable, CaseIterable, Sendable {
    case move
    case clone
}

/// 加密卷内单个受管应用记录。
public struct VaultAppRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var bundleId: String
    public var version: String
    public var originalAppPath: String
    public var vaultAppRelativePath: String
    public var appSizeBytes: Int64
    public var dataMappings: [DataMapping]
    public var addedAt: Date
    public var mode: VaultAppMode
    public var cloneHomeRelativePath: String?

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        bundleId: String,
        version: String,
        originalAppPath: String,
        vaultAppRelativePath: String,
        appSizeBytes: Int64 = 0,
        dataMappings: [DataMapping] = [],
        addedAt: Date = Date(),
        mode: VaultAppMode = .move,
        cloneHomeRelativePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleId = bundleId
        self.version = version
        self.originalAppPath = originalAppPath
        self.vaultAppRelativePath = vaultAppRelativePath
        self.appSizeBytes = appSizeBytes
        self.dataMappings = dataMappings
        self.addedAt = addedAt
        self.mode = mode
        self.cloneHomeRelativePath = cloneHomeRelativePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.bundleId = try c.decode(String.self, forKey: .bundleId)
        self.version = try c.decode(String.self, forKey: .version)
        self.originalAppPath = try c.decode(String.self, forKey: .originalAppPath)
        self.vaultAppRelativePath = try c.decode(String.self, forKey: .vaultAppRelativePath)
        self.appSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .appSizeBytes) ?? 0
        self.dataMappings = try c.decodeIfPresent([DataMapping].self, forKey: .dataMappings) ?? []
        self.addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        self.mode = try c.decodeIfPresent(VaultAppMode.self, forKey: .mode) ?? .move
        self.cloneHomeRelativePath = try c.decodeIfPresent(String.self, forKey: .cloneHomeRelativePath)
    }

    public var totalSizeBytes: Int64 {
        appSizeBytes + dataMappings.reduce(0) { $0 + $1.sizeBytes }
    }

    public var initials: String {
        let cleaned = displayName
            .replacingOccurrences(of: "(分身)", with: "")
            .replacingOccurrences(of: "（分身）", with: "")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !cleaned.isEmpty else { return "AP" }
        let words = cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(cleaned.prefix(2)).uppercased()
    }
}

/// 加密卷内清单（仅在解锁挂载后可读写，路径：<mountpoint>/.vault/manifest.json）。
public struct EncryptedVaultManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var apps: [VaultAppRecord]

    public init(
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        apps: [VaultAppRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.apps = apps
    }
}

/// 仅内存保留的脱敏活动日志。
public struct VaultLogEntry: Identifiable, Equatable, Sendable {
    public enum Level: String, Sendable {
        case unlock
        case lock
        case info
        case warning
    }

    public let id: UUID
    public let timestamp: Date
    public let level: Level
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: Level, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

/// 负责宿主机配置与加密卷内清单的读写。
public final class VaultStorageStore {
    public let appSupportDir: URL
    public let configFileURL: URL
    public let containersDir: URL

    public init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.appvault.macos", isDirectory: true)
        self.appSupportDir = base
        self.configFileURL = base.appendingPathComponent("config.json")
        self.containersDir = base.appendingPathComponent("containers", isDirectory: true)
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: containersDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func defaultContainerURL(vaultId: String) -> URL {
        containersDir.appendingPathComponent("\(vaultId).sparsebundle", isDirectory: true)
    }

    public func loadHostConfig() throws -> HostVaultConfig? {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else { return nil }
        let data = try Data(contentsOf: configFileURL)
        return try JSONDecoder().decode(HostVaultConfig.self, from: data)
    }

    public func saveHostConfig(_ config: HostVaultConfig) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFileURL.path)
    }

    public func manifestURL(in mountPoint: URL) -> URL {
        mountPoint.appendingPathComponent(".vault/manifest.json")
    }

    public func loadManifest(in mountPoint: URL) throws -> EncryptedVaultManifest {
        let url = manifestURL(in: mountPoint)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EncryptedVaultManifest()
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EncryptedVaultManifest.self, from: data)
    }

    public func saveManifest(_ manifest: EncryptedVaultManifest, in mountPoint: URL) throws {
        let fm = FileManager.default
        let vaultMetaDir = mountPoint.appendingPathComponent(".vault", isDirectory: true)
        try fm.createDirectory(at: vaultMetaDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var updated = manifest
        updated.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(updated)
        try data.write(to: manifestURL(in: mountPoint), options: .atomic)
    }
}
