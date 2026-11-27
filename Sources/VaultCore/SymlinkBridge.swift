import Foundation

public enum SymlinkBridgeError: LocalizedError {
    case hostPathOccupiedByRealFile(String)
    case hostPathOccupiedByForeignSymlink(String)
    case vaultTargetMissing(String)
    case linkFailed(source: String, destination: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .hostPathOccupiedByRealFile(let path):
            return "宿主路径已存在真实文件/目录，拒绝覆盖：\(path)"
        case .hostPathOccupiedByForeignSymlink(let path):
            return "宿主路径已存在指向其他位置的软链，拒绝覆盖：\(path)"
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

    /// 为指定应用建立所有已配置的数据软链；若任一失败则自动回滚本次新建的软链。
    public func activateMappings(_ mappings: [DataMapping], mountPoint: URL) throws {
        let fm = FileManager.default
        let libraryRoot = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        var createdLinks: [URL] = []

        do {
            for mapping in mappings {
                let hostURL = mapping.resolvedHostURL(homeDirectory: homeDirectory)
                let vaultURL = mapping.resolvedVaultURL(mountPoint: mountPoint)

                guard PathSafety.isStrictlyContained(hostURL, within: libraryRoot),
                      PathSafety.isStrictlyContained(vaultURL, within: mountPoint) else {
                    throw SymlinkBridgeError.linkFailed(
                        source: hostURL.path,
                        destination: vaultURL.path,
                        underlying: "路径安全校验未通过（疑似路径穿越）"
                    )
                }

                guard fm.fileExists(atPath: vaultURL.path) else {
                    throw SymlinkBridgeError.vaultTargetMissing(vaultURL.path)
                }

                if let attrs = try? fm.attributesOfItem(atPath: hostURL.path) {
                    if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
                        let existingDest = try? fm.destinationOfSymbolicLink(atPath: hostURL.path)
                        let destURL = existingDest.map { URL(fileURLWithPath: $0) }
                        if let destURL, destURL.resolvingSymlinksInPath().path == vaultURL.resolvingSymlinksInPath().path
                            || existingDest == vaultURL.path {
                            continue
                        }
                        // FIX-07：不静默覆盖指向别处的软链
                        throw SymlinkBridgeError.hostPathOccupiedByForeignSymlink(hostURL.path)
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
        let mountRoot = mountPoint.resolvingSymlinksInPath().standardizedFileURL

        for mapping in mappings {
            let hostURL = mapping.resolvedHostURL(homeDirectory: homeDirectory)
            guard let attrs = try? fm.attributesOfItem(atPath: hostURL.path),
                  let fileType = attrs[.type] as? FileAttributeType,
                  fileType == .typeSymbolicLink,
                  let destination = try? fm.destinationOfSymbolicLink(atPath: hostURL.path) else {
                continue
            }
            if PathSafety.destinationIsStrictlyContained(destination, within: mountRoot) {
                try? fm.removeItem(at: hostURL)
            }
        }
    }

    /// 启动自检：清理指向 `~/Library/Caches/.av_<12 hex>` 且已断链的残留软链。
    @discardableResult
    public func cleanupOrphanedSymlinks(in subdirectories: [String] = [
        "Library/Application Support",
        "Library/Preferences",
        "Library/Caches"
    ]) -> Int {
        let fm = FileManager.default
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
                if PathSafety.isAppVaultMountOrphanDestination(dest) && !fm.fileExists(atPath: dest) {
                    if (try? fm.removeItem(at: entry)) != nil {
                        removed += 1
                    }
                }
            }
        }
        return removed
    }
}
