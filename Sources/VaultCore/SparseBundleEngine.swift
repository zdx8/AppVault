import Foundation

public enum VaultEngineError: LocalizedError, Equatable, Sendable {
    case emptyPassword
    case containerAlreadyExists(String)
    case containerNotFound(String)
    case mountPointNotEmpty(String)
    case commandFailed(tool: String, exitCode: Int32, stderr: String)
    case volumeBusy(processes: [String])
    case wrongPassword

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "主密码不能为空。"
        case .containerAlreadyExists(let path):
            return "加密容器已存在：\(path)"
        case .containerNotFound(let path):
            return "未找到加密容器：\(path)"
        case .mountPointNotEmpty(let path):
            return "私有挂载点非空，拒绝挂载：\(path)"
        case .wrongPassword:
            return "主密码错误，无法解锁加密容器。"
        case .volumeBusy(let procs):
            let list = procs.isEmpty ? "未知进程" : procs.joined(separator: ", ")
            return "容器仍被进程占用（\(list)），请先关闭相关进程后重试。"
        case .commandFailed(let tool, let code, let stderr):
            return "\(tool) 执行失败（退出码 \(code)）：\(stderr)"
        }
    }
}

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

/// 封装 macOS 原生 AES-256 APFS 稀疏捆绑映像（.sparsebundle）的创建、隐藏挂载、卸载与压缩。
public final class SparseBundleEngine: @unchecked Sendable {
    public init() {}

    /// 过滤 macOS 27 hdiutil 废弃告警行，保留真实错误信息。
    public static func cleanStderr(_ raw: String) -> String {
        let filtered = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hdiutil: WARNING:") }
        return filtered.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : filtered.joined(separator: " ")
    }

    /// 创建新的 AES-256 APFS 加密稀疏捆绑映像，并通过 stdin 管道传入主密码。
    public func createVault(
        at imageURL: URL,
        volumeName: String = "AppVaultData",
        maxSizeMB: Int = 20480,
        passphrase: String
    ) throws {
        guard !passphrase.isEmpty else { throw VaultEngineError.emptyPassword }
        let fm = FileManager.default
        if fm.fileExists(atPath: imageURL.path) {
            throw VaultEngineError.containerAlreadyExists(imageURL.path)
        }
        try fm.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let args = [
            "create",
            "-size", "\(max(100, maxSizeMB))m",
            "-fs", "APFS",
            "-encryption", "AES-256",
            "-type", "SPARSEBUNDLE",
            "-volname", volumeName,
            "-stdinpass",
            imageURL.path
        ]
        let result = try runProcess("/usr/bin/hdiutil", arguments: args, stdinString: passphrase)
        guard result.exitCode == 0 else {
            throw VaultEngineError.commandFailed(tool: "hdiutil create", exitCode: result.exitCode, stderr: Self.cleanStderr(result.stderr))
        }

        _ = try? runProcess("/usr/bin/chflags", arguments: ["hidden", imageURL.path])
    }

