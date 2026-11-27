import Foundation

public enum SymlinkBridgeError: LocalizedError {
    case hostPathOccupiedByRealFile(String)
    case vaultTargetMissing(String)
    case linkFailed(source: String, destination: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .hostPathOccupiedByRealFile(let path):
            return "宿主路径已存在真实文件/目录，拒绝覆盖：\(path)"
        case .vaultTargetMissing(let path):
            return "加密卷内目标数据路径不存在：\(path)"
        case .linkFailed(let src, let dst, let err):
            return "建立符号链接失败（\(src) -> \(dst)）：\(err)"
        }
    }
}

/// 负责解锁期建立 ~/Library 软链桥接，以及锁定前安全撤除软链（事务化回滚）。
public final class SymlinkBridge {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// 校验目标路径严格位于指定根目录内，防止 manifest 篡改导致的路径穿越（../）。
    private func isStrictlyContained(_ child: URL, within root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath.hasPrefix(rootPath + "/")
    }

    /// 为指定应用建立所有已配置的数据软链；若任一失败则自动回滚本次新建的软链。
    public func activateMappings(_ mappings: [DataMapping], mountPoint: URL) throws {
        let fm = FileManager.default
        let libraryRoot = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        var createdLinks: [URL] = []

        do {
            for mapping in mappings {
                let hostURL = mapping.resolvedHostURL(homeDirectory: homeDirectory)
                let vaultURL = mapping.resolvedVaultURL(mountPoint: mountPoint)

                guard isStrictlyContained(hostURL, within: libraryRoot),
                      isStrictlyContained(vaultURL, within: mountPoint) else {
                    throw SymlinkBridgeError.linkFailed(
                        source: hostURL.path,
                        destination: vaultURL.path,
                        underlying: "路径安全校验未通过（疑似路径穿越）"
                    )
                }

                guard fm.fileExists(atPath: vaultURL.path) else {
                    throw SymlinkBridgeError.vaultTargetMissing(vaultURL.path)
                }

                // 检查宿主路径是否已存在
                if let attrs = try? fm.attributesOfItem(atPath: hostURL.path) {
                    if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
                        let existingDest = try? fm.destinationOfSymbolicLink(atPath: hostURL.path)
                        if existingDest == vaultURL.path {
                            continue // 已正确链接
                        }
                        try fm.removeItem(at: hostURL)
                    } else {
                        throw SymlinkBridgeError.hostPathOccupiedByRealFile(hostURL.path)
                    }
                }

                try fm.createDirectory(at: hostURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try fm.createSymbolicLink(at: hostURL, withDestinationURL: vaultURL)
                    createdLinks.append(hostURL)
                } catch {
                    throw SymlinkBridgeError.linkFailed(
                        source: hostURL.path,
                        destination: vaultURL.path,
                        underlying: error.localizedDescription
                    )
                }
            }
        } catch {
            for link in createdLinks {
                try? fm.removeItem(at: link)
            }
            throw error
        }
    }

    /// 锁定前安全撤除指向当前加密卷挂载点的符号链接（仅删除确认指向 mountPoint 的软链，绝不误删真实文件）。
    public func deactivateMappings(_ mappings: [DataMapping], mountPoint: URL) {
        let fm = FileManager.default
        let mountPrefix = mountPoint.standardizedFileURL.path

        for mapping in mappings {
            let hostURL = mapping.resolvedHostURL(homeDirectory: homeDirectory)
            guard let attrs = try? fm.attributesOfItem(atPath: hostURL.path),
                  let fileType = attrs[.type] as? FileAttributeType,
                  fileType == .typeSymbolicLink,
                  let destination = try? fm.destinationOfSymbolicLink(atPath: hostURL.path) else {
                continue
            }
            let normalizedDest = URL(fileURLWithPath: destination).standardizedFileURL.path
            if normalizedDest.hasPrefix(mountPrefix) {
                try? fm.removeItem(at: hostURL)
            }
        }
    }

    /// 启动自检：清理因异常崩溃遗留的、指向旧 `.av_` 私有挂载点的失效断链。
    @discardableResult
    public func cleanupOrphanedSymlinks(in subdirectories: [String] = [
        "Library/Application Support",
        "Library/Preferences",
        "Library/Caches"
    ]) -> Int {
        let fm = FileManager.default
        let marker = "/Library/Caches/.av_"
        var removed = 0

        for sub in subdirectories {
            let dirURL = homeDirectory.appendingPathComponent(sub, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) else {
                continue
            }
            for entry in entries {
                guard let attrs = try? fm.attributesOfItem(atPath: entry.path),
                      let fileType = attrs[.type] as? FileAttributeType,
                      fileType == .typeSymbolicLink,
                      let dest = try? fm.destinationOfSymbolicLink(atPath: entry.path) else {
                    continue
                }
                if dest.contains(marker) && !fm.fileExists(atPath: dest) {
                    if (try? fm.removeItem(at: entry)) != nil {
                        removed += 1
                    }
                }
            }
        }
        return removed
    }
}
