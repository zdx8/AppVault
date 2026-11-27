import Foundation

/// 路径 containment 与标识符净化（导入 / 软链 / 提权共用）。
public enum PathSafety {
    /// 拒绝空串、`..`、`/`、绝对路径与控制字符，防止 Info.plist 字段拼出路径穿越。
    public static func sanitizePathComponent(_ raw: String, field: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PathSafetyError.invalidIdentifier(field: field, value: raw)
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed == "." || trimmed == ".."
            || trimmed.contains("..") || trimmed.hasPrefix("~")
            || trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw PathSafetyError.invalidIdentifier(field: field, value: raw)
        }
        return trimmed
    }

    /// Bundle ID：允许字母数字与 `.-_`，仍拒绝路径分隔与 `..`。
    public static func sanitizeBundleId(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PathSafetyError.invalidIdentifier(field: "bundleId", value: raw)
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("..")
            || trimmed.hasPrefix(".") || trimmed.hasPrefix("~")
            || trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw PathSafetyError.invalidIdentifier(field: "bundleId", value: raw)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw PathSafetyError.invalidIdentifier(field: "bundleId", value: raw)
        }
        return trimmed
    }

    /// 解析软链后检查 child 是否严格位于 root 内（root + `/` 边界）。
    public static func isStrictlyContained(_ child: URL, within root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        if childPath == rootPath { return true }
        return childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// 软链 destination 字符串解析后是否严格位于 root 内。
    public static func destinationIsStrictlyContained(_ destination: String, within root: URL) -> Bool {
        let destURL: URL
        if destination.hasPrefix("/") {
            destURL = URL(fileURLWithPath: destination)
        } else {
            destURL = root.appendingPathComponent(destination)
        }
        return isStrictlyContained(destURL, within: root)
    }

    /// 是否匹配 AppVault 私有挂载点断链：`…/Library/Caches/.av_` + 12 位十六进制。
    public static func isAppVaultMountOrphanDestination(_ destination: String) -> Bool {
        let pattern = #"/Library/Caches/\.av_[0-9a-f]{12}(/|$)"#
        return destination.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public enum PathSafetyError: LocalizedError, Equatable {
    case invalidIdentifier(field: String, value: String)
    case pathEscape(path: String, root: String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let field, let value):
            return "非法 \(field)（拒绝路径穿越或控制字符）：\(value)"
        case .pathEscape(let path, let root):
            return "路径越界：\(path) 不在允许根目录 \(root) 内"
        }
    }
}