    /// 私有隐藏挂载（-nobrowse -noautoopen，挂载点权限 0700），并写入 .metadata_never_index 阻止 Spotlight 索引。
    public func mountVault(
        imageURL: URL,
        mountPoint: URL,
        passphrase: String
    ) throws {
        guard !passphrase.isEmpty else { throw VaultEngineError.emptyPassword }
        let fm = FileManager.default
        guard fm.fileExists(atPath: imageURL.path) else {
            throw VaultEngineError.containerNotFound(imageURL.path)
        }

        if fm.fileExists(atPath: mountPoint.path) {
            let attrs = try fm.attributesOfItem(atPath: mountPoint.path)
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw VaultEngineError.mountPointNotEmpty(mountPoint.path)
            }
            if let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value != getuid() {
                throw VaultEngineError.mountPointNotEmpty(mountPoint.path)
            }
            let contents = (try? fm.contentsOfDirectory(atPath: mountPoint.path)) ?? []
            if !contents.isEmpty {
                throw VaultEngineError.mountPointNotEmpty(mountPoint.path)
            }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mountPoint.path)
        } else {
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        _ = try? runProcess("/usr/bin/chflags", arguments: ["hidden", mountPoint.path])

        let args = [
            "attach",
            "-nobrowse",
            "-noautoopen",
            "-mountpoint", mountPoint.path,
            "-stdinpass",
            imageURL.path
        ]
        let result = try runProcess("/usr/bin/hdiutil", arguments: args, stdinString: passphrase)
        guard result.exitCode == 0 else {
            try? fm.removeItem(at: mountPoint)
            let cleaned = Self.cleanStderr(result.stderr)
            let lower = cleaned.lowercased()
            if lower.contains("authentication error") || lower.contains("passphrase") || lower.contains("invalid") || cleaned.contains("认证失败") {
                throw VaultEngineError.wrongPassword
            }
            throw VaultEngineError.commandFailed(tool: "hdiutil attach", exitCode: result.exitCode, stderr: cleaned)
        }

        let noIndexFile = mountPoint.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: noIndexFile.path) {
            fm.createFile(atPath: noIndexFile.path, contents: Data())
        }
        _ = try? runProcess("/usr/bin/mdutil", arguments: ["-i", "off", mountPoint.path])

        for sub in ["apps", "data", ".vault"] {
            let dir = mountPoint.appendingPathComponent(sub, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// 检查挂载点是否仍有文件句柄被占用，返回占用进程名列表。
    public func busyProcesses(at mountPoint: URL) -> [String] {
        guard let result = try? runProcess("/usr/sbin/lsof", arguments: ["-t", "+D", mountPoint.path]),
              result.exitCode == 0 else {
            return []
        }
        let pids = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if pids.isEmpty { return [] }

        var names: [String] = []
        for pid in Set(pids) {
            if let ps = try? runProcess("/bin/ps", arguments: ["-p", pid, "-o", "comm="]),
               ps.exitCode == 0 {
                let name = URL(fileURLWithPath: ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
                if !name.isEmpty { names.append("\(name) (PID \(pid))") }
            }
        }
        return names.sorted()
    }

    /// 安全卸载加密卷并删除空私有挂载目录（内置瞬时占用重试，兼容中文「资源忙」与退出码 16）。
    public func unmountVault(mountPoint: URL, force: Bool = false) throws {
        if !force {
            let busy = busyProcesses(at: mountPoint)
            if !busy.isEmpty {
                throw VaultEngineError.volumeBusy(processes: busy)
            }
        }
        var args = ["detach", mountPoint.path]
        if force { args.append("-force") }

        let maxAttempts = force ? 2 : 3
        var lastResult = CommandResult(exitCode: 0, stdout: "", stderr: "")
        for attempt in 1...maxAttempts {
            let result = try runProcess("/usr/bin/hdiutil", arguments: args)
            lastResult = result
            if result.exitCode == 0 || !isMounted(mountPoint: mountPoint) {
                try? FileManager.default.removeItem(at: mountPoint)
                return
            }
            let lower = result.stderr.lowercased()
            let isBusy = result.exitCode == 16 || lower.contains("resource busy") || result.stderr.contains("资源忙")
            if isBusy && attempt < maxAttempts {
                Thread.sleep(forTimeInterval: 0.8)
                continue
            }
            if isBusy {
                throw VaultEngineError.volumeBusy(processes: busyProcesses(at: mountPoint))
            }
            throw VaultEngineError.commandFailed(tool: "hdiutil detach", exitCode: result.exitCode, stderr: Self.cleanStderr(result.stderr))
        }
        throw VaultEngineError.commandFailed(tool: "hdiutil detach", exitCode: lastResult.exitCode, stderr: Self.cleanStderr(lastResult.stderr))
    }

    /// 获取指定路径所在文件系统的内核挂载点（通过 POSIX statfs）。
    public func kernelMountPoint(for url: URL) -> String? {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return nil }
        return withUnsafePointer(to: &st.f_mntonname) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// 解析路径的真实物理路径（POSIX realpath）。
    public func canonicalPath(for url: URL) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buf) != nil {
            return String(cString: buf)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 判断指定挂载点当前是否已挂载。
    public func isMounted(mountPoint: URL) -> Bool {
        guard let mnt = kernelMountPoint(for: mountPoint) else { return false }
        let target = canonicalPath(for: mountPoint)
        return mnt == target
    }

    /// 回收稀疏捆绑映像已释放的磁盘空间（必须在锁定未挂载状态调用）。
    public func compactVault(imageURL: URL) throws {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw VaultEngineError.containerNotFound(imageURL.path)
        }
        let result = try runProcess("/usr/bin/hdiutil", arguments: ["compact", imageURL.path])
        guard result.exitCode == 0 else {
            throw VaultEngineError.commandFailed(tool: "hdiutil compact", exitCode: result.exitCode, stderr: Self.cleanStderr(result.stderr))
        }
    }

    /// 修改加密卷主密码（必须在锁定未挂载状态调用）。
    public func changePassphrase(imageURL: URL, oldPassphrase: String, newPassphrase: String) throws {
        guard !oldPassphrase.isEmpty, !newPassphrase.isEmpty else {
            throw VaultEngineError.emptyPassword
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw VaultEngineError.containerNotFound(imageURL.path)
        }
        let payload = oldPassphrase + "\0" + newPassphrase + "\0"
        let result = try runProcess(
            "/usr/bin/hdiutil",
            arguments: ["chpass", "-oldstdinpass", "-newstdinpass", imageURL.path],
            stdinString: payload
        )
        guard result.exitCode == 0 else {
            let cleaned = Self.cleanStderr(result.stderr)
            if cleaned.lowercased().contains("authentication") || cleaned.contains("认证失败") {
                throw VaultEngineError.wrongPassword
            }
            throw VaultEngineError.commandFailed(tool: "hdiutil chpass", exitCode: result.exitCode, stderr: cleaned)
        }
    }

    /// 清理 QuickLook 缩略图缓存。
    public func clearQuickLookCache() {
        _ = try? runProcess("/usr/bin/qlmanage", arguments: ["-r", "cache"])
    }

    /// 生成私有 0700 临时挂载点路径。
    public func makePrivateMountPoint() -> URL {
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent(".av_\(UUID().uuidString.prefix(12).lowercased())", isDirectory: true)
    }

    /// 计算稀疏容器在宿主机上实际占用的磁盘字节数（bands/ 物理大小）。
    public func containerAllocatedBytes(at imageURL: URL) -> Int64 {
        Self.directorySize(at: imageURL)
    }

    /// 计算已挂载加密卷内实际存放的应用、分身与数据字节数。
    public func volumeUsedBytes(at mountPoint: URL) -> Int64 {
        let subdirs = ["apps", "clones", "homes", "data", ".vault"]
        return subdirs.reduce(0) { sum, sub in
            sum + Self.directorySize(at: mountPoint.appendingPathComponent(sub, isDirectory: true))
        }
    }

    public static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
            for case let fileURL as URL in enumerator {
                if let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   vals.isRegularFile == true,
                   let size = vals.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    @discardableResult
    public func runProcess(_ launchPath: String, arguments: [String], stdinString: String? = nil) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LC_ALL": "en_US.UTF-8"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinPipe: Pipe?
        if stdinString != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        }

        try process.run()

        if let stdinString, let stdinPipe {
            // FIX-10：用可覆写 Data 写入后立即清零，减少明文残留于堆的窗口
            var payload = Array(stdinString.utf8)
            payload.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 {
                    stdinPipe.fileHandleForWriting.write(Data(bytes: base, count: raw.count))
                    memset(base, 0, raw.count)
                }
            }
            for i in payload.indices { payload[i] = 0 }
            try? stdinPipe.fileHandleForWriting.close()
        }

        // 并发排空 stdout 与 stderr，彻底规避 64KB 管道缓冲满导致的双向死锁
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
